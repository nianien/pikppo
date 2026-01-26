# 豆包大模型版 API 请求参数说明

## 快速开始：预设配置

针对**短剧字幕场景**（<3分钟 + BGM/转场多 + 需要时间对齐），提供了以下预设配置：

### 预设配置列表

| 预设名 | 说明 | 模型版本 | VAD切句 | end_window_size | 适用场景 |
|--------|------|----------|---------|-----------------|----------|
| `default` | 默认配置 | 1.0 | ❌ | - | 通用场景 |
| `drama_v1` | 短剧主路 | 1.0 | ✅ | 800ms | **推荐**：短剧主路，稳+可重打轴 |
| `drama_v2` | 短剧对照 | 2.0 | ✅ | 800ms | 对照测试，说话人分离更好 |
| `drama_fast` | 短剧快速 | 1.0 | ✅ | 600ms | 更碎，更贴口型，字幕条数多 |
| `drama_smooth` | 短剧平滑 | 1.0 | ✅ | 1000ms | 更不碎，合并更多句子 |
| `drama_semantic` | 短剧语义 | 1.0 | ❌ | - | 语义切句，不开VAD |

### 使用方法

```bash
# 使用预设配置（大模型标准版）
python test/test_doubao_asr.py --llm <音频URL> --preset drama_v1

# 使用预设配置（大模型极速版）
python test/test_doubao_asr.py --flash <音频文件或URL> --preset drama_v1

# 不指定预设，使用默认配置
python test/test_doubao_asr.py --llm <音频URL>
```

### 推荐配置说明

#### 1. **drama_v1（短剧主路）** - 推荐作为主路

**参数特点**：
- ✅ `show_utterances=true`：必须开，拿到可重打轴的信息
- ✅ `vad_segment=true`：VAD切句，更贴时间轴
- ✅ `end_window_size=800ms`：平衡的静音判停时间
- ✅ `enable_ddc=false`：不开顺滑，避免改写原话
- ✅ `enable_punc=false`：先不开，后处理补标点
- ✅ `model_version="400"`：使用优化后的模型版本

**适用场景**：
- 短剧字幕工程
- 需要时间对齐
- 宁可碎一点，也不要合并

#### 2. **drama_fast（短剧快速）** - 更碎，更贴口型

**参数特点**：
- `end_window_size=600ms`：更短的静音判停，句子更碎
- 字幕条数会变多，但更贴口型

**适用场景**：
- 语速快的短剧
- 对白密集的场景

#### 3. **drama_smooth（短剧平滑）** - 更不碎

**参数特点**：
- `end_window_size=1000ms`：更长的静音判停，合并更多句子
- 字幕条数更少

**适用场景**：
- 语速慢的短剧
- 对白稀疏的场景

#### 4. **drama_v2（短剧对照）** - 模型2.0

**参数特点**：
- 使用 `volc.seedasr.auc`（模型2.0）
- 更强的说话人分离/上下文理解
- 在转场/BGM边缘可能"顺一句"

**适用场景**：
- 需要说话人分离时
- 作为对照测试

### 参数调优建议

**针对同一集短剧，建议做3档扫参**：

```bash
# 600ms：更碎，更贴口型
python test/test_doubao_asr.py --llm <URL> --preset drama_fast

# 800ms：平衡（推荐起点）
python test/test_doubao_asr.py --llm <URL> --preset drama_v1

# 1000ms：更不碎
python test/test_doubao_asr.py --llm <URL> --preset drama_smooth
```

看哪个最符合字幕节奏（条数/对齐/碎不碎），再定下来全量跑。

---

## 一、大模型标准版（submit/query 模式）

### 1.1 提交任务接口（submit）

**接口地址**: `POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit`

