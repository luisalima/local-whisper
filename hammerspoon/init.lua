-- init.lua — local-whisper: Hammerspoon-only dictation
-- Hold a modifier key → record → transcribe → insert at cursor
-- No Karabiner needed. Just Hammerspoon + ffmpeg + whisper.cpp

require("hs.ipc")

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local HOME = os.getenv("HOME")
local TMPDIR = os.getenv("TMPDIR") or "/tmp"
local WHISPER_TMP = TMPDIR .. "/whisper-dictate"
local CHUNK_DIR = WHISPER_TMP .. "/chunks"

-- Config directory (all user settings live here)
local CONFIG_DIR = HOME .. "/.local-whisper"
os.execute("mkdir -p '" .. CONFIG_DIR .. "'")

-- External binaries (absolute paths)
local FFMPEG = "/opt/homebrew/bin/ffmpeg"
local WHISPER_BIN = HOME .. "/whisper.cpp/build/bin/whisper-cli"
local MODELS_DIR = HOME .. "/whisper.cpp/models"
local MODEL_FILE = CONFIG_DIR .. "/model"

-- Scan available models
local function getAvailableModels()
    local models = {}
    local ok, iter, dir = pcall(hs.fs.dir, MODELS_DIR)
    if not ok then return models end
    for file in iter, dir do
        local name = file:match("^ggml%-(.+)%.bin$")
        if name then table.insert(models, name) end
    end
    table.sort(models)
    return models
end

-- Get/set active model
local function getModelName()
    local saved = ""
    local f = io.open(MODEL_FILE, "r")
    if f then saved = f:read("*a"):gsub("%s+", ""); f:close() end
    if saved ~= "" then
        -- Verify model file exists
        local path = MODELS_DIR .. "/ggml-" .. saved .. ".bin"
        local attr = hs.fs.attributes(path)
        if attr then return saved end
    end
    return "medium"  -- default
end

local function getModelPath()
    return MODELS_DIR .. "/ggml-" .. getModelName() .. ".bin"
end

-- Audio device: ":default" for system default, ":0", ":1" etc. for specific
local AUDIO_DEVICE = ":1"

-- Trigger key: "rightAlt", "rightCmd", "rightCtrl"
local TRIGGER_KEY = "rightCmd"

-- User preference files (all in CONFIG_DIR)
local LANG_FILE = CONFIG_DIR .. "/lang"
local OUTPUT_FILE = CONFIG_DIR .. "/output"
local PREFERRED_LANGS_FILE = CONFIG_DIR .. "/preferred_langs"
local ENTER_FILE = CONFIG_DIR .. "/enter"
local PROMPT_FILE = CONFIG_DIR .. "/prompt"
local RECENT_FILE = CONFIG_DIR .. "/recent.json"
local LOG_FILE = WHISPER_TMP .. "/whisper-dictate.log"

-- Action hooks config
local ACTIONS_FILE = HOME .. "/.hammerspoon/local_whisper_actions.lua"

-- Auto-stop on silence
local AUTO_STOP_SILENCE_SECONDS = 3
local AUTO_STOP_THRESHOLD_DB = -40

-- LLM refinement (requires Ollama)
local REFINE_FILE = CONFIG_DIR .. "/refine"
local REFINE_PROMPT_FILE = CONFIG_DIR .. "/refine_prompt"
local REFINE_MODEL_FILE = CONFIG_DIR .. "/refine_model"
local REFINE_DEFAULT_MODEL = "llama3.1:8b"
local REFINE_MIN_CHARS = 50  -- skip refinement for short text
local REFINE_DEFAULT_PROMPT = "You are a text cleanup tool. Your ONLY job is to output the cleaned version of the input text. Rules: fix punctuation and capitalization, remove filler words (um, uh, like, you know, so, well, I mean), format numbered lists with newlines. NEVER start with phrases like 'Here is', 'Here's', 'The cleaned text', 'Sure', etc. Just output the text directly. Nothing before it, nothing after it."

local function getRefineModel()
    local f = io.open(REFINE_MODEL_FILE, "r")
    if f then
        local val = f:read("*a"):gsub("%s+", ""); f:close()
        if val ~= "" then return val end
    end
    return REFINE_DEFAULT_MODEL
end

local function getRefinePrompt()
    local f = io.open(REFINE_PROMPT_FILE, "r")
    if f then
        local content = f:read("*a"); f:close()
        content = content:gsub("^%s+", ""):gsub("%s+$", "")
        if content ~= "" then return content end
    end
    return REFINE_DEFAULT_PROMPT
end

local function hasOllama()
    -- Check if Ollama API is reachable
    local ok = os.execute("curl -s -o /dev/null -w '' http://localhost:11434/api/tags 2>/dev/null")
    if ok then return true end
    -- Fallback: check if binary exists
    return os.execute("command -v ollama >/dev/null 2>&1")
end

local function getRefineMode()
    local f = io.open(REFINE_FILE, "r")
    if not f then return false end
    local val = f:read("*a"):gsub("%s+", ""); f:close()
    return val == "on"
end

local function setRefineMode(on)
    local f = io.open(REFINE_FILE, "w")
    if f then f:write(on and "on" or "off"); f:close() end
end

local function cycleRefine()
    local current = getRefineMode()
    setRefineMode(not current)
end

-- Timing
local PARTIAL_INTERVAL = 2.0   -- seconds between partial transcriptions
local OVERLAY_LINGER = 0.5     -- seconds to show final text before closing

-- Known whisper hallucinations on silence/short audio
local HALLUCINATIONS = {
    "you", "thank you", "thanks for watching", "thanks for listening",
    "bye", "goodbye", "the end", "thank you for watching",
    "subscribe", "like and subscribe", "see you", "you.",
    "(applause)", "(keyboard clicking)", "(typing)", "(silence)",
    "(soft music)", "(lighter clicking)", "(applauding)",
    "[BLANK_AUDIO]", "[silence]",
}

--------------------------------------------------------------------------------
-- Trigger key mapping
--------------------------------------------------------------------------------

local TRIGGER_MASKS = {
    rightAlt  = hs.eventtap.event.rawFlagMasks["deviceRightAlternate"],
    rightCmd  = hs.eventtap.event.rawFlagMasks["deviceRightCommand"],
    rightCtrl = hs.eventtap.event.rawFlagMasks["deviceRightControl"],
}

