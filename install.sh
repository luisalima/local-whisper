#!/usr/bin/env bash
# install.sh — local-whisper installer
# Sets up everything needed for hold-to-dictate on macOS with whisper.cpp
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }

# ─── Detect script location (repo root) ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Configurable paths ─────────────────────────────────────────────────────
WHISPER_CPP_DIR="$HOME/whisper.cpp"
WHISPER_DICTATE_DIR="$HOME/whisper-dictate"
WHISPER_MODEL="medium"
HAMMERSPOON_DIR="$HOME/.hammerspoon"
KARABINER_RULES_DIR="$HOME/.config/karabiner/assets/complex_modifications"

# ─── Preflight ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}local-whisper installer${NC}"
echo -e "Hold Right Option → speak → release → text at cursor"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "This tool is macOS-only."
    exit 1
fi

# Check Apple Silicon
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon detected ($ARCH)"
else
    warn "Intel Mac detected ($ARCH) — will work but transcription will be slower"
fi

# Check Homebrew
if ! command -v brew &>/dev/null; then
    error "Homebrew not found. Install it first: https://brew.sh"
    exit 1
fi
ok "Homebrew found"

# ─── Step 1: Brew dependencies ──────────────────────────────────────────────
echo ""
info "Step 1/6: Installing dependencies via Homebrew..."

BREW_FORMULAE=(ffmpeg cmake git)
for formula in "${BREW_FORMULAE[@]}"; do
    if brew list "$formula" &>/dev/null; then
        ok "$formula already installed"
    else
        info "Installing $formula..."
        brew install "$formula"
        ok "$formula installed"
    fi
done

BREW_CASKS=(karabiner-elements hammerspoon)
# Heads up: Karabiner-Elements installs a system-level keyboard daemon
# and will prompt for your macOS password during install. This is normal.
warn "Karabiner-Elements may ask for your macOS password (it installs a system keyboard daemon)"
for cask in "${BREW_CASKS[@]}"; do
    if brew list --cask "$cask" &>/dev/null; then
        ok "$cask already installed"
    else
        info "Installing $cask..."
        brew install --cask "$cask"
        ok "$cask installed"
    fi
done

# ─── Step 2: Build whisper.cpp ───────────────────────────────────────────────
echo ""
info "Step 2/6: Building whisper.cpp..."

