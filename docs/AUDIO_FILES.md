# dub/1/ 目录下 WAV 文件说明

## 文件清单与用途

### 1. `1.wav` - 原始音频
- **生成步骤**：Step 1 (MediaPrep)
- **来源**：从视频 `1.mp4` 提取
- **格式**：16kHz, mono, PCM s16le
- **用途**：
  - 用于 ASR 识别（Google STT）
  - 用于人声分离（Demucs）
- **说明**：这是整个 pipeline 的基础音频文件

---

### 2. `1-vocals.wav` - 人声分离（纯人声）
- **生成步骤**：Step 2 (VocalSeparation)
- **来源**：Demucs 从 `1.wav` 分离出的人声部分
- **格式**：原始采样率（通常 44.1kHz 或 48kHz），stereo
- **用途**：
  - 用于声线分配（gender detection，但 v1 已改为交替分配策略）
  - **注意**：v1 整改后，ASR 不再使用此文件，改用原始音频
- **说明**：去除背景音乐后的纯人声，质量取决于 Demucs 分离效果

---

### 3. `1-accompaniment.wav` - 人声分离（背景音乐/伴奏）
- **生成步骤**：Step 2 (VocalSeparation)
- **来源**：Demucs 从 `1.wav` 分离出的背景音乐部分
- **格式**：原始采样率（通常 44.1kHz 或 48kHz），stereo
- **用途**：
  - 用于最终混音（Step 10）
  - 与 TTS 音频混合，生成最终配音视频
- **说明**：去除人声后的背景音乐，用于替换原视频音轨

---

### 4. `1-vocals-16k.wav` - 人声转码（16k mono）
- **生成步骤**：Step 2.5（已废弃，但可能仍存在）
- **来源**：`1-vocals.wav` 转码为 16k mono
- **格式**：16kHz, mono, PCM s16le
- **用途**：
  - **v1 整改前**：用于 Google STT ASR
  - **v1 整改后**：**已废弃**，ASR 改用原始音频 `1.wav`
- **说明**：此文件可能仍存在，但不再使用

---

### 5. `1-tts.wav` - TTS 合成音频（段内对齐 + gap 插入）
- **生成步骤**：Step 8 (TTS Synthesis)
- **来源**：Azure Neural TTS 合成每个 segment，然后：
  1. 每个 segment 对齐到时间窗（`seg.end - seg.start`）
  2. 插入 gap 静音段（`seg.start - prev.end`）
  3. 拼接成完整音频
- **格式**：24kHz, mono, PCM s16le
- **用途**：
  - 用于最终混音（Step 10）
  - 复制为 `1-tts-aligned.wav`（保持接口兼容）
- **说明**：**这是 v1 整改的核心**，音频时间轴严格遵循 segment 时间窗

---

### 6. `1-tts-aligned.wav` - TTS 对齐音频（接口兼容）
- **生成步骤**：Step 9 (DurationAlign)
- **来源**：直接复制自 `1-tts.wav`
- **格式**：24kHz, mono, PCM s16le（与 `1-tts.wav` 相同）
- **用途**：
  - 用于最终混音（Step 10）
  - 保持接口兼容性
- **说明**：**v1 整改后，此文件等于 `1-tts.wav`**（因为段内对齐已在 TTS 合成时完成）

---

## 文件关系图

```
1.mp4 (视频)
  ↓
1.wav (原始音频，16k mono)
  ├─→ ASR 识别 (Google STT)
  └─→ Demucs 分离
      ├─→ 1-vocals.wav (人声)
      │   └─→ 1-vocals-16k.wav (已废弃)
      └─→ 1-accompaniment.wav (背景音乐)
          └─→ 用于混音

翻译 + TTS
  ↓
1-tts.wav (TTS 合成，段内对齐 + gap)
  ↓ (复制)
1-tts-aligned.wav (接口兼容)

混音 (Step 10)
1-tts-aligned.wav + 1-accompaniment.wav
  ↓
1-dub-nosub.mp4 (不烧录字幕)
  ↓ (烧录字幕)
1-dub.mp4 (最终输出)
```

---

## v1 整改后的变化

### ASR 音频源
- **整改前**：使用 `1-vocals-16k.wav`（人声分离后）
- **整改后**：使用 `1.wav`（原始音频）
- **原因**：原始音频质量更稳定，diarization 效果更好

### TTS 对齐
- **整改前**：`1-tts.wav` 整段拉伸 → `1-tts-aligned.wav`
- **整改后**：`1-tts.wav` 已包含段内对齐和 gap → `1-tts-aligned.wav` 直接复制
- **原因**：避免整段拉伸破坏段内对齐

---

## 清理建议

以下文件可以安全删除（如果不需要调试）：
- `1-vocals-16k.wav`（已废弃，不再使用）

以下文件应保留：
- `1.wav`（原始音频，用于重新运行 ASR）
- `1-vocals.wav`（用于声线分配，虽然 v1 已改为交替策略）
- `1-accompaniment.wav`（用于最终混音）
- `1-tts.wav`（TTS 合成结果）
- `1-tts-aligned.wav`（用于混音）
