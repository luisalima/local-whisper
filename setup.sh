#!/usr/bin/env bash
# setup.sh — post-install setup for local-whisper
# Configures: trigger key, audio device, permissions, Hammerspoon CLI
# Architecture: Hammerspoon-only (everything runs in init.lua)
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

HAMMERSPOON_DIR="$HOME/.hammerspoon"
INIT_LUA="$HAMMERSPOON_DIR/init.lua"

echo ""
echo -e "${BOLD}local-whisper setup${NC}"
echo ""

if [[ ! -f "$INIT_LUA" ]]; then
    error "Hammerspoon config not found at $INIT_LUA"
    error "Run install.sh first."
    exit 1
fi

# ─── Step 1: Choose trigger key ─────────────────────────────────────────────
echo -e "${BOLD}Step 1: Choose your dictation trigger key${NC}"
echo ""

# Read current value
CURRENT_KEY=$(grep -m1 'local TRIGGER_KEY' "$INIT_LUA" | sed 's/.*"\(.*\)".*/\1/')
echo -e "  Current: ${BOLD}${CURRENT_KEY}${NC}"
echo ""
echo "  1) rightCmd     (Right Command)      — recommended"
echo "  2) rightAlt     (Right Option / Alt)"
echo "  3) rightCtrl    (Right Control)"
echo ""
read -r -p "Choice [keep current]: " KEY_CHOICE

case "$KEY_CHOICE" in
    1) NEW_KEY="rightCmd";  KEY_LABEL="Right Command" ;;
    2) NEW_KEY="rightAlt";  KEY_LABEL="Right Option" ;;
    3) NEW_KEY="rightCtrl"; KEY_LABEL="Right Control" ;;
    *) NEW_KEY="$CURRENT_KEY"; KEY_LABEL="$CURRENT_KEY (unchanged)" ;;
esac

if [[ "$NEW_KEY" != "$CURRENT_KEY" ]]; then
    sed -i '' "s/local TRIGGER_KEY = \".*\"/local TRIGGER_KEY = \"${NEW_KEY}\"/" "$INIT_LUA"
    ok "Trigger key set to: $KEY_LABEL"
else
    ok "Trigger key: $KEY_LABEL"
fi

# ─── Step 2: Choose audio device ────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 2: Choose your microphone${NC}"
echo ""

FFMPEG_BIN="$(brew --prefix 2>/dev/null)/bin/ffmpeg"
if [[ ! -x "$FFMPEG_BIN" ]]; then
    FFMPEG_BIN="$(which ffmpeg 2>/dev/null || echo "")"
fi

if [[ -n "$FFMPEG_BIN" ]]; then
    info "Available audio devices:"
    echo ""
    # Parse audio device list from ffmpeg
    DEVICE_OUTPUT=$("$FFMPEG_BIN" -f avfoundation -list_devices true -i "" 2>&1 || true)
    echo "$DEVICE_OUTPUT" | grep -A 100 "AVFoundation audio devices:" | grep -E "^\[AVFoundation" | head -10
    echo ""
fi

CURRENT_DEVICE=$(grep -m1 'local AUDIO_DEVICE' "$INIT_LUA" | sed 's/.*"\(.*\)".*/\1/')
echo -e "  Current: ${BOLD}${CURRENT_DEVICE}${NC}"
echo ""
echo "  Enter a device string (e.g. :0, :1, :default) or press Enter to keep current:"
read -r -p "  Device [${CURRENT_DEVICE}]: " NEW_DEVICE
NEW_DEVICE="${NEW_DEVICE:-$CURRENT_DEVICE}"

if [[ "$NEW_DEVICE" != "$CURRENT_DEVICE" ]]; then
    # Validate device format (colon + digits or :default)
    if [[ ! "$NEW_DEVICE" =~ ^:[0-9]+$ ]] && [[ "$NEW_DEVICE" != ":default" ]]; then
        warn "Unusual device format: $NEW_DEVICE (expected :0, :1, :default)"
    fi
    # Escape special chars for sed
    ESCAPED_DEVICE=$(printf '%s\n' "$NEW_DEVICE" | sed 's/[&/\]/\\&/g')
    sed -i '' "s/local AUDIO_DEVICE = \".*\"/local AUDIO_DEVICE = \"${ESCAPED_DEVICE}\"/" "$INIT_LUA"
    ok "Audio device set to: $NEW_DEVICE"
else
    ok "Audio device: $NEW_DEVICE (unchanged)"
fi

# ─── Step 3: Permissions ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 3: macOS permissions${NC}"
echo ""