if [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-cli" ]]; then
    ok "whisper-cli already built at $WHISPER_CPP_DIR/build/bin/whisper-cli"
else
    if [[ ! -d "$WHISPER_CPP_DIR" ]]; then
        info "Cloning whisper.cpp..."
        git clone https://github.com/ggml-org/whisper.cpp "$WHISPER_CPP_DIR"
    else
        ok "whisper.cpp repo already at $WHISPER_CPP_DIR"
    fi

    info "Building with cmake (this may take a few minutes)..."
    cd "$WHISPER_CPP_DIR"
    cmake -B build
    cmake --build build -j --config Release
    cd "$SCRIPT_DIR"

    if [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-cli" ]]; then
        ok "whisper-cli built successfully"
    else
        error "Build failed — check output above"
        exit 1
    fi
fi

# ─── Step 3: Download model ─────────────────────────────────────────────────
echo ""
info "Step 3/6: Downloading whisper model ($WHISPER_MODEL)..."

MODEL_FILE="$WHISPER_CPP_DIR/models/ggml-${WHISPER_MODEL}.bin"
if [[ -f "$MODEL_FILE" ]]; then
    ok "Model already downloaded: $MODEL_FILE"
else
    info "Downloading ggml-${WHISPER_MODEL}.bin (~1.5 GB)..."
    cd "$WHISPER_CPP_DIR"
    bash ./models/download-ggml-model.sh "$WHISPER_MODEL"
    cd "$SCRIPT_DIR"

    if [[ -f "$MODEL_FILE" ]]; then
        ok "Model downloaded"
    else
        error "Model download failed"
        exit 1
    fi
fi

# ─── Step 4: Install scripts ────────────────────────────────────────────────
echo ""
info "Step 4/6: Installing scripts to $WHISPER_DICTATE_DIR..."

mkdir -p "$WHISPER_DICTATE_DIR"

# Copy scripts from repo (or they may already be there)
for script in config.sh start_record.sh stop_transcribe.sh partial_transcribe.sh; do
    if [[ -f "$SCRIPT_DIR/scripts/$script" ]]; then
        cp "$SCRIPT_DIR/scripts/$script" "$WHISPER_DICTATE_DIR/$script"
        chmod +x "$WHISPER_DICTATE_DIR/$script"
        ok "Installed $script"
    elif [[ -f "$WHISPER_DICTATE_DIR/$script" ]]; then
        ok "$script already in place"
    else
        error "$script not found in repo or $WHISPER_DICTATE_DIR"
        exit 1
    fi
done

# ─── Audio device ────────────────────────────────────────────────────────────
echo ""
ok "Audio device set to system default (follows System Settings > Sound > Input)"
info "Available devices on this machine:"

FFMPEG_BIN="$(brew --prefix)/bin/ffmpeg"
DEVICE_LIST=$("$FFMPEG_BIN" -f avfoundation -list_devices true -i "" 2>&1 || true)
echo "$DEVICE_LIST" | grep -A 100 "AVFoundation audio devices:" | grep -E "^\[AVFoundation" | head -10

echo ""
info "To pin a specific device, edit ~/whisper-dictate/config.sh and change AUDIO_DEVICE"

# ─── Update paths in config.sh ──────────────────────────────────────────────
# Ensure whisper binary and model paths match this system
if [[ -f "$WHISPER_DICTATE_DIR/config.sh" ]]; then
    FFMPEG_PATH="$(which ffmpeg)"
    sed -i '' "s|FFMPEG=.*|FFMPEG=\"${FFMPEG_PATH}\"|" "$WHISPER_DICTATE_DIR/config.sh"
    sed -i '' "s|WHISPER_BIN=.*|WHISPER_BIN=\"${WHISPER_CPP_DIR}/build/bin/whisper-cli\"|" "$WHISPER_DICTATE_DIR/config.sh"
    sed -i '' "s|WHISPER_MODEL=.*|WHISPER_MODEL=\"${MODEL_FILE}\"|" "$WHISPER_DICTATE_DIR/config.sh"
    ok "Paths updated in config.sh"
fi

# ─── Step 5: Install Hammerspoon config ─────────────────────────────────────
echo ""
info "Step 5/6: Setting up Hammerspoon..."

mkdir -p "$HAMMERSPOON_DIR"

if [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    # Check if it already has our module
    if grep -q "WhisperOverlay" "$HAMMERSPOON_DIR/init.lua"; then
        ok "Hammerspoon already configured with WhisperOverlay"
    else
        warn "Existing init.lua found — backing up to init.lua.backup"
        cp "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.backup"
        if [[ -f "$SCRIPT_DIR/hammerspoon/init.lua" ]]; then
            cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
            ok "Hammerspoon config installed (backup saved)"
        fi
    fi
else
    if [[ -f "$SCRIPT_DIR/hammerspoon/init.lua" ]]; then
        cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
        ok "Hammerspoon config installed"
    elif [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
        ok "Hammerspoon config already in place"
    else
        error "Hammerspoon init.lua not found in repo"
        exit 1
    fi
fi

# ─── Step 6: Install Karabiner rule ─────────────────────────────────────────
echo ""
info "Step 6/6: Installing Karabiner-Elements rule..."

mkdir -p "$KARABINER_RULES_DIR"

if [[ -f "$KARABINER_RULES_DIR/local-whisper.json" ]]; then
    ok "Karabiner rule already installed"
else
    cp "$SCRIPT_DIR/karabiner/local-whisper.json" "$KARABINER_RULES_DIR/local-whisper.json"
    ok "Karabiner rule installed"
fi

# ─── Permissions reminder ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────────────${NC}"
echo -e "${BOLD}Setup complete!${NC} A few manual steps remain:"
echo -e "${BOLD}────────────────────────────────────────────────${NC}"
echo ""
echo -e "1. ${YELLOW}Grant permissions${NC} in System Settings > Privacy & Security:"
echo ""
echo "   Karabiner-Elements  → Input Monitoring"
echo "   Hammerspoon         → Accessibility"
echo "   Terminal             → Microphone, Accessibility"
echo ""
echo -e "2. ${YELLOW}Enable Hammerspoon CLI${NC} — open Hammerspoon console and run:"
echo ""
echo "   hs.ipc.cliInstall()"
echo ""
echo -e "3. ${YELLOW}Enable the Karabiner rule${NC}:"
echo "   Open Karabiner-Elements > Complex Modifications > Add predefined rule"
echo "   Enable \"Right Option: hold = record + transcribe\""
echo ""
echo -e "4. ${YELLOW}Reload Hammerspoon${NC} (click the menu bar icon > Reload Config)"
echo ""
echo -e "Then hold ${BOLD}Right Option${NC}, speak, and release!"
echo ""