local triggerMask = TRIGGER_MASKS[TRIGGER_KEY]
if not triggerMask then
    hs.notify.new({ title = "local-whisper", informativeText = "ERROR: Invalid TRIGGER_KEY: " .. TRIGGER_KEY }):send()
    return
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

os.execute("mkdir -p '" .. WHISPER_TMP .. "'")

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
        f:close()
    end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return end
    f:write(content)
    f:close()
end

local function getLang()
    local lang = readFile(LANG_FILE):gsub("%s+", "")
    if lang == "en" or lang == "pt" or lang == "auto" then return lang end
    return "en"
end

local function getOutputMode()
    local mode = readFile(OUTPUT_FILE):gsub("%s+", "")
    if mode == "type" then return "type" end
    return "paste"
end

local function getPreferredLangs()
    local content = readFile(PREFERRED_LANGS_FILE):gsub("%s+$", "")
    if content == "" then return {"en", "pt"} end
    local langs = {}
    for lang in content:gmatch("[^,]+") do
        lang = lang:match("^%s*(.-)%s*$")
        if lang ~= "" then table.insert(langs, lang) end
    end
    return #langs > 0 and langs or {"en", "pt"}
end

local function getEnterMode()
    local mode = readFile(ENTER_FILE):gsub("%s+", "")
    return mode == "on"
end

local function shellQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function expandPath(path)
    if type(path) ~= "string" then return nil end
    if path:sub(1, 2) == "~/" then return HOME .. path:sub(2) end
    return path
end

local function ensureParentDir(path)
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return true end
    local ok = os.execute("mkdir -p " .. shellQuote(parent))
    return ok == true or ok == 0
end

local function normalizeText(text)
    return ((text or ""):gsub("%s+", " ")):gsub("^%s+", ""):gsub("%s+$", "")
end

-- App bundle IDs where auto-capitalize should be skipped (terminals, code editors)
local NO_CAPITALIZE_APPS = {
    ["com.apple.Terminal"] = true,
    ["com.googlecode.iterm2"] = true,
    ["dev.warp.Warp-Stable"] = true,
    ["com.microsoft.VSCode"] = true,
    ["com.apple.dt.Xcode"] = true,
    ["com.jetbrains.intellij"] = true,
    ["com.sublimetext.4"] = true,
    ["com.github.atom"] = true,
    ["dev.zed.Zed"] = true,
}

-- Text post-processing: capitalize, remove fillers, clean whitespace
-- appBundleID is optional; when provided, adjusts behavior per-app
local function postProcess(text, appBundleID)
    -- Trim
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return text end
    -- Remove filler words (standalone, case-insensitive)
    text = text:gsub("%f[%w][Uu][mm]%f[%W]", "")
    text = text:gsub("%f[%w][Uu][hh]%f[%W]", "")
    text = text:gsub("%f[%w][Hh][Mm][Mm]+%f[%W]", "")
    -- Remove "like," used as filler (comma-following)
    text = text:gsub("%f[%w][Ll]ike,%s*", "")
    -- Collapse multiple spaces
    text = text:gsub("%s+", " ")
    -- Trim again after removals
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Auto-capitalize first letter (skip for terminals and code editors)
    if not (appBundleID and NO_CAPITALIZE_APPS[appBundleID]) then
        text = text:gsub("^%l", string.upper)
    end
    return text
end

