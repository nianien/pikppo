# MT Phase 翻译引擎切换指南

MT Phase 支持两套独立的翻译方案：**Gemini** 和 **OpenAI**，可以在运行时切换。

**注意**：默认使用 **Gemini**。如果遇到模型不可用的错误，可以切换到 OpenAI。

## 配置方式

### 方式1：通过 `engine` 参数显式指定（推荐）

在配置中明确指定使用哪个引擎：

```python
config = {
    "phases": {
        "mt": {
            "engine": "gemini",  # 或 "openai"
            "model": "gemini-pro",  # 或 "gpt-4o-mini"
            "temperature": 0.4,
        }
    }
}
```

### 方式2：通过模型名称自动推断

如果不指定 `engine`，系统会根据模型名称自动推断：

- 模型名称以 `gemini` 开头 → 使用 Gemini 引擎
- 模型名称以 `gpt` 或 `o1` 开头 → 使用 OpenAI 引擎
- 默认：使用 Gemini

```python
config = {
    "phases": {
        "mt": {
            "model": "gemini-pro",  # 自动推断为 Gemini
        }
    }
}
```

### 方式3：全局配置

在全局配置中设置：

```python
config = {
    "mt_engine": "openai",  # 全局默认引擎
    "mt_model": "gpt-4o-mini",
}
```

## 配置优先级

1. `phases.mt.engine` - 显式指定引擎（最高优先级）
2. `phases.mt.model` - 通过模型名称推断
3. `mt_engine` - 全局配置
4. 默认：`"gemini"`

## 完整配置示例

### Gemini 方案

```python
config = {
    "phases": {
        "mt": {
            "engine": "gemini",
            "model": "gemini-pro",  # 或 "gemini-1.5-pro"
            "api_key": None,  # 从环境变量 GEMINI_API_KEY 读取
            "temperature": 0.4,
            "max_retries": 3,
        }
    }
}
```

### OpenAI 方案

```python
config = {
    "phases": {
        "mt": {
            "engine": "openai",
            "model": "gpt-4o-mini",  # 或 "gpt-4o", "gpt-3.5-turbo"
            "api_key": None,  # 从环境变量 OPENAI_API_KEY 读取
            "temperature": 0.3,
            "max_retries": 3,
        }
    }
}
```

## 环境变量

### Gemini
- `GEMINI_API_KEY` 或 `GOOGLE_API_KEY`

### OpenAI
- `OPENAI_API_KEY`

## 特性

1. **统一使用同一模型**：翻译和人名补全都使用选定的引擎，保持一致性
2. **独立配置**：Gemini 和 OpenAI 的配置完全独立，互不干扰
3. **自动 API Key 管理**：根据选定的引擎自动使用对应的 API key
4. **Fallback 支持**（可选）：可以配置 fallback 引擎，但推荐保持关闭

## 推荐配置

### 使用 Gemini（默认，推荐用于长上下文）
```python
{
    "phases": {
        "mt": {
            "engine": "gemini",
            "model": "gemini-pro",
            "temperature": 0.4,
        }
    }
}
```

### 使用 OpenAI（可选，推荐用于短文本、高一致性需求）
```python
{
    "phases": {
        "mt": {
            "engine": "openai",
            "model": "gpt-4o-mini",
            "temperature": 0.3,
        }
    }
}
```

## 注意事项

1. **API Key 必须正确**：确保对应引擎的 API key 已设置
2. **模型名称要匹配**：确保模型名称与引擎匹配（gemini-* 用于 Gemini，gpt-* 用于 OpenAI）
3. **温度参数**：Gemini 推荐 0.3-0.5，OpenAI 推荐 0.3
4. **Fallback**：默认关闭，如需启用请谨慎使用（可能导致输出不一致）
