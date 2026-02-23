---@diagnostic disable: undefined-global

-- Requires

require "secrets"

-- Helper functions

function BindAppShortcut(keyStroke, appName)
    hs.hotkey.bind({"ctrl", "cmd"}, keyStroke, function()
        hs.application.launchOrFocus(appName)
        hs.alert.show(appName, 0.5)
    end)
end

function BindAltShortcut(keyStroke, appName)
    hs.hotkey.bind({"ctrl", "option"}, keyStroke, function()
        hs.application.launchOrFocus(appName)
        hs.alert.show(appName, 0.5)
    end)
end

function BindCommandShortcut(keyStroke, command)
    hs.hotkey.bind({"ctrl", "cmd"}, keyStroke, function()
        os.execute(command)
        hs.alert.show(command, 0.5)
    end)
end

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
BindAppShortcut("e", "Telegram")
BindAppShortcut("f", "Finder")
BindAppShortcut("g", "Google Chrome")
BindAppShortcut("y", "Quickgif")
BindAppShortcut("h", "Photos")
BindAppShortcut("i", "iTerm")
BindAppShortcut("m", "iPhone Mirroring")
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
BindAppShortcut("z", "Zoom")

-- App shortcuts: Ctrl-Option

BindAltShortcut("c", "ChatGPT")
BindAltShortcut("o", "Microsoft Outlook")
BindAltShortcut("s", "Simulator")

-- Command shortcuts

BindCommandShortcut("d", "open ~/Downloads")

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

-- Turn bluetooth off and on again, with a 5 second delay in between
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