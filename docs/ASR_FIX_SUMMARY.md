# ASR 问题修复总结

## 问题诊断

### 1. ASR 识别内容完全错误
- **原始字幕**："坐牢10年，我被冤枉杀父弑母的事，"
- **ASR 识别**："这是我很不舒服舒服的时候还"
- **根本原因**：使用了包含大量背景音乐的 `1.wav`，导致 Google STT 产生幻觉

### 2. SRT 文件重复
- **现象**：`1-zh-segments.json` 中第 13-24 条与第 1-12 条完全重复
- **根本原因**：Google STT 返回的结果中包含重复的词，代码没有去重

## 修复方案

### ✅ 修复 1：改用 vocals 音频进行 ASR
**文件**：`app/src/video_remix/pipeline/dub_pipeline.py`

**修改**：
- 从使用 `1.wav`（原始音频，含背景音乐）改为使用 `1-vocals.wav`（人声分离后的音频）
- 自动转换为 16k mono PCM 格式（Google STT 要求）
- 生成 `1-vocals-16k.wav` 作为 ASR 输入

**代码位置**：Step 3，第 199-234 行

### ✅ 修复 2：防止重复 segments
**文件**：`app/src/video_remix/pipeline/asr_google.py`

**修改**：
- 添加去重逻辑：使用 `seen_words` set 防止重复的词
- 添加排序逻辑：按时间戳排序，确保词按顺序处理
- 防止 Google STT 返回的重复结果被重复添加

**代码位置**：`transcribe()` 方法，第 192-225 行

### ✅ 修复 3：避免重复写入 SRT
**文件**：`app/src/video_remix/pipeline/dub_pipeline.py`

**修改**：
- Step 4 不再重复写入 SRT（因为 `_save_cache()` 已经写入）
- 只检查文件是否存在，避免重复写入

**代码位置**：Step 4，第 273-282 行

## 验证步骤

1. **清除旧缓存**：
   ```bash
   rm -f videos/dbqsfy/dub/1/1-zh-segments.json videos/dbqsfy/dub/1/1-zh-words.json videos/dbqsfy/dub/1/1-zh.srt
   ```

2. **重新运行 ASR**：
   ```bash
   vsd dub-en videos/dbqsfy/1.mp4 --force-asr
   ```

3. **验证结果**：
   ```bash
   python3 test_asr.py
   ```

## 预期结果

- ✅ ASR 使用 `1-vocals-16k.wav`（人声分离后的音频）
- ✅ 识别内容应该接近原始字幕
- ✅ 无重复 segments
- ✅ SRT 文件不重复

## 技术细节

### 音频文件格式要求
- **Google STT 要求**：16kHz, mono, LINEAR16 (PCM s16le)
- **当前实现**：从 `1-vocals.wav`（44.1kHz stereo）转换为 `1-vocals-16k.wav`（16kHz mono）

### Google STT 配置
- **语言代码**：`zh-CN`
- **说话人分离**：启用（`enable_speaker_diarization=True`）
- **自动标点**：启用（`enable_automatic_punctuation=True`）

## 注意事项

1. **时间轴保持**：`1-vocals.wav` 时长与原视频一致，ASR 输出的时间戳可直接用于视频字幕
2. **缓存机制**：ASR 结果会缓存到 `1-zh-segments.json`，如需重新识别请使用 `--force-asr`
3. **GCS 上传**：音频文件会上传到 GCS (`gs://pikppo-asr-audio/asr/{series}/{stem}-vocals-{hash}.wav`)