local function refineWithOllama(text, callback)
    if not getRefineMode() or not hasOllama() or #text < REFINE_MIN_CHARS then
        callback(text)
        return
    end
    log("refine: sending to Ollama API (" .. #text .. " chars)")
    local prompt = getRefinePrompt() .. "\n\n" .. text
    local model = getRefineModel()
    -- Use Ollama HTTP API (more reliable than CLI, avoids version mismatch issues)
    local jsonPayload = hs.json.encode({
        model = model,
        prompt = prompt,
        stream = false,
    })
    local tmpPayload = WHISPER_TMP .. "/refine_payload.json"
    local f = io.open(tmpPayload, "w")
    if f then f:write(jsonPayload); f:close() end
    local task = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
        if code == 0 and stdout and #stdout > 0 then
            local ok, result = pcall(hs.json.decode, stdout)
            if ok and result and result.response then
                local refined = result.response:gsub("^%s+", ""):gsub("%s+$", "")
                -- Strip common LLM preamble
                refined = refined:gsub("^[Hh]ere%s+is%s+the%s+cleaned%s+text:%s*\n?", "")
                refined = refined:gsub("^[Hh]ere'?s?%s+the%s+cleaned[%-]?%s*text:%s*\n?", "")
                refined = refined:gsub("^[Hh]ere%s+is%s+the%s+refined%s+text:%s*\n?", "")
                refined = refined:gsub("^[Ss]ure[,!]?%s*[Hh]?e?r?e?'?s?%s*t?h?e?%s*", "")
                refined = refined:gsub("^%s+", "")
                if refined ~= "" then
                    log("refine: success (" .. #refined .. " chars)")
                    callback(refined)
                    return
                end
            end
        end
        log("refine: failed (code=" .. tostring(code) .. "), using original")
        callback(text)
    end, {
        "-s", "-X", "POST",
        "http://localhost:11434/api/generate",
        "-H", "Content-Type: application/json",
        "-d", "@" .. tmpPayload,
    })
    task:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
    task:start()
end

local function isHallucination(text)
    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- strip trailing period for comparison
    local stripped = lower:gsub("%.$", "")
    for _, h in ipairs(HALLUCINATIONS) do
        if stripped == h:lower() or lower == h:lower() then return true end
    end
    -- Also filter anything in brackets/parens (whisper noise markers)
    if lower:match("^%[.*%]$") or lower:match("^%(.*%)$") then return true end
    return false
end

local function getChunkFiles()
    local chunks = {}
    local ok, iter, dir = pcall(hs.fs.dir, CHUNK_DIR)
    if not ok then return chunks end
    for file in iter, dir do
        if file:match("^chunk_.*%.wav$") then
            table.insert(chunks, CHUNK_DIR .. "/" .. file)
        end
    end
    table.sort(chunks)
    return chunks
end

-- Cycle helpers
local function cycleLang()
    local cycle = { en = "pt", pt = "auto", auto = "en" }
    local next = cycle[getLang()] or "en"
    writeFile(LANG_FILE, next)
    return next
end

local function cycleModel()
    local models = getAvailableModels()
    if #models == 0 then return getModelName() end
    local current = getModelName()
    local next = models[1]
    for i, m in ipairs(models) do
        if m == current and models[i + 1] then
            next = models[i + 1]
            break
        end
    end
    if next == current then next = models[1] end
    writeFile(MODEL_FILE, next)
    return next
end

local function cycleOutput()
    local next = (getOutputMode() == "paste") and "type" or "paste"
    writeFile(OUTPUT_FILE, next)
    return next
end

local function cycleEnter()
    local next = getEnterMode() and "off" or "on"
    writeFile(ENTER_FILE, next)
    return next
end

-- Pick fastest available model for live partial transcription
local function getPartialModelPath()
    local preferred = { "tiny", "tiny.en", "base", "base.en", "small", "small.en" }
    for _, name in ipairs(preferred) do
        local path = MODELS_DIR .. "/ggml-" .. name .. ".bin"
        if hs.fs.attributes(path) then return path end
    end
    return getModelPath()  -- fall back to main model
end

-- Read custom vocabulary prompt for whisper
local function getPromptArgs()
    local content = readFile(PROMPT_FILE):gsub("%s+$", "")
    if content ~= "" then return { "--prompt", content } end
    return {}
end

--------------------------------------------------------------------------------
-- App-aware context (captured at recording start)
--------------------------------------------------------------------------------

local capturedAppName = nil
local capturedAppBundleID = nil

local function captureActiveApp()
    local app = hs.application.frontmostApplication()
    if app then
        capturedAppName = app:name()
        capturedAppBundleID = app:bundleID()
    else
        capturedAppName = nil
        capturedAppBundleID = nil
    end
end

--------------------------------------------------------------------------------
-- Optional post-dictation action hooks (user config)
--------------------------------------------------------------------------------

local actionConfig = nil
local actionConfigMtime = 0

local function safeHookCall(label, fn, ctx)
    local ok, err = pcall(fn, ctx)
    if not ok then
        log("actions: " .. label .. " failed: " .. tostring(err))
    end
end

-- Auto-reload: check mtime and reload if file changed
local function loadActionConfig()
    local attr = hs.fs.attributes(ACTIONS_FILE)
    if not attr then
        actionConfig = nil
        actionConfigMtime = 0
        return nil
    end

    local mtime = attr.modification or 0
    if actionConfig and mtime == actionConfigMtime then
        return actionConfig
    end

    local chunk, err = loadfile(ACTIONS_FILE)
    if not chunk then
        log("actions: could not load config: " .. tostring(err))
        return nil
    end

    local ok, cfg = pcall(chunk)
    if not ok then
        log("actions: config execution failed: " .. tostring(cfg))
        return nil
    end
    if type(cfg) ~= "table" then
        log("actions: config must return a table")
        return nil
    end

    actionConfig = cfg
    actionConfigMtime = mtime
    log("actions: loaded " .. ACTIONS_FILE)
    return actionConfig
end

local function reloadActionConfig()
    actionConfigMtime = 0
    actionConfig = nil
    return loadActionConfig()
end

local function buildActionContext(text, lang, mode)
    local ctx = {
        text = text,
        textLower = text:lower(),
        originalText = text,
        lang = lang,
        outputMode = mode,
        appName = capturedAppName,
        appBundleID = capturedAppBundleID,
        insert = true,
        inserted = false,
        handled = false,
        timestamp = os.time(),
        isoTime = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    function ctx:setText(newText)
        if type(newText) ~= "string" then return end
        self.text = normalizeText(newText)
        self.textLower = self.text:lower()
    end

    function ctx:disableInsert()
        self.insert = false
    end

    function ctx:enableInsert()
        self.insert = true
    end

    function ctx:launchApp(appName)
        if type(appName) ~= "string" or appName == "" then return false end
        return hs.application.launchOrFocus(appName)
    end

    function ctx:appendToFile(path, line)
        local resolved = expandPath(path)
        if not resolved or resolved == "" then return false, "invalid path" end
        if not ensureParentDir(resolved) then return false, "mkdir failed" end
        local f = io.open(resolved, "a")
        if not f then return false, "open failed" end
        f:write(tostring(line or self.text or "") .. "\n")
        f:close()
        return true
    end

    function ctx:runShell(command, inputText)
        if type(command) ~= "string" or command == "" then
            return false, "", "invalid command", 1
        end
        local token = tostring(os.time()) .. "_" .. tostring(math.random(1000000))
        local stdinPath = WHISPER_TMP .. "/action_stdin_" .. token .. ".txt"
        writeFile(stdinPath, tostring(inputText or self.text or ""))
        local output, ok, kind, rc = hs.execute(command .. " < " .. shellQuote(stdinPath), true)
        os.remove(stdinPath)
        return ok, output, kind, rc
    end

    function ctx:keystroke(mods, key)
        hs.eventtap.keyStroke(mods or {}, key)
    end

    function ctx:notify(message)
        hs.notify.new({ title = "local-whisper", informativeText = tostring(message) }):send()
    end

    function ctx:log(message)
        log("action: " .. tostring(message))
    end

    return ctx
end

local function runActionList(actions, ctx)
    if type(actions) ~= "table" then return end
    for i, action in ipairs(actions) do
        if ctx.handled then break end
        if type(action) == "function" then
            safeHookCall("actions[" .. i .. "]", action, ctx)
        elseif type(action) == "table" and type(action.run) == "function" then
            local name = action.name or ("actions[" .. i .. "]")
            local shouldRun = true
            if type(action.when) == "function" then
                local ok, res = pcall(action.when, ctx)
                if not ok then
                    shouldRun = false
                    log("actions: " .. name .. ".when failed: " .. tostring(res))
                else
                    shouldRun = not not res
                end
            elseif type(action.pattern) == "string" then
                shouldRun = ctx.textLower:match(action.pattern) ~= nil
            end
            if shouldRun then
                safeHookCall(name, action.run, ctx)
            end
        end
    end
end

local function runPreInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.beforeInsert) == "function" then
        safeHookCall("beforeInsert", cfg.beforeInsert, ctx)
    end
    if not ctx.handled then
        runActionList(cfg.actions, ctx)
    end
end

local function runPostInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.afterInsert) == "function" then
        safeHookCall("afterInsert", cfg.afterInsert, ctx)
    end
