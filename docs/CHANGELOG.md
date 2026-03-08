# Changelog

## 2026-03-02

### Pipeline

- 合并 parse + reseg 为单个 phase，减少 dub.json 多阶段写入冲突
- should_run 改为逐 artifact 一致性校验，替代 composite inputs_fingerprint
- 删除 reseg phase（processor 层保留），清理 compute_inputs_fingerprint
- parse 阶段增加 LLM emotion 修正，reseg 断句后根据台词语义修正情绪标注
  - 新增 `emotion_correct` processor 和 prompt 模板
  - 提取 `_create_llm_fn()` 供 reseg 和 emotion_correct 共用
  - 支持 `phases.parse.emotion_correct_enabled` 开关（默认开启）
- ASR 热词从 `names.json` 自动加载，移除 `PipelineConfig.doubao_hotwords` 硬编码

### 翻译 (MT)

- 翻译 prompt 支持故事背景注入，自动读取 `{drama_dir}/story_background.txt`
- 移除硬编码的 plot_overview 默认值，清理整条链路的 plot_overview 参数
- system prompt 从 "crime drama" 改为 "Chinese TV drama"（通用化）

### 工程

- `emotions.json` 从 `src/dubora/config/` 迁移到项目根 `resources/`
- 新增 `PROJECT_ROOT` 常量（通过查找 `pyproject.toml` 定位），替代脆弱的 `parents[N]` 路径

### Web IDE

- 段落面板时间显示：左侧改为开始时间 + 结束时间，右侧保留时长，修复重复显示问题

#### 快捷键优化

- 方向键操作时自动暂停播放，便于精确对齐
- 新增 Shift+Alt+方向键：segment 边界直接对齐到光标位置
- Alt+方向键调整精度从 100ms 改为 50ms
- 播放 seek 精度从 100ms 改为 50ms

#### 段落操作优化

- 拆分段落时按标点符号切分，移除分割点的标点
- 生成 dub.json 时自动去除每句末尾的逗号和句号

#### 时间轴交互优化

- 点击 segment 只选中，不移动播放光标
- 播放光标靠近窗口左右 10% 区域时自动滚动居中
- segment 标签不再显示说话人前缀，节省空间
- 选中 segment 的活跃边界手柄高亮为黄色

#### 段落列表优化

- 显示起始时间 + 时长（双行显示）
- 角色不在 roles 中时显示灰色标记

## 2026-03-01

### Web IDE

#### 角色管理

- 角色下拉列表按拼音排序
- 角色/音色映射页面支持内联添加和删除角色

#### 数据保存

- 新增自动保存：修改后 2 秒自动保存
- Ctrl+S 手动保存

#### 基础快捷键

- Space 播放/暂停
- Enter 跳转下一段并播放
- 方向键上下切换段落
- 方向键左右微调播放进度
- Alt+方向键微调 segment 起止时间（光标位置决定调 start 还是 end）
- Ctrl+B 拆分段落，Ctrl+M 合并段落
- Ctrl+I 插入空段落，Delete 删除段落
- 数字键 1-9 快速切换说话人
- N/A/S/E/I/F 快速切换情绪

#### 撤销/重做

- Ctrl+Z 撤销，Ctrl+Shift+Z 重做
- 所有段落操作（编辑、拆分、合并、插入、删除）均支持撤销
