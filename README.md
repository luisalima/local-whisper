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
git clone https://github.com/luisalima/local-whisper.git
cd local-whisper
./install.sh
```

The installer handles everything: Homebrew dependencies, building whisper.cpp, downloading the model, detecting your microphone, setting up Karabiner + Hammerspoon, granting permissions, and choosing your trigger key.

To change the trigger key or re-run setup later:

```bash
./setup.sh
```

<details>
<summary>Manual install (if you prefer)</summary>

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

# 4. Copy scripts
cp scripts/*.sh ~/whisper-dictate/
chmod +x ~/whisper-dictate/*.sh

# 5. Copy Hammerspoon config
cp hammerspoon/init.lua ~/.hammerspoon/init.lua

# 6. Copy Karabiner rule
cp karabiner/local-whisper.json ~/.config/karabiner/assets/complex_modifications/
```

</details>

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
| Ctrl+Alt+R | Reload action hook config (`~/.hammerspoon/local_whisper_actions.lua`) |
| Ctrl+Alt+X | Emergency stop (kill recording + close overlay) |

## Custom post-dictation actions (Hammerspoon)

You can hook custom logic after transcription so dictations can trigger automations, route to files, open apps, or call a local LLM command.

1. Copy the example file:

```bash
cp hammerspoon/local_whisper_actions.example.lua ~/.hammerspoon/local_whisper_actions.lua
```

2. Edit `~/.hammerspoon/local_whisper_actions.lua` and customize your rules.
3. Reload with `Ctrl+Alt+R` (or reload Hammerspoon config).

The hook context (`ctx`) includes:

- `ctx.text` and `ctx.originalText`
- `ctx.lang`, `ctx.outputMode`
- `ctx:appendToFile(path, line)` for routing text to notes/tasks files
- `ctx:launchApp("Safari")` for app automation
- `ctx:runShell("your local command", optionalInputText)` to pipe dictated text into a local command
- `ctx:setText(...)`, `ctx:disableInsert()`, `ctx:enableInsert()`

Example voice commands you can wire in your hook file:

- `note: buy coffee` -> append to notes file, skip cursor insertion
- `journal: today was productive` -> append to journal file
- `open app Safari` -> launch/focus an app
- `rewrite: ...` -> rewrite text via a local LLM CLI, then insert rewritten text

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