end

-- Global reload function (used by hotkey and menu bar)
WhisperActions = WhisperActions or {}
function WhisperActions.reload()
    local cfg = reloadActionConfig()
    if cfg then
        hs.notify.new({ title = "local-whisper", informativeText = "Action hooks reloaded" }):send()
    else
        hs.notify.new({ title = "local-whisper", informativeText = "No action hook config found" }):send()
    end
end

--------------------------------------------------------------------------------
-- Overlay UI
--------------------------------------------------------------------------------

local overlay = nil
local btnColor = { red = 0.5, green = 0.8, blue = 1.0, alpha = 1.0 }
local btnHover = { red = 0.7, green = 0.9, blue = 1.0, alpha = 1.0 }

-- Element indices: 1=bg, 2=lang, 3=sep1, 4=output, 5=sep2, 6=enter, 7=sep3, 8=model, 9=close, 10=text, 11=dot, 12=timer
local EL = { lang = 2, output = 4, enter = 6, model = 8, refine = 10, text = 11, dot = 12, timer = 13, close = 14 }

local enterOnColor = { red = 0.3, green = 1.0, blue = 0.3, alpha = 1.0 }
local enterOffColor = { red = 0.5, green = 0.5, blue = 0.5, alpha = 0.5 }
local refineOnColor = { red = 0.4, green = 0.8, blue = 1.0, alpha = 1.0 }
local refineOffColor = { red = 0.5, green = 0.5, blue = 0.5, alpha = 0.5 }

local function refreshOverlayLabels()
    if not overlay then return end
    overlay[EL.lang].text = getLang():upper()
    overlay[EL.output].text = getOutputMode():upper()
    overlay[EL.enter].text = "⏎"
    overlay[EL.enter].textColor = getEnterMode() and enterOnColor or enterOffColor
    overlay[EL.model].text = getModelName()
    local refineOn = getRefineMode() and hasOllama()
    overlay[EL.refine].text = refineOn and "refine ✓" or "refine ✗"
    overlay[EL.refine].textColor = refineOn and refineOnColor or refineOffColor
end