ALL_OK=true

# Find hs binary
HS_BIN=""
if [[ -x "/usr/local/bin/hs" ]]; then
    HS_BIN="/usr/local/bin/hs"
elif [[ -x "/opt/homebrew/bin/hs" ]]; then
    HS_BIN="/opt/homebrew/bin/hs"
fi

# Helper: run command with a timeout (macOS has no `timeout` by default)
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return $rc
}

check_accessibility() {
    [[ -n "$HS_BIN" ]] && run_with_timeout 5 "$HS_BIN" -c "return hs.accessibilityState()" 2>/dev/null | grep -q "true"
}

check_microphone() {
    [[ -n "$FFMPEG_BIN" ]] && run_with_timeout 5 "$FFMPEG_BIN" -f avfoundation -i ":default" -t 0.1 -f null - 2>/dev/null
}

# ── Accessibility (Hammerspoon) ──
if check_accessibility; then
    ok "Accessibility: granted (Hammerspoon)"
else
    ALL_OK=false
    warn "Accessibility: Hammerspoon needs Accessibility permission"
    echo -e "  Enable ${BOLD}Hammerspoon${NC} in System Settings > Privacy & Security > Accessibility"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
    read -r -p "  Press Enter when done..."

    if check_accessibility; then
        ok "Accessibility: granted"
    else
        warn "Accessibility: could not verify — make sure Hammerspoon is enabled"
    fi
fi

# ── Microphone ──
if check_microphone; then
    ok "Microphone: granted"
else
    ALL_OK=false
    warn "Microphone: Hammerspoon needs Microphone permission"
    echo -e "  Enable ${BOLD}Hammerspoon${NC} in System Settings > Privacy & Security > Microphone"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true
    read -r -p "  Press Enter when done..."

    if check_microphone; then
        ok "Microphone: granted"
    else
        warn "Microphone: could not verify — you may need to restart Hammerspoon"
    fi
fi

if [[ "$ALL_OK" == true ]]; then
    ok "All permissions already granted"
fi

# ─── Step 4: Hammerspoon CLI ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 4: Hammerspoon CLI & reload${NC}"

# Launch Hammerspoon if not running
if ! pgrep -q Hammerspoon; then
    info "Launching Hammerspoon..."
    open -a "Hammerspoon"
    sleep 2
fi

if [[ -x "/usr/local/bin/hs" ]] || [[ -x "/opt/homebrew/bin/hs" ]]; then
    ok "Hammerspoon CLI (hs) already installed"
else
    warn "Hammerspoon CLI (hs) not found."
    echo ""
    echo -e "  Open the Hammerspoon console (click menu bar icon > Console) and run:"
    echo ""
    echo -e "    ${BOLD}hs.ipc.cliInstall()${NC}"
    echo ""
    read -r -p "  Press Enter when done..."

    if [[ -x "/usr/local/bin/hs" ]] || [[ -x "/opt/homebrew/bin/hs" ]]; then
        ok "Hammerspoon CLI installed"
    else
        warn "hs not found — you can run hs.ipc.cliInstall() later from the Hammerspoon console"
    fi
fi

# Re-find hs after possible install
HS_BIN=""
if [[ -x "/usr/local/bin/hs" ]]; then
    HS_BIN="/usr/local/bin/hs"
elif [[ -x "/opt/homebrew/bin/hs" ]]; then
    HS_BIN="/opt/homebrew/bin/hs"
fi

# Reload Hammerspoon config
if [[ -n "$HS_BIN" ]]; then
    run_with_timeout 5 "$HS_BIN" -c "hs.reload()" 2>/dev/null && ok "Hammerspoon config reloaded" || warn "Could not reload — click the Hammerspoon menu bar icon > Reload Config"
else
    warn "Reload Hammerspoon manually: click menu bar icon > Reload Config"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────────────${NC}"
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo -e "${BOLD}────────────────────────────────────────────────${NC}"
echo ""
echo -e "Hold ${BOLD}${KEY_LABEL}${NC}, speak, and release."
echo ""
echo "Click the waveform icon in the menu bar to change settings."
echo ""
echo -e "Voice commands (say these while recording):"
echo "  \"voice command note <text>\"      — save a note"
echo "  \"voice command remind <text>\"    — create a Reminder"
echo "  \"voice command open app <name>\"  — launch an app"
echo "  \"voice command copy\"             — Cmd+C"
echo "  \"voice command cancel\"           — discard dictation"
echo ""
echo -e "To change settings later, run: ${BOLD}./setup.sh${NC}"
echo ""
