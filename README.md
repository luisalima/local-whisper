# local-whisper

A fast, fully-local speech-to-text dictation tool for macOS, powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp). No subscriptions, no cloud — just local transcription optimized for Apple Silicon.

Hold **Right Cmd**, speak, release — text appears at your cursor.

## Features

- **Hold-to-dictate**: Hold a modifier key to record, release to transcribe and insert
- **Voice commands**: Say "voice command note buy coffee" to save a note, "voice command open app Safari" to launch apps, and more — fully customizable
- **Live preview**: Streaming overlay shows partial transcription while you speak
- **Recording indicator**: Pulsing red dot and elapsed timer in the overlay
- **Multi-language**: English, Portuguese, and auto-detect with preferred language fallback
- **App-aware processing**: Auto-capitalizes in most apps, skips in terminals and code editors
- **Text post-processing**: Remove filler words (um, uh, hmm), clean whitespace
- **Custom vocabulary**: Provide a prompt file to improve recognition of domain-specific terms
- **Auto-stop on silence**: Automatically stops recording after 3 seconds of silence
- **Menu bar**: Waveform icon shows recording status (turns red), click for settings and recent dictations
- **Recent dictations**: View and re-paste your last 10 dictations from the menu bar
- **Fully local**: All processing on-device via whisper.cpp — nothing leaves your machine

## Voice Commands

Voice commands turn dictation into actions. All commands start with **"voice command"** to prevent false matches on normal speech.

| Say | What happens |
|-----|-------------|
| "voice command note buy coffee" | Saves to `~/whisper_notes.md` |
| "voice command remind call mom" | Creates a Reminder in the Reminders app |
| "voice command open app Safari" | Launches or focuses an app |
| "voice command copy" | Fires Cmd+C |
| "voice command paste" | Fires Cmd+V |
| "voice command select all" | Fires Cmd+A |
| "voice command undo" | Fires Cmd+Z |
| "voice command cancel" | Discards the current dictation (works mid-sentence) |

Voice commands are fully customizable — edit `~/.hammerspoon/local_whisper_actions.lua` to add your own. The config auto-reloads when you save.

For a full guide on writing custom commands, see **[docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md)**.

## Requirements

- macOS (Apple Silicon recommended — tested on M4)
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/luisalima/local-whisper.git && cd local-whisper && ./install.sh
```

The installer handles everything: Homebrew dependencies, building whisper.cpp, downloading models, and setting up Hammerspoon. It then runs `setup.sh` which walks you through choosing your trigger key, microphone, and granting permissions.

To change the trigger key or re-run setup later:

```bash
./setup.sh
```

<details>
<summary>Manual install (if you prefer)</summary>

```bash
# 1. Dependencies
brew install ffmpeg cmake git
brew install --cask hammerspoon

# 2. Build whisper.cpp
cd ~
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build
cmake --build build -j --config Release

# 3. Download model (~1.5 GB)
./models/download-ggml-model.sh medium

# 4. Optional: download tiny model for faster live preview
./models/download-ggml-model.sh tiny