local function createOverlay()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()
    local width, height = 420, 100
    local padding = 20
    local x = frame.x + frame.w - width - padding
    local y = frame.y + frame.h - height - padding - 50

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- 1: Background (click to pin overlay open)
    overlay:appendElements({
        id = "bg",
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 },
        trackMouseUp = true,
    })

    -- Clickable status labels (each cycles on click)
    local sepColor = { red = 0.4, green = 0.4, blue = 0.4, alpha = 1 }

    -- 2: Language
    overlay:appendElements({
        id = "lang", type = "text", text = getLang():upper(),
        textColor = btnColor, textSize = 11,
        frame = { x = "4%", y = "6%", w = "10%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 3: Separator
    overlay:appendElements({
        id = "sep1", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "13%", y = "6%", w = "2%", h = "25%" },
    })
    -- 4: Output mode
    overlay:appendElements({
        id = "output", type = "text", text = getOutputMode():upper(),
        textColor = btnColor, textSize = 11,
        frame = { x = "15%", y = "6%", w = "13%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 5: Separator
    overlay:appendElements({
        id = "sep2", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "27%", y = "6%", w = "2%", h = "25%" },
    })
    -- 6: Enter mode (⏎ green=on, gray=off)
    overlay:appendElements({
        id = "enter", type = "text", text = "⏎",
        textColor = getEnterMode() and enterOnColor or enterOffColor, textSize = 11,
        frame = { x = "29%", y = "6%", w = "5%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 7: Separator
    overlay:appendElements({
        id = "sep3", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "34%", y = "6%", w = "2%", h = "25%" },
    })
    -- 8: Model
    overlay:appendElements({
        id = "model", type = "text", text = getModelName(),
        textColor = btnColor, textSize = 11,
        frame = { x = "36%", y = "6%", w = "20%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 9: Separator
    overlay:appendElements({
        id = "sep4", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "54%", y = "6%", w = "2%", h = "25%" },
    })
    -- 10: LLM refine toggle
    overlay:appendElements({
        id = "refine", type = "text",
        text = (getRefineMode() and hasOllama()) and "refine ✓" or "refine ✗",
        textColor = (getRefineMode() and hasOllama()) and refineOnColor or refineOffColor,
        textSize = 11,
        frame = { x = "57%", y = "6%", w = "18%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 11: Transcript text
    overlay:appendElements({
        id = "text", type = "text", text = "Listening...",
        textColor = { red = 1, green = 1, blue = 1, alpha = 1.0 },
        textSize = 14,
        frame = { x = "5%", y = "35%", w = "90%", h = "60%" },
    })
    -- 10: Recording indicator (pulsing red dot)
    overlay:appendElements({
        id = "dot", type = "oval", action = "fill",
        fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = 0.0 },
        frame = { x = "89%", y = "8%", w = "3%", h = "12%" },
    })
    -- 11: Elapsed time display
    overlay:appendElements({
        id = "timer", type = "text", text = "",
        textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 0.0 },
        textSize = 10,
        frame = { x = "75%", y = "8%", w = "14%", h = "20%" },
        textAlignment = "right",
    })
    -- 12: Close button (X) — last element so it's on top and clickable
    overlay:appendElements({
        id = "close", type = "text", text = "✕",
        textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 0.8 },
        textSize = 16, textAlignment = "center",
        frame = { x = "90%", y = "10%", w = "8%", h = "20%" },
        trackMouseDown = true, trackMouseUp = true, trackMouseEnterExit = true,
    })

    overlay:level(hs.canvas.windowLevels.floating)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- Map string IDs to numeric indices for element access
    local idMap = { bg = 1, lang = EL.lang, output = EL.output, enter = EL.enter, model = EL.model, refine = EL.refine, close = EL.close }

    -- Mouse handler: click bg to pin, click labels to cycle settings, X to close
    overlay:canvasMouseEvents(true, true, true, false)  -- mouseDown + mouseUp + enterExit
    overlay:mouseCallback(function(canvas, event, id, mx, my)
        -- Close button — deferred to avoid deleting canvas inside its own callback
        if id == "close" and (event == "mouseUp" or event == "mouseDown") then
            log("overlay: X clicked (" .. event .. ")")
            if event == "mouseUp" then
                hs.timer.doAfter(0.01, function()
                    log("overlay: X executing close")
                    if isRecording then emergencyStop() else forceHideOverlay() end
                end)
            end
            return
        end

        if event == "mouseUp" then
            if id == "bg" then
                overlayPinned = not overlayPinned
                if overlayPinned then
                    canvas[1].fillColor = { red = 0.15, green = 0.15, blue = 0.2, alpha = 0.92 }
                    log("overlay pinned")
                else
                    canvas[1].fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 }
                    log("overlay unpinned")
                    if not isRecording then hideOverlay() end
                end
                return
            end

            if id == "lang" then cycleLang()
            elseif id == "output" then cycleOutput()
            elseif id == "enter" then cycleEnter()
            elseif id == "model" then cycleModel()
            elseif id == "refine" then cycleRefine()
            end
            refreshOverlayLabels()

        elseif event == "mouseEnter" then
            local idx = idMap[id]
            if not idx or id == "bg" then return end
            if id == "close" then
                canvas[idx].textColor = { red = 1, green = 0.3, blue = 0.3, alpha = 1 }
            elseif id == "enter" then
                canvas[idx].textColor = enterOnColor
            elseif id == "refine" then
                canvas[idx].textColor = refineOnColor
            else
                canvas[idx].textColor = btnHover
            end

        elseif event == "mouseExit" then
            local idx = idMap[id]
            if not idx or id == "bg" then return end
            if id == "close" then
                canvas[idx].textColor = { red = 1, green = 1, blue = 1, alpha = 0.5 }
            elseif id == "enter" then
                canvas[idx].textColor = getEnterMode() and enterOnColor or enterOffColor
            elseif id == "refine" then
                canvas[idx].textColor = (getRefineMode() and hasOllama()) and refineOnColor or refineOffColor
            else
                canvas[idx].textColor = btnColor
            end
        end
    end)
end

local function showOverlay()
    overlayPinned = false
    if overlay then overlay:delete() end
    createOverlay()
    overlay:show()
end

local function hideOverlay()
    if overlayPinned then return end  -- pinned overlay stays open
    if overlay then overlay:delete(); overlay = nil end
end

local function forceHideOverlay()
    overlayPinned = false
    if overlay then overlay:delete(); overlay = nil end
end

local function setOverlayText(text)
    if overlay then overlay[EL.text].text = text end
end

local function setOverlayStatus()
    refreshOverlayLabels()
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local isRecording = false
local overlayPinned = false
local ffmpegTask = nil
local partialTimer = nil
local partialBusy = false
local lastChunkCount = 0

-- Menu bar
local menuBar = nil

-- Recording indicator state
local pulseTimer = nil
local clockTimer = nil
local recordingStartTime = 0
local pulseAlpha = 1.0
local pulseFading = true

-- Undo state
local lastInsertedText = nil

-- Recent dictations (newest first, max 10)
local MAX_RECENT = 10

local recentDictations = {}

local function loadRecentDictations()
    local f = io.open(RECENT_FILE, "r")
    if not f then return end
    local data = f:read("*a"); f:close()
    local ok, result = pcall(hs.json.decode, data)
    if ok and type(result) == "table" then
        -- Clear and populate in-place (preserve table reference)
        for i = #recentDictations, 1, -1 do recentDictations[i] = nil end
        for i, entry in ipairs(result) do recentDictations[i] = entry end
    end
end

local function saveRecentDictations()
    local ok, json = pcall(hs.json.encode, recentDictations)
    if not ok then return end
    local f = io.open(RECENT_FILE, "w")
    if f then f:write(json); f:close() end
end

loadRecentDictations()

-- Auto-stop state
local silentChunkCount = 0
local silenceTimer = nil
local lastCheckedChunk = 0

--------------------------------------------------------------------------------
-- Menu bar status icon
--------------------------------------------------------------------------------

local function makeWaveformIcon(color, asTemplate)
    local w, h = 18, 18
    local c = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
    -- Bar heights (symmetric waveform: short-medium-tall-medium-short)
    local bars = { 0.3, 0.55, 1.0, 0.55, 0.3 }
    local barW = 2
    local gap = 1.5
    local totalW = #bars * barW + (#bars - 1) * gap
    local startX = (w - totalW) / 2
    for i, scale in ipairs(bars) do
        local barH = math.floor(h * 0.75 * scale)
        local x = startX + (i - 1) * (barW + gap)
        local y = (h - barH) / 2
        c:appendElements({
            type = "rectangle",
            frame = { x = x, y = y, w = barW, h = barH },
            fillColor = color,
            roundedRectRadii = { xRadius = 1, yRadius = 1 },
            action = "fill",
        })
    end
    local img = c:imageFromCanvas()
    c:delete()
    img:template(asTemplate)
    return img
end

function updateMenuBar()
    if not menuBar then return end
    if isRecording then
        local icon = makeWaveformIcon({ red = 1, green = 0.15, blue = 0.15, alpha = 1 }, false)
        menuBar:setIcon(icon, false)
    else
        local icon = makeWaveformIcon({ red = 0, green = 0, blue = 0, alpha = 1 }, true)
        menuBar:setIcon(icon, true)
    end
end

local function buildMenuBarMenu()
    local items = {}

    -- Current status
    table.insert(items, { title = isRecording and "● Recording..." or "Idle", disabled = true })
    table.insert(items, { title = "-" })

    -- Language
    local langDisplay = getLang():upper()
    table.insert(items, {
        title = "Language: " .. langDisplay,
        fn = function() cycleLang(); updateMenuBar() end,
    })

    -- Model
    table.insert(items, {
        title = "Model: " .. getModelName(),
        fn = function() cycleModel(); updateMenuBar() end,
    })

    -- Output mode
    table.insert(items, {
        title = "Output: " .. getOutputMode():upper(),
        fn = function() cycleOutput(); updateMenuBar() end,
    })

    -- Enter mode
    local enterState = getEnterMode() and "ON" or "OFF"
    table.insert(items, {
        title = "Enter after insert: " .. enterState,
        fn = function() cycleEnter(); updateMenuBar() end,
    })

    -- LLM refinement
    if hasOllama() then
        local refineState = getRefineMode() and "ON" or "OFF"
        table.insert(items, {
            title = "LLM Refine: " .. refineState .. " (" .. getRefineModel() .. ")",
            fn = function() cycleRefine(); updateMenuBar() end,
        })
    else
        table.insert(items, {
            title = "LLM Refine (install ollama.com)",
            disabled = true,
        })
    end

    -- Preferred langs
    local preferred = table.concat(getPreferredLangs(), ", ")
    table.insert(items, { title = "Preferred: " .. preferred, disabled = true })

    table.insert(items, { title = "-" })

    -- Settings overlay
    table.insert(items, {
        title = "Settings...",
        fn = function()
            if overlay then
                forceHideOverlay()
            else
                showOverlay()
                overlayPinned = true
                overlay[1].fillColor = { red = 0.15, green = 0.15, blue = 0.2, alpha = 0.92 }
                setOverlayText("Click labels to change settings")
            end
        end,
    })

    -- Recent dictations
    if #recentDictations > 0 then
        table.insert(items, { title = "-" })
        table.insert(items, { title = "Recent Dictations", disabled = true })
        for _, entry in ipairs(recentDictations) do
            local ago = os.time() - entry.time
            local timeStr
            if ago < 60 then timeStr = "just now"
            elseif ago < 3600 then timeStr = math.floor(ago / 60) .. "m ago"
            else timeStr = math.floor(ago / 3600) .. "h ago"
            end
            local preview = entry.text
            if #preview > 40 then preview = preview:sub(1, 37) .. "..." end
            local icon = entry.inserted and "⏎" or "⚡"
            table.insert(items, {
                title = icon .. " " .. preview .. "  " .. timeStr,
                fn = function()
                    hs.pasteboard.setContents(entry.text)
                    hs.eventtap.keyStroke({"cmd"}, "v")
                    hs.notify.new({ title = "Pasted", informativeText = entry.text }):send()
                end,
            })
        end
    end

    table.insert(items, { title = "-" })

    -- Reload actions
    table.insert(items, {
        title = "Reload Actions",
        fn = function() WhisperActions.reload() end,
    })

    -- Emergency stop
    table.insert(items, { title = "-" })
    table.insert(items, {
        title = "Emergency Stop",
        fn = function() emergencyStop() end,
    })

    return items
end

local function createMenuBar()
    -- Clean up previous instance on reload
    if menuBar then menuBar:delete(); menuBar = nil end
    menuBar = hs.menubar.new()
    if not menuBar then return end
    updateMenuBar()
    menuBar:setMenu(buildMenuBarMenu)
end

--------------------------------------------------------------------------------
-- Recording indicator (pulsing dot + timer)
--------------------------------------------------------------------------------

local function startRecordingIndicator()
    if not overlay then return end
    recordingStartTime = hs.timer.secondsSinceEpoch()
    pulseAlpha = 1.0
    pulseFading = true

    -- Show dot and timer
    overlay[EL.dot].fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = 1.0 }
    overlay[EL.timer].textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 1.0 }

    -- Pulse the red dot
    pulseTimer = hs.timer.doEvery(0.05, function()
        if not overlay then return end
        if pulseFading then
            pulseAlpha = pulseAlpha - 0.03
            if pulseAlpha <= 0.2 then pulseFading = false end
        else
            pulseAlpha = pulseAlpha + 0.03
            if pulseAlpha >= 1.0 then pulseFading = true end
        end
        overlay[EL.dot].fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = pulseAlpha }
    end)

    -- Update elapsed time every second
    clockTimer = hs.timer.doEvery(1, function()
        if not overlay then return end
        local elapsed = math.floor(hs.timer.secondsSinceEpoch() - recordingStartTime)
        local min = math.floor(elapsed / 60)
        local sec = elapsed % 60
        overlay[EL.timer].text = string.format("%d:%02d", min, sec)
    end)
end

local function stopRecordingIndicator()
    if pulseTimer then pulseTimer:stop(); pulseTimer = nil end
    if clockTimer then clockTimer:stop(); clockTimer = nil end
    if overlay then
        overlay[EL.dot].fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = 0.0 }
        overlay[EL.timer].textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 0.0 }
        overlay[EL.timer].text = ""
    end
end

--------------------------------------------------------------------------------
-- Emergency stop (forward declaration)
--------------------------------------------------------------------------------

function emergencyStop()
    log("emergency stop")
    isRecording = false
    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    stopRecordingIndicator()
    if ffmpegTask and ffmpegTask:isRunning() then ffmpegTask:interrupt() end
    ffmpegTask = nil
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    forceHideOverlay()
    updateMenuBar()
    os.execute("killall whisper-cli 2>/dev/null")
    hs.notify.new({ title = "local-whisper", informativeText = "Stopped" }):send()
end

--------------------------------------------------------------------------------
-- Partial transcription (live preview while recording)
--------------------------------------------------------------------------------

local function doPartialTranscribe()
    if partialBusy or not isRecording then return end

    local chunks = getChunkFiles()
    local numChunks = #chunks
    if numChunks < 3 then return end

    local completed = numChunks - 1  -- skip last chunk (being written)
    if completed <= lastChunkCount then return end

    partialBusy = true

    -- Batch last 4 completed chunks
    local startIdx = math.max(1, completed - 3)
    local batchList = WHISPER_TMP .. "/partial_concat.txt"
    local f = io.open(batchList, "w")
    for i = startIdx, completed do
        f:write("file '" .. chunks[i] .. "'\n")
    end
    f:close()

    local batchWav = WHISPER_TMP .. "/partial_batch.wav"
    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            partialBusy = false
            return
        end
        local lang = getLang()
        -- In auto mode, use first preferred lang for speed during partial transcription
        if lang == "auto" then lang = getPreferredLangs()[1] end
        local whisperArgs = { "-m", getPartialModelPath(), "-f", batchWav, "-l", lang, "-nt", "--no-prints" }
        local promptArgs = getPromptArgs()
        for _, a in ipairs(promptArgs) do table.insert(whisperArgs, a) end
        local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
            partialBusy = false
            lastChunkCount = completed
            if code2 ~= 0 or not isRecording then return end
            local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            if text ~= "" and not isHallucination(text) then
                local display = text
                if #display > 200 then display = "..." .. display:sub(-197) end
                setOverlayText(display)
                log("partial: " .. text)
            end
        end, whisperArgs)
        whisperTask:start()
    end, { "-y", "-f", "concat", "-safe", "0", "-i", batchList, "-c", "copy", batchWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Final transcription
--------------------------------------------------------------------------------

-- Low-level text insertion at cursor
local function insertTextAtCursor(text, mode)
    if mode == "paste" then
        local oldClipboard = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)
        hs.eventtap.keyStroke({"cmd"}, "v")
        hs.timer.doAfter(0.3, function()
            if oldClipboard then hs.pasteboard.setContents(oldClipboard) end
        end)
    else
        hs.eventtap.keyStrokes(text)
    end
end

-- Finish insertion after all processing (post-process, refine, hooks)
local function finishInsertion(text, detectedLang)
    -- Build action context and run pre-insert hooks
    local ctx = buildActionContext(normalizeText(text), detectedLang or getLang(), getOutputMode())
    runPreInsertActions(ctx)

    local finalText = normalizeText(ctx.text)
    if finalText == "" then
        log("final: empty text after actions")
        hideOverlay()
        return
    end

    if ctx.insert then
        -- Track for undo
        lastInsertedText = finalText
        insertTextAtCursor(finalText, ctx.outputMode)
        ctx.inserted = true

        -- Press Enter after insertion if enter mode is on
        if getEnterMode() then
            hs.timer.doAfter(0.15, function()
                hs.eventtap.keyStroke({}, "return")
            end)
        end
    else
        log("final: insertion disabled by action hooks")
    end

    ctx.text = finalText
    runPostInsertActions(ctx)

    -- Track in recent dictations
    table.insert(recentDictations, 1, {
        text = ctx.originalText,
        time = os.time(),
        inserted = ctx.inserted,
        app = capturedAppName or "?",
    })
    while #recentDictations > MAX_RECENT do
        table.remove(recentDictations)
    end
    saveRecentDictations()

    local display = finalText
    if detectedLang then display = display .. " [" .. detectedLang:upper() .. "]" end
    setOverlayText(display)
    hs.sound.getByFile("/System/Library/Sounds/Glass.aiff"):play()
    hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
end

-- Insert transcribed text at cursor, with post-processing, optional LLM refinement, and action hooks
local function insertTranscribedText(text, detectedLang)
    if text == "" or isHallucination(text) then
        hideOverlay()
        return
    end

    -- Apply app-aware post-processing
    text = postProcess(text, capturedAppBundleID)
    if text == "" then hideOverlay(); return end

    -- Skip LLM refinement for voice commands (refine would strip the prefix)
    local isVoiceCommand = text:lower():match("voice%s+command")

    -- Optional LLM refinement (async, skips short text and voice commands)
    if not isVoiceCommand and getRefineMode() and #text >= REFINE_MIN_CHARS then
        setOverlayText("Refining...")
        refineWithOllama(text, function(refined)
            finishInsertion(refined, detectedLang)
        end)
    else
        finishInsertion(text, detectedLang)
    end
end

local function doFinalTranscription()
    local chunks = getChunkFiles()
    if #chunks < 2 then
        log("final: not enough chunks, skipping")
        hideOverlay()
        return
    end

    setOverlayText("Transcribing...")

    local concatFile = WHISPER_TMP .. "/concat.txt"
    local f = io.open(concatFile, "w")
    for _, chunk in ipairs(chunks) do
        f:write("file '" .. chunk .. "'\n")
    end
    f:close()

    local finalWav = WHISPER_TMP .. "/final.wav"
    local lang = getLang()
    local preferred = getPreferredLangs()

    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            log("final: concat failed")
            setOverlayText("Error: concat failed")
            hs.timer.doAfter(2, hideOverlay)
            return
        end

        local promptArgs = getPromptArgs()

        if lang == "auto" then
            -- Auto mode: run without --no-prints to capture detected language from stderr
            local autoArgs = { "-m", getModelPath(), "-f", finalWav, "-l", "auto", "-nt" }
            for _, a in ipairs(promptArgs) do table.insert(autoArgs, a) end
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2, err2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    setOverlayText("Error: transcription failed")
                    hs.timer.doAfter(2, hideOverlay)
                    return
                end

                -- Parse detected language from whisper stderr
                local detected = (err2 or ""):match("auto%-detected language:%s*(%w+)")
                log("auto-detected: " .. tostring(detected))

                local inPreferred = false
                if detected then
                    for _, pl in ipairs(preferred) do
                        if detected == pl then inPreferred = true; break end
                    end
                end

                if inPreferred then
                    local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                    log("final (auto/" .. detected .. "): '" .. text .. "'")
                    insertTranscribedText(text, detected)
                else
                    -- Detected language not in preferred list — re-transcribe with first preferred
                    local fallback = preferred[1]
                    log("auto-detect got '" .. tostring(detected) .. "', re-running with " .. fallback)
                    setOverlayText("Re-transcribing (" .. fallback:upper() .. ")...")
                    local retryArgs = { "-m", getModelPath(), "-f", finalWav, "-l", fallback, "-nt", "--no-prints" }
                    for _, a in ipairs(promptArgs) do table.insert(retryArgs, a) end
                    local retryTask = hs.task.new(WHISPER_BIN, function(code3, out3)
                        if code3 ~= 0 then
                            log("final: retry whisper failed")
                            setOverlayText("Error: transcription failed")
                            hs.timer.doAfter(2, hideOverlay)
                            return
                        end
                        local text = (out3 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                        log("final (retry/" .. fallback .. "): '" .. text .. "'")
                        insertTranscribedText(text, fallback)
                    end, retryArgs)
                    retryTask:start()
                end
            end, autoArgs)
            whisperTask:start()
        else
            -- Specific language mode
            local langArgs = { "-m", getModelPath(), "-f", finalWav, "-l", lang, "-nt", "--no-prints" }
            for _, a in ipairs(promptArgs) do table.insert(langArgs, a) end
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    setOverlayText("Error: transcription failed")
                    hs.timer.doAfter(2, hideOverlay)
                    return
                end
                local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                log("final: '" .. text .. "'")
                insertTranscribedText(text)
            end, langArgs)
            whisperTask:start()
        end
    end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", finalWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Auto-stop on silence
