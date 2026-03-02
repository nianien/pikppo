# Changelog

## 2026-03-02

### Pipeline

- 合并 parse + reseg 为单个 phase，减少 dub.json 多阶段写入冲突
- should_run 改为逐 artifact 一致性校验，替代 composite inputs_fingerprint
- 删除 reseg phase（processor 层保留），清理 compute_inputs_fingerprint

### 翻译 (MT)

- 翻译 prompt 支持故事背景注入，自动读取 `{drama_dir}/story_background.txt`
- 移除硬编码的 plot_overview 默认值，清理整条链路的 plot_overview 参数
- system prompt 从 "crime drama" 改为 "Chinese TV drama"（通用化）

### Web IDE

- 详见 [IDE-CHANGELOG.md](IDE-CHANGELOG.md)
