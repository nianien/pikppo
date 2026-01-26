# ASR 命令行工具使用指南

## 快速开始

### 1. 生成字幕（推荐，自动处理 ASR + 字幕生成）

```bash
# 使用 URL
python test/asr_cli.py \
  --url https://pikppo-video.tos-cn-beijing.volces.com/dbqsfy/1.m4a \
  --preset asr_vad_spk \
  --postprofile axis

# 使用本地文件（会自动上传）
python test/asr_cli.py \
  --file audio.mp3 \
  --preset asr_vad_spk \
  --postprofile axis
```

**说明：**
- 如果已有 ASR 结果缓存，会自动使用，不会重复调用 API
- 如果已有字幕文件缓存，会自动使用，不会重复生成
- 生成的文件：
  - `asr_vad_spk-raw-response.json`（原始 ASR 响应）
  - `asr_vad_spk_axis-segments.json`（segments，含 speaker）
  - `asr_vad_spk_axis.srt`（SRT 字幕文件）

---

### 2. 只运行 ASR（不生成字幕）

```bash
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --asr-only
```

**说明：**
- 只调用 ASR API，生成原始响应文件
- 结果保存在：`{preset}-raw-response.json`

---

### 3. 批量生成多个字幕策略

```bash
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofiles axis axis_default axis_soft
```

**说明：**
- 使用同一个 ASR 结果，生成多个字幕策略的文件
- ASR 只会调用一次（如果缓存存在则使用缓存）
- 生成的文件：
  - `asr_vad_spk_axis-segments.json` / `asr_vad_spk_axis.srt`
  - `asr_vad_spk_axis_default-segments.json` / `asr_vad_spk_axis_default.srt`
  - `asr_vad_spk_axis_soft-segments.json` / `asr_vad_spk_axis_soft.srt`

---

### 4. 检查缓存状态

```bash
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis \
  --check-cache
```

**说明：**
- 只检查缓存，不执行任何操作
- 显示哪些文件已缓存，哪些未缓存

---

### 5. 强制重新生成（忽略缓存）

```bash
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis \
  --no-cache
```

**说明：**
- 忽略所有缓存，强制重新调用 API 和生成文件

---

## 参数说明

### 必需参数

- `--preset`: ASR 预设名称
  - 可选值：`asr_vad_spk`, `asr_vad_spk_sensitive`, `asr_vad_spk_smooth`, `asr_spk_semantic`
  - 示例：`--preset asr_vad_spk`

### 音频输入（二选一）

- `--url`: 音频文件 URL
  - 示例：`--url https://example.com/audio.m4a`
- `--file`: 本地音频文件路径（会自动上传到 TOS）
  - 示例：`--file audio.mp3`

### 字幕生成

- `--postprofile`: 单个字幕策略名称
  - 可选值：`axis`, `axis_default`, `axis_soft`
  - 示例：`--postprofile axis`
- `--postprofiles`: 多个字幕策略名称（批量生成）
  - 示例：`--postprofiles axis axis_default axis_soft`

### 其他选项

- `--output-dir`: 输出目录（默认：`doubao_test`）
  - 示例：`--output-dir my_output`
- `--asr-only`: 只运行 ASR，不生成字幕
- `--check-cache`: 只检查缓存状态，不执行操作
- `--no-cache`: 忽略缓存，强制重新生成

---

## 使用场景示例

### 场景 1：首次处理音频

```bash
# 第一次处理，会调用 API 并生成所有文件
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofiles axis axis_default axis_soft
```

**结果：**
- 调用 ASR API 一次
- 生成 3 组字幕文件（共 6 个文件）

---

### 场景 2：使用不同预设生成字幕

```bash
# 使用 asr_vad_spk 预设
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis

# 使用 asr_vad_spk_smooth 预设（会调用新的 API）
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk_smooth \
  --postprofile axis
```

**说明：**
- 不同预设会调用不同的 API（因为预设不同）
- 相同预设的不同策略会复用 ASR 结果

---

### 场景 3：基于已有 ASR 结果生成新策略

```bash
# 第一次：生成 axis 策略
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis

# 第二次：生成 axis_default 策略（会复用 ASR 结果）
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis_default
```

**说明：**
- 第二次不会调用 API（使用缓存的 ASR 结果）
- 只生成新的字幕文件

---

## 文件命名规则

### ASR 原始响应
- 格式：`{preset}-raw-response.json`
- 示例：`asr_vad_spk-raw-response.json`

### Segments 文件
- 格式：`{preset}_{postprofile}-segments.json`
- 示例：`asr_vad_spk_axis-segments.json`

### SRT 文件
- 格式：`{preset}_{postprofile}.srt`
- 示例：`asr_vad_spk_axis.srt`

---

## 环境变量

```bash
export DOUBAO_APPID=your_appid
export DOUBAO_ACCESS_TOKEN=your_access_token
```

或者在 `.env` 文件中设置。

---

## 完整示例

```bash
# 1. 检查缓存
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis \
  --check-cache

# 2. 生成字幕（如果缓存存在会自动使用）
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis

# 3. 批量生成多个策略
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofiles axis axis_default axis_soft

# 4. 使用不同预设
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk_smooth \
  --postprofile axis_soft

# 5. 强制重新生成
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofile axis \
  --no-cache
```
