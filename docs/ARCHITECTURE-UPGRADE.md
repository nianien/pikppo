# Pipeline 架构升级：事件驱动状态机

## 1. 动机

当前 `PhaseRunner` 用 for 循环驱动 phase 执行：

```python
# runner.py 现状
for idx, phase in enumerate(phases_to_run):
    success = self.run_phase(phase, ctx, force=force)
    if not success:
        raise RuntimeError(...)
    # gate 检查...
```

流程顺序硬编码在 `run_pipeline()` 和 `_auto_advance()` 两个 ~180 行的方法里。要加环节（质量评估、segment 重跑、外部触发）需要改引擎循环代码。Gate 暂停用 `return {}` 实现，恢复靠重新调用整个方法。

**目标**：将 pipeline 引擎从"遍历 phase 列表"改为"事件循环 + 转移表查表"。引擎不知道流程长什么样，只负责收到事件 → 查表 → 执行 → 产出新事件。加环节 = 加一行转移规则，引擎代码不动。

---

## 2. 核心模型

```
事件              →  TransitionTable  →  动作          →  新事件
──────────────────────────────────────────────────────────────
pipeline_start    →  execute(extract)  →  执行 extract  →  extract_done
extract_done      →  execute(asr)      →  执行 asr      →  asr_done
asr_done          →  execute(parse)    →  执行 parse    →  parse_done
parse_done        →  gate(src_review)  →  检查/暂停     →  src_review_passed | gate_awaiting
src_review_passed →  execute(mt)       →  执行 mt       →  mt_done
mt_done           →  execute(align)    →  执行 align    →  align_done
align_done        →  gate(trans_review)→  检查/暂停     →  trans_review_passed | gate_awaiting
trans_review_passed → execute(tts)     →  执行 tts      →  tts_done
tts_done          →  execute(mix)      →  执行 mix      →  mix_done
mix_done          →  execute(burn)     →  执行 burn     →  burn_done
burn_done         →  (无转移)                           →  pipeline_done
```

引擎是 `while queue: event = dequeue(); transition = table.lookup(event); result = execute(transition); enqueue(result)` 的循环。

---

## 3. 与现有架构的关系

### 3.1 分层变化

```
之前：
  CLI → PhaseRunner.run_pipeline() [for 循环 + gate 逻辑]
    └→ PhaseRunner.run_phase()     [执行单个 phase]

之后：
  CLI → PipelineEngine.run()       [事件循环 + 查表]
    └→ PhaseRunner.run_phase()     [执行单个 phase，不变]
```

```
+-------------------------------------------------------------+
|  CLI (cli.py)                                               |
|  构建 TransitionTable → 创建 PipelineEngine → engine.run()  |
+-----------------------------+-------------------------------+
                              |
+-----------------------------v-------------------------------+
|  PipelineEngine (pipeline/core/engine.py)        [新]       |
|  事件循环 + TransitionTable 查表 + 事件持久化               |
+-----------------------------+-------------------------------+
                              |
+-----------------------------v-------------------------------+
|  PhaseRunner (pipeline/core/runner.py)           [简化]     |
|  run_phase() / should_run() / resolve_inputs()              |
|  删除 run_pipeline() 和 _auto_advance()                     |
+-----------------------------+-------------------------------+
                              |
+-----------------------------v-------------------------------+
|  Phases / Processors / Manifest / Fingerprints   [不变]     |
+-------------------------------------------------------------+
```

### 3.2 不变的部分

| 组件 | 说明 |
|------|------|
| Phase ABC (`phase.py`) | `requires()` / `provides()` / `run()` 接口不变 |
| 所有 Phase 实现 (`phases/*.py`) | 零改动 |
| 所有 Processor (`processors/`) | 零改动 |
| PhaseRunner.run_phase() | 执行单 phase 的完整逻辑不变（should_run、resolve_inputs、allocate_outputs、manifest 更新、fingerprint） |
| Manifest | `manifest.json` 格式和读写逻辑不变 |
| Fingerprints | 增量执行决策逻辑不变 |
| Workspace 布局 | `input/state/derived/output/` 不变 |
| PipelineConfig | 不变 |

### 3.3 删除的部分

| 方法 | 原位置 | 替代方案 |
|------|--------|---------|
| `PhaseRunner.run_pipeline()` | runner.py:435-535 | `PipelineEngine.run()` |
| `PhaseRunner._auto_advance()` | runner.py:358-433 | TransitionTable 中的 gate 转移规则 |

两个方法共 ~180 行，核心逻辑（for 循环 + `--from`/`--to` 索引计算 + gate 状态检查）全部由转移表和事件循环替代。

---

