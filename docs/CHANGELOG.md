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
- 详见 [IDE-CHANGELOG.md](IDE-CHANGELOG.md)
