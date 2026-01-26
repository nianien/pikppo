# Video Subtitle Dubber v2.0

Complete video dubbing pipeline: **Chinese short drama → English subtitles + English dubbing with multi-voice support**

## 🎯 Features

- ✅ **Complete Dubbing Pipeline**: One command from video to dubbed output
- ✅ **Multi-Voice Support**: Automatic speaker diarization + voice assignment (8 Azure Neural TTS voices)
- ✅ **High-Quality Translation**: Two-stage OpenAI translation (context-aware, consistent terminology)
- ✅ **Professional Audio**: Demucs vocal separation, ducking, loudness normalization
- ✅ **Subtitle Generation**: SRT + ASS formats with safe area support
- ✅ **Quality Control**: Automatic QC reports for all pipeline stages
- ✅ **Modular & Resumable**: Each stage outputs intermediate files, can rerun specific steps

## 🚀 Quick Start

### Installation

**推荐安装方式：**

```bash
# 1. 创建并激活虚拟环境
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate

# 2. 进入 app 目录
cd app

# 3. 安装项目（包含 dubbing 功能）
pip install -e ".[dub]"
```

**详细安装说明请查看 [INSTALL.md](INSTALL.md)**

### Installation (Legacy)

```bash
cd app
pip install -e ".[dub]"
```

**Note**: The `[dub]` extra includes all dependencies for the complete dubbing pipeline:
- `demucs` - Vocal separation
- `google-cloud-speech` - ASR + diarization
- `openai` - Translation
- `azure-cognitiveservices-speech` - TTS
- `librosa` - Gender detection (optional)

### Environment Configuration

**Recommended**: Use project-level `.env` file (not global environment variables).

1. Copy the example file:
```bash
cp .env.example .env
```

2. Edit `.env` and fill in your credentials:
```bash
# Google Cloud Speech-to-Text
# 相对路径相对于 .env 文件所在目录（推荐使用相对路径）
GCP_SPEECH_CREDENTIALS=.gcp/gcp-pikppo-speech.json

# OpenAI
OPENAI_API_KEY=your-openai-api-key

# Azure Speech Service
AZURE_SPEECH_KEY=your-azure-speech-key
AZURE_SPEECH_REGION=eastus
```

3. Place your Google Cloud service account JSON file:
```bash
mkdir -p credentials
# Download from Google Cloud Console and save as:
# credentials/gcp-pikppo-speech.json
```

**Note**: Relative paths in `.env` are resolved relative to the `.env` file's directory, not the current working directory. This means the path works correctly regardless of where you run the command from.

**Why `.env`?**
- ✅ Project-level isolation (no conflicts between projects)
- ✅ Not committed to git (`.env` is git-ignored)
- ✅ Works consistently in CLI, IDE, and CI/CD
- ✅ No shell environment pollution

### Basic Usage

```bash
# Complete dubbing pipeline (credentials loaded from .env)
vsd dub-en video.mp4

# Or override credentials via argument
vsd dub-en video.mp4 --google-credentials .gcp/gcp-pikppo-speech.json

# Output will be in: <video_dir>/dub/<video_stem>/
#   - <video_stem>-dubbed.mp4 (final dubbed video)
#   - <video_stem>-en.srt, <video_stem>-en.ass
#   - <video_stem>-qc.json
# 
# Example: videos/1.mp4 -> videos/dub/1/1-dubbed.mp4
```

**Note**: If `GCP_SPEECH_CREDENTIALS` is set in `.env`, you don't need to pass `--google-credentials` argument.

## 📋 Complete Pipeline

The `dub-en` command runs the complete pipeline:

1. **MediaPrep**: Extract audio (16k, mono, PCM)
2. **VocalSeparation**: Demucs separation (vocals + accompaniment)
3. **ASR + Diarization**: Google STT with speaker labels
4. **SubtitleBuild (Chinese)**: Generate zh.srt
5. **Translation**: OpenAI two-stage (context + segments)
6. **SubtitleBuild (English)**: Generate en.srt, en.ass
7. **Voice Assignment**: Map speakers to voice pool
8. **TTS Synthesis**: Azure Neural TTS per segment (with episode-level caching)
9. **Duration Alignment**: Stretch/trim to match timing
10. **Mixing + Mastering**: Ducking + loudness normalization
11. **QC Report**: Quality control report

### Output Structure

**Input**: `xxxx/1.mp4`  
**Output**: `xxxx/dub/1/`

```
xxxx/
├── 1.mp4
├── 2.mp4
└── dub/
    ├── 1/
    │   ├── 1.wav                          # Raw audio
    │   ├── 1-vocals.wav                   # Separated vocals
    │   ├── 1-accompaniment.wav            # Background audio
    │   ├── 1-zh-segments.json             # ASR segments
    │   ├── 1-zh-words.json                # Word-level data
    │   ├── 1-zh.srt                       # Chinese subtitles
    │   ├── 1-translation-context.json     # Translation context
    │   ├── 1-en-segments.json             # English segments
    │   ├── 1-en.srt                       # English subtitles (SRT)
    │   ├── 1-en.ass                       # English subtitles (ASS)
    │   ├── 1-voice-assignment.json        # Voice assignment
    │   ├── 1-tts.wav                      # TTS audio
    │   ├── 1-tts-aligned.wav              # Aligned TTS
    │   ├── 1-dubbed.mp4                   # Final output video
    │   ├── 1-qc.json                      # QC report
    │   └── .cache/                        # Episode-level cache (not deleted)
    │       └── tts/
    │           └── azure/
    │               ├── segments/           # Cached TTS segments
    │               │   └── <sha256>.wav
    │               └── manifest.jsonl     # Cache manifest
    └── 2/
        ├── 2.wav
        ├── 2-zh.srt
        ├── 2-en.srt
        └── ...
```

