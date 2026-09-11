---@diagnostic disable: undefined-global

-- Requires

-- secrets.lua not included in version control, and should contain the following:
-- LoginUrl = "WORK_LOGIN_URL"
-- PasswordPrefix = "PASSWORD_PREFIX"
-- PasswordSuffix = "PASSWORD_SUFFIX"
require "secrets"


-- Helper functions

function IsCitrixFrontmost()
    local frontmostApp = hs.application.frontmostApplication()
    if frontmostApp and frontmostApp:name() == "Citrix Viewer" then
        return true, frontmostApp
    end
    return false, nil
end

function IsCharacterKeyCode(keyCode)
    local keyName = hs.keycodes.map[keyCode]
    if type(keyName) ~= "string" then
        return false
    end
    return keyName:len() == 1 or keyName == "space"
end

function SendCtrlRightCmdRightOptionKeyToApp(keyCode, targetApp)
    local rightCmdKeyCode = hs.keycodes.map["rightcmd"]
    local rightOptionKeyCode = hs.keycodes.map["rightalt"]
    local ctrlKeyCode = hs.keycodes.map["ctrl"]
    if rightCmdKeyCode == nil or rightOptionKeyCode == nil or ctrlKeyCode == nil or keyCode == nil then
        return
    end

    local function postKey(code, isDown)
        local event = hs.eventtap.event.newKeyEvent(code, isDown)
        if targetApp then
            event:post(targetApp)
        else
            event:post()
        end
    end

    postKey(ctrlKeyCode, true)
    postKey(rightCmdKeyCode, true)
    postKey(rightOptionKeyCode, true)

    hs.timer.doAfter(0.1, function()
        postKey(keyCode, true)

        hs.timer.doAfter(0.2, function()
            postKey(keyCode, false)
            postKey(ctrlKeyCode, false)
            postKey(rightOptionKeyCode, false)
            postKey(rightCmdKeyCode, false)
        end)
    end)
end

function SendCtrlCmdKeyToApp(keyCode, targetApp)
    local cmdKeyCode = hs.keycodes.map["cmd"]
    local optionKeyCode = hs.keycodes.map["alt"]
    local ctrlKeyCode = hs.keycodes.map["ctrl"]
    if cmdKeyCode == nil or ctrlKeyCode == nil or keyCode == nil then
        return
    end

    local function postKey(code, isDown)
        local event = hs.eventtap.event.newKeyEvent(code, isDown)
        if targetApp then
            event:post(targetApp)
        else
            event:post()
        end
    end

    postKey(ctrlKeyCode, true)
    postKey(optionKeyCode, true)
    postKey(cmdKeyCode, true)

    hs.timer.doAfter(0.1, function()
        postKey(keyCode, true)

        hs.timer.doAfter(0.2, function()
            postKey(keyCode, false)
            postKey(ctrlKeyCode, false)
            postKey(optionKeyCode, false)
            postKey(cmdKeyCode, false)
        end)
    end)
end

function BindAppShortcut(keyStroke, appName)
    hs.hotkey.bind({"ctrl", "cmd"}, keyStroke, function()
        local isCitrixFrontmost, frontmostApp = IsCitrixFrontmost()
        if isCitrixFrontmost then
            local keyCode = hs.keycodes.map[keyStroke]
            if keyCode ~= nil then
                SendCtrlCmdKeyToApp(keyCode, frontmostApp)
            end
            return
        end

        hs.application.launchOrFocus(appName)
        hs.alert.show(appName, 0.5)
    end)
end

function BindAltShortcut(keyStroke, appName)
    hs.hotkey.bind({"ctrl", "option"}, keyStroke, function()
        local isCitrixFrontmost, frontmostApp = IsCitrixFrontmost()
        if isCitrixFrontmost then
            local keyCode = hs.keycodes.map[keyStroke]
            if keyCode ~= nil then
                SendCtrlRightCmdRightOptionKeyToApp(keyCode, frontmostApp)
            end
            return
        end

        hs.application.launchOrFocus(appName)
        hs.alert.show(appName, 0.5)
    end)
end

-- When Citrix is frontmost, remap ctrl+option+<character> to ctrl+rightcmd+rightoption+<character>.
local citrixCtrlAltRemapTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local isCitrixFrontmost, frontmostApp = IsCitrixFrontmost()
    if not isCitrixFrontmost then
        return false
    end

    local flags = event:getFlags()
    if not flags:containExactly({"ctrl", "alt"}) then
        return false
    end

    local keyCode = event:getKeyCode()
    if not IsCharacterKeyCode(keyCode) then
        return false
    end

    SendCtrlRightCmdRightOptionKeyToApp(keyCode, frontmostApp)
    return true
