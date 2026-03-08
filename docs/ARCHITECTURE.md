# Dubora Architecture Document

> 本文档为新 session 提供完整的架构参考。基于 2026-03 重构后的 DB-first 架构。

---

## 1. 整体架构

### 1.1 Pipeline 流程

```
Stage:  提取      识别              翻译              配音              合成
Phase:  extract → asr → parse  →  translate  →  tts → align → mix  →  burn
Gate:                        ↑              ↑
                      source_review   translation_review
```

8 个 Phase + 2 个 Gate，5 个 Stage。

| Phase | 职责 | 技术 |
|-------|------|------|
| extract | 提取音频 + 人声/伴奏分离 | FFmpeg + Demucs v4 |
| asr | 语音识别 + 说话人分离 | Doubao ASR (ByteDance) |
| parse | ASR 后处理 → DB cues (含 reseg + emotion) | 本地 + LLM |
| translate | 增量翻译 (utterance 级, per-cue 回填) | OpenAI / Gemini |
| tts | 语音合成 (增量, voice_hash 判脏) | VolcEngine seed-tts-1.0 |
| align | drift_score 安全阀 + 生成 en.srt | 本地 |
| mix | 混音 (adelay timeline placement) | FFmpeg |
| burn | 烧字幕到视频 | FFmpeg subtitles filter |

### 1.2 Task 执行架构

```
submit_pipeline()  → 写第一个 task 到 DB，退出
PipelineReactor    → 监听 task_succeeded 事件，创建下一个 task
PipelineWorker     → 全局 worker，轮询 DB 取 pending task，执行
```

分离原则：提交方 (CLI/Web) 只写 DB；Worker (独立线程) 只读+执行。

Worker.tick() 流程：
1. `claim_any_pending_task()` — 原子地把 pending → running
2. 构建 RunContext (workdir, config, store, episode_id)
3. PhaseRunner.run_phase() 执行
4. 成功 → complete_task + emit task_succeeded → Reactor 创建下一个 task
5. 失败 → fail_task + emit task_failed → Reactor 设 episode status=failed

### 1.3 Gate 机制

Gate 在指定 phase 完成后暂停，等待人工确认。

```python
GATES = [
    {"key": "source_review",      "after": "parse",     "label": "校准"},
    {"key": "translation_review", "after": "translate",  "label": "审阅"},
]
```

- parse 完成后 → 创建 source_review gate task (status=pending) → episode status=review
- 用户通过 Web UI 确认 → `pass_gate_task()` → gate task status=succeeded → Reactor 继续
- translate 完成后 → 同理 translation_review

### 1.4 Phase/Processor 分层

- **Phase** (`pipeline/phases/`): 编排层 — 文件 I/O、DB 读写、错误处理。实现 `Phase` 抽象类。
- **Processor** (`pipeline/processors/`): 无状态业务逻辑 — 纯计算，无文件 I/O。可独立测试。

---

## 2. 表结构

### 2.1 核心表关系

```
dramas (1) ──┬── (N) episodes (1) ──┬── (N) cues
             │                      ├── (N) utterances
             │                      ├── (N) tasks
             │                      └── (N) artifacts
             ├── (N) roles
             └── (N) dictionary
                         utterance_cues (junction: utterance ↔ SRC cues)
```

### 2.2 cues 表 — 原子段

```sql
CREATE TABLE cues (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id   INTEGER NOT NULL REFERENCES episodes(id),
    type         TEXT NOT NULL DEFAULT 'SRC',    -- 'SRC' 或 'DST'
    text         TEXT NOT NULL DEFAULT '',        -- 中文原文 (SRC) 或英文 (DST)
    text_en      TEXT NOT NULL DEFAULT '',        -- SRC cue 上的英文翻译
    start_ms     INTEGER NOT NULL,
    end_ms       INTEGER NOT NULL,
    speaker      TEXT NOT NULL DEFAULT '',        -- 实际存 roles.id 的整数字符串
    emotion      TEXT NOT NULL DEFAULT 'neutral',
    gender       TEXT,
    kind         TEXT NOT NULL DEFAULT 'speech',  -- 'speech' 或 'singing'
    cv           INTEGER NOT NULL DEFAULT 1,      -- content version
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
```