## 4. 数据结构

### 4.1 PipelineEvent

```python
@dataclass
class PipelineEvent:
    ts: str               # ISO 8601 UTC 时间戳
    kind: str             # 事件类型
    data: dict            # 可扩展的事件数据
    run_id: str           # 本次 run 的短标识
```

**事件命名约定**：

| 模式 | 示例 | 含义 |
|------|------|------|
| `{phase}_done` | `extract_done` | Phase 执行成功（包括被 fingerprint 跳过） |
| `{phase}_error` | `asr_error` | Phase 执行失败 |
| `{gate_key}_passed` | `source_review_passed` | Gate 通过 |
| `gate_awaiting` | - | Gate 暂停等待人工（信息性，不触发转移） |
| `pipeline_start` | - | Pipeline 启动 |
| `pipeline_done` | - | Pipeline 完成/失败/取消 |

**data 字段**（按事件类型）：

```python
# pipeline_start
{"phases": ["extract", "asr", ...], "from_phase": "mt", "to_phase": "burn"}

# phase_done（执行）
{"duration_ms": 32000, "metrics": {"utterances_count": 48}, "skipped": False}

# phase_done（跳过）
{"duration_ms": 0, "metrics": {}, "skipped": True, "reason": "all checks passed"}

# phase_error
{"error_type": "TimeoutError", "error_message": "TOS upload timeout"}

# gate_awaiting
{"gate_key": "source_review", "gate_label": "校准"}

# pipeline_done
{"status": "succeeded", "duration_ms": 185000}  # | "failed" | "cancelled" | "paused"
```

### 4.2 Transition

```python
@dataclass
class Transition:
    trigger: str           # 触发事件 kind
    action: str            # "execute" | "gate"
    target: str            # phase name 或 gate key
    produces: str          # 成功时产出的事件 kind
    force: bool = False    # 是否强制执行（跳过 should_run 检查）
```

### 4.3 TransitionTable

```python
class TransitionTable:
    def __init__(self, transitions: list[Transition]):
        self._table = {t.trigger: t for t in transitions}

    def lookup(self, event_kind: str) -> Transition | None:
        return self._table.get(event_kind)
```

---

## 5. 转移表构建

从现有的 `build_phases()` + `GATE_AFTER` 自动生成：

```python
def build_transition_table(
    phases: list[Phase],
    gates: dict[str, dict],
    *,
    from_phase: str | None = None,
    to_phase: str | None = None,
) -> TransitionTable:
```

**`--from`/`--to` 的实现**：不再是 for 循环中的索引计算，而是修剪转移表。

- `--to burn`：截断转移表，`burn_done` 之后无转移 → 自然结束
- `--from mt`：mt 及之后的 execute 转移标记 `force=True`

**示例**：`--from mt --to burn` 生成的转移表：

```
pipeline_start   → execute(extract, force=False)  → extract_done
extract_done     → execute(asr, force=False)       → asr_done
asr_done         → execute(parse, force=False)     → parse_done
parse_done       → execute(mt, force=True)         → mt_done      ← force 从这里开始
mt_done          → execute(align, force=True)      → align_done
align_done       → execute(tts, force=True)        → tts_done
tts_done         → execute(mix, force=True)         → mix_done
mix_done         → execute(burn, force=True)        → burn_done
                                                      (无转移，结束)
```

`--from` 之前的 phase，`force=False` + `should_run()` 返回 False → 产出 `{phase}_done(skipped=True)` → 转移表查到下一步 → 继续。效果等同于现有的 "skip before --from" 逻辑。

---

## 6. PipelineEngine

```python
class PipelineEngine:
    """事件驱动 pipeline 引擎"""

    def __init__(
        self,
        table: TransitionTable,
        executor: PhaseRunner,
        emitter: EventEmitter,
        ctx: RunContext,
        phases: list[Phase],
    ):
        self.table = table
        self.executor = executor
        self.emitter = emitter
        self.ctx = ctx
        self._phases = {p.name: p for p in phases}
        self._queue: deque[PipelineEvent] = deque()
        self._run_id = EventEmitter.generate_run_id()

    def run(self, *, cancel: threading.Event | None = None) -> dict[str, str]:
        """主事件循环"""
        self._enqueue("pipeline_start", phases=..., ...)

        while self._queue:
            # 取消检查
            if cancel and cancel.is_set():
                self._enqueue("pipeline_done", status="cancelled")
                self._drain_and_emit()
                return {}

            event = self._queue.popleft()
            self.emitter.emit(event)

            transition = self.table.lookup(event.kind)

            if transition is None:
                # 无转移 = 终态或信息性事件
                if event.kind == "pipeline_done":
                    return self._collect_outputs()
                if event.kind.endswith("_error"):
                    self._enqueue("pipeline_done", status="failed")
                    continue
                if event.kind == "gate_awaiting":
                    self._enqueue("pipeline_done", status="paused")
                    continue
                continue

            result_event = self._dispatch(transition)
            if result_event:
                self._enqueue(result_event.kind, **result_event.data)

        return self._collect_outputs()
```

