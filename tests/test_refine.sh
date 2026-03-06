#!/usr/bin/env bash
# test_refine.sh — eval suite for Ollama LLM refinement
# Tests that the refine prompt produces correct output for common patterns.
# Requires: Ollama running locally with the configured model.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

OLLAMA_URL="http://localhost:11434/api/generate"
CONFIG_DIR="$HOME/.local-whisper"

# Read model from config or use default
MODEL_FILE="$CONFIG_DIR/refine_model"
if [[ -f "$MODEL_FILE" ]]; then
    MODEL=$(cat "$MODEL_FILE" | tr -d '[:space:]')
fi
MODEL="${MODEL:-gemma3:4b}"

# Read prompt from config or use default
PROMPT_FILE="$CONFIG_DIR/refine_prompt"
if [[ -f "$PROMPT_FILE" ]] && [[ -s "$PROMPT_FILE" ]]; then
    PROMPT=$(cat "$PROMPT_FILE")
else
    PROMPT="You are a text cleanup tool. Output ONLY the cleaned text, nothing else. Fix punctuation and capitalization. Remove ONLY filler words like um, uh, you know, I mean. Do NOT remove sentences or meaningful content. When the text lists sequential items using first/second/third or one/two/three, convert them into a numbered list with each item on a new line. NEVER add commentary or preamble. Just output the cleaned text."
fi

PASS=0
FAIL=0
TOTAL=0

call_ollama() {
    local input="$1"
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': '$MODEL',
    'prompt': sys.stdin.read(),
    'stream': False
}))
" <<< "$PROMPT

$input")

    local response
    response=$(curl -s -X POST "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo "ERROR: No response from Ollama"
        return 1
    fi

    python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print(data.get('response', '').strip())
" <<< "$response"
}

# Test case runner
# Usage: test_case "description" "input" "check_type" "expected"
# check_type: "exact" | "contains" | "not_contains" | "starts_with" | "has_newlines"
test_case() {
    local desc="$1"
    local input="$2"
    local check="$3"
    local expected="$4"

    TOTAL=$((TOTAL + 1))

    local output
    output=$(call_ollama "$input" 2>/dev/null) || {
        echo -e "${RED}FAIL${NC} [$desc] — Ollama call failed"
        FAIL=$((FAIL + 1))
        return
    }

    local passed=false
    case "$check" in
        exact)
            [[ "$output" == "$expected" ]] && passed=true
            ;;
        contains)
            echo "$output" | grep -qi "$expected" && passed=true
            ;;
        not_contains)
            ! echo "$output" | grep -qi "$expected" && passed=true
            ;;
        starts_with)
            [[ "$output" == "$expected"* ]] && passed=true
            ;;
        has_newlines)
            # Check output has multiple lines (numbered list)
            local lines
            lines=$(echo "$output" | wc -l | tr -d ' ')
            [[ "$lines" -ge "$expected" ]] && passed=true
            ;;
    esac

    if $passed; then
        echo -e "${GREEN}PASS${NC} [$desc]"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} [$desc]"
        echo -e "  Input:    ${input:0:80}"
        echo -e "  Output:   ${output:0:120}"
        echo -e "  Expected: $check '$expected'"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Preflight ────────────────────────────────────────────────────────────────

echo -e "${BOLD}local-whisper refine eval suite${NC}"
echo -e "Model: ${BOLD}$MODEL${NC}"
echo ""

# Check Ollama is running
if ! curl -s "$OLLAMA_URL" -d '{"model":"'$MODEL'","prompt":"hi","stream":false}' > /dev/null 2>&1; then
    echo -e "${RED}Error: Ollama not reachable at $OLLAMA_URL${NC}"
    echo "Make sure Ollama is running: ollama serve"
    exit 1
fi
echo -e "${GREEN}Ollama reachable${NC} ($OLLAMA_URL)"
echo ""

# ─── Test Cases ───────────────────────────────────────────────────────────────

echo -e "${BOLD}--- Filler word removal ---${NC}"

test_case "Remove um/uh" \
    "Um, so I was thinking, uh, we should probably, you know, update the docs." \
    "not_contains" "um"

test_case "Keep meaningful content" \
    "I built a dictation tool for macOS. It uses whisper.cpp for transcription." \
    "contains" "dictation tool"

test_case "Keep all sentences" \
    "Ok, here is my itemized list. Let's test whether it worked. First item is great." \
    "contains" "itemized list"

echo ""
echo -e "${BOLD}--- Numbered list formatting ---${NC}"

test_case "First/second/third → numbered list" \
    "First, buy groceries. Second, do laundry. Third, cook dinner." \
    "has_newlines" "3"

test_case "One/two/three → numbered list" \
    "One, check the logs. Two, fix the bug. Three, write a test." \
    "has_newlines" "3"

test_case "Sequential items with context" \
    "I am going to test the itemized feature. First, testing the first item. Second, testing the second item. Third, testing the third item." \
    "has_newlines" "3"

echo ""
echo -e "${BOLD}--- No preamble ---${NC}"

test_case "No 'Here is' preamble" \
    "So basically, um, the main thing is that we need to update the server config and restart the service." \
    "not_contains" "here is"

test_case "No 'Sure' preamble" \
    "I think we should probably consider refactoring the authentication module." \
    "not_contains" "^sure"

echo ""
echo -e "${BOLD}--- Punctuation & capitalization ---${NC}"

test_case "Capitalize first word" \
    "the quick brown fox jumps over the lazy dog" \
    "starts_with" "The"

echo ""
echo -e "${BOLD}--- Short text passthrough ---${NC}"

test_case "Short text preserved" \
    "Hello world, this is a test." \
    "contains" "Hello"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}─────────────────────────────${NC}"
echo -e "${BOLD}Results: ${PASS}/${TOTAL} passed${NC}"
if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}${FAIL} failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed${NC}"
fi