# 5. Copy Hammerspoon config
cp hammerspoon/init.lua ~/.hammerspoon/init.lua
```

</details>

## Uninstall

```bash
./uninstall.sh
```

Removes Hammerspoon config, `~/.local-whisper/` settings, and temp files. Optionally removes `~/whisper.cpp`. Does not uninstall Homebrew packages.

## Setup

### Permissions (System Settings > Privacy & Security)

| App | Permission |
|-----|-----------|
| Hammerspoon | Accessibility, Microphone |
| Terminal (or your terminal app) | Accessibility (for `hs` CLI) |

### Hammerspoon CLI

Open Hammerspoon console and run once:

```lua
hs.ipc.cliInstall()
```

This installs the `hs` command-line tool used for IPC.

### Audio device

Find your microphone device index:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Update `AUDIO_DEVICE` in `~/.hammerspoon/init.lua` if it's not `:1`.

## Menu bar

A waveform icon in the menu bar shows recording status (turns red when recording). Click it to:

- See current language, model, output mode, and enter mode
- Click any setting to cycle it
- View and re-paste recent dictations
- Open the settings overlay
- Reload voice commands
- Emergency stop

All settings are accessible from the menu bar — no keyboard shortcuts needed.

## Custom vocabulary prompt

Create `~/.local-whisper/prompt` with terms whisper should recognize better:

```
Claude, Hammerspoon, whisper.cpp, ffmpeg, macOS, Lua, Anthropic
```

This is passed as `--prompt` to whisper-cli for both partial and final transcription. Adding your voice command trigger words here improves recognition.

## Faster live preview

By default, partial transcription uses the same model as final transcription. For faster live preview, download a smaller model:

```bash
cd ~/whisper.cpp/models
./download-ggml-model.sh tiny
```

The system automatically picks the smallest available model (tiny > base > small) for partials while keeping your chosen model for the final transcription.

## App-aware text processing

Post-processing adapts to the frontmost application when you start recording:

- **Terminals** (Terminal, iTerm2, Warp): skips auto-capitalize (commands are lowercase)
- **Code editors** (VS Code, Xcode, Zed, Sublime Text): skips auto-capitalize
- **Everything else**: auto-capitalizes first letter, removes filler words

The active app is also available in voice command hooks as `ctx.appName` and `ctx.appBundleID`.

## Writing custom voice commands

Edit `~/.hammerspoon/local_whisper_actions.lua` to add your own commands. The file returns a table with hooks that run on each dictation:

```lua
return {
    beforeInsert = function(ctx)
        -- Match and handle commands here
    end,
    actions = { },
    afterInsert = function(ctx)
        -- Post-insertion logic (logging, etc.)
    end,
}
```

### Hook context

| Field / Method | Description |
|---------------|-------------|
| `ctx.text` | Current text (mutable via `ctx:setText()`) |
| `ctx.textLower` | Lowercase version for case-insensitive matching |
| `ctx.originalText` | Original transcription (immutable) |
| `ctx.appName` | App name where dictation started (e.g. "Safari") |
| `ctx.appBundleID` | Bundle ID (e.g. "com.apple.Safari") |
| `ctx:setText(text)` | Replace text before insertion |
| `ctx:disableInsert()` | Skip cursor insertion (for command-only actions) |
| `ctx:appendToFile(path, line)` | Append a line to a file (creates parent dirs) |
| `ctx:launchApp("Safari")` | Launch or focus an app |
| `ctx:runShell("cmd", input)` | Run a shell command with optional stdin |
| `ctx:keystroke({"cmd"}, "a")` | Fire a keystroke |
| `ctx:notify("msg")` | Show a notification |
| `ctx.handled` | Set to `true` to skip remaining actions |

The config auto-reloads when you save the file. For more patterns and examples, see **[docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md)**.

## How it works

```
Modifier key hold/release (detected by Hammerspoon eventtap)
  → ffmpeg records chunked WAV segments (1s each)
  → Partial transcription loop: concat latest chunks → whisper-cli (tiny model)
  → On release: concat all chunks → final whisper-cli transcription (chosen model)
  → Post-processing: remove fillers, capitalize, app-aware adjustments
  → Voice command hooks: beforeInsert → actions → text insertion → afterInsert
  → Text inserted at cursor via paste (Cmd+V) or keystroke
```

## Auto-stop on silence

Recording automatically stops after 3 consecutive seconds of silence (< -40 dB). This is useful for hands-free dictation. Configure thresholds in `init.lua`:

```lua
local AUTO_STOP_SILENCE_SECONDS = 3
local AUTO_STOP_THRESHOLD_DB = -40
```

## Troubleshooting

- **No transcription output**: Check `$TMPDIR/whisper-dictate/whisper-dictate.log` for errors (run `echo $TMPDIR` to find the path)
- **Wrong microphone**: Run `ffmpeg -f avfoundation -list_devices true -i ""` and update `AUDIO_DEVICE` in init.lua
- **`hs` command not found**: Run `hs.ipc.cliInstall()` in Hammerspoon console
- **Permissions errors**: Ensure Hammerspoon has Accessibility and Microphone permissions in System Settings
- **Voice commands not triggering**: Check the log to see what whisper transcribed — add command words to `~/.local-whisper/prompt`
- **Overlay not appearing**: Hammerspoon may need Accessibility permission re-granted after updates

## Disclaimer

This project was **vibe-coded** — built quickly with AI assistance for personal use. It works on my machine (M4 MacBook Pro), it might work on yours. PRs and issues welcome.

## License

[MIT](LICENSE)