**Header 参数**:
- `X-Api-App-Key`: appid（必填）
- `X-Api-Access-Key`: access_token（必填）
- `X-Api-Resource-Id`: 资源 ID（默认：`volc.bigasr.auc`，可选：`volc.seedasr.auc`）
- `X-Api-Request-Id`: 任务 ID（UUID，自动生成）
- `X-Api-Sequence`: `-1`（固定值）
- `Content-Type`: `application/json`

**请求体参数（request）**:

| 参数 | 类型 | 说明 | 当前使用值 | 是否必填 |
|------|------|------|------------|----------|
| `model_name` | string | 模型名称 | `"bigmodel"` | ✅ 必填 |
| `enable_itn` | bool | 启用 ITN（文本规范化） | `True` | ❌ 可选 |
| `enable_punc` | bool | 启用标点 | `False` | ❌ 可选 |
| `enable_ddc` | bool | 启用顺滑 | `False` | ❌ 可选 |
| `enable_speaker_info` | bool | 启用说话人聚类分离 | `False` | ❌ 可选 |
| `show_utterances` | bool | 输出语音停顿、分句、分词信息 | `True` | ❌ 可选 |
| `model_version` | string | 模型版本 | ❌ 未使用 | ❌ 可选 |
| `ssd_version` | string | SSD 版本 | ❌ 未使用 | ❌ 可选 |
| `enable_channel_split` | bool | 启用双声道识别 | ❌ 未使用 | ❌ 可选 |
| `vad_segment` | bool | 使用 VAD 分句 | ❌ 未使用 | ❌ 可选 |
| `end_window_size` | int | 强制判停时间（300-5000ms） | ❌ 未使用 | ❌ 可选 |
| `sensitive_words_filter` | string | 敏感词过滤 | ❌ 未使用 | ❌ 可选 |
| `enable_poi_fc` | bool | 开启 POI function call | ❌ 未使用 | ❌ 可选 |
| `enable_music_fc` | bool | 开启音乐 function call | ❌ 未使用 | ❌ 可选 |
| `corpus` | dict | 语料/干预词等 | ❌ 未使用 | ❌ 可选 |
| `boosting_table_name` | string | 自学习平台热词表名称 | ❌ 未使用 | ❌ 可选 |
| `correct_table_name` | string | 自学习平台替换词表名称 | ❌ 未使用 | ❌ 可选 |
| `enable_lid` | bool | 启用语种识别 | ❌ 未使用 | ❌ 可选 |
| `enable_emotion_detection` | bool | 启用情绪检测 | ❌ 未使用 | ❌ 可选 |
| `enable_gender_detection` | bool | 启用性别检测 | ❌ 未使用 | ❌ 可选 |
| `show_volume` | bool | 分句信息携带音量 | ❌ 未使用 | ❌ 可选 |
| `show_speech_rate` | bool | 分句信息携带语速 | ❌ 未使用 | ❌ 可选 |

**请求体参数（audio）**:

| 参数 | 类型 | 说明 | 当前使用值 | 是否必填 |
|------|------|------|------------|----------|
| `url` | string | 音频文件 URL | 从参数传入 | ✅ 必填（与 data 二选一） |
| `language` | string | 指定可识别的语言 | `""`（空字符串，自动识别） | ❌ 可选 |
| `format` | string | 音频容器格式 | ❌ 未使用 | ❌ 可选 |
| `codec` | string | 音频编码格式 | ❌ 未使用 | ❌ 可选 |
| `rate` | int | 音频采样率 | ❌ 未使用 | ❌ 可选 |
| `bits` | int | 音频采样点位数 | ❌ 未使用 | ❌ 可选 |
| `channel` | int | 音频声道数 | ❌ 未使用 | ❌ 可选 |

**请求体参数（user）**:

| 参数 | 类型 | 说明 | 当前使用值 | 是否必填 |
|------|------|------|------------|----------|
| `uid` | string | 用户标识 | `"test_user"` | ❌ 可选 |

### 1.2 查询任务接口（query）

**接口地址**: `POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/query`