**类型约定：**
- `type='SRC'`: 来自 ASR，用户可编辑。text=中文，text_en=翻译。
- `type='DST'`: 由 translate phase 从 SRC.text_en 生成，用于 SRT 字幕。
- `speaker`: SQLite 列类型为 TEXT，但存储 roles.id 的整数字符串 (如 "10001")。应用层通过 `_cast_speaker()` 读取时转为 int。
- `cv`: content version，text/speaker/start_ms/end_ms/emotion/kind/gender 变化时 cv++。

**cv 机制 (diff_and_save)：**
```
用户编辑 cue → diff_and_save() → 对比 _CV_FIELDS → 变了 → cv++ → 触发 calculate_utterances → 可能产生新 utterance (source_hash=NULL → 触发重翻)
text_en 编辑 → 不 bump cv (翻译审阅编辑)，但更新 voice_hash
```

### 2.3 utterances 表 — 分组壳 + TTS 缓存

```sql
CREATE TABLE utterances (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id      INTEGER NOT NULL REFERENCES episodes(id),
    text_cn         TEXT NOT NULL DEFAULT '',    -- 冗余缓存：合并自 sub-cues
    text_en         TEXT NOT NULL DEFAULT '',    -- 冗余缓存：合并自 sub-cues text_en
    speaker         TEXT NOT NULL DEFAULT '',    -- roles.id 整数字符串
    emotion         TEXT NOT NULL DEFAULT 'neutral',
    gender          TEXT,
    kind            TEXT NOT NULL DEFAULT 'speech',
    tts_policy      TEXT,                        -- JSON: {max_rate, allow_extend_ms}
    source_hash     TEXT,                        -- 翻译判脏用
    voice_hash      TEXT,                        -- TTS 判脏用
    audio_path      TEXT,                        -- TTS 输出路径
    tts_duration_ms INTEGER,
    tts_rate        REAL,
    tts_error       TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
```

**关键字段语义：**
- `text_cn`, `text_en`: 冗余缓存，不是 SSOT。真值在 cues 表。由 `sync_utterance_text_cache()` 同步。
- `source_hash`: 翻译判脏。SHA256(合并 sub-cue text)[:16]。translate phase 翻译成功后写入。
- `voice_hash`: TTS 判脏。SHA256(text_en|speaker|emotion)[:16]。TTS phase 合成成功后写入。
- `tts_policy`: JSON 字符串 `{"max_rate": 1.3, "allow_extend_ms": 500}`。由 translate phase 根据 utterance 间隙计算。
- `start_ms`, `end_ms`: **不存储在表中**，由 `get_utterances()` 从 junction 关联的 cues 实时计算。

### 2.4 utterance_cues 表 — 关联表

```sql
CREATE TABLE utterance_cues (
    utterance_id INTEGER NOT NULL REFERENCES utterances(id),
    cue_id       INTEGER NOT NULL REFERENCES cues(id),
    PRIMARY KEY (utterance_id, cue_id)
);
```

由 `calculate_utterances()` 管理。utterance 本身不存 start_ms/end_ms，从关联的 cues 实时计算。

### 2.5 roles 表 — 角色声线映射

```sql
CREATE TABLE roles (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    drama_id    INTEGER NOT NULL REFERENCES dramas(id),
    name        TEXT NOT NULL,         -- 角色名 (如 "平安")
    voice_type  TEXT NOT NULL DEFAULT '', -- 音色 ID (如 "zh_male_jieshuonansheng_mars_bigtts")
    UNIQUE(drama_id, name)
);
```

**speaker 用 role.id 的完整链路：**
```
ASR 输出 speaker="0","1" → parse phase: ensure_role(drama_id, "0") → role.id=10001
→ cue.speaker = "10001" (TEXT 列存整数字符串)
→ 前端读取: _cast_speaker() → speaker=10001 (int)
→ SpeakerBadge 显示: roles.find(r => r.id === cue.speaker)?.name
→ TTS: dub_manifest_from_utterances → DubUtterance.speaker=str(10001)="10001"
→ voice_assignment["speakers"]["10001"] = {voice_type: "..."}
→ volcengine.py: speakers.get(speaker) → 匹配
```

