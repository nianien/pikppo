# 测试指南

## 快速开始

### 1. 本地文件 ASR 测试工具（最简单）

专门用于测试本地文件 → TOS 上传 → ASR 调用 → 返回结果：

```bash
# 基本用法（使用默认预设）
python test/test_asr_local.py audio/1.wav

# 指定预设
python test/test_asr_local.py audio/1.wav --preset asr_vad_spk

# 指定输出目录
python test/test_asr_local.py audio/1.wav --preset asr_vad_spk --output results/

# 使用热词
python test/test_asr_local.py audio/1.wav --preset asr_vad_spk --hotwords 平安 平安哥 哥
```

**输出文件：**
- `{文件名}-asr-raw-response.json` - 原始 ASR 响应
- `{文件名}-utterances.json` - Utterances 数据（含时间轴和 speaker）

---

### 2. ASR CLI 工具（推荐）

用于测试 ASR 和字幕生成：

```bash
# 使用音频 URL
python test/asr_cli.py \
  --url https://pikppo-video.tos-cn-beijing.volces.com/dbqsfy/1.m4a \
  --preset asr_vad_spk \
  --postprofile axis

# 使用本地文件（会自动上传到 TOS）
python test/asr_cli.py \
  --file audio/1.wav \
  --preset asr_vad_spk \
  --postprofile axis

# 只运行 ASR（不生成字幕）
python test/asr_cli.py \
  --url <音频URL> \
  --preset asr_vad_spk \
  --asr-only

# 检查缓存状态
python test/asr_cli.py \
  --url <音频URL> \
  --preset asr_vad_spk \
  --postprofile axis \
  --check-cache

# 强制重新生成（忽略缓存）
python test/asr_cli.py \
  --url <音频URL> \
  --preset asr_vad_spk \
  --postprofile axis \
  --no-cache
```

**输出文件：**
- `{preset}-raw-response.json` - 原始 ASR 响应
- `{preset}_{postprofile}-segments.json` - Segments 数据
- `{preset}_{postprofile}.srt` - SRT 字幕文件

---

### 2. 完整 ASR 测试工具

用于批量测试多个预设和策略组合：

```bash
# 单个测试
python test/test_doubao_asr.py --llm <音频文件路径或URL> --preset asr_vad_spk

# 批量测试所有预设
python test/test_doubao_asr.py --llm --all-presets <音频文件路径或URL>

# 测试 5 组推荐组合
python test/test_doubao_asr.py --llm --test-6-groups <音频文件路径或URL>

# 并行执行（更快）
python test/test_doubao_asr.py --llm --all-presets --parallel <音频文件路径或URL>
```

---

### 3. 单元测试

测试代码逻辑和校验：

```bash
# 测试 request_types 校验
python test/test_request_types.py

# 测试 ASR 工具（示例代码）
python test/test_asr_tools.py
```

---

## 环境变量

测试前需要设置环境变量（在 `.env` 文件中或导出）：

```bash
export DOUBAO_APPID=your_appid
export DOUBAO_ACCESS_TOKEN=your_access_token

# TOS 配置（如果使用本地文件上传）
export TOS_ACCESS_KEY_ID=your_access_key_id
export TOS_SECRET_ACCESS_KEY=your_secret_access_key
export TOS_REGION=cn-beijing
export TOS_BUCKET=pikppo-video
```

---

## 测试场景

### 场景 1：首次处理音频

```bash
python test/asr_cli.py \
  --url https://example.com/audio.m4a \
  --preset asr_vad_spk \
  --postprofiles axis axis_default axis_soft
```

**结果：**
- 调用 ASR API 一次
- 生成 3 组字幕文件（共 6 个文件）

---

### 场景 2：使用不同预设

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

## 可用预设

- `asr_vad_spk` - 默认，VAD 分句，800ms 窗口，稳定
- `asr_vad_spk_smooth` - VAD 分句，1000ms 窗口，更少碎片
- `asr_spk_semantic` - 不走 VAD，语义切分，完整性强

---

## 可用后处理策略

- `axis` - 默认，轴优先模式
- `axis_default` - 轴默认模式
- `axis_soft` - 轴软模式

---

## 详细文档

- `test/ASR_CLI_USAGE.md` - ASR CLI 工具详细使用说明