### 6.1 execute 动作

```python
def _do_execute(self, transition: Transition) -> PipelineEvent:
    phase = self._phases[transition.target]
    start = time.monotonic()

    success = self.executor.run_phase(phase, self.ctx, force=transition.force)

    duration_ms = int((time.monotonic() - start) * 1000)

    if success:
        # 从 manifest 读取 metrics（run_phase 已写入）
        phase_data = self.executor.manifest.get_phase_data(phase.name) or {}
        return PipelineEvent(
            kind=transition.produces,
            data={
                "duration_ms": duration_ms,
                "metrics": phase_data.get("metrics", {}),
                "skipped": phase_data.get("skipped", False),
            },
        )
    else:
        phase_data = self.executor.manifest.get_phase_data(phase.name) or {}
        error_data = phase_data.get("error", {})
        return PipelineEvent(
            kind=f"{transition.target}_error",
            data={
                "error_type": error_data.get("type", "Unknown"),
                "error_message": error_data.get("message", ""),
            },
        )
```

### 6.2 gate 动作

```python
def _do_gate(self, transition: Transition) -> PipelineEvent:
    gate_key = transition.target
    gate_status = self.executor.manifest.get_gate_status(gate_key)

    if gate_status == "passed":
        return PipelineEvent(kind=transition.produces, data={"gate_key": gate_key})

    if gate_status == "awaiting":
        # 用户已审阅过（第二次调用 run），标记通过
        self.executor.manifest.update_gate(gate_key, status="passed", finished_at=now_iso())
        self.executor.manifest.save()
        return PipelineEvent(kind=transition.produces, data={"gate_key": gate_key})

    # pending → awaiting，暂停
    gate_def = next((g for g in GATES if g["key"] == gate_key), {})
    self.executor.manifest.update_gate(gate_key, status="awaiting", started_at=now_iso())
    self.executor.manifest.save()
    return PipelineEvent(
        kind="gate_awaiting",
        data={"gate_key": gate_key, "gate_label": gate_def.get("label", "")},
    )
```

---

## 7. 存储架构：SQLite 为 SSOT

### 7.1 设计原则

- **DB（SQLite）是所有元数据的 SSOT**：jobs、events、phase_records、artifacts、gates
- **本地 manifest.json 是缓存**：PhaseRunner 读本地缓存做增量决策（`should_run()`），engine 负责 DB ↔ cache 同步
- **文件系统只存工作区文件**（音频、视频、JSON 数据文件）：未来可迁移到对象存储
- DB 位置：`{drama_dir}/dub/pipeline.db`（drama 级共享，所有集数的元数据在同一个 DB 中）

### 7.2 DB Schema

DB 建模到 **episode 粒度**。utterance 级数据留在文件（dub.json），避免双写。

```sql
-- ── 业务实体 ──

CREATE TABLE dramas (
    id          TEXT PRIMARY KEY,       -- slug，如 "jljw"
    name        TEXT NOT NULL,
    source_lang TEXT NOT NULL DEFAULT 'zh',
    target_lang TEXT NOT NULL DEFAULT 'en',
    base_dir    TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE episodes (
    id          TEXT PRIMARY KEY,       -- "{drama_id}_{episode_num}"
    drama_id    TEXT NOT NULL REFERENCES dramas(id),
    episode_num TEXT NOT NULL,
    video_path  TEXT NOT NULL,
    workspace   TEXT NOT NULL,
    duration_ms INTEGER,
    status      TEXT NOT NULL DEFAULT 'pending',
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    UNIQUE(drama_id, episode_num)
);

-- ── Pipeline 执行 ──

CREATE TABLE jobs (
    id          TEXT PRIMARY KEY,
    episode_id  TEXT NOT NULL REFERENCES episodes(id),
    status      TEXT NOT NULL DEFAULT 'pending',
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE events (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id  TEXT NOT NULL REFERENCES jobs(id),
    run_id  TEXT NOT NULL,
    ts      TEXT NOT NULL,
    kind    TEXT NOT NULL,
    phase   TEXT,
    data    TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_events_job ON events(job_id, run_id);

CREATE TABLE phase_records (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id              TEXT NOT NULL REFERENCES jobs(id),
    phase_name          TEXT NOT NULL,
    version             TEXT NOT NULL,
    status              TEXT NOT NULL,
    started_at          TEXT,
    finished_at         TEXT,
    config_fingerprint  TEXT,
    metrics             TEXT DEFAULT '{}',
    error               TEXT,
    skipped             INTEGER DEFAULT 0,
    UNIQUE(job_id, phase_name)
);

CREATE TABLE artifacts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id       TEXT NOT NULL REFERENCES jobs(id),
    key          TEXT NOT NULL,
    relpath      TEXT NOT NULL,
    kind         TEXT NOT NULL,
    fingerprint  TEXT NOT NULL,
    storage_url  TEXT,
    UNIQUE(job_id, key)
);

CREATE TABLE gates (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id      TEXT NOT NULL REFERENCES jobs(id),
    gate_key    TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    started_at  TEXT,
    finished_at TEXT,
    UNIQUE(job_id, gate_key)
);
```

