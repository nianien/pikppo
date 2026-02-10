# PIKPPO - 国产短剧本地化方案

## 1. 项目定位

将中文短剧（竖屏 9:16，单集 2-5 分钟）自动转化为英文配音版本。

**输入**：单集 mp4 视频（无剧本、无角色表）

**输出**：
- 英文配音成片（多角色声线、保留 BGM）
- 英文字幕（硬烧到视频）

**设计原则**：
- 效果优先：宁可慢，也要质量稳定
- 在线服务为主：ASR/MT/TTS 全在线，仅人声分离在本地
- 声线池模式：不做原演员克隆，用预定义声线池区分角色
- 可重跑：每步产物落盘，支持局部重跑和人工干预

---

## 2. 系统架构

### 2.1 Pipeline 总览

```
demux → sep → asr → sub → [人工校验] → mt → align → tts → mix → burn
  │       │      │      │                  │      │       │      │      │
  │       │      │      │                  │      │       │      │      └─ burn.video (成片)
  │       │      │      │                  │      │       │      └─ mix.audio (混音)
  │       │      │      │                  │      │       └─ tts/segments/ (逐句音频)
  │       │      │      │                  │      └─ dub_manifest.json (SSOT)
  │       │      │      │                  └─ mt_output.jsonl
  │       │      │      └─ subtitle.model.json (SSOT)
  │       │      └─ asr-result.json
  │       └─ vocals.wav / accompaniment.wav
  └─ audio.wav
```

9 个阶段严格线性执行，通过 `manifest.json` 记录状态和指纹，支持增量跑。

### 2.2 CLI 用法

```bash
vsd run video.mp4 --to burn                    # 全流程
vsd run video.mp4 --from mt --to tts           # 从 mt 强制重跑到 tts
vsd run video.mp4 --to burn                    # 增量跑（已完成的阶段自动跳过）
vsd bless video.mp4 sub                        # 手动编辑产物后刷新指纹
```

### 2.3 核心数据流（三个 SSOT）

| SSOT | 产出阶段 | 消费阶段 | 说明 |
|------|---------|---------|------|
| `asr-result.json` | asr | sub | ASR 原始响应，包含 word 级时间戳、speaker、emotion |
| `subtitle.model.json` | sub | mt, align | 字幕数据源，utterance + cue 结构，支持人工校验 |
| `dub_manifest.json` | align | tts, mix | 配音时间轴，包含翻译文本、时长预算、voice 映射 |

### 2.4 文件布局

```
videos/dbqsfy/              # 剧级目录
├── 1.mp4                   # 原视频
├── dub/
│   ├── speakers_to_role.json    # 剧级：speaker → 角色名（人工填写）
│   ├── role_to_voice.json       # 剧级：角色名 → voice_type（人工填写）
│   ├── dict/
│   │   └── slang.json           # 剧级：行话词典
│   └── 1/                       # 集级 workspace
│       ├── manifest.json        # Pipeline 状态机
│       ├── asr-result.json      # ASR 原始输出
│       ├── subtitle.model.json  # 字幕 SSOT（可人工编辑后 bless）
│       ├── dub_manifest.json    # 配音 SSOT
│       ├── mt_input.jsonl       # MT 输入
│       ├── mt_output.jsonl      # MT 输出
│       ├── en.srt               # 英文字幕（burn 阶段消费）
│       ├── zh.srt               # 中文字幕（仅供参考）
│       ├── voice-assignment.json # 声线分配快照（debug 用）
│       ├── audio/
│       │   ├── 1.wav            # 原始音频
│       │   ├── 1-vocals.wav     # 人声
│       │   ├── 1-vocals-16k.wav # 人声 16k（ASR 用）
│       │   ├── 1-accompaniment.wav # 伴奏
│       │   └── 1-mix.wav        # 最终混音
│       └── tts/
│           ├── segments/        # 逐句 TTS 音频
│           └── tts_report.json  # TTS 合成报告
```

---

