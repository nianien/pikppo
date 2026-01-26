# 安装指南

本文档说明如何根据 `pyproject.toml` 初始化安装项目。

## 📋 前置要求

- Python >= 3.9
- pip >= 23.0
- FFmpeg（用于音频/视频处理）

### 安装 FFmpeg

**macOS:**
```bash
brew install ffmpeg
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get update
sudo apt-get install ffmpeg
```

**Windows:**
下载并安装 [FFmpeg](https://ffmpeg.org/download.html)，确保添加到 PATH。

## 🚀 快速开始

### 1. 克隆项目（如果从 Git 仓库）

```bash
git clone <repository-url>
cd pikppo
```

### 2. 创建虚拟环境（推荐）

```bash
# 创建虚拟环境
python -m venv .venv

# 激活虚拟环境
# macOS/Linux:
source .venv/bin/activate
# Windows:
.venv\Scripts\activate
```

### 3. 安装项目

#### 选项 A: 基础安装（仅核心功能）

```bash
cd app
pip install -e .
```

#### 选项 B: 完整安装（包含所有功能）

```bash
cd app
pip install -e ".[dub,openai,terms,faster]"
```

#### 选项 C: 仅安装 Dubbing 功能（推荐）

```bash
cd app
pip install -e ".[dub]"
```

这将安装：
- ✅ 核心依赖
- ✅ Demucs（人声分离）
- ✅ Google Cloud Speech（ASR）
- ✅ OpenAI（翻译）
- ✅ Azure Speech（TTS）
- ✅ 其他 dubbing 相关库

#### 选项 D: 开发模式安装

```bash
cd app
pip install -e ".[dev,dub,openai,terms,faster]"
```

## 📦 依赖组说明

根据 `pyproject.toml`，项目包含以下可选依赖组：

| 依赖组 | 说明 | 包含内容 |
|--------|------|----------|
| `dub` | **Dubbing 功能**（推荐） | demucs, google-cloud-speech, openai, azure-cognitiveservices-speech, librosa, numpy, torchaudio |
| `openai` | OpenAI 功能 | openai |
| `terms` | 术语管理 | pyyaml |
| `faster` | Faster Whisper ASR | faster-whisper |
| `dev` | 开发工具 | pytest, black, ruff |

## 🔧 验证安装

### 检查 CLI 命令

```bash
vsd --help
```

应该看到命令帮助信息。

### 检查依赖

```bash
pip list | grep -E "(demucs|torchaudio|openai|azure)"
```

### 测试导入

```python
python -c "from video_subtitle_dubber.cli import main; print('✅ Import successful')"
```

## ⚙️ 环境配置

安装完成后，需要配置环境变量。创建 `.env` 文件：

```bash
cd app
cp .env.example .env  # 如果存在示例文件
# 或手动创建 .env
```

编辑 `.env` 文件，填入必要的 API 密钥：

```env
# OpenAI
OPENAI_API_KEY=your-openai-api-key

# Azure Speech Service
AZURE_SPEECH_KEY=your-azure-speech-key
AZURE_SPEECH_REGION=eastus

# Google Cloud (路径相对于 .env 文件)
GCP_SPEECH_CREDENTIALS=../credentials/gcp-pikppo-speech.json
```

## 🐛 常见问题

### 1. `torchcodec` 相关错误

如果遇到 `torchcodec` 错误，项目已配置使用 `torchaudio<2.4.0` 来避免此问题。如果仍有问题：

```bash
pip install "torchaudio<2.4.0" --force-reinstall
```

### 2. FFmpeg 未找到

确保 FFmpeg 已安装并在 PATH 中：

```bash
ffmpeg -version
```

### 3. 权限错误

如果遇到权限错误，使用虚拟环境或添加 `--user` 标志：

```bash
pip install -e ".[dub]" --user
```

### 4. 依赖冲突

如果遇到依赖冲突，建议使用全新的虚拟环境：

```bash
# 删除旧环境
rm -rf .venv

# 创建新环境
python -m venv .venv
source .venv/bin/activate

# 重新安装
cd app
pip install -e ".[dub]"
```

## 📝 更新依赖

### 更新项目

```bash
cd app
pip install -e ".[dub]" --upgrade
```

### 更新特定包

```bash
pip install --upgrade demucs
```

## 🎯 推荐安装流程

对于新用户，推荐以下流程：

```bash
# 1. 创建虚拟环境
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate

# 2. 进入 app 目录
cd app

# 3. 安装项目（包含 dubbing 功能）
pip install -e ".[dub]"

# 4. 配置环境变量
# 创建 .env 文件并填入 API 密钥

# 5. 验证安装
vsd --help
```

## 📚 下一步

安装完成后，查看 [README.md](README.md) 了解如何使用项目。
