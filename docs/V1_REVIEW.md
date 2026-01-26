# v1 整改代码 Review 报告

## 问题清单

### ✅ 问题 1：字幕时间完全对不上

**根因**：TTS 音频时间轴构建错误
- 旧逻辑：直接拼接 segment，丢失 gap；整段拉伸破坏段内对齐

**整改方案**：
1. **段内对齐**（`tts_azure.py::_align_segment_to_window`）
   - ✅ 合成每个 segment 后立刻对齐到时间窗（`seg.end - seg.start`）
   - ✅ 如果 `tts_len < target`：pad 静音补齐
   - ✅ 如果 `tts_len > target`：先尝试 atempo 压缩（最大 1.35x），超出则 trim
   - ✅ 代码位置：`tts_azure.py:342` 调用 `_align_segment_to_window()`

2. **Gap 插入**（`tts_azure.py::_concatenate_with_gaps`）
   - ✅ 在 concat 前插入 gap 静音段（`seg.start - prev.end`）
   - ✅ 处理第一个 segment 前的静音（从 0 到 `seg_start`）
   - ✅ 代码位置：`tts_azure.py:356-358` 调用 `_concatenate_with_gaps()`

3. **删除整段 duration_align**
   - ✅ Step 9 改为 no-op（直接复制 `tts_en.wav`）
   - ✅ 代码位置：`dub_pipeline.py:428-445`

**验证**：
- ✅ `_align_segment_to_window()` 已实现（`tts_azure.py:379-459`）
- ✅ `_concatenate_with_gaps()` 已实现（`tts_azure.py:462-513`）
- ✅ 段内对齐在合成时完成（`tts_azure.py:343`）
- ✅ Gap 插入在 concat 前完成（`tts_azure.py:356-358`）

**结论**：✅ **已解决** - 音频时间轴严格遵循 segment 时间窗，不再整段拉伸

---

### ✅ 问题 2：人物音色完全不对

**根因**：依赖脆弱的 pitch 检测，失败时全变成女声

**整改方案**：
1. **稳定的交替分配策略**（`assign_voices.py`）
   - ✅ 不依赖 librosa/pitch 检测
   - ✅ rank 1 → male_1, rank 2 → female_1, rank 3 → male_2...
   - ✅ 代码位置：`assign_voices.py:93-103`

2. **同一 speaker 固定 voice_id**
   - ✅ 同一 `speaker_id` 在一集内永远同一个 `voice_id`
   - ✅ 代码位置：`assign_voices.py:109-120`（assignment 字典）

3. **其余 speaker 稳定映射**
   - ✅ 使用 hash(speaker_id) 稳定映射到男/女
   - ✅ 代码位置：`assign_voices.py:127-152`

**验证**：
- ✅ 交替分配策略已实现（`assign_voices.py:94-103`）
- ✅ 不再依赖 `_calculate_speaker_stats()` 的 gender 检测结果
- ✅ 使用 rank 直接分配，不依赖 pitch

**结论**：✅ **已解决** - 声线分配稳定，同一 speaker 固定 voice，男女分开

---

### ✅ 问题 3：没有英文字幕

**根因**：生成了但没烧进视频

**整改方案**：
1. **输出两个版本**
   - ✅ `1-dub-nosub.mp4`：不烧录，只换音轨（给后期留空间）
   - ✅ `1-dub.mp4`：烧录英文字幕（开箱即用）
   - ✅ 代码位置：`dub_pipeline.py:448-491`

2. **字幕烧录函数**
   - ✅ `_burn_subtitles_to_video()` 已实现
   - ✅ 使用 `ffmpeg -vf ass=...` 烧录 ASS 字幕
   - ✅ 代码位置：`dub_pipeline.py:527-549`

3. **保留外挂字幕**
   - ✅ `1-en.srt` / `1-en.ass` 保留在输出目录
   - ✅ 代码位置：`dub_pipeline.py:340-341`

**验证**：
- ✅ Step 10 生成 nosub 版本（`dub_pipeline.py:448-467`）
- ✅ Step 10.5 烧录字幕版本（`dub_pipeline.py:470-491`）
- ✅ `_burn_subtitles_to_video()` 函数已实现（`dub_pipeline.py:527-549`）

**结论**：✅ **已解决** - 输出视频带英文字幕（硬烧），同时保留外挂字幕文件

---

## 其他改进

### GCS 上传规范（v1）
- ✅ Bucket 写死：`pikppo-asr-audio`
- ✅ 路径格式：`gs://pikppo-asr-audio/asr/{series}/{stem}-vocals-{hash}.wav`
- ✅ 幂等上传：检查对象存在性，存在则复用
- ✅ 代码位置：`asr_google.py:206-240`

---

## 潜在问题检查

### 1. 第一个 segment 前的静音
- ✅ `_concatenate_with_gaps()` 中 `prev_end = 0.0`，第一个 segment 的 `gap = seg_start - 0.0` 会正确插入静音

### 2. 总时长对齐
- ✅ `_concatenate_with_gaps()` 使用 `ffmpeg concat`，会自动处理总时长
- ✅ 最后一个 segment 的 `end` 时间已包含在 segment 中

### 3. 空 segment 处理
- ✅ 空 segment 创建静音音频（`tts_azure.py:255-260`）

### 4. 错误处理
- ✅ TTS 失败时创建静音 segment（`tts_azure.py:333-340`）
- ✅ ASS 文件不存在时复制 nosub 版本（`dub_pipeline.py:487-489`）

---

## 总结

| 问题 | 状态 | 验证 |
|------|------|------|
| 字幕时间完全对不上 | ✅ 已解决 | 段内对齐 + Gap 插入 + 删除整段拉伸 |
| 人物音色完全不对 | ✅ 已解决 | 交替分配策略 + 固定 speaker-voice 映射 |
| 没有英文字幕 | ✅ 已解决 | 烧录字幕版本 + 保留外挂字幕 |

**所有问题均已解决，代码实现符合 v1 整改方案。**