## 3. Pipeline Framework

### 3.1 Phase 接口

每个 Phase 实现三个方法：

```python
class Phase(ABC):
    name: str
    version: str  # 逻辑变更时递增，触发重跑

    def requires(self) -> List[str]:   # 输入 artifact keys
    def provides(self) -> List[str]:   # 输出 artifact keys
    def run(ctx, inputs, outputs) -> PhaseResult
```

Phase 只声明输出，Runner 负责路径分配、指纹计算和 manifest 注册。

### 3.2 增量执行（should_run 决策）

Runner 的 7 级检查决定是否跳过：

1. `force` 标记（`--from` 指定的阶段及之后）
2. manifest 中无记录 → 跑
3. `phase.version` 变化 → 跑
4. 输入 artifact 指纹变化（上游产物内容变了） → 跑
5. config 指纹变化 → 跑
6. **输出文件指纹不匹配** → 跑（人工编辑会触发）
7. status != succeeded → 跑

**`vsd bless` 命令**：人工编辑 subtitle.model.json 后，运行 `vsd bless video.mp4 sub` 刷新 manifest 中的输出指纹，避免 sub 阶段被重跑。

### 3.3 Processor / Phase 分离

- **Processor**：无状态纯业务逻辑，不做文件 I/O
- **Phase**：编排层，负责读输入、调 processor、写输出、更新 manifest

---

## 4. 各阶段实现

### 4.1 Demux（音频提取）

| | |
|---|---|
| **输入** | 原视频 mp4 |
| **输出** | `demux.audio` → WAV (16k, mono, PCM s16le) |
| **实现** | ffmpeg 一行命令 |

### 4.2 Sep（人声分离）

| | |
|---|---|
| **输入** | `demux.audio` |
| **输出** | `sep.vocals` (人声), `sep.vocals_16k` (16k 人声), `sep.accompaniment` (伴奏) |
| **实现** | Demucs htdemucs v4（本地 GPU/CPU） |

**问题与取舍**：
- Demucs 是 pipeline 中最慢的环节（2 分钟音频需 3-10 分钟 CPU）
- 但它显著提升 ASR 准确率和混音质量，值得
- 未来可用 GPU 加速或换更快的分离模型

### 4.3 ASR（语音识别 + 说话人分离）

| | |
|---|---|
| **输入** | `demux.audio` |
| **输出** | `asr.asr_result` → JSON (原始 ASR 响应) |
| **服务** | 豆包大模型 ASR (ByteDance) |
| **预设** | `asr_vad_spk`（VAD 分句 + Speaker Diarization） |

**流程**：
1. 音频上传至 TOS（火山引擎对象存储），基于内容哈希去重
2. 调用豆包 ASR API（submit → poll query）
3. 返回 word 级时间戳 + speaker 标签 + emotion/gender

**问题与取舍**：
- 原始设计用 Google STT，实际切换到豆包 ASR（中文识别更准、成本更低）
- Diarization 存在误判：同一人物可能被分为多个 speaker（需人工校验 subtitle.model.json）
- 短句/语气词容易 speaker 漂移

### 4.4 Sub（字幕模型生成）

| | |
|---|---|
| **输入** | `asr.asr_result` |
| **输出** | `subs.subtitle_model` (SSOT v1.2), `subs.zh_srt`, `subs.en_srt`（首次为空） |
| **核心逻辑** | Utterance Normalization → Subtitle Model Build → SRT Render |

**Subtitle Model v1.2 结构**：

```json
{
  "schema": {"name": "subtitle.model", "version": "1.2"},
  "audio": {"lang": "zh-CN", "duration_ms": 167000},
  "utterances": [
    {
      "utt_id": "utt_0001",
      "speaker": "spk_1",
      "start_ms": 5280,
      "end_ms": 6520,
      "text": "坐牢十年，",
      "emotion": {"label": "sad", "confidence": 0.85},
      "gender": "male",
      "speech_rate": {"zh_tps": 4.2},
      "cues": [
        {"start_ms": 5280, "end_ms": 6520, "source": {"lang": "zh", "text": "坐牢十年，"}}
      ]
    }
  ]
}
```