#### 实体关系

```
dramas 1──N episodes 1──N jobs 1──N events
                       │        │
                       │        ├── 1──N phase_records
                       │        ├── 1──N artifacts
                       │        └── 1──N gates
                       │
                       └── workspace/
                            ├── state/dub.json     ← utterance 数据（文件）
                            ├── input/             ← 不可变资产
                            ├── derived/           ← 可重算中间产物
                            └── output/            ← 最终交付物
```

#### 文件 vs DB 分工

| 数据 | 存储位置 | 理由 |
|------|---------|------|
| 剧集/集元数据 | DB (dramas, episodes) | 结构化查询、状态管理 |
| Pipeline 状态 | DB (jobs, events, phase_records, gates) | 事件驱动、可视化 |
| 文件地址注册 | DB (artifacts) | 统一管理 local_path + storage_url |
| utterance 数据 | 文件 (dub.json) | 文档型、整体操作、避免双写 |
| 角色音色映射 | 文件 (roles.json) | 人工编辑、剧级共享 |
| 媒体文件 | 文件 (*.wav, *.mp4) | 本地缓存 + 远程存储 |

### 7.3 PipelineStore

```python
class PipelineStore:
    """SQLite 存储层"""

    def __init__(self, db_path: Path):
        self.conn = sqlite3.connect(str(db_path))
        self._init_schema()

    # ── 业务实体 ──
    def ensure_drama(self, drama_id, *, name, base_dir): ...
    def ensure_episode(self, episode_id, *, drama_id, episode_num, video_path, workspace): ...

    # ── Pipeline 执行 ──
    def create_job(self, job_id, *, episode_id): ...
    def update_job_status(self, job_id, status): ...
    def insert_event(self, event: PipelineEvent, job_id: str): ...
    def upsert_phase_record(self, job_id, phase_name, **kw): ...
    def upsert_artifact(self, job_id, key, relpath, kind, fingerprint, storage_url=None): ...
    def upsert_gate(self, job_id, gate_key, status, **kw): ...

    # ── 查询 ──
    def get_job(self, job_id) -> dict | None: ...
    def get_events(self, job_id, *, run_id=None) -> list[dict]: ...
    def get_episodes(self, drama_id) -> list[dict]: ...
    def get_episode_artifacts(self, episode_id) -> list[dict]: ...
```

### 7.4 DB ↔ Manifest 同步（Stage 1 渐进策略）

Stage 1 保持 PhaseRunner 读写 manifest.json 不变，由 engine 负责同步：

```
phase 执行前:  engine → manifest.update_phase(running) → manifest.save()
phase 执行后:  engine → manifest (已由 run_phase 更新)
              engine → store.upsert_phase_record(...)   ← 从 manifest 同步到 DB
              engine → store.upsert_artifact(...)       ← 从 manifest 同步到 DB
```

这样 PhaseRunner.run_phase() 完全不改，DB 同步是 engine 层的附加动作。

### 7.5 多次执行的时间线

同一个 job 的多次 run 通过 `run_id` 区分：

```
Run a1b2 (14:01):  extract ✓  asr ✗(timeout)  → failed
Run c3d4 (14:05):  extract ⊘  asr ✓  parse ✓  → paused (source_review)
Run e5f6 (15:30):  source_review ✓  mt ✓  align ✓  → paused (translation_review)
Run g7h8 (16:00):  translation_review ✓  tts ✓  mix ✓  burn ✓  → succeeded
```

前端从 DB events 表查询重建完整的执行历史。

### 7.6 manifest.json 的角色演化