--------------------------------------------------------------------------------

local function checkSilence()
    if not isRecording then return end
    local chunks = getChunkFiles()
    local numChunks = #chunks
    -- Only check completed chunks (not the one being written)
    local completed = numChunks - 1
    if completed <= lastCheckedChunk then return end

    -- Check the latest completed chunk
    local chunkPath = chunks[completed]
    lastCheckedChunk = completed

    local volTask = hs.task.new(FFMPEG, function(code, out, err)
        if code ~= 0 or not isRecording then return end
        local maxVol = (err or ""):match("max_volume:%s*([-%.%d]+)")
        if maxVol then
            maxVol = tonumber(maxVol)
            if maxVol and maxVol < AUTO_STOP_THRESHOLD_DB then
                silentChunkCount = silentChunkCount + 1
                log("silence: chunk " .. completed .. " vol=" .. maxVol .. "dB (count=" .. silentChunkCount .. ")")
                if silentChunkCount >= AUTO_STOP_SILENCE_SECONDS then
                    log("auto-stop: " .. AUTO_STOP_SILENCE_SECONDS .. "s of silence")
                    stopRecording()
                end
            else
                silentChunkCount = 0
            end
        end
    end, { "-i", chunkPath, "-af", "volumedetect", "-f", "null", "-" })
    volTask:start()