**Utterance Normalization**：ASR 的 utterance 边界不稳定，normalization 从 word 级时间戳重建边界：
- 基于静音间隔（>300ms）拆分
- 最大时长约束（避免超长 utterance）
- 附加标点：ASR word 级数据无标点，从 utterance 文本反推附加到 word

**问题与取舍**：
- ASR 的 speaker 标签偶有错误，需人工在 subtitle.model.json 中修正
- 修正后用 `vsd bless video.mp4 sub` 刷新指纹，再从 mt 重跑
- Word 级 ASR 无标点是已知限制，当前用启发式方法从 utterance 文本附加

**副作用**：Sub 阶段完成后会自动更新 `speakers_to_role.json`（剧级文件），收集本集出现的所有 speaker。

### 4.5 MT（机器翻译）

| | |
|---|---|
| **输入** | `subs.subtitle_model` |
| **输出** | `mt.mt_input` (JSONL), `mt.mt_output` (JSONL) |
| **服务** | OpenAI GPT-4o / Google Gemini 2.0 Flash |

**翻译策略**：
- 按 utterance 粒度逐句翻译（不做整集批翻）
- 整集上下文从 `asr-result.json` 的 `result.text` 获取
- Per-utterance 词典匹配：只在当前句命中时才注入 glossary 到 prompt
- 条件性领域提示：只在当前句包含牌桌关键词时才注入赌博语境提示

**词典系统** (`dub/dict/slang.json`)：
```json
{
  "三条": "three of a kind",
  "胡了": "I've won!",
  "给钱给钱": "Pay up!"
}
```

**问题与取舍**：
- 早期设计用全局 glossary 注入（"MUST follow EXACTLY"），导致非牌桌台词被污染（"哈哈哈，师傅" → "Got your ace right here"）
- 已修复为 per-utterance 匹配 + 条件领域提示，消除交叉污染
- 原始设计有 `<sep>` 分隔符和 `<<NAME_i:原文>>` 占位符方案，实际实现简化为直接翻译

### 4.6 Align（时间轴对齐 + 重断句）

| | |
|---|---|
| **输入** | `subs.subtitle_model`, `mt.mt_output`, `demux.audio` |
| **输出** | `subs.subtitle_align`, `subs.en_srt`, `dub.dub_manifest` |

**核心职责**：
1. 将英文翻译映射回原始中文时间轴
2. 计算 TTS 时长预算（`budget_ms = end_ms - start_ms`）
3. 允许 `end_ms` 微延长（不超过 200ms，不与下一句重叠）
4. 在 utterance 内重断句生成 en.srt 的字幕条
5. 生成 `dub_manifest.json`（TTS 和 Mix 的输入合约）

**DubManifest 结构**：

```json
{
  "audio_duration_ms": 167000,
  "utterances": [
    {
      "utt_id": "utt_0001",
      "start_ms": 5280, "end_ms": 6520,
      "budget_ms": 1240,
      "text_zh": "坐牢十年，",
      "text_en": "Ten years in prison...",
      "speaker": "spk_1",
      "tts_policy": {"max_rate": 1.3}
    }
  ]
}
```

### 4.7 TTS（语音合成）

| | |
|---|---|
| **输入** | `dub.dub_manifest`, speakers_to_role.json, role_to_voice.json |
| **输出** | `tts.segments_dir` (逐句 WAV), `tts.report`, `tts.voice_assignment` |
| **服务** | 火山引擎 TTS (VolcEngine seed-tts-1.0) |

**两层声线映射**：

```
subtitle.model.json    speakers_to_role.json    role_to_voice.json     VolcEngine API
    spk_1          →       "Ping_An"        →     voice_type:           → speaker 参数
                                                "en_male_adam_mars_bigtts"
```

