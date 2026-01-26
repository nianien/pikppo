# 术语配置指南

解决 ASR 识别专有名词（如"平安哥"被识别成"天哥"）的问题。

## 问题说明

Whisper 在识别短剧中的专有名词时，容易出现同音歧义：
- "平安哥" → "天哥"（声学相似 + 语言模型先验）
- 人名、称呼等低频词容易被误识别

## 解决方案

### 方案 1: 使用 initial_prompt（推荐）

在 ASR 前告诉 Whisper 重要的人名和术语：

```bash
vsd extract ../videos/1.mp4 --asr-prompt "人物称呼包括：平安哥、林宁、李总"
```

**效果**：Whisper 会在 beam search 时提高这些词的概率。

### 方案 2: 术语纠错（后处理）

ASR 后自动纠正常见误识别：

```bash
# 使用 YAML 配置文件
vsd extract ../videos/1.mp4 --terms-file terms.yaml
```

## 配置文件格式

创建 `terms.yaml` 文件：

```yaml
# ASR initial prompt: 帮助 Whisper 识别人名和术语
asr_prompt: "人物称呼包括：平安哥、林宁、李总。"

# 术语纠错: 修复常见误识别
# 格式: {误识别: 正确}
term_corrections:
  "天哥": "平安哥"
  "林总": "林宁"
  "李哥": "李总"
```

## 使用示例

### 方法 1: 命令行参数

```bash
# 只设置 prompt
vsd extract ../videos/1.mp4 --asr-prompt "人物称呼包括：平安哥"

# 使用配置文件（推荐）
vsd extract ../videos/1.mp4 --terms-file terms.yaml
```

### 方法 2: 配置文件（推荐）

1. 复制示例文件：
```bash
cp app/terms_example.yaml terms.yaml
```

2. 编辑 `terms.yaml`，填入你的人名和术语

3. 使用配置文件：
```bash
vsd extract ../videos/1.mp4 --terms-file terms.yaml
vsd transcribe ../videos/1.mp4 --terms-file terms.yaml
```

## 最佳实践

1. **第一集处理时**：
   - 先运行一次 ASR
   - 检查识别错误的人名/术语
   - 添加到 `term_corrections`

2. **后续集数**：
   - 使用相同的 `terms.yaml`
   - 保证人名一致性

3. **组合使用**：
   - `asr_prompt` 提高识别准确率（预防）
   - `term_corrections` 修复误识别（纠正）

## 安装 YAML 支持（可选）

如果使用 `--terms-file`，需要安装 PyYAML：

```bash
pip install pyyaml
```

或安装可选依赖：

```bash
pip install -e .[terms]
```