### 2.6 其他表

| 表 | 用途 |
|---|------|
| dramas | 剧集 (name, synopsis) |
| episodes | 集数 (drama_id, name, path, status) |
| tasks | 任务队列 (type=phase name 或 gate key, status=pending/running/succeeded/failed) |
| events | 审计日志 (task 生命周期事件) |
| artifacts | episode 级文件注册表 (key, relpath, fingerprint) |
| dictionary | 术语表 (drama_id, type=name/slang, src, target) |

---

## 3. 各 Phase 执行逻辑

### 3.1 parse — ASR 后处理

```
ASR raw response (JSON) → parse_utterances() → SubtitleModel
→ 转 AsrModel segments → reseg (LLM 断句优化) → emotion_correct (LLM 情绪修正)
→ 为每个 speaker 调 ensure_role() 创建角色 (speaker name → role.id)
→ 写入 SRC cues 到 DB (speaker 存 role.id 字符串)
```

- 清空旧 cues + utterances 后全量写入
- speaker_to_role_id 映射: `{ASR speaker name → role.id}`

### 3.2 calculate_utterances — Greedy Merge

由 `store.calculate_utterances()` 执行（在 translate phase 和 diff_and_save 中调用）。

```
SRC cues (按 start_ms 排序) → 贪心合并:
  同 speaker + 同 emotion + gap ≤ 500ms + 总时长 ≤ 10000ms → 合入同组
  否则 → 新组

每组算 cue_id 集合 (frozenset)，与 DB 现有 utterance 的 cue_id 集合对比:
  - 匹配 → 保留 (TTS 缓存复用)
  - 不匹配 → 新建 utterance (source_hash=NULL → 标记为脏 → 触发翻译)
  - 多余 → 删除
```

关键设计：**用 cue_id 集合匹配**，不用 source_hash。这保证了 TTS 缓存的精确复用。

### 3.3 translate — 增量翻译

```
1. calculate_utterances() 合并 SRC cues → utterances + junction
2. get_dirty_utterances_for_translate() 找脏行:
   - source_hash 为 NULL (从未翻译)
   - source_hash 不匹配 (cues 内容变了)
   - 任何 sub-cue 的 text_en 为空
3. 对每个脏 utterance:
   - 单 cue → 直接翻译
   - 多 cue → 编号格式 [1] text1\n[2] text2 送 LLM，返回 per-cue 翻译
   - 写 cue.text_en
4. 计算 tts_policy (根据 utterance 间隙)
5. 更新 utterance: text_en cache + source_hash + tts_policy
6. _sync_dst_cues: 从 SRC cue.text_en 创建 DST cues (用于字幕)
```

**Name Guard 机制：**
- 提取中文人名 → 替换为占位符 `<<NAME_1>>` → 翻译 → 还原为英文名
- 英文名从 dictionary 表 (type='name') 查找
- 缺失的名字通过 LLM 补全

### 3.4 tts — 增量语音合成

```
1. 读所有 utterances，构建 full DubManifest
2. get_dirty_utterances_for_tts() 找脏行 (voice_hash 不匹配)
3. 无脏行 → no-op
4. _check_voice_assignment(): 检查所有 speaker(role_id) 在 roles 表中有 voice_type
   - 未分配 → 返回错误 "以下角色未分配音色"
5. 构建 dirty-only DubManifest
6. tts_run_per_segment(): VolcEngine API 合成
7. 更新 DB: audio_path, tts_duration_ms, tts_rate, voice_hash
```

**voice_assignment 构建 (str-keyed)：**
```python
# roles_map: {10001: "zh_male_..."} (int → str)
str_roles_map = {str(k): v for k, v in roles_map.items()}
# processor 中: voice_assignment["speakers"]["10001"] = {"voice_type": "zh_male_..."}
# DubManifest 中: DubUtterance.speaker = str(u.get("speaker", "")) = "10001"
# volcengine.py: speakers.get(speaker) 用 speaker str key 查找，匹配
```

### 3.5 align — Drift 检查 + SRT 生成

