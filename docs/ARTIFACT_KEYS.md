# Artifact Keys 规范

本文档定义了 Pipeline Framework v1 中所有 artifact keys 的命名规范。

## 命名规则

- 格式：`{domain}.{object}`
- `domain`：功能域（如 `subs`, `demux`, `translate`, `tts`, `mix`, `burn`）
- `object`：具体对象（如 `zh_segments`, `audio`, `context`）

## 完整 Artifact Key 列表

### Demux Phase
- `demux.audio` → `audio/{episode_stem}.wav`

### ASR Phase
- `subs.zh_segments` → `subs/zh-segments.json`
- `subs.zh_srt` → `subs/zh.srt`
- `subs.asr_raw_response` → `subs/asr-raw-response.json`

### MT Phase
- `translate.context` → `subs/translation-context.json`
- `subs.en_segments` → `subs/en-segments.json`
- `subs.en_srt` → `subs/en.srt`

### TTS Phase
- `tts.audio` → `audio/tts.wav`
- `tts.voice_assignment` → `voice-assignment.json`

### Mix Phase
- `mix.audio` → `audio/mix.wav`

### Burn Phase
- `burn.video` → `{episode_stem}-dubbed.mp4`

## 依赖关系

```
demux.audio
  ↓
subs.zh_segments, subs.zh_srt, subs.asr_raw_response
  ↓
translate.context, subs.en_segments, subs.en_srt
  ↓
tts.audio, tts.voice_assignment
  ↓
mix.audio
  ↓
burn.video
```

## 使用示例