1. `speakers_to_role.json`（集级 → 剧级，人工填写）：`spk_1` → `"Ping_An"`
2. `role_to_voice.json`（剧级，人工填写）：`"Ping_An"` → `{voice_type: "en_male_adam_mars_bigtts"}`
3. TTS 阶段 resolve：读两层映射，得到每个 speaker 的 voice_type

**合成流程**：
- 并行逐句合成（默认 4 workers）
- 静音裁剪（trim silence）
- 语速调整：若 TTS 时长超过 budget，加速到 max_rate（1.3x）
- Episode 级缓存：相同 text + voice 的 TTS 结果复用

**问题与取舍**：
- 原始设计用 Azure Neural TTS（8 条固定美式声线池），实际切换到火山引擎 TTS（成本更低、中文生态更好）
- volcengine.py 之前有 bug：读取嵌套 `voice_info.get("voice", {}).get("voice_id")`，实际数据是扁平结构，已修复为直接读 `voice_type`
- 原始设计用 pitch 检测自动判断性别 → 实际采用人工指定（更准确、更可控）

### 4.8 Mix（混音）

| | |
|---|---|
| **输入** | `dub.dub_manifest`, `tts.segments_dir`, `tts.report`, `sep.accompaniment` |
| **输出** | `mix.audio` |
| **实现** | FFmpeg adelay + amix |

**Timeline-First 架构**：
- 用 FFmpeg `adelay` 滤镜将每段 TTS 精确放置到时间轴位置
- 不做全局拼接后拉伸（这是 v0 的致命 bug）
- 伴奏轨 + TTS 轨混合，TTS 播放时伴奏自动压低（ducking）
- `apad + atrim` 强制输出与原音频等长

**问题与取舍**：
- v0 用"全部 TTS concat → 全局 time-stretch"，导致字幕时间越来越偏
- v1 改为逐段 adelay 精确放置，彻底解决对齐问题
- 混音目标：-16 LUFS（短视频标准），True Peak -1.5 dB

### 4.9 Burn（字幕烧录）

| | |
|---|---|
| **输入** | `mix.audio`, `subs.en_srt` |
| **输出** | `burn.video` → 最终成片 mp4 |
| **实现** | FFmpeg subtitles 滤镜硬烧 |

原视频画面 + 混音音频 + 英文字幕 → 成片。

---

## 5. 外部服务依赖

| 服务 | 用途 | 环境变量 | 成本预估 |
|------|------|---------|---------|
| **豆包 ASR** | 中文语音识别 + 说话人分离 | `DOUBAO_APPID`, `DOUBAO_ACCESS_TOKEN` | ~¥0.05/分钟 |
| **火山引擎 TOS** | 音频文件存储（ASR 需要） | `TOS_ACCESS_KEY_ID`, `TOS_SECRET_ACCESS_KEY` | 极低 |
| **火山引擎 TTS** | 英文语音合成 | 同豆包 credentials | ~¥0.02/千字符 |
| **OpenAI** | 翻译（GPT-4o / 4o-mini） | `OPENAI_API_KEY` | ~$0.003-0.01/集 |
| **Gemini** | 翻译（备选引擎） | `GEMINI_API_KEY` | 类似 |
| **Demucs** | 人声分离 | 本地 | 免费（CPU/GPU 计算） |
| **FFmpeg** | 音频/视频处理 | 本地 | 免费 |

单集总成本约 ¥0.3-0.5（不含计算资源）。

---

## 6. 已解决的问题

### 6.1 字幕时间对不上（v0 → v1）
- **根因**：v0 将所有 TTS 段无缝 concat 后全局 time-stretch，gap 丢失导致越来越偏
- **解决**：v1 Timeline-First 架构，用 adelay 逐段精确放置

### 6.2 人物音色全乱（v0 → v1）
- **根因**：v0 用 pitch 检测自动判性别，短剧场景（混响/情绪大）下 pyin 频繁失败
- **解决**：v1 改为人工指定 speakers_to_role + role_to_voice，100% 可控