end)
citrixCtrlAltRemapTap:start()

-- When Citrix is frontmost, remap ctrl+cmd+<character> to ctrl+cmd+<character> (delayed send).
local citrixCtrlCmdRemapTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local isCitrixFrontmost, frontmostApp = IsCitrixFrontmost()
    if not isCitrixFrontmost then
        return false
    end

    local flags = event:getFlags()
    if not flags:containExactly({"ctrl", "cmd"}) then
        return false
    end

    local keyCode = event:getKeyCode()
    if not IsCharacterKeyCode(keyCode) then
        return false
    end

    SendCtrlCmdKeyToApp(keyCode, frontmostApp)
    return true
end)
citrixCtrlCmdRemapTap:start()

function BindPasswordShortcut(passwordIndex)
    print("Binding password shortcut for: "..passwordIndex)
    hs.hotkey.bind({"ctrl", "cmd"}, passwordIndex, function()
        hs.eventtap.keyStroke({"cmd"}, "a")
        hs.eventtap.keyStrokes(PasswordPrefix..passwordIndex..PasswordSuffix)
        hs.eventtap.keyStroke({}, "return")
    end)
end

function SearchAudible(searchQuery)
    searchQuery = searchQuery:gsub(' by ', ' ')
    searchQuery = searchQuery:gsub(' %- ', ' ')
    searchQuery = searchQuery:gsub("'", '')
    print("Searching Audible for book (after title has been sanitised): "..searchQuery)
    local audibleSearchUrl = "https://www.audible.co.uk/search?keywords="..searchQuery
    os.execute("open '"..audibleSearchUrl.."'")
end

function SearchBook(bookName)
    bookName = bookName:gsub(' by ', ' ')
    bookName = bookName:gsub(' %- ', ' ')
    bookName = bookName:gsub("'", '')
    print("Searching for book (after title has been sanitised): "..bookName)
    local bookReviewSearchUrl = "https://duckduckgo.com/?va=q&t=hd&q=\\"..bookName.."+site%3Agoodreads.com&ia=web"
    local bookDownloadSearchUrl = "https://libgen.vg/index.php?req="..bookName.."&criteria=&language=English&format=epub"
    os.execute("open '"..bookReviewSearchUrl.."'")
    os.execute("open '"..bookDownloadSearchUrl.."'")
    hs.timer.doAfter(0.5, function()
        hs.eventtap.keyStroke({"ctrl", "shift"}, "tab")
    end)
end

-- App shortcuts: Ctrl-Alt

BindAppShortcut("c", "Claude")
BindAppShortcut("d", "Discord")
BindAppShortcut("e", "Telegram")
BindAppShortcut("f", "Finder")
BindAppShortcut("g", "Google Chrome")
BindAppShortcut("y", "Quickgif")
BindAppShortcut("h", "HTTPie")
BindAppShortcut("i", "iTerm")
BindAppShortcut("m", "MongoDB Compass")
BindAppShortcut("n", "Notes")
BindAppShortcut("o", "Codex")
BindAppShortcut("p", "Preview")
BindAppShortcut("r", "Reminders")
BindAppShortcut("s", "Signal")
BindAppShortcut("t", "Bitwarden")
BindAppShortcut("u", "Cursor")
BindAppShortcut("v", "Visual Studio Code")
BindAppShortcut("w", "WhatsApp")
BindAppShortcut("x", "Xcode")
BindAppShortcut("z", "zoom.us")

-- App shortcuts: Ctrl-Option

BindAltShortcut("c", "ChatGPT Classic")
BindAltShortcut("g", "Gmail")
BindAltShortcut("s", "Simulator")

-- Other hotkeys

-- Search Audible for highlighted book
hs.hotkey.bind({"alt", "cmd"}, "a", function()
    -- Backup the existing clipboard
    local clipboardContents = hs.pasteboard.getContents()

    -- Copy the highlighted text, and get the book name
    hs.eventtap.keyStroke({"cmd"}, "c")
    local searchQuery = hs.pasteboard.getContents()
    
    SearchAudible(searchQuery)

    -- Restore the original clipboard
    hs.pasteboard.setContents(clipboardContents)
end)

-- Search for highlighted book
hs.hotkey.bind({"alt", "cmd"}, "b", function()
    -- Backup the existing clipboard
    local clipboardContents = hs.pasteboard.getContents()

    -- Copy the highlighted text, and get the book name
    hs.eventtap.keyStroke({"cmd"}, "c")
    local bookName = hs.pasteboard.getContents()
    
    SearchBook(bookName)

    -- Restore the original clipboard
    hs.pasteboard.setContents(clipboardContents)
end)