**Header 参数**:
- `X-Api-App-Key`: appid（必填）
- `X-Api-Access-Key`: access_token（必填）
- `X-Api-Resource-Id`: 资源 ID（默认：`volc.bigasr.auc`）
- `X-Api-Request-Id`: task_id（提交任务时返回的 task_id）
- `Content-Type`: `application/json`

**请求体**: 空 JSON `{}`

---

## 二、大模型极速版（一次请求返回）

### 2.1 识别接口（recognize/flash）

**接口地址**: `POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash`

**Header 参数**:
- `X-Api-App-Key`: appid（必填）
- `X-Api-Access-Key`: access_token（必填）
- `X-Api-Resource-Id`: `volc.bigasr.auc_turbo`（固定值）
- `X-Api-Request-Id`: 请求 ID（UUID，自动生成）
- `X-Api-Sequence`: `-1`（固定值）
- `Content-Type`: `application/json`

**请求体参数（request）**:

| 参数 | 类型 | 说明 | 当前使用值 | 是否必填 |
|------|------|------|------------|----------|
| `model_name` | string | 模型名称 | `"bigmodel"` | ✅ 必填 |
| `enable_itn` | bool | 启用 ITN（文本规范化） | `True` | ❌ 可选 |
| `enable_punc` | bool | 启用标点 | `False` | ❌ 可选 |
| `enable_ddc` | bool | 启用顺滑 | `False` | ❌ 可选 |
| `enable_speaker_info` | bool | 启用说话人聚类分离 | `False` | ❌ 可选 |

**注意**: 极速版不支持以下参数（标准版支持）：
- `show_utterances`（极速版默认返回 utterances）
- `enable_lid`（语种识别）
- `enable_emotion_detection`（情绪检测）
- `enable_gender_detection`（性别检测）
- `show_volume`（音量信息）
- `show_speech_rate`（语速信息）
- `callback`（回调地址）
- `callback_data`（回调信息）

**请求体参数（audio）**:

| 参数 | 类型 | 说明 | 当前使用值 | 是否必填 |
|------|------|------|------------|----------|
| `url` | string | 音频文件 URL | 从参数传入 | ✅ 必填（与 data 二选一） |
| `data` | string | Base64 编码的音频内容 | 从本地文件转换 | ✅ 必填（与 url 二选一） |
| `language` | string | 指定可识别的语言 | `""`（空字符串，自动识别） | ❌ 可选 |

**请求体参数（user）**:

| 参数 | 类型 | 说明 | 当前使用值 | 是否必填 |
|------|------|------|------------|----------|
| `uid` | string | 用户标识 | `appid` | ❌ 可选 |

---

## 三、当前代码使用的参数总结

### 3.1 大模型标准版（submit_audio_task_llm）

**当前使用的参数**:
```python
{
    "user": {
        "uid": "test_user"
    },
    "audio": {
        "url": "<audio_url>",
        "language": ""  # 空字符串表示自动识别
    },
    "request": {
        "model_name": "bigmodel",
        "enable_itn": True,
        "enable_punc": False,
        "enable_ddc": False,
        "enable_speaker_info": False,
        "show_utterances": True
    }
}
```

**未使用的参数**:
- `model_version`（模型版本，如 "400"）
- `ssd_version`（SSD 版本）
- `enable_channel_split`（双声道识别）
- `vad_segment`（VAD 分句）
- `end_window_size`（强制判停时间）
- `sensitive_words_filter`（敏感词过滤）
- `enable_poi_fc`（POI function call）
- `enable_music_fc`（音乐 function call）
- `corpus`（语料/干预词）
- `boosting_table_name`（热词表）
- `correct_table_name`（替换词表）
- `enable_lid`（语种识别）
- `enable_emotion_detection`（情绪检测）
- `enable_gender_detection`（性别检测）
- `show_volume`（音量信息）
- `show_speech_rate`（语速信息）

### 3.2 大模型极速版（recognize_audio_flash）

