# Video Subtitle Dubber

**Complete video dubbing pipeline: Chinese short drama → English subtitles + English dubbing with multi-voice support**

## 🎯 Overview

This project provides a complete, production-ready pipeline for automatically dubbing Chinese short dramas into English with:

- **Multi-voice support**: Automatic speaker diarization + voice assignment (8 Azure Neural TTS voices)
- **High-quality translation**: Two-stage OpenAI translation (context-aware, consistent terminology)
- **Professional audio**: Demucs vocal separation, ducking, loudness normalization
- **Subtitle generation**: SRT + ASS formats with safe area support
- **Quality control**: Automatic QC reports for all pipeline stages

## 🚀 Quick Start

### Installation

```bash
cd app
pip install -e ".[dub]"
```

### Environment Setup

**Recommended**: Use project-level `.env` file (not global environment variables).

1. Copy the example file:
```bash
cd app
cp .env.example .env
```

2. Edit `.env` and fill in your credentials:
```bash
# Google Cloud Speech-to-Text
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

**Why `.env`?**
- ✅ Project-level isolation (no conflicts between projects)
- ✅ Not committed to git (`.env` is git-ignored)
- ✅ Works consistently in CLI, IDE, and CI/CD
- ✅ No shell environment pollution

### Usage

```bash
# Complete dubbing pipeline
vsd dub-en video.mp4

# Output in: <video_dir>/dub/<video_stem>/<video_stem>-dubbed.mp4
# Example: videos/1.mp4 -> videos/dub/1/1-dubbed.mp4
```

## 📁 Project Structure

```
pikppo/
├── app/                          # Main application
│   ├── pyproject.toml            # Project configuration
│   ├── README.md                 # Detailed documentation
│   └── src/
│       └── video_subtitle_dubber/
│           ├── cli.py            # CLI entry point
│           ├── config/           # Configuration
│           ├── models/           # AI model adapters
│           │   └── voice_pool.py  # Voice pool management
│           └── pipeline/         # Core pipeline modules
│               ├── dub_pipeline.py      # Main dubbing pipeline
│               ├── media_prep.py        # Audio extraction
│               ├── vocal_separation.py  # Demucs separation
│               ├── asr_google.py        # Google STT + diarization
│               ├── translate_openai.py  # Two-stage translation
│               ├── assign_voices.py     # Voice assignment
│               ├── tts_azure.py      # Azure TTS synthesis
│               ├── duration_align.py    # Duration alignment
│               ├── mix_audio.py         # Audio mixing
│               └── qc_report.py          # QC reporting
├── docs/                         # Documentation
│   ├── prd.txt                   # Product requirements
│   └── technical.txt             # Technical specifications
└── videos/                       # Video files directory
    ├── 1.mp4
    ├── 2.mp4
    └── dub/                      # Output directory (auto-created)
        ├── 1/                    # Output for 1.mp4
        └── 2/                    # Output for 2.mp4
```

## 🔄 Complete Pipeline

The `dub-en` command runs 11 stages:

1. **MediaPrep**: Extract audio (16k, mono, PCM)
2. **VocalSeparation**: Demucs separation (vocals + accompaniment)
3. **ASR + Diarization**: Google STT with speaker labels
4. **SubtitleBuild (Chinese)**: Generate zh.srt
5. **Translation**: OpenAI two-stage (context + segments)
6. **SubtitleBuild (English)**: Generate en.srt, en.ass
7. **Voice Assignment**: Map speakers to voice pool
8. **TTS Synthesis**: Azure Neural TTS per segment
9. **Duration Alignment**: Stretch/trim to match timing
10. **Mixing + Mastering**: Ducking + loudness normalization
11. **QC Report**: Quality control report

## 🎤 Voice Pool

8 pre-configured Azure Neural TTS voices:

**Male**: GuyNeural (lead), DavisNeural (support), JasonNeural (young), TonyNeural (generic)
**Female**: JennyNeural (lead), AriaNeural (mature), AmberNeural (young), AnaNeural (generic)

Assignment based on:
- Speaker importance (speech duration)
- Gender detection (pitch analysis)
- Conservative fallback strategy

## 📊 Performance & Cost

**Processing Time** (2-minute video):
- Total: ~10-20 minutes
- Demucs: 3-10 min (CPU), 1-3 min (GPU)
- Google STT: ~2-5 min
- OpenAI translation: ~1-2 min
- Azure TTS: ~2-3 min

**Cost** (per 2-minute video):
- Google STT: ~$0.02-0.05
- OpenAI: ~$0.01-0.03
- Azure TTS: ~$0.02-0.04
- **Total: ~$0.05-0.12** (vs $2-4/minute for SaaS)

## 📚 Documentation

- **[app/README.md](app/README.md)**: Complete documentation with examples
- **[docs/prd.txt](docs/prd.txt)**: Product requirements document
- **[docs/technical.txt](docs/technical.txt)**: Technical specifications

## 🔧 Legacy Commands

Backward compatible commands still available:
- `vsd transcribe` - Old pipeline (Whisper + Gemini)
- `vsd extract` - Extract Chinese subtitles
- `vsd translate` - Translate subtitle file
- `vsd tts` - TTS synthesis (old method)
- `vsd embed` - Embed subtitles
- `vsd remove` - Remove hardcoded subtitles

## 🐛 Troubleshooting

See [app/README.md](app/README.md#-troubleshooting) for detailed troubleshooting guide.

Common issues:
- **Demucs installation**: Install PyTorch first
- **Google credentials**: Verify JSON file path and API enabled
- **Azure TTS**: Check key and region environment variables
- **Low diarization quality**: Review audio quality and QC report

## 📝 License

MIT License

## 🤝 Contributing

Contributions welcome! Please open an issue or submit a PR.