-- Search Audible via prompt
hs.hotkey.bind({"ctrl", "cmd"}, "a", function()
    local button, searchQuery = hs.dialog.textPrompt("Audible search", "Please enter a title to search for:", "", "OK", "Cancel")
    if button == "OK" then
        SearchAudible(searchQuery)
    end
end)


-- Search for book via prompt
hs.hotkey.bind({"ctrl", "cmd"}, "b", function()
    local button, bookName = hs.dialog.textPrompt("Book search", "Please enter a book title to search for:", "", "OK", "Cancel")
    if button == "OK" then
        SearchBook(bookName)
    end
end)

-- Password
for passwordIndex = 1, 9, 1 do
    BindPasswordShortcut(tostring(passwordIndex))
end

-- Login to work
hs.hotkey.bind({"ctrl", "cmd"}, "l", function()

    local function citrixIsActuallyOpen()
    local app = hs.application.get("Citrix Viewer")
    if not app then return false end
    return app:mainWindow() ~= nil
    end

    -- If Citrix Viewer is running, focus it
    if citrixIsActuallyOpen() then
        local app = hs.application.get("Citrix Viewer")
        app:activate()
        hs.alert.show("Citrix Viewer", 0.5)
    else
        -- Load the login page, and hit the login button
        hs.alert.show("Logging in to work...", 0.5)
        hs.urlevent.openURL(LoginUrl)
        hs.timer.doAfter(5, function()
            hs.eventtap.keyStroke({}, "tab")
            hs.eventtap.keyStroke({}, "tab")
            hs.eventtap.keyStroke({}, "return")
        end)
    end
end)

-- Reload Hammerspoon config
hs.hotkey.bind({"cmd", "ctrl"}, "/", function()
    hs.execute("open -a 'Visual Studio Code' ~/.hammerspoon/init.lua", true)
    hs.alert.show("Reloading Hammerspoon config...", 0.5)
    -- Wait a second, then reload the config
    hs.timer.doAfter(1, function()
        hs.reload()
    end)
end)

-- Turn bluetooth off and on again, with a short delay in between
-- Note: Requires blueutil to be installed via homebrew, i.e. `brew install blueutil`
hs.hotkey.bind({"cmd", "ctrl"}, "'", function()
    hs.alert.show("Turning bluetooth off...", 0.5)
    hs.execute("/opt/homebrew/bin/blueutil --power 0", true)
    hs.timer.doAfter(0.5, function()
        hs.alert.show("Turning bluetooth on...", 0.5)
        hs.execute("/opt/homebrew/bin/blueutil --power 1", true)
    end)
end)

-- Bind cmd + slash to flash the active window
hs.hotkey.bind({"alt", "cmd"}, "/", function()
    FlashActiveWindowBorder()
end)

-- Bind cmd + alt + l to lock the screen
hs.hotkey.bind({"alt", "cmd"}, "l", function()
    hs.caffeinate.lockScreen()
end)



-- 03:40 Claude

local timer = require("hs.timer")
local application = require("hs.application")
local eventtap = require("hs.eventtap")

local function continueClaude()
    local app = application.find("Claude")

    if app then
        app:activate()

        -- Give macOS a moment to switch focus
        timer.doAfter(0.5, function()
            eventtap.keyStrokes("Continue")
            eventtap.keyStroke({}, "return")
        end)
    else
        hs.alert.show("Claude not running")
    end
end

-- Check once per minute
timer.doEvery(60, function()
    local now = os.date("*t")

    if now.hour == 3 and now.min == 40 then
        continueClaude()
    end
end)


-- Ctrl + Option + Cmd + S
-- Take screenshot of the connected iPhone in Xcode,
-- return to previous app,
-- then copy the resulting PNG image to the clipboard.

local screenshotDir = os.getenv("HOME") .. "/Desktop"

local screenshotWatcher = nil
local screenshotStartedAt = nil
local screenshotCopied = false

local function copyScreenshotToClipboard(path)
    -- Give Xcode a tiny moment to finish writing the PNG.
    hs.timer.doAfter(0.15, function()

        local image = hs.image.imageFromPath(path)

        if not image then
            print("Could not load screenshot:", path)
            return
        end

        local success = hs.pasteboard.writeObjects(image)

        if success then
            screenshotCopied = true
            hs.alert.show("📋 Screenshot copied", 0.6)
            print("Screenshot copied to clipboard:", path)
        else
            hs.alert.show("❌ Clipboard copy failed", 1)
            print("Failed to copy screenshot:", path)
        end
    end)
end