```
1. 读 utterances (有 text_en 的)
2. drift_score = tts_duration_ms / physical_ms → > 1.1 则警告
   - drift 警告中显示角色名: role_names.get(int(speaker_id), str(speaker_id))
3. 读 DST cues → 生成 en.srt
```

### 3.6 mix — 混音

```
1. 读所有 utterances (无 tts_error 的)
2. 构建 DubManifest (使用 dub_manifest_from_utterances)
3. 读 singing cues (kind='singing') → 保留原始人声时间窗
4. adelay filter 进行 timeline placement (每个 TTS segment 按 start_ms 定位)
5. 混合: accompaniment + TTS + (可选)原始 vocals (ducking 模式)
6. apad + atrim 强制精确时长
7. 校验输出时长 (tolerance ±50ms)
```

### 3.7 burn — 烧字幕

```
mix.audio + subs.en_srt → FFmpeg subtitles filter → dubbed video
```

---

## 4. Dirty 判脏机制

### 4.1 source_hash — 翻译判脏

```python
def _compute_source_hash(src_cues: list[dict]) -> str:
    """子 cue text 合并后的 SHA256[:16]。"""
    merged = "".join(c.get("text", "") for c in src_cues)
    return sha256(merged.encode()).hexdigest()[:16]
```

**触发翻译的条件 (get_dirty_utterances_for_translate)：**
1. `source_hash IS NULL` → 从未翻译 (新 utterance)
2. `source_hash != _compute_source_hash(当前 sub-cues)` → 中文文本变了
3. 任何 sub-cue 的 `text_en` 为空 → 翻译不完整

**source_hash 写入时机：** translate phase 翻译成功后。

**source_hash 不在 calculate_utterances 中更新** — 只有 translate phase 才写。这样新 utterance 的 source_hash=NULL，自动标记为脏。

### 4.2 voice_hash — TTS 判脏

```python
def _compute_voice_hash(text_en: str, speaker: str = "", emotion: str = "") -> str:
    """text_en + speaker + emotion 的 SHA256[:16]。"""
    data = f"{text_en}|{speaker}|{emotion}"
    return sha256(data.encode()).hexdigest()[:16]
```

**触发 TTS 的条件 (get_dirty_utterances_for_tts)：**
- `voice_hash != _compute_voice_hash(当前 text_en, speaker, emotion)`
- 即 text_en、speaker(role_id)、emotion 任一变化 → 重新合成

**voice_hash 写入时机：** TTS phase 合成成功后。

**voice_hash 中的 speaker 值：**
- 之前: 角色名字符串 (如 "平安")
- 现在: role.id 字符串 (如 "10001")
- 迁移后一次性 hash 变化 → 全量 TTS 重跑（预期行为，之后稳定）
- id 和 name 都唯一标识同一角色，hash 稳定性等价

### 4.3 cv (content version) — 前端编辑判脏

```python
_CV_FIELDS = ("text", "speaker", "start_ms", "end_ms", "emotion", "kind", "gender")
# diff_and_save: 对比上述字段，变了 → cv++
# text_en 变化不 bump cv (翻译审阅编辑)
```

cv 变化 → `calculate_utterances()` 可能生成新 utterance → source_hash=NULL → 触发翻译。

### 4.4 sync_utterance_text_cache

用户在前端编辑 cue.text_en → `diff_and_save()` → `sync_utterance_text_cache()`:
- 重算 utterance 的 text_cn/text_en 缓存
- 如果 text_en 变了 → 更新 voice_hash → TTS 判脏

---

## 5. 前端显示规则

### 5.1 数据类型

```typescript
interface Cue {
  speaker: number      // roles.id FK (从 API 返回时已转 int)
  // ...
}

interface Role {
  id: number
  name: string
  voice_type: string
}
```

### 5.2 Speaker 显示

- **SpeakerBadge**: `roles.find(r => r.id === cue.speaker)?.name ?? String(cue.speaker)`
- **颜色**: `deriveSpeakers(cues)` 返回 `number[]` (去重, 保持出现顺序)，speaker 在数组中的 index 决定颜色
- **无效角色**: `roles.length > 0 && !roles.some(r => r.id === cue.speaker)` → 红色边框警告
- **切换角色**: 下拉列表展示 `role.name`，选中后 `updateCue(id, { speaker: role.id })`
- **新建角色**: 先 `saveRoles()` 获取真实 id，再 `updateCue(id, { speaker: newId })`