end

--------------------------------------------------------------------------------
-- Start / stop recording
--------------------------------------------------------------------------------

local function startRecording()
    if isRecording then return end
    isRecording = true
    log("recording: start")

    os.execute("rm -rf '" .. CHUNK_DIR .. "'")
    os.execute("mkdir -p '" .. CHUNK_DIR .. "'")

    captureActiveApp()
    log("recording: app=" .. tostring(capturedAppName) .. " (" .. tostring(capturedAppBundleID) .. ")")

    showOverlay()
    if getRefineMode() and hasOllama() then
        setOverlayText("Listening... (LLM refine ON)")
    end
    startRecordingIndicator()
    updateMenuBar()
    hs.sound.getByFile("/System/Library/Sounds/Pop.aiff"):play()

    ffmpegTask = hs.task.new(FFMPEG, function(code, out, err)
        log("recording: ffmpeg exited " .. tostring(code))
    end, {
        "-f", "avfoundation", "-i", AUDIO_DEVICE,
        "-ac", "1", "-ar", "16000",
        "-f", "segment", "-segment_time", "1", "-segment_format", "wav",
        CHUNK_DIR .. "/chunk_%03d.wav"
    })
    ffmpegTask:start()

    lastChunkCount = 0
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    partialTimer = hs.timer.doEvery(PARTIAL_INTERVAL, doPartialTranscribe)
    silenceTimer = hs.timer.doEvery(1.0, checkSilence)
