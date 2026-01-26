# ASR 最终配置（参数锁定版）

## 核心原则

**字幕系统宁可少，不可乱（压制胡说比挽救弱人声重要）**

---

## 一、ASR 输入策略（自动选择）

### 优先级顺序

1. **优先使用 raw-16k.wav**（原始音频，16k mono + dynaudnorm）
2. **如果 raw 质量差（健康度 < 60），自动回退到 vocals-16k.wav**（人声分离，16k mono + afftdn + dynaudnorm）
3. **如果最终结果仍然很差（健康度 < 50），尝试 FunASR 回退**

### 音频预处理

**Raw 音频**:
```bash
ffmpeg -i audio/1.wav -ar 16000 -ac 1 -af dynaudnorm -acodec pcm_s16le -y audio/raw-16k.wav
```

**Vocals 音频**:
```bash
ffmpeg -i audio/vocals.wav -ar 16000 -ac 1 -af "afftdn,dynaudnorm" -acodec pcm_s16le -y audio/vocals-16k.wav
```

**为什么优先 raw？**
- Demucs vocals 可能含伪影/金属感/残留伴奏
- `dynaudnorm` 会把低能量部分抬起来，可能放大伪影
- Raw 音频更接近真实语音，避免伪影干扰

---

## 二、Whisper 核心参数（锁定）

```python
# 模型
model_size: "small"              # M2 16GB 推荐
device: "cpu"                    # 固定
compute_type: "int8"              # CPU 推荐，速度快

# 解码参数（字幕稳定优先）
beam_size: 5                      # 字幕稳定优先
best_of: 5                        # Best of N candidates
temperature: 0.0                  # 防幻觉（固定）
vad_filter: False                 # 时间轴不折叠（固定）
condition_on_previous_text: False # 防编话（固定）
no_speech_threshold: 0.4          # 压制胡说（0.4 或 0.6，不再用 0.2）
```

**为什么 `no_speech_threshold=0.4`（而不是 0.2）？**
- 0.2 在 vocals + dynaudnorm + 短剧场景下会导致过度解码
- 模型在非语音/伪语音区间被强行解码，导致系统性胡说
- 0.4 更克制，在不确定时选择不输出（符合字幕系统原则）

---

## 三、ASR 健康度评分器

### 评分维度（0-100 分，越高越好）

1. **平均每条时长**（理想：1.5-6.0 秒）
   - 过短（< 0.7s）：过度切分，扣 20 分
   - 过长（> 10s）：句子被粘，扣 15 分

2. **2-4 字短句占比**（理想：< 30%）
   - 过高（> 30%）：噪声词过多，扣 25 分（最严重）
   - 中等（> 20%）：扣 10 分

3. **重复词/称呼占比**（理想：< 15%）
   - 过高（> 15%）：已失控，扣 20 分
   - 中等（> 10%）：扣 10 分

4. **首条字幕时间**（理想：接近真实开口）
   - 过早（< 0.1s）且为短词：可能在静音也输出

5. **模板语占比**（理想：< 20%）
   - 过高（> 20%）：可能幻觉，扣 15 分

6. **总字数/时长比**（理想：2.0-8.0 字/秒）
   - 过低（< 2.0）：可能丢失内容，扣 10 分
   - 过高（> 8.0）：可能过度解码，扣 10 分

### 自动选择逻辑

- **Raw 健康度 >= 60**：使用 raw
- **Raw 健康度 < 60 且 Vocals 存在**：尝试 vocals，选择健康度更高的
- **最终健康度 < 50**：尝试 FunASR 回退

---

## 四、字幕后处理

### 处理规则

1. **合并连续短行**（2-4 字）
   - 如果相邻且时间连续（间隔 < 0.5s），合并
   - 如果下一个也是短行（<= 6 字）或间隔很小（< 1.0s），合并

2. **丢弃孤立短行**
   - 如果前后间隔都 > 1.5s，认为是孤立短行，丢弃

3. **过滤高频重复短词**
   - 如果同一短词（2-4 字）在 3 秒内重复出现 3 次以上，保留第一次，移除后续

---

## 五、完整执行流程

```
1. 提取原始音频 (audio/1.wav)
   ↓
2. 人声分离（如果需要，生成 audio/vocals.wav）
   ↓
3. 预处理 raw 音频 → audio/raw-16k.wav
   ↓
4. 预处理 vocals 音频 → audio/vocals-16k.wav（如果存在）
   ↓
5. ASR 识别 raw 音频
   ↓
6. 评估 raw 健康度
   ↓
7. 如果健康度 < 60 且 vocals 存在：
   - ASR 识别 vocals 音频
   - 评估 vocals 健康度
   - 选择健康度更高的结果
   ↓
8. 如果最终健康度 < 50：
   - 尝试 FunASR 回退
   ↓
9. 字幕后处理（合并短行、过滤重复词）
   ↓
10. 保存输出（zh-segments.json, zh-words.json, zh.srt）
```

---

## 六、配置总结

| 配置项 | 值 | 说明 |
|--------|-----|------|
| **ASR 输入** | `raw` 优先，`vocals` 备选 | 避免伪影干扰 |
| **no_speech_threshold** | `0.4` | 压制胡说（不再用 0.2） |
| **compute_type** | `int8` | CPU 推荐，速度快 |
| **beam_size** | `5` | 字幕稳定优先 |
| **temperature** | `0.0` | 防幻觉（固定） |
| **vad_filter** | `False` | 时间轴不折叠（固定） |
| **condition_on_previous_text** | `False` | 防编话（固定） |

---

## 七、关键改进点

1. ✅ **输入策略反转**：从 "vocals 优先" 改为 "raw 优先"
2. ✅ **健康度评分器**：自动判断 raw/vocals 哪个更好
3. ✅ **参数锁定**：`no_speech_threshold=0.4`（不再用 0.2）
4. ✅ **字幕后处理**：合并短行、过滤重复词
5. ✅ **自动回退**：raw → vocals → FunASR

---

## 八、使用示例

```bash
# 使用默认配置（raw 优先，no_speech_threshold=0.4）
vsd run videos/dbqsfy/1.mp4 --to asr-zh

# 如果需要更高准确度（但会慢）
vsd run videos/dbqsfy/1.mp4 --to asr-zh --whisper-compute-type float32

# 如果需要更激进的阈值（不推荐，可能导致过度解码）
vsd run videos/dbqsfy/1.mp4 --to asr-zh --whisper-no-speech-threshold 0.2
```

---

## 九、预期效果

- ✅ **减少过度解码**：不再在非语音/伪语音区间输出字幕
- ✅ **减少短词碎片**：2-4 字短句会被合并或丢弃
- ✅ **减少重复词**：高频重复短词会被过滤
- ✅ **更稳定的质量**：自动选择 raw/vocals 中更好的结果

---

## 十、核心原则重申

**字幕系统宁可少，不可乱（压制胡说比挽救弱人声重要）**

这个原则贯穿整个 pipeline：
- 输入选择：优先 raw（避免伪影）
- 参数设置：`no_speech_threshold=0.4`（更克制）
- 健康度评分：检测过度解码、短词碎片、重复词
- 后处理：合并短行、过滤重复词