### 5.3 Roles API

```
GET  /episodes/{drama}/roles  → {"roles": [{id, name, voice_type}, ...]}
PUT  /episodes/{drama}/roles  → body: {"roles": [{id?, name, voice_type}, ...]}
     有 id → 更新, 无 id → 新建, 缺失 → 删除
```

### 5.4 Voice Casting 页面 (VoicePreview)

- `roles: Role[]` state
- assigned/unassigned 按 `role.voice_type` 是否为空分组
- 分配音色: `roles.map(r => r.id === selectedRole ? {...r, voice_type: voiceId} : r)`
- 新建角色: `{id: -Date.now(), name, voice_type: ''}`（负数临时 ID，保存时 DB 分配真实 ID）

### 5.5 快捷键 (useKeyboard)

- 1-9: 快速切换 speaker (`speakerList[idx]`，已是 number)
- Ctrl+B: 分割 cue
- Ctrl+M: 合并 cue
- Ctrl+I: 插入空 cue (默认 speaker: `refCue?.speaker ?? 0`)
- Delete/Backspace: 删除 cue
- Alt+Arrow: 微调 cue 边界 ±30ms
- Shift+Alt+Arrow: 吸附 cue 边界到播放位置

### 5.6 Undo/Redo

- Command 模式: `{apply, inverse, description}`
- 所有 cue 操作通过 `useUndoableOps()` hook
- `changeSpeaker(id, oldSpeaker: number, newSpeaker: number)`

### 5.7 Auto-save

- cue 修改后 2 秒自动保存 (`scheduleAutoSave`)
- 保存调用 `diff_and_save()` → cv bump → calculate_utterances → sync_utterance_text_cache

---

## 6. 技术债

### 6.1 SQLite TEXT 列存 int 的类型不一致

- `cues.speaker` 和 `utterances.speaker` 列类型为 TEXT，存储整数字符串
- 应用层通过 `_cast_speaker()` 转 int，但 SQL 查询时仍为字符串比较
- 理想方案：ALTER TABLE 改列类型（SQLite 不支持，需 recreate table）
- 当前方案可工作，`_cast_speaker()` 保证了应用层一致性

### 6.2 store.py 中的遗留方法

以下方法已被新的 id-keyed 方法替代，但尚未删除：
- `get_roles_map()` — 被 `get_roles_by_id()` 替代 (TTS 用)
- `upsert_role()` — 被 `ensure_role()` 和 `set_roles_by_list()` 替代
- `delete_role()` — 被 `set_roles_by_list()` 的删除逻辑替代
- `set_roles()` — 被 `set_roles_by_list()` 替代

### 6.3 DubManifest.speaker 类型

- `DubUtterance.speaker` 声明为 `str`
- `dub_manifest_from_utterances()` 中显式 `speaker=str(u.get("speaker", ""))` 转换
- 因为 DB 读出的 speaker 经 `_cast_speaker()` 已是 int，必须显式 str() 才能匹配 voice_assignment 的 str key

### 6.4 _probe_duration_ms 重复定义

- `translate.py`, `tts.py`, `mix.py` 各有一份相同的 `_probe_duration_ms()` 函数
- 应提取为公共 util

### 6.5 utterances.start_ms / end_ms 不存储

- `get_utterances()` 每次从 junction + cues 实时计算 start_ms/end_ms
- utterances 表无 start_ms/end_ms 列（新 schema 设计如此）
- 如果查询频繁可考虑冗余存储，但当前性能可接受

### 6.6 Gate task 与 Phase task 混在 tasks 表

- tasks.type 既可以是 phase name (如 "tts") 也可以是 gate key (如 "source_review")
- Worker 只 claim phase names，gate tasks 由 Web API `pass_gate_task()` 处理
- 不是严重问题，但可读性欠佳

### 6.7 emotion 快捷键与 speaker 数字键冲突

- 1-9 切换 speaker，n/a/s/e/i/f 切换 emotion
- 如果 emotion 快捷键字母刚好是某些常用文字输入，可能误触
- 已有 `isInput` 检查排除输入框内的触发