### 6.3 翻译污染（"师傅" → "Got your ace right here"）
- **根因**：全局 glossary（"MUST follow EXACTLY"）+ 全局赌博领域提示污染所有句子
- **解决**：per-utterance glossary 匹配 + 条件领域提示，只在命中时注入

### 6.4 中文字幕标点丢失
- **根因**：ASR word 级数据无标点，NormalizedUtterance.text 直接 join words 导致标点消失
- **解决**：`_attach_trailing_punctuation()` 从 utterance 文本反推标点附加到对应 word

### 6.5 手动编辑触发重跑
- **根因**：should_run 检查输出文件指纹，手动编辑 → 指纹不匹配 → 阶段重跑覆盖编辑
- **解决**：`vsd bless` 命令刷新 manifest 指纹

---

## 7. 当前限制与未来改进

### 7.1 Speaker Diarization 准确率
- **现状**：ASR diarization 偶有错误，需人工校验 subtitle.model.json
- **改进方向**：
  - Voiceprint 阶段（已有框架）：用声纹嵌入做 speaker re-identification
  - 跨集 speaker 一致性：同一角色在不同集保持同一 speaker ID

### 7.2 翻译质量
- **现状**：逐句翻译，缺乏跨句上下文理解
- **改进方向**：
  - 滑动窗口：翻译时带入前后 N 句
  - 术语自动抽取：从整集 ASR 文本自动构建 glossary
  - 翻译一致性校验：同一人名/术语在全集中保持一致

### 7.3 TTS 自然度
- **现状**：声线池模式，不做原演员克隆
- **改进方向**：
  - Voice cloning（ICL 模式）：用原演员音频片段做参考
  - 情绪控制：根据 ASR emotion 标签调整 TTS 情绪参数
  - 语速自适应：根据原始语速动态调整 TTS 语速

### 7.4 Pipeline 自动化
- **现状**：需要人工填写 speakers_to_role.json 和 role_to_voice.json
- **改进方向**：
  - 自动性别检测 → 自动分配声线池
  - Web UI：可视化编辑 speaker 映射和翻译结果
  - 批量处理：整剧自动化（多集并行）

### 7.5 性能
- **现状**：Demucs 是瓶颈（CPU 模式下 2 分钟音频需 3-10 分钟）
- **改进方向**：
  - GPU 加速 Demucs
  - TTS 缓存优化：跨集复用高频短句
  - 并行化：多集同时处理

---

## 8. 安装与配置

### 8.1 依赖安装

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dub]"
```

### 8.2 环境变量 (.env)

```bash
# 豆包 ASR + TTS
DOUBAO_APPID=your_appid
DOUBAO_ACCESS_TOKEN=your_access_token

# TOS 存储
TOS_ACCESS_KEY_ID=your_key
TOS_SECRET_ACCESS_KEY=your_secret
TOS_REGION=cn-beijing
TOS_BUCKET=pikppo-video

# 翻译引擎（二选一或都配）
OPENAI_API_KEY=sk-xxx
GEMINI_API_KEY=xxx
```

### 8.3 剧级配置

运行前需在 `videos/{剧名}/dub/` 下准备：

1. `role_to_voice.json`：角色 → 声线映射
2. `dict/slang.json`：行话词典（可选）

`speakers_to_role.json` 由 sub 阶段自动生成，人工填写 speaker → 角色名。

---

## 9. 典型工作流

```bash
# 1. 首次全流程（到 sub 暂停）
vsd run videos/dbqsfy/1.mp4 --to sub

# 2. 检查 subtitle.model.json，修正 speaker 错误
#    检查 speakers_to_role.json，填写角色名

# 3. 刷新指纹
vsd bless videos/dbqsfy/1.mp4 sub

# 4. 继续跑完
vsd run videos/dbqsfy/1.mp4 --to burn

# 5. 如果翻译不满意，从 mt 重跑
vsd run videos/dbqsfy/1.mp4 --from mt --to burn
```