end

local function stopRecording()
    if not isRecording then return end
    isRecording = false
    log("recording: stop")

    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0

    stopRecordingIndicator()
    updateMenuBar()

    if ffmpegTask and ffmpegTask:isRunning() then
        ffmpegTask:interrupt()
    end
    ffmpegTask = nil

    hs.sound.getByFile("/System/Library/Sounds/Tink.aiff"):play()

    -- Brief delay for ffmpeg to finalize last chunk
    hs.timer.doAfter(0.3, doFinalTranscription)
end

--------------------------------------------------------------------------------
-- Key detection (replaces Karabiner)
--------------------------------------------------------------------------------

-- Map trigger key to generic modifier name for polling
local GENERIC_MOD = { rightAlt = "alt", rightCmd = "cmd", rightCtrl = "ctrl" }
local genericMod = GENERIC_MOD[TRIGGER_KEY]

local releasePoller = nil

-- Global so we can inspect state via hs -c
_whisper = { modTap = nil, recording = false }

local modTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    -- Wrap in pcall so errors don't kill the eventtap
    local ok, err = pcall(function()
        local rawFlags = event:rawFlags()
        local triggered = (rawFlags & triggerMask) > 0

        if triggered and not isRecording then
            startRecording()
            -- Poll for release since flagsChanged doesn't fire on key-up
            if releasePoller then releasePoller:stop() end
            releasePoller = hs.timer.doEvery(0.1, function()
                local mods = hs.eventtap.checkKeyboardModifiers()
                if not mods[genericMod] then
                    releasePoller:stop()
                    releasePoller = nil
                    stopRecording()
                end
            end)
        elseif not triggered and isRecording then
            if releasePoller then releasePoller:stop(); releasePoller = nil end
            stopRecording()
        end
    end)
    if not ok then log("eventtap error: " .. tostring(err)) end

    return false
end)
modTap:start()
_whisper.modTap = modTap

-- Re-enable eventtap if it gets disabled (e.g. by secure input)
hs.timer.doEvery(5, function()
    if not modTap:isEnabled() then
        log("eventtap was disabled, re-enabling")
        modTap:start()
    end
end)

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

-- Request mic permission (child processes via hs.task inherit it)
if type(hs.microphoneState) == "function" and not hs.microphoneState() then
    log("requesting microphone permission")
    hs.microphoneState(true)
end

-- Create default preferred langs file if it doesn't exist
if readFile(PREFERRED_LANGS_FILE) == "" then
    writeFile(PREFERRED_LANGS_FILE, "en,pt")
end

-- Create menu bar icon
createMenuBar()

-- Load action hooks
local actionsEnabled = loadActionConfig() ~= nil
log("actions: " .. (actionsEnabled and "enabled" or "disabled"))

local enterStatus = getEnterMode() and "⏎" or ""
local actionsFlag = actionsEnabled and " +actions" or ""
log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. getModelName() .. ", preferred=" .. table.concat(getPreferredLangs(), ",") .. ")")
hs.notify.new({
    title = "local-whisper",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. enterStatus .. " / " .. getModelName() .. actionsFlag .. ") — hold " .. TRIGGER_KEY
}):send()