local function startScreenshotWatcher()
    screenshotStartedAt = hs.timer.secondsSinceEpoch()
    screenshotCopied = false

    -- Stop any previous watcher.
    if screenshotWatcher then
        screenshotWatcher:stop()
        screenshotWatcher = nil
    end

    screenshotWatcher = hs.pathwatcher.new(
        screenshotDir,
        function(paths)

            if screenshotCopied then
                return
            end

            for _, path in ipairs(paths) do

                -- Only consider PNG files.
                if path:lower():match("%.png$") then

                    local attrs = hs.fs.attributes(path)

                    if attrs then
                        local modified = attrs.modification or 0

                        -- Only accept a file created/modified after
                        -- we initiated this screenshot.
                        if modified >= screenshotStartedAt - 1 then

                            copyScreenshotToClipboard(path)

                            -- We only want one screenshot.
                            if screenshotWatcher then
                                screenshotWatcher:stop()
                                screenshotWatcher = nil
                            end

                            return
                        end
                    end
                end
            end
        end
    )

    screenshotWatcher:start()

    -- Safety timeout: don't leave the watcher running forever.
    hs.timer.doAfter(10, function()
        if screenshotWatcher then
            screenshotWatcher:stop()
            screenshotWatcher = nil
        end
    end)
end


hs.hotkey.bind({"ctrl", "alt", "cmd"}, "s", function()

    local previousApp = hs.application.frontmostApplication()
    local xcode = hs.application.get("Xcode")

    if not xcode then
        hs.alert.show("❌ Xcode not running")
        return
    end

    -- Start watching BEFORE asking Xcode to create the screenshot.
    startScreenshotWatcher()

    xcode:activate()

    hs.timer.doAfter(0.2, function()

        local success = xcode:selectMenuItem(
            "^Take Screenshot of .+$",
            true
        )

        if not success then
            hs.alert.show("❌ Screenshot command not found", 1)

            if screenshotWatcher then
                screenshotWatcher:stop()
                screenshotWatcher = nil
            end
        end

        -- Return to whatever you were doing.
        hs.timer.doAfter(0.15, function()
            if previousApp and previousApp:isRunning() then
                previousApp:activate()
            end
        end)

    end)

end)


local expansions = require("text-expansions")

local buffer = ""
local maxBufferLength = 100
local isExpanding = false

-- IMPORTANT: global reference so Hammerspoon doesn't garbage-collect it
textExpander = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown },
    function(event)

        -- Ignore events generated by our own expansion
        if isExpanding then
            return false
        end

        local flags = event:getFlags()

        -- Ignore keyboard shortcuts
        if flags.cmd or flags.ctrl or flags.alt then
            buffer = ""
            return false
        end

        local keyCode = event:getKeyCode()
        local key = hs.keycodes.map[keyCode]
        local chars = event:getCharacters()

        --------------------------------------------------
        -- Backspace
        --------------------------------------------------

        if key == "delete" then
            buffer = buffer:sub(1, -2)
            return false
        end

        --------------------------------------------------
        -- Navigation keys reset our typing buffer
        --------------------------------------------------

        if key == "escape"
            or key == "left"
            or key == "right"
            or key == "up"
            or key == "down"
        then
            buffer = ""
            return false
        end

        --------------------------------------------------
        -- Space / Enter / Tab triggers expansion
        --------------------------------------------------

        if key == "space" or key == "return" or key == "tab" then

            for trigger, replacement in pairs(expansions) do

                if buffer:sub(-#trigger) == trigger then

                    local output

                    if type(replacement) == "function" then
                        output = replacement()
                    else
                        output = replacement
                    end

                    isExpanding = true

                    -- Consume the terminating key, then do the replacement
                    hs.timer.doAfter(0.01, function()

                        -- Remove the typed trigger
                        for _ = 1, #trigger do
                            hs.eventtap.keyStroke({}, "delete", 0)
                        end

                        -- Type expansion
                        hs.eventtap.keyStrokes(output)

                        -- Restore the terminating key
                        if key == "space" then
                            hs.eventtap.keyStroke({}, "space", 0)
                        elseif key == "return" then
                            hs.eventtap.keyStroke({}, "return", 0)
                        elseif key == "tab" then
                            hs.eventtap.keyStroke({}, "tab", 0)
                        end

                        buffer = ""

                        hs.timer.doAfter(0.05, function()
                            isExpanding = false
                        end)
                    end)

                    -- Block the original Space/Return/Tab
                    return true
                end
            end

            buffer = ""
            return false
        end

        --------------------------------------------------
        -- Ordinary typing
        --------------------------------------------------

        if chars and chars ~= "" then
            buffer = (buffer .. chars):sub(-maxBufferLength)
        end

        return false
    end
)

textExpander:start()

hs.alert.show("Text expander loaded")