# Dubora

中文短剧自动配音流水线。输入中文视频（无需剧本），输出英文配音版本，包含多角色语音合成、硬烧英文字幕、保留背景音乐。

## 流水线

```
阶段:  提取      识别              [校准]    翻译            [审阅]    配音           合成
Phase: extract   asr → parse                mt → align                tts → mix     burn
Gate:                              ↑                          ↑
                            source_review              translation_review
```

8 个 phase，2 个人工审阅 gate，基于 SHA256 指纹的增量执行。

## 快速开始

```bash
# 安装（按角色选择）
make install          # 仅核心依赖
make install-full     # 全部依赖（本地开发推荐）

# 运行完整流水线
vsd run video.mp4 --to burn

# 启动校准 IDE
vsd ide --videos ./videos
```

## 命令行

```bash
vsd run video.mp4 --to burn                # 完整流水线
vsd run video.mp4 --from mt --to tts       # 从 mt 重跑到 tts
vsd bless video.mp4 parse                  # 手动编辑后刷新指纹
vsd phases                                 # 列出所有 phase
vsd ide --videos ./videos                  # 校准 IDE（默认端口 8765）
```

## 校准 IDE

基于 Web 的 ASR 校准工具，用于翻译和配音前的字幕校准。

- 可视化段落编辑：文本（中英文）、说话人、情绪、时间轴
- 段落拆分 / 合并 / 插入 / 删除，支持撤销重做
- 视频同步播放与字幕叠加
- 流水线控制面板：运行、取消、从任意阶段重跑
- 配音视频播放，支持 A/B 对比
- 角色选角：为角色分配 TTS 音色，内联试听

```bash
vsd ide --videos ./videos      # http://localhost:8765
vsd ide --port 9000 --dev      # 开发模式，支持热更新
```

详见 [docs/IDE-GUIDE.md](docs/IDE-GUIDE.md) 操作手册，[docs/IDE-CHANGELOG.md](docs/IDE-CHANGELOG.md) 变更记录。

## 架构

```
CLI (cli.py)
  └── Pipeline Framework (pipeline/core/)
        ├── PhaseRunner, Manifest, Fingerprints
        └── Phases (pipeline/phases/)  ←→  Processors (无状态业务逻辑)
              └── Schema, Config, External Services
```

- **Phase**：编排层（文件 IO、manifest 更新）
- **Processor**：无状态业务逻辑（纯计算，可独立测试）
- **Manifest**：JSON 状态机，跟踪 phase 状态和 artifact 指纹

详见 [docs/DESIGN.md](docs/DESIGN.md) 技术设计，[docs/CHANGELOG.md](docs/CHANGELOG.md) 变更记录。

## 工作区布局

```
videos/{drama}/
├── 1.mp4                          # 源视频
├── story_background.txt           # 故事背景（翻译时自动注入 prompt）
└── dub/
    ├── dict/
    │   ├── roles.json             # 角色音色映射
    │   ├── names.json             # 角色名翻译
    │   └── slang.json             # 领域术语表
    └── 1/                         # 单集工作区
        ├── manifest.json          # 流水线状态
        ├── input/                 # 不可变（音频、人声、asr-result.json）
        ├── state/                 # 人工可编辑 SSOT（dub.json）
        ├── derived/               # 可重算中间产物（mt/、tts/、mix）
        └── output/                # 最终交付物（配音视频、SRT 字幕）
```

## 外部服务

| 服务 | 用途 | 环境变量 |
|------|------|----------|
| 豆包 ASR（字节跳动） | 语音识别 + 说话人分离 | `DOUBAO_APPID`, `DOUBAO_ACCESS_TOKEN` |
| 火山引擎 TOS | ASR 音频上传存储 | `TOS_ACCESS_KEY_ID`, `TOS_SECRET_ACCESS_KEY` |
| 火山引擎 TTS | 英文语音合成 | 同豆包 |
| Google Gemini | 翻译（默认引擎） | `GEMINI_API_KEY` |
| OpenAI | 翻译（备选）+ 断句优化 | `OPENAI_API_KEY` |
| Demucs | 人声分离 | 本地 |
| FFmpeg | 音视频处理 | 本地 |

## 开发

```bash
make install-dev     # 安装开发依赖
make test            # 运行测试
make lint            # Ruff 检查
make clean           # 清理缓存
```

## 许可证

私有 / 保留所有权利。
