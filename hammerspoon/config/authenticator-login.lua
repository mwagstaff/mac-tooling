-- Ctrl-Cmd-Shift-A: capture the mapped Authenticator account; press again/Escape to cancel.
local M = {}
local root = os.getenv("HOME") .. "/dev/mac-tooling/"
local active
local escape

local function json(value)
    if value == nil then return "null" end
    if type(value) == "table" then return hs.json.encode(value) end
    -- Hammerspoon's encoder accepts containers only, not scalar strings.
    return hs.json.encode({value}):sub(2, -2)
end

local function finish(message)
    local session = active
    active = nil
    if session then
        for _, name in ipairs({"timeout", "watcher"}) do
            if session[name] then session[name]:stop() end
        end
        for _, name in ipairs({"browser", "camera"}) do
            if session[name] and session[name]:isRunning() then session[name]:terminate() end
        end
    end
    if escape then escape:disable() end
    if message then hs.alert.show(message, 4) end
end

local function chromeFrontmost()
    local app = hs.application.frontmostApplication()
    return app and app:bundleID() == "com.google.Chrome"
end

-- Send scripts on stdin: neither scripts nor tokens enter shell history/process arguments.
local function chrome(session, javascript, callback)
    local script = [[
        (function () {
            var chrome = Application('Google Chrome');
            if (!chrome.running() || !chrome.frontmost()) throw Error('Chrome is not active');
            var win = chrome.windows[0], tab = win.activeTab;
            var result = {window: String(win.id()), tab: String(tab.id()), url: tab.url()};
            var expected = EXPECTED;
            if (expected && (result.window !== expected.window || result.tab !== expected.tab || result.url !== expected.url))
                throw Error('Tab changed');
            var source = SOURCE;
            if (source) result.page = JSON.parse(tab.execute({javascript: source}));
            return JSON.stringify(result);
        })()
    ]]
    script = script:gsub("EXPECTED", function() return json(session.target) end)
        :gsub("SOURCE", function() return json(javascript) end)
    local task
    task = hs.task.new("/usr/bin/osascript", function(status, output)
        if active ~= session or session.browser ~= task then return end
        session.browser = nil
        local ok, result = pcall(hs.json.decode, output)
        if status ~= 0 or not ok or type(result) ~= "table" then
            finish("Chrome access failed. Check Automation permission and View > Developer > Allow JavaScript from Apple Events.")
            return
        end
        if result.page and not result.page.ok then finish(result.page.error); return end
        callback(result)
    end, {"-l", "JavaScript", "-"})
    session.browser = task
    task:setInput(script)
    if not task:start() then finish("Could not start Chrome capture helper.") end
end

local function pageScript(session, action, code)
    return session.source .. "\nJSON.stringify(authenticatorPage(" ..
        json(action) .. "," .. json(session.config) .. "," ..
        json(session.nonce) .. "," .. json(code) .. "))"
end

function M.start()
    if active then finish("Authenticator capture cancelled."); return end
    if not chromeFrontmost() then hs.alert.show("Focus Chrome's verification-code field first."); return end
    local file = io.open(root .. "authenticator-login/page.js", "r")
    if not file then hs.alert.show("Authenticator page helper is missing."); return end
    local source = file:read("*a")
    file:close()
    local ok, config = pcall(hs.json.read, root .. "authenticator-login/config.json")
    if not ok or type(config) ~= "table" then hs.alert.show("Invalid Authenticator configuration."); return end
    local session = {source = source, nonce = hs.host.uuid()}
    active = session
    escape:enable()
    session.timeout = hs.timer.doAfter(60, function() if active == session then finish("Authenticator capture timed out.") end end)
    session.watcher = hs.timer.doEvery(0.5, function()
        if active ~= session then return end
        if not chromeFrontmost() then finish("Chrome lost focus. Capture cancelled."); return end
        if session.camera and not session.browser then chrome(session, pageScript(session, "check"), function() end) end
    end)
    chrome(session, nil, function(target)
        local parts = hs.http.urlParts(target.url)
        session.config = parts and parts.scheme == "https" and config[parts.host] or nil
        if not session.config then finish("No Authenticator account configured for this website."); return end
        session.target = target
        chrome(session, pageScript(session, "prepare"), function()
            hs.alert.show("Hold up Authenticator: " .. session.config.account, 3)
            session.camera = hs.task.new(root .. "camera-otp/camera-otp.sh", function(status, output)
                if active ~= session then return end
                session.camera = nil
                local code = output:match("^([0-9][0-9][0-9][0-9][0-9][0-9])%s*$")
                if status ~= 0 or not code then finish("No matching code captured. Check camera permission and show the full account label."); return end
                if not chromeFrontmost() then finish("Chrome lost focus. Capture cancelled."); return end
                -- A check may be finishing; its callback is harmless. Do not overlap scripts.
                if session.browser then session.browser:terminate(); session.browser = nil end
                chrome(session, pageScript(session, "submit", code), function()
                    finish("Authenticator code submitted.")
                end)
            end, {"--account", session.config.account})
            if not session.camera:start() then finish("Could not start the camera reader.") end
        end)
    end)
end

escape = hs.hotkey.new({}, "escape", function() finish("Authenticator capture cancelled.") end)
M.hotkey = hs.hotkey.bind({"ctrl", "cmd", "shift"}, "a", M.start)
M.cancel = finish
return M
