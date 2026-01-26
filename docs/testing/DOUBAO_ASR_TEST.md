# 豆包语音 API 音频转文字测试

## 简介

这是一个独立的测试脚本，用于测试豆包语音（火山引擎）的"音视频字幕生成"功能。

**官方文档**: https://www.volcengine.com/docs/6561/80909?lang=zh

## 环境配置

### 1. 安装依赖

```bash
pip install requests
```

### 2. 配置 API 参数

在项目根目录的 `.env` 文件中添加：

```bash
# 豆包语音 API 配置
DOUBAO_APPID=your_appid_here          # 应用标识（必填）
DOUBAO_ACCESS_TOKEN=your_token_here    # 访问令牌（必填）
DOUBAO_AUDIO_URL=https://...          # 音频文件公开 URL（可选）
```

### 3. 获取 API 凭证

1. 访问火山引擎控制台：https://console.volcengine.com/
2. 开通"豆包语音"服务
3. 创建应用并获取 `appid` 和 `access_token`
4. 参考[鉴权方法文档](https://www.volcengine.com/docs/6561/80909?lang=zh)获取访问令牌

### 4. 音频文件处理

脚本支持两种方式：

**方式 1: 直接上传二进制文件（推荐，简单）**
- 不需要设置 `DOUBAO_AUDIO_URL`
- 脚本会自动读取本地文件并上传
- 支持 wav, mp3, m4a 等格式

**方式 2: 使用音频 URL**
- 设置 `DOUBAO_AUDIO_URL` 环境变量
- 适用于音频文件已在可访问的存储服务中
- 上传到火山引擎 TOS 或其他对象存储服务

## 使用方法

### 基本用法（二进制上传，推荐）

```bash
# 从项目根目录运行（直接上传本地文件）
python test/test_doubao_asr.py <音频文件路径>

# 示例
python test/test_doubao_asr.py videos/dbqsfy/1.mp4
python test/test_doubao_asr.py app/runs/1/audio/1.wav
python test/test_doubao_asr.py audio.wav
```

脚本会自动：
1. 读取本地音频文件
2. 使用 multipart/form-data 方式上传
3. 提交字幕生成任务
4. 自动轮询查询结果

### 使用音频 URL（可选）

如果音频文件已在可访问的存储服务中：

```bash
export DOUBAO_AUDIO_URL=https://your-audio-url.com/audio.wav
python test/test_doubao_asr.py <任意路径>  # 路径会被忽略，使用 URL
```

## 输出

测试脚本会在音频文件所在目录创建 `doubao_test/` 文件夹，包含：

- `<音频名>-doubao-segments.json`: 转录结果 JSON（包含时间戳）
- `<音频名>-doubao.srt`: 字幕文件（SRT 格式）

## 支持的音频格式

- mp3, mp4, mpeg, mpga, m4a, wav, webm

如果音频格式不支持，脚本会提示，建议使用 ffmpeg 转换：

```bash
ffmpeg -i input.xxx -ar 16000 -ac 1 -acodec pcm_s16le output.wav
```

## API 说明

根据[官方文档](https://www.volcengine.com/docs/6561/80909?lang=zh)，豆包语音字幕生成 API 使用以下流程：

1. **提交任务**: `POST https://openspeech.bytedance.com/api/v1/vc/submit`
   - 需要提供音频文件的公开 URL
   - 返回任务 ID（job_id）

2. **查询结果**: `GET https://openspeech.bytedance.com/api/v1/vc/query`
   - 使用任务 ID 查询处理结果
   - 支持阻塞式和非阻塞式查询

## 注意事项

1. **音频 URL**: API 需要音频文件的公开可访问 URL，不支持直接上传文件
2. **鉴权方式**: 使用 Bearer token 鉴权，格式：`Bearer; {access_token}`
3. **任务状态**: 任务可能处于 `processing` 状态，脚本会自动轮询直到完成
4. **支持参数**:
   - `language`: 字幕语言（如 zh-CN）
   - `words_per_line`: 每行最多展示字数（默认 46）
   - `max_lines`: 每屏最多展示行数（默认 1）
   - `use_itn`: 数字转换（默认 True）
   - `caption_type`: 字幕类型（auto/speech/singing，默认 auto）

## 故障排查

### 错误：DOUBAO_API_KEY 未设置
- 检查 `.env` 文件是否存在
- 确认环境变量已正确加载

### 错误：API 调用失败
- 检查 API Key 是否正确
- 检查网络连接
- 确认 API 服务已开通

### 错误：音频格式不支持
- 使用 ffmpeg 转换为支持的格式
- 推荐使用 wav 或 m4a 格式

## 与现有系统集成

测试通过后，可以将豆包 API 集成到 `asr_factory.py` 中：

1. 创建 `asr_doubao.py` 实现 ASR 接口
2. 在 `asr_factory.py` 中添加 `doubao` 选项
3. 配置默认 ASR 引擎为 `doubao`
