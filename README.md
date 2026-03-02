# local-whisper

A fast, fully-local speech-to-text dictation tool for macOS, powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp). No subscriptions, no cloud — just local transcription optimized for Apple Silicon.

Hold **Right Option**, speak, release — text appears at your cursor.

## Features

- **Hold-to-dictate**: Right Option key triggers recording via Karabiner-Elements
- **Live preview**: Streaming overlay shows partial transcription while you speak
- **Insert at cursor**: Final text is pasted (or typed) into any app on release
- **Multi-language**: English, Portuguese, and auto-detect, switchable via hotkeys
- **Fully local**: All processing on-device via whisper.cpp — nothing leaves your machine

## Requirements

- macOS (Apple Silicon recommended — tested on M4)
- [Homebrew](https://brew.sh)

## Install

```bash
# 1. Dependencies
brew install ffmpeg cmake git
brew install --cask karabiner-elements hammerspoon

# 2. Build whisper.cpp
cd ~
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build
cmake --build build -j --config Release

# 3. Download model (~1.5 GB)
./models/download-ggml-model.sh medium
```

Then follow the setup instructions below.

## Setup

### Permissions (System Settings > Privacy & Security)

| App | Permission |
|-----|-----------|
| Karabiner-Elements | Input Monitoring |
| Hammerspoon | Accessibility |
| Terminal (or your terminal app) | Microphone, Accessibility |

### Hammerspoon CLI

Open Hammerspoon console and run once:

```lua
hs.ipc.cliInstall()
```

This installs the `hs` command-line tool that the scripts use to communicate with Hammerspoon.

### Audio device

Find your microphone device index:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Update the device index in `~/whisper-dictate/config.sh` if it's not `:0`.

## Hotkeys

| Shortcut | Action |
|----------|--------|
| Hold Right Option | Record → transcribe → insert |
| Ctrl+Alt+E | Set language: English |
| Ctrl+Alt+P | Set language: Portuguese |
| Ctrl+Alt+A | Set language: Auto-detect |
| Ctrl+Alt+T | Cycle languages |
| Ctrl+Alt+O | Toggle output mode (paste / type) |

## How it works

```
Right Option (hold/release via Karabiner)
  → start_record.sh: ffmpeg records chunked WAV segments
  → partial_transcribe.sh: background loop transcribes latest chunks for live preview
  → stop_transcribe.sh: concatenates chunks, runs final whisper-cli transcription
  → Hammerspoon: displays overlay, inserts final text at cursor
```

## Troubleshooting

- **No transcription output**: Check `$TMPDIR/whisper-dictate/whisper-dictate.log` for errors (run `echo $TMPDIR` to find the path)
- **Wrong microphone**: Run `ffmpeg -f avfoundation -list_devices true -i ""` and update `config.sh`
- **`hs` command not found**: Run `hs.ipc.cliInstall()` in Hammerspoon console
- **Permissions errors**: Ensure all permissions are granted in System Settings (see table above)
- **Karabiner not triggering**: Check that the rule is enabled in Karabiner-Elements preferences

## Disclaimer

This project was **vibe-coded** — built quickly with AI assistance for personal use. It works on my machine (M4 MacBook Pro), it might work on yours. PRs and issues welcome.

## License

[MIT](LICENSE)