| 阶段 | manifest.json | SQLite |
|------|-------------|--------|
| Stage 1（本次） | PhaseRunner 读写（不变），engine 同步到 DB | events + phase_records + artifacts |
| Stage 2（Web） | 由 DB 生成（只读缓存） | SSOT for all metadata |
| Stage 3（云） | 不再需要 | 迁移到 Cloud SQL / Firestore |

---

## 8. EventEmitter

```python
class EventEmitter:
    def __init__(self, store: PipelineStore | None = None):
        self._listeners: list[Callable] = []
        self._store = store

    def on(self, listener): ...
    def emit(self, event: PipelineEvent, job_id: str): ...  # 写 DB + 通知 listener

    @staticmethod
    def generate_run_id() -> str: ...           # 短 UUID (8 hex chars)

class LogListener:
    """将 PipelineEvent 转成 [INFO]/[ERROR] 格式输出到 stdout/stderr"""
    def __call__(self, event: PipelineEvent): ...
```

CLI 使用：
```python
store = PipelineStore(db_path)
emitter = EventEmitter(store=store)
emitter.on(LogListener())
```

Web 使用（未来）：
```python
emitter.on(LogListener())
emitter.on(lambda e: websocket.send_json(asdict(e)))  # 实时推送
```

---

## 9. CLI 适配

`cli.py` 的 `run_one()` 变化：

```python
def run_one(video_path, args, config):
    workdir = get_workdir(video_path)
    workdir.mkdir(parents=True, exist_ok=True)
    manifest = Manifest(workdir / "manifest.json")

    # 存储 + 事件系统
    store = PipelineStore(workdir.parent / "pipeline.db")
    emitter = EventEmitter(store=store)
    emitter.on(LogListener())

    # 转移表
    phases = build_phases(config)
    table = build_transition_table(
        phases, GATE_AFTER,
        from_phase=args.from_phase,
        to_phase=args.to,
    )

    # 引擎
    job_id = str(uuid.uuid4())
    store.ensure_job(job_id, drama=..., episode=workdir.name, workspace=str(workdir))
    executor = PhaseRunner(manifest, workdir)
    ctx = RunContext(job_id=job_id, workspace=str(workdir), config=config_dict)
    engine = PipelineEngine(table, executor, emitter, ctx, phases, store=store)
    outputs = engine.run()
```

---

## 10. 演化路线

### Stage 1（本次）

事件驱动状态机引擎 + SQLite 持久化。

- 线性 pipeline 通过自动生成的 TransitionTable 执行
- `--from`/`--to` 通过修剪转移表实现
- Gate 作为转移规则中的 gate 动作处理
- SQLite 存储所有元数据（events、phase_records、artifacts、gates）
- manifest.json 保留作为 PhaseRunner 本地缓存，engine 同步到 DB
- CLI 行为不变

### Stage 2（Web 平台）

Web 层对接事件系统。

- `emitter.on(WsListener)` 将事件推送到 WebSocket
- 前端从 events.jsonl 重建时间线
- Gate 暂停后，Web 端显示校准 UI，用户完成后通过 API 恢复 pipeline
- 外部事件注入：`engine.inject("source_review_approved")`

### Stage 3（智能 Agent）

转移表中加入质量评估和条件分支。

```python
# 质量评估节点
Transition("asr_done",     "evaluate", "asr_quality",  produces="asr_eval_pass")
Transition("asr_eval_fail", "execute",  "asr",          produces="asr_done")

# Segment 级重跑
Transition("mt_done",         "evaluate", "mt_quality",    produces="mt_eval_pass")
Transition("mt_eval_retry",   "execute",  "mt_segment",    produces="mt_segment_done")

# 条件分支（Transition 加 condition 字段）
Transition("tts_done", "execute", "mix",
           condition=lambda data: data.get("failed_count", 0) == 0)
Transition("tts_done", "execute", "tts_retry_failed",
           condition=lambda data: data.get("failed_count", 0) > 0)
```

引擎代码不动，只加转移规则。

---

## 11. 文件变更汇总

| 文件 | 操作 | 估计行数 |
|------|------|---------|
| `src/dubora/pipeline/core/store.py` | 新建 | ~150 行 |
| `src/dubora/pipeline/core/events.py` | 新建 | ~80 行 |
| `src/dubora/pipeline/core/engine.py` | 新建 | ~180 行 |
| `src/dubora/pipeline/core/runner.py` | 修改（删除 run_pipeline + _auto_advance） | -180 行 |
| `src/dubora/cli.py` | 修改（run_one 用 engine + store） | ~25 行变更 |

净代码量：~410 行新增，~180 行删除，净 +230 行。

不动：所有 Phase、所有 Processor、Manifest（manifest.py）、types.py、fingerprints.py、Phase ABC、web API、schema/。
