-- Copy to: ~/.hammerspoon/local_whisper_actions.lua
-- Optional hooks for local-whisper dictation output.
--
-- Hooks:
--   beforeInsert(ctx)  -> runs once before default insertion
--   actions = { ... }  -> ordered list of actions (function or {name, when|pattern, run})
--   afterInsert(ctx)   -> runs after default insertion (or after insert is skipped)
--
-- Context fields:
--   ctx.text, ctx.textLower, ctx.originalText
--   ctx.lang, ctx.outputMode
--   ctx.appName, ctx.appBundleID   -- app that was focused when recording started
--   ctx.insert, ctx.inserted, ctx.handled
--
-- Context methods:
--   ctx:setText("new text")
--   ctx:disableInsert(), ctx:enableInsert()
--   ctx:launchApp("Safari")
--   ctx:appendToFile(path, line)
--   ctx:runShell("command", optionalInputText)
--   ctx:keystroke({"cmd"}, "a")      -- fire a keystroke
--   ctx:notify("message"), ctx:log("message")
--
-- Patterns in actions[].pattern match against ctx.textLower (case-insensitive).
-- Set ctx.handled = true in any hook to skip remaining actions.
-- Config auto-reloads when the file changes (no need for Ctrl+Alt+R).

local HOME = os.getenv("HOME")
local NOTES_ROOT = HOME .. "/Notes/dictation"

local function dailyFile(name)
    return string.format("%s/%s-%s.md", NOTES_ROOT, name, os.date("%Y-%m-%d"))
end

local function normalizeCommandText(text)
    return ((text or ""):gsub("%s+", " ")):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parseOpenAppCommand(text)
    local normalized = normalizeCommandText(text)
    local lower = normalized:lower()
    local appName = lower:match("^open%s+app%s+(.+)$")
    if not appName then return nil end

    -- Keep original app casing by slicing from normalized text
    local originalAppName = normalized:sub(#normalized - #appName + 1)
    originalAppName = originalAppName:gsub("[%.%,%!%?;:%s]+$", "")
    if originalAppName == "" then return nil end
    return originalAppName
end

return {
    beforeInsert = function(ctx)
        -- "note buy coffee" -> append to daily notes, skip insertion
        -- Whisper may transcribe as "Note: buy coffee", "Note, buy coffee", etc.
        local note = ctx.textLower:match("^note[%s%p]+(.+)$")
        if note then
            -- Use original-case text for the note content
            local origNote = ctx.text:match("^%w+[%s%p]+(.+)$")
            ctx:appendToFile(dailyFile("notes"), "- " .. (origNote or note))
            ctx:disableInsert()
            ctx:notify("Saved note")
            ctx.handled = true
            return
        end

        -- "journal today was productive" -> append to daily journal
        local journal = ctx.textLower:match("^journal[%s%p]+(.+)$")
        if journal then
            local origJournal = ctx.text:match("^%w+[%s%p]+(.+)$")
            ctx:appendToFile(dailyFile("journal"), origJournal or journal)
            ctx:disableInsert()
            ctx:notify("Saved journal entry")
            ctx.handled = true
            return
        end

        -- "open app Safari" -> launch/focus an app
        local appName = parseOpenAppCommand(ctx.text)
        if appName then
            ctx:launchApp(appName)
            ctx:disableInsert()
            ctx.handled = true
            return
        end
    end,

    actions = {
        -- "todo call mom" -> append to daily tasks
        {
            name = "todo-to-file",
            pattern = "^todo[%s%p]+(.+)$",
            run = function(ctx)
                local task = ctx.text:match("^%w+[%s%p]+(.+)$")
                if task then
                    ctx:appendToFile(dailyFile("tasks"), "- [ ] " .. task)
                    ctx:disableInsert()
                    ctx:notify("Saved todo")
                end
            end,
        },

        -- Example: app-aware behavior
        -- When dictating in Slack, add a trailing newline to auto-send
        -- {
        --     name = "slack-auto-send",
        --     when = function(ctx)
        --         return ctx.appBundleID == "com.tinyspeck.slackmacgap"
        --     end,
        --     run = function(ctx)
        --         ctx:setText(ctx.text)  -- text is inserted normally
        --         -- afterInsert will handle the Enter key
        --     end,
        -- },

        -- Example: local LLM rewrite (requires ollama)
        -- "rewrite: this needs to sound professional"
        -- {
        --     name = "local-llm-rewrite",
        --     pattern = "^rewrite:%s*(.+)$",
        --     run = function(ctx)
        --         local payload = ctx.text:match("^%w+:%s*(.+)$")
        --         if not payload then return end
        --         ctx:notify("Rewriting...")
        --         local ok, output = ctx:runShell(
        --             "ollama run llama3.2 \"Rewrite concisely:\"",
        --             payload
        --         )
        --         if ok and output and output:gsub("%s+", "") ~= "" then
        --             ctx:setText(output)
        --         else
        --             ctx:notify("Rewrite failed; using original")
        --         end
        --     end,
        -- },
    },

    afterInsert = function(ctx)
        if ctx.inserted then
            ctx:log("inserted: [" .. (ctx.appName or "?") .. "] " .. ctx.text)
        end
    end,
}
