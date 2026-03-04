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

-- External binaries (absolute paths)
local FFMPEG = "/opt/homebrew/bin/ffmpeg"
local WHISPER_BIN = HOME .. "/whisper.cpp/build/bin/whisper-cli"
local WHISPER_MODEL = HOME .. "/whisper.cpp/models/ggml-medium.bin"

-- Model name (extracted from path for display)
local MODEL_NAME = WHISPER_MODEL:match("ggml%-(.+)%.bin") or "unknown"

-- Audio device: ":default" for system default, ":0", ":1" etc. for specific
local AUDIO_DEVICE = ":1"

-- Trigger key: "rightAlt", "rightCmd", "rightCtrl"
local TRIGGER_KEY = "rightCmd"

-- User preference files
local LANG_FILE = HOME .. "/.whisper_dictation_lang"
local OUTPUT_FILE = HOME .. "/.whisper_dictation_output"
local LOG_FILE = WHISPER_TMP .. "/whisper-dictate.log"

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

local function statusLine()
    return string.format("[%s | %s | %s]", getLang():upper(), getOutputMode():upper(), MODEL_NAME)
end

--------------------------------------------------------------------------------
-- Overlay UI
--------------------------------------------------------------------------------

local overlay = nil

local function createOverlay()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()
    local width, height = 420, 100
    local padding = 20
    local x = frame.x + frame.w - width - padding
    local y = frame.y + frame.h - height - padding - 50

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- 1: Background
    overlay:appendElements({
        id = "bg",
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 },
    })

    -- 2: Status line (lang | output | model)
    overlay:appendElements({
        id = "status",
        type = "text", text = statusLine(),
        textColor = { red = 0.5, green = 0.8, blue = 1.0, alpha = 1.0 },
        textSize = 11,
        frame = { x = "5%", y = "8%", w = "80%", h = "25%" },
    })

    -- 3: Close button (X)
    overlay:appendElements({
        id = "close",
        type = "text", text = "✕",
        textColor = { red = 1, green = 1, blue = 1, alpha = 0.5 },
        textSize = 14,
        textAlignment = "right",
        frame = { x = "88%", y = "4%", w = "10%", h = "25%" },
        trackMouseUp = true,
    })

    -- 4: Transcript text
    overlay:appendElements({
        id = "text",
        type = "text", text = "Listening...",
        textColor = { red = 1, green = 1, blue = 1, alpha = 1.0 },
        textSize = 14,
        frame = { x = "5%", y = "35%", w = "90%", h = "60%" },
    })

    overlay:level(hs.canvas.windowLevels.overlay)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- Mouse click handler for close button
    overlay:canvasMouseEvents(false, true, false, false)  -- track mouseUp only
    overlay:mouseCallback(function(canvas, event, id, x, y)
        if event == "mouseUp" and id == "close" then
            emergencyStop()
        end
    end)
end

local function showOverlay()
    if overlay then overlay:delete() end
    createOverlay()
    overlay:show()
end

local function hideOverlay()
    if overlay then overlay:delete(); overlay = nil end
end

local function setOverlayText(text)
    if overlay then overlay[4].text = text end  -- element 4 = transcript
end

local function setOverlayStatus()
    if overlay then overlay[2].text = statusLine() end  -- element 2 = status
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local isRecording = false
local ffmpegTask = nil
local partialTimer = nil
local partialBusy = false
local lastChunkCount = 0

--------------------------------------------------------------------------------
-- Emergency stop (forward declaration)
--------------------------------------------------------------------------------

function emergencyStop()
    log("emergency stop")
    isRecording = false
    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if ffmpegTask and ffmpegTask:isRunning() then ffmpegTask:interrupt() end
    ffmpegTask = nil
    partialBusy = false
    hideOverlay()
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
        end, { "-m", WHISPER_MODEL, "-f", batchWav, "-l", lang, "-nt", "--no-prints" })
        whisperTask:start()
    end, { "-y", "-f", "concat", "-safe", "0", "-i", batchList, "-c", "copy", batchWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Final transcription
--------------------------------------------------------------------------------

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
    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            log("final: concat failed")
            setOverlayText("Error: concat failed")
            hs.timer.doAfter(2, hideOverlay)
            return
        end

        local lang = getLang()
        local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
            if code2 ~= 0 then
                log("final: whisper failed")
                setOverlayText("Error: transcription failed")
                hs.timer.doAfter(2, hideOverlay)
                return
            end

            local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            log("final: '" .. text .. "'")

            if text == "" or isHallucination(text) then
                hideOverlay()
                return
            end

            -- Insert text at cursor
            local mode = getOutputMode()
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

            setOverlayText(text)
            hs.sound.getByFile("/System/Library/Sounds/Glass.aiff"):play()
            hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
        end, { "-m", WHISPER_MODEL, "-f", finalWav, "-l", lang, "-nt", "--no-prints" })
        whisperTask:start()
    end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", finalWav })
    concatTask:start()
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

    showOverlay()
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
    partialTimer = hs.timer.doEvery(PARTIAL_INTERVAL, doPartialTranscribe)
end

local function stopRecording()
    if not isRecording then return end
    isRecording = false
    log("recording: stop")

    if partialTimer then partialTimer:stop(); partialTimer = nil end
    partialBusy = false

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

local modTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
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

    return false
end)
modTap:start()

--------------------------------------------------------------------------------
-- Language hotkeys
--------------------------------------------------------------------------------

local function setLang(lang)
    writeFile(LANG_FILE, lang)
    setOverlayStatus()  -- update overlay if visible
    hs.notify.new({ title = "local-whisper", informativeText = "Language: " .. lang:upper() }):send()
end

hs.hotkey.bind({"ctrl", "alt"}, "E", function() setLang("en") end)
hs.hotkey.bind({"ctrl", "alt"}, "P", function() setLang("pt") end)
hs.hotkey.bind({"ctrl", "alt"}, "A", function() setLang("auto") end)

hs.hotkey.bind({"ctrl", "alt"}, "T", function()
    local cycle = { en = "pt", pt = "auto", auto = "en" }
    setLang(cycle[getLang()] or "en")
end)

--------------------------------------------------------------------------------
-- Output mode hotkey
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "O", function()
    local next = (getOutputMode() == "paste") and "type" or "paste"
    writeFile(OUTPUT_FILE, next)
    setOverlayStatus()  -- update overlay if visible
    hs.notify.new({ title = "local-whisper", informativeText = "Output: " .. next:upper() }):send()
end)

--------------------------------------------------------------------------------
-- Emergency stop hotkey (Ctrl+Alt+X)
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "X", function() emergencyStop() end)

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

-- Request mic permission (child processes via hs.task inherit it)
if type(hs.microphoneState) == "function" and not hs.microphoneState() then
    log("requesting microphone permission")
    hs.microphoneState(true)
end

log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. MODEL_NAME .. ")")
hs.notify.new({
    title = "local-whisper",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. " / " .. MODEL_NAME .. ") — hold " .. TRIGGER_KEY
}):send()
