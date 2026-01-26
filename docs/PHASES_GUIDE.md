# Pipeline Phases 说明

Pipeline 按固定顺序执行以下 6 个阶段（phases）：

## Phase 流程

```
demux → asr → mt → tts → mix → burn
```

---

## 1. demux - 音频提取

**功能：** 从视频中提取 16kHz 单声道音频（demux：从视频里"拆"出音频）

**输入：**
- 视频文件（如 `videos/dbqsfy/1.mp4`）

**输出：**
- `audio/{episode_stem}.wav` - 提取的音频文件（16k mono）

**实现：**
- 使用 `extract_raw_audio` 从视频提取音频
- 输出格式：16kHz, 单声道, WAV

---

## 2. asr - 语音识别

**功能：** 调用 ASR 模型识别中文，生成中文字幕

**输入：**
- `audio/{episode_stem}.wav`（来自 demux phase）

**输出：**
- `subs/zh-segments.json` - 中文 segments 数据（含时间轴、speaker）
- `subs/zh.srt` - 中文字幕文件
- `subs/asr-raw-response.json` - ASR API 原始响应

**实现：**
- 上传音频到 TOS 获取 URL
- 调用豆包大模型 ASR API（预设：`asr_vad_spk`）
- 使用 `speaker_aware_postprocess` 后处理（轴优先切分）
- 生成 segments 和 SRT 文件

---

## 3. mt - 机器翻译

**功能：** 将中文字幕翻译成英文

**输入：**
- `subs/zh-segments.json`（来自 asr phase）

**输出：**
- `subs/en-segments.json` - 英文 segments 数据
- `subs/en.srt` - 英文字幕文件
- `subs/translation-context.json` - 翻译上下文

**实现：**
- 使用 `translate_episode` 函数（当前未实现）
- 支持 OpenAI 等翻译引擎
- 生成英文 segments 和 SRT

**状态：** ⚠️ 当前未实现（抛出 `NotImplementedError`）

---

## 4. tts - 语音合成

**功能：** 根据英文字幕合成配音音频

**输入：**
- `subs/en-segments.json`（来自 mt phase）
- `subs/zh-segments.json`（用于声线分配）
- `audio/{episode_stem}.wav` 或 `audio/vocals.wav`（用于声线分配）

**输出：**
- `audio/tts.wav` - 合成的配音音频
- `voice-assignment.json` - 声线分配配置

**实现：**
- 使用 `assign_voices` 分配声线（根据中文 segments 的 speaker）
- 使用 Azure Neural TTS 合成英文配音
- 支持多声线、并发合成

---

## 5. mix - 音频混音

**功能：** 混合 TTS 音频和背景音乐（BGM）

**输入：**
- `audio/tts.wav`（来自 tts phase）
- `audio/accompaniment.wav`（背景音乐，可选）
- 原始视频（用于时长对齐）

**输出：**
- `audio/mix.wav` - 混合后的音频

**实现：**
- 使用 `mix_audio` 函数进行混音
- 支持侧链压缩（ducking）或简单混合
- 响度归一化（target_lufs）

---

## 6. burn - 字幕烧录

**功能：** 将字幕烧录到视频，替换音频轨道

**输入：**
- 原始视频
- `subs/en.srt`（来自 mt phase）或 `subs/zh.srt`（来自 asr phase）
- `audio/mix.wav`（来自 mix phase）

**输出：**
- `video/final.mp4` - 最终视频（含字幕 + 新音频）

**实现：**
- 使用 ffmpeg 烧录字幕（ASS 格式）
- 替换音频轨道为混音后的音频
- 生成最终视频文件

---

## 文件结构

执行完成后，工作目录结构：

```
videos/dbqsfy/dub/1/
├── audio/
│   ├── 1.wav              # demux phase 输出
│   ├── tts.wav            # tts phase 输出
│   ├── mix.wav             # mix phase 输出
│   └── vocals.wav          # 可选：人声分离
├── subs/
│   ├── zh-segments.json    # asr phase 输出
│   ├── zh.srt              # asr phase 输出
│   ├── en-segments.json    # mt phase 输出
│   ├── en.srt              # mt phase 输出
│   ├── asr-raw-response.json # asr phase 输出
│   └── translation-context.json # mt phase 输出
├── voice-assignment.json   # tts phase 输出
├── video/
│   └── final.mp4          # burn phase 输出
└── manifest.json           # 阶段执行状态
```

---

## 使用示例

```bash
# 执行到 asr 阶段
vsd run videos/dbqsfy/1.mp4 --to asr

# 执行到 mt 阶段（会先执行 demux → asr → mt）
vsd run videos/dbqsfy/1.mp4 --to mt

# 执行完整 pipeline
vsd run videos/dbqsfy/1.mp4 --to burn

# 从指定阶段重新执行
vsd run videos/dbqsfy/1.mp4 --to burn --from mt
```

---

## 依赖关系

```
demux
  ↓
asr (依赖 demux)
  ↓
mt (依赖 asr)
  ↓
tts (依赖 mt + asr)
  ↓
mix (依赖 tts)
  ↓
burn (依赖 mix + mt)
```
