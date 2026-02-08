# TTS 引擎配置指南

Pikppo 支持两种 TTS 引擎：Azure TTS 和 VolcEngine TTS。

## 引擎选择

默认使用 Azure TTS（向后兼容）。可以通过配置切换到 VolcEngine TTS。

## 配置方式

### 方式 1: 配置文件

在配置文件中设置：

```yaml
phases:
  tts:
    engine: "volcengine"  # 或 "azure"
    # VolcEngine 配置
    volcengine_app_id: "your_app_id"
    volcengine_access_key: "your_access_key"
    volcengine_resource_id: "seed-tts-1.0"  # 可选，默认 "seed-tts-1.0"
    volcengine_format: "pcm"  # 可选，默认 "pcm" (mp3/ogg_opus/pcm)
    volcengine_sample_rate: 24000  # 可选，默认 24000
```

### 方式 2: 环境变量

设置环境变量：

```bash
# VolcEngine TTS 配置
export DOUBAO_APPID="your_app_id"
export DOUBAO_ACCESS_TOKEN="your_access_token"

# 或使用通用火山引擎变量
export VOLC_APP_ID="your_app_id"
export VOLC_ACCESS_KEY="your_access_key"
```

然后在配置文件中设置引擎：

```yaml
phases:
  tts:
    engine: "volcengine"
```

### 方式 3: 命令行参数（如果支持）

某些 CLI 可能支持通过命令行参数设置引擎。

## VolcEngine TTS 参数说明

### 必需参数

- `volcengine_app_id`: 火山引擎 APP ID（从控制台获取）
- `volcengine_access_key`: 火山引擎 Access Key（从控制台获取）

### 可选参数

- `volcengine_resource_id`: 资源 ID
  - `seed-tts-1.0`: 豆包语音合成模型 1.0（字符版）
  - `seed-tts-1.0-concurr`: 豆包语音合成模型 1.0（并发版）
  - `seed-tts-2.0`: 豆包语音合成模型 2.0（字符版）
  - `seed-icl-1.0`: 声音复刻 1.0（字符版）
  - `seed-icl-1.0-concurr`: 声音复刻 1.0（并发版）
  - `seed-icl-2.0`: 声音复刻 2.0（字符版）
  - 默认: `seed-tts-1.0`

- `volcengine_format`: 音频格式
  - `pcm`: PCM 格式（推荐，质量最好）
  - `mp3`: MP3 格式
  - `ogg_opus`: OGG Opus 格式
  - 默认: `pcm`

- `volcengine_sample_rate`: 采样率
  - 可选值: 8000, 16000, 22050, 24000, 32000, 44100, 48000
  - 默认: 24000

## Azure TTS 配置（向后兼容）

如果使用 Azure TTS（默认），配置方式不变：

```yaml
phases:
  tts:
    engine: "azure"  # 或省略（默认）
    azure_key: "your_azure_key"
    azure_region: "your_azure_region"
    azure_language: "en-US"
```

## 功能对比

| 功能 | Azure TTS | VolcEngine TTS |
|------|-----------|----------------|
| 缓存支持 | ✅ | ✅ |
| 音频对齐 | ✅ | ✅ |
| 静音裁剪 | ✅ | ✅ |
| 语速调整 | ✅ | ✅ |
| 情感支持 | ✅ | ✅ |
| 流式合成 | ❌ | ✅ |
| 时间戳 | ❌ | ✅ (TTS1.0) |
| 字幕 | ❌ | ✅ (TTS2.0) |

## 注意事项

1. **缓存隔离**: Azure 和 VolcEngine 使用不同的缓存目录，不会互相干扰。

2. **音色映射**: 两种引擎使用不同的音色 ID 格式：
   - Azure: `en-US-JennyNeural`
   - VolcEngine: `zh_female_shuangkuaisisi_moon_bigtts`
   
   需要在 `voice_pool.json` 中为不同引擎配置不同的音色。

3. **音频格式**: 
   - Azure 输出 MP3，然后转换为 WAV
   - VolcEngine 默认输出 PCM，直接转换为 WAV（质量更好）

4. **错误处理**: 如果 TTS 合成失败，会自动创建静音段作为后备方案。

## 示例配置

### 使用 VolcEngine TTS

```yaml
phases:
  tts:
    engine: "volcengine"
    volcengine_app_id: "123456789"
    volcengine_access_key: "your_access_key"
    volcengine_resource_id: "seed-tts-2.0"  # 使用 TTS 2.0 模型
    volcengine_format: "pcm"
    volcengine_sample_rate: 24000
```

### 使用 Azure TTS（默认）

```yaml
phases:
  tts:
    engine: "azure"  # 可以省略
    azure_key: "your_azure_key"
    azure_region: "eastus"
    azure_language: "en-US"
```

## 故障排查

### VolcEngine TTS 认证失败

检查：
1. `DOUBAO_APPID` 和 `DOUBAO_ACCESS_TOKEN` 是否正确设置
2. 或在配置文件中正确设置了 `volcengine_app_id` 和 `volcengine_access_key`

### 音频格式错误

如果使用 PCM 格式，确保：
1. 采样率设置正确（默认 24000）
2. 资源 ID 支持 PCM 格式（大部分资源都支持）

### 音色不存在

检查 `voice_pool.json` 中的音色 ID 是否与 VolcEngine 支持的音色匹配。
参考：[VolcEngine 音色列表](https://www.volcengine.com/docs/6561/1257544)