**Note**: All files use the video stem as prefix (e.g., `1-zh.srt` for `1.mp4`). Multiple videos in the same directory will have separate `dub/<stem>/` directories.

## 🎤 Voice Pool

The system uses 8 pre-configured Azure Neural TTS voices:

**Male Voices:**
- `en-US-GuyNeural` - Male lead (mature, stable)
- `en-US-DavisNeural` - Male support (calm, rational)
- `en-US-JasonNeural` - Young male (emotional, energetic)
- `en-US-TonyNeural` - Generic male (fallback)

**Female Voices:**
- `en-US-JennyNeural` - Female lead (emotional, expressive)
- `en-US-AriaNeural` - Mature female (professional, clear)
- `en-US-AmberNeural` - Young female (bright, lively)
- `en-US-AnaNeural` - Generic female (fallback, neutral)

**Assignment Strategy:**
- Top speakers (by speech duration) get unique voices
- Gender detection via pitch analysis
- Fallback to generic voices for minor speakers
- Conservative approach: better to use fewer distinct voices than risk misassignment

## ⚙️ Configuration

### Command-Line Options

```bash
# Using .env (recommended)
vsd dub-en video.mp4 \
  --output runs/ \
  --language-code zh-CN \
  --max-speakers 6 \
  --openai-model gpt-4o-mini \
  --demucs-model htdemucs \
  --demucs-device cpu \
  --voice-pool custom_voice_pool.json \
  --no-qc

# Or override credentials via argument
vsd dub-en video.mp4 --google-credentials .gcp/gcp-pikppo-speech.json
```

### Custom Voice Pool

Create a custom `voice_pool.json`:

```json
{
  "language": "en-US",
  "voices": {
    "adult_male_1": {
      "voice_id": "en-US-GuyNeural",
      "gender": "male",
      "role": "male_lead",
      "prosody": {"rate": 1.0, "pitch": 0, "volume": 0}
    },
    ...
  }
}
```

## 🔧 Advanced Usage

### Rerun Specific Stages

The pipeline saves all intermediate files. You can modify and rerun specific stages:

```python
from video_remix import translate_episode

# Rerun translation only
translate_episode(
    "xxxx/dub/1/1-zh-segments.json",
    "xxxx/dub/1/.temp_translate/",
    model="gpt-4",
)
```

### Quality Control

Check the QC report:

```bash
cat xxxx/dub/1/1-qc.json
```

The report includes:
- ASR confidence scores
- Diarization quality (number of speakers, overlaps)
- Translation violations (length, consistency)
- TTS duration alignment issues
- Mixing loudness levels

## 📊 Performance

**Typical processing times** (2-minute video):
- Demucs separation: 3-10 minutes (CPU), 1-3 minutes (GPU)
- Google STT: ~2-5 minutes
- OpenAI translation: ~1-2 minutes
- Azure TTS: ~2-3 minutes
- Mixing: ~1 minute

**Total**: ~10-20 minutes per video (depending on hardware and API speeds)

## 💰 Cost Estimation

**Per 2-minute video:**
- Google STT: ~$0.02-0.05
- OpenAI translation: ~$0.01-0.03
- Azure TTS: ~$0.02-0.04

**Total**: ~$0.05-0.12 per video

Much cheaper than SaaS platforms ($2-4/minute)!

## 🐛 Troubleshooting

### Demucs Installation Issues

```bash
# Install PyTorch first
pip install torch torchaudio

# Then install demucs
pip install demucs
```

### Google Cloud Credentials Setup

**Recommended approach**: Use project-level `.env` file.

1. **Download service account JSON** from Google Cloud Console:
   - Go to IAM & Admin → Service Accounts
   - Create or select a service account
   - Create a key (JSON format)
   - Save it as `credentials/gcp-pikppo-speech.json`

2. **Enable Speech-to-Text API** in your Google Cloud project

3. **Set in `.env` file**:
   ```bash
   GCP_SPEECH_CREDENTIALS=.gcp/gcp-pikppo-speech.json
   ```

4. **Done!** The CLI will automatically load from `.env`

**Alternative**: You can also pass credentials via `--google-credentials` argument to override `.env`.

**Why this approach?**
- ✅ Project-level isolation (no conflicts between projects)
- ✅ Not committed to git (`.env` is git-ignored)
- ✅ Works consistently in CLI, IDE, and CI/CD
- ✅ No shell environment pollution

### Azure TTS Issues

- Verify `AZURE_SPEECH_KEY` and `AZURE_SPEECH_REGION` are set
- Check Azure Speech Service is enabled in your subscription
- Ensure you have sufficient quota

### Low-Quality Diarization

If speakers are not being separated correctly:
- Check audio quality (vocals.wav should be clear)
- Try adjusting `--max-speakers` parameter
- Review QC report for diarization confidence

## 📚 Legacy Commands

The following commands are still available for backward compatibility:

- `vsd transcribe` - Old pipeline (Whisper + Gemini)
- `vsd extract` - Extract Chinese subtitles only
- `vsd translate` - Translate subtitle file
- `vsd tts` - TTS synthesis (old method)
- `vsd embed` - Embed subtitles
- `vsd remove` - Remove hardcoded subtitles
- `vsd replace` - Replace subtitles

## 🎯 Best Practices

1. **Audio Quality**: Ensure source video has clear audio
2. **Speaker Count**: For best results, limit to 2-4 main speakers
3. **Video Length**: Optimized for 1-5 minute short dramas
4. **Translation Quality**: Review `translation_context.json` for terminology consistency
5. **Voice Assignment**: Check `voice_assignment.json` and adjust if needed

## 📝 License

MIT License

## 🤝 Contributing

Contributions welcome! Please open an issue or submit a PR.
