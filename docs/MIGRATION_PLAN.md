# Doubao ASR 重构迁移计划

## 函数分配清单（从 doubao_asr.py 拆分）

### 📁 models/doubao/client.py
**职责：纯 API 调用（HTTP 客户端）**

| 函数/类 | 来源行号 | 说明 |
|---------|---------|------|
| `DoubaoASRClient` | ~371-487 | 完整类（submit, query, submit_and_poll） |
| `guess_audio_format()` | ~489-495 | 从 URL/路径猜测音频格式 |

**禁止包含：**
- ❌ preset 选择逻辑
- ❌ speaker 解析
- ❌ SRT 生成
- ❌ 视频/音频处理

---

### 📁 models/doubao/presets.py
**职责：预设参数管理（纯配置）**

| 函数/类 | 来源行号 | 说明 |
|---------|---------|------|
| `load_presets_from_yaml()` | ~53-95 | 从 YAML 加载预设 |
| `get_presets()` | ~156-161 | 获取预设（优先 YAML） |
| `_DEFAULT_PRESETS` | ~60-152 | 内置预设字典（如果 YAML 不存在） |
| `POSTPROFILES` | ~186-219 | 后处理策略配置 |

**禁止包含：**
- ❌ API 调用
- ❌ speaker 算法
- ❌ SRT 生成

---

### 📁 models/doubao/parser.py
**职责：数据解码（raw JSON → 结构化数据）**

| 函数/类 | 来源行号 | 说明 |
|---------|---------|------|
| `parse_utterances()` | ~243-268 | raw JSON → `Utterance[]` |
| `normalize_text()` | ~234-240 | 文本规范化（空格、标点） |

**禁止包含：**
- ❌ 合并句子
- ❌ speaker 策略
- ❌ 业务规则

---

### 📁 models/doubao/postprocess.py ⭐
**职责：speaker-aware 算法（核心逻辑）**

| 函数/类 | 来源行号 | 说明 |
|---------|---------|------|
| `speaker_aware_postprocess()` | ~271-340 | `Utterance[]` → `Segment[]`（保留 speaker） |
| 内部辅助函数（如 `flush()`） | ~297-304 | 合并逻辑 |

**注意：**
- ✅ 输入：`Utterance[]`（带 speaker）
- ✅ 输出：`Segment[]`（仍带 speaker，但已切分/合并）
- ✅ 硬规则：speaker 变化必须切分
- ✅ 只允许同 speaker 合并

**禁止包含：**
- ❌ SRT 输出
- ❌ 读取 preset/yaml（通过参数传入）
- ❌ API 调用

---

### 📁 models/doubao/formats.py
**职责：格式转换（Segment → SRT）**

| 函数/类 | 来源行号 | 说明 |
|---------|---------|------|
| `to_srt()` | 新建 | `Segment[]` → `SrtCue[]`（去掉 speaker） |
| `ms_to_srt_time()` | ~222-231 | 毫秒 → SRT 时间格式 |
| `write_srt()` | ~356-364 | `SrtCue[]` → SRT 文件 |

**注意：**
- ✅ 输入：`Segment[]`（带 speaker）
- ✅ 输出：`SrtCue[]`（不带 speaker）
- ✅ 强制：不输出 `[speaker]` 标签
- ✅ 强制：不在同一条字幕中混 speaker

---

### 📁 pipeline/asr/doubao.py
**职责：Pipeline 适配器（胶水层）**

| 函数/类 | 来源行号 | 说明 |
|---------|---------|------|
| `DoubaoLLMASR` | asr_doubao_llm.py | 完整类（transcribe 方法） |
| `_compute_audio_sha1()` | asr_doubao_llm.py ~32-38 | 计算音频 SHA1 |
| `_generate_cache_key()` | asr_doubao_llm.py ~41-64 | 生成缓存 key |
| `_get_cache_paths()` | asr_doubao_llm.py ~67-79 | 获取缓存路径 |
| `_write_cache_atomic()` | asr_doubao_llm.py ~82-96 | 原子写入缓存 |
| `_append_manifest()` | asr_doubao_llm.py ~99-110 | 追加 manifest |
| `_get_doubao_config()` | asr_doubao_llm.py ~113-138 | 获取 API 配置 |
| `_extract_audio_to_m4a()` | asr_doubao_llm.py ~348-367 | 从视频提取音频 |

**禁止包含：**
- ❌ 解析 raw JSON（调用 `parser.parse()`）
- ❌ speaker 算法（调用 `postprocess.speaker_aware_postprocess()`）
- ❌ 拼 SRT（调用 `formats.to_srt()`）

---

## 迁移步骤

### 1. 创建目录结构
```bash
mkdir -p src/video_remix/models/doubao
mkdir -p src/video_remix/pipeline/asr
```

### 2. 移动文件
```bash
# 移动 pipeline 文件
git mv src/video_remix/pipeline/asr_doubao_llm.py \
       src/video_remix/pipeline/asr/doubao.py

# doubao_asr.py 将在拆分后删除
```

### 3. 拆分 doubao_asr.py

按上述清单，将函数分配到对应文件：

1. **client.py**: 创建 `DoubaoASRClient` 和 `guess_audio_format`
2. **presets.py**: 创建预设加载和配置函数
3. **parser.py**: 创建 `parse_utterances` 和 `normalize_text`
4. **postprocess.py**: 创建 `speaker_aware_postprocess`（修改返回 `Segment[]`）
5. **formats.py**: 创建 `to_srt` 和 `write_srt`

### 4. 更新导入

**旧代码：**
```python
from video_remix.models.doubao_asr import (
    DoubaoASRClient,
    parse_utterances,
    speaker_aware_to_srt,
)
```

**新代码：**
```python
from video_remix.models.doubao import (
    client,
    parser,
    postprocess,
    formats,
)

# 使用
raw = client.DoubaoASRClient(...).submit_and_poll(...)
utterances = parser.parse_utterances(raw)
segments = postprocess.speaker_aware_postprocess(utterances, profile)
srt_cues = formats.to_srt(segments)
formats.write_srt(srt_cues, "out.srt")
```

### 5. 删除旧文件
```bash
rm src/video_remix/models/doubao_asr.py
```

---

## 关键修改点

### postprocess.py 返回值修改

**旧代码：**
```python
def speaker_aware_to_srt(utterances, profile) -> List[SrtCue]:
    # ... 返回 SrtCue[]
```

**新代码：**
```python
def speaker_aware_postprocess(utterances, profile) -> List[Segment]:
    # ... 返回 Segment[]（仍带 speaker）
```

### formats.py 新增函数

```python
def to_srt(segments: List[Segment]) -> List[SrtCue]:
    """Segment[] → SrtCue[]（去掉 speaker）"""
    return [
        SrtCue(
            start_ms=seg.start_ms,
            end_ms=seg.end_ms,
            text=seg.text,  # 不包含 speaker 标签
        )
        for seg in segments
    ]
```

---

## 验证清单

- [ ] 所有文件语法检查通过
- [ ] 所有导入路径更新
- [ ] `test_doubao_asr.py` 能正常运行
- [ ] `asr_doubao_llm.py` (新 `pipeline/asr/doubao.py`) 能正常运行
- [ ] 数据结构 `Segment` 已明确定义
- [ ] 旧文件 `doubao_asr.py` 已删除