**当前使用的参数**:
```python
{
    "user": {
        "uid": "<appid>"
    },
    "audio": {
        "url": "<audio_url>",  # 或 "data": "<base64_data>"
        "language": ""  # 空字符串表示自动识别
    },
    "request": {
        "model_name": "bigmodel",
        "enable_itn": True,
        "enable_punc": False,
        "enable_ddc": False,
        "enable_speaker_info": False
    }
}
```

**未使用的参数**:
- 极速版不支持标准版的扩展参数（见上方说明）

---

## 四、参数说明

### 4.1 常用参数

- **`enable_itn`**: 文本规范化，将中文数字转为阿拉伯数字（如"一九七零年"→"1970年"）
- **`enable_punc`**: 增加标点符号
- **`enable_ddc`**: 语义顺滑，删除停顿词、语气词、重复词等
- **`enable_speaker_info`**: 说话人聚类分离（10人以内效果较好）
- **`show_utterances`**: 输出分句、分词信息（包含时间戳）

### 4.2 语言参数

- 空字符串 `""`: 自动识别（支持中英文、上海话、闽南语、四川、陕西、粤语）
- `"en-US"`: 英语
- `"ja-JP"`: 日语
- `"id-ID"`: 印尼语
- `"es-MX"`: 西班牙语
- `"pt-BR"`: 葡萄牙语
- `"de-DE"`: 德语
- `"fr-FR"`: 法语
- `"ko-KR"`: 韩语
- `"fil-PH"`: 菲律宾语
- `"ms-MY"`: 马来语
- `"th-TH"`: 泰语
- `"ar-SA"`: 阿拉伯语

---

## 五、使用建议

### 5.1 标准版 vs 极速版

- **极速版**：音频 ≤ 2h，≤ 100MB，一次请求返回
- **标准版**：无时长限制，需要 submit/query 轮询

### 5.2 资源 ID 选择

- `volc.bigasr.auc`: 豆包录音文件识别模型1.0（更保守，适合自动链路主结果）
- `volc.seedasr.auc`: 豆包录音文件识别模型2.0（更强的说话人分离/上下文理解）
- `volc.bigasr.auc_turbo`: 极速版（固定值）

### 5.3 短剧字幕场景参数选择

**核心原则**：宁可碎一点，也不要合并；宁可少"顺滑"，也不要"改写"；要 word/utterance 级时间戳，轴你自己掌控。

**必须打开**：
- ✅ `show_utterances=true`：拿到可重打轴的信息，解决"Flash 合并句子"问题

**断句策略**：
- ✅ `vad_segment=true`：按声音停顿切，更贴时间轴
- ✅ `end_window_size=600~900`：建议从 800ms 开始
  - 600ms：更碎、更贴口型，但字幕条数会变多
  - 800ms：比较平衡（短剧常用）
  - 1000ms：更不碎，但可能合并更多句子

**不要开**：
- ❌ `enable_ddc=false`：顺滑会删口头禅、重复词、语气词，短剧对白里这些东西往往是情绪和节奏的一部分
- ❌ `enable_punc=false`：先不开，减少模型插入标点造成的切句变化，后处理阶段自己补标点/断句

**建议开**：
- ✅ `enable_itn=true`：文本规范化，把"一九七零年"变"1970年"，可读性更好
- ✅ `model_version="400"`：有提升且 ITN 优化更好

**说话人分离**：
- 短剧一般先别开（`enable_speaker_info=false`），因为短剧往往有远近变化、环境声、转场，会让 diarization 更不稳定

### 5.4 参数调优流程

1. **先用预设配置跑一次**：`--preset drama_v1`
2. **如果句子太碎**：尝试 `--preset drama_smooth`（1000ms）
3. **如果句子太合并**：尝试 `--preset drama_fast`（600ms）
4. **需要说话人分离**：尝试 `--preset drama_v2`（模型2.0）
5. **找到甜点后**：固定参数，全量跑
