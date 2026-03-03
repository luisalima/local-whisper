#!/usr/bin/env bash
# config.sh — shared environment for local-whisper scripts
# Source this at the top of every script: source "$(dirname "$0")/config.sh"

set -euo pipefail
umask 077  # temp files owner-only (no world-readable transcripts)

# --- Paths (absolute — Karabiner runs in minimal env) ---
WHISPER_BIN="$HOME/whisper.cpp/build/bin/whisper-cli"
WHISPER_MODEL="$HOME/whisper.cpp/models/ggml-medium.bin"
FFMPEG="/opt/homebrew/bin/ffmpeg"
HS="/usr/local/bin/hs"

# --- Audio device ---
# ":default" = system default mic (follows System Settings selection)
# To pin a specific device: ":0", ":1", etc.
# List devices: ffmpeg -f avfoundation -list_devices true -i ""
AUDIO_DEVICE=":default"

# --- Temp directory (macOS $TMPDIR is per-user, mode 700 — no symlink attacks) ---
WHISPER_TMP="${TMPDIR:-/tmp}/whisper-dictate"
mkdir -p "$WHISPER_TMP"

# --- Recording ---
CHUNK_DIR="$WHISPER_TMP/chunks"
CHUNK_DURATION=1  # seconds per chunk
PID_FILE="$WHISPER_TMP/recording.pid"
PARTIAL_PID_FILE="$WHISPER_TMP/partial.pid"

# --- Transcription output ---
PARTIAL_FILE="$WHISPER_TMP/partial.txt"
FINAL_FILE="$WHISPER_TMP/final.txt"

# --- User state ---
LANG_FILE="$HOME/.whisper_dictation_lang"
OUTPUT_FILE="$HOME/.whisper_dictation_output"

# --- Logging ---
LOG_FILE="$WHISPER_TMP/whisper-dictate.log"

# --- Sounds ---
SND_START="/System/Library/Sounds/Pop.aiff"
SND_STOP="/System/Library/Sounds/Tink.aiff"
SND_DONE="/System/Library/Sounds/Glass.aiff"

# --- Helpers ---

log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
}

get_lang() {
    if [[ -f "$LANG_FILE" ]]; then
        local val
        val=$(cat "$LANG_FILE")
        # Only allow known values
        if [[ "$val" =~ ^(en|pt|auto)$ ]]; then
            echo "$val"
        else
            echo "en"
        fi
    else
        echo "en"
    fi
}

get_output_mode() {
    if [[ -f "$OUTPUT_FILE" ]]; then
        cat "$OUTPUT_FILE"
    else
        echo "paste"
    fi
}

play_sound() {
    /usr/bin/afplay "$1" &
}

# Validate critical dependencies exist
check_deps() {
    local missing=()
    [[ -x "$FFMPEG" ]] || missing+=("ffmpeg ($FFMPEG)")
    [[ -x "$WHISPER_BIN" ]] || missing+=("whisper-cli ($WHISPER_BIN)")
    [[ -f "$WHISPER_MODEL" ]] || missing+=("whisper model ($WHISPER_MODEL)")
    [[ -x "$HS" ]] || missing+=("hammerspoon cli ($HS)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: missing dependencies: ${missing[*]}"
        echo "Missing: ${missing[*]}" >&2
        return 1
    fi
}
