-- Run through Hammerspoon's Lua runtime; all browser/camera tasks are simulated.
local realHS = hs
local root = os.getenv("HOME") .. "/dev/mac-tooling/"
local count = 0
local function setup()
    local tasks, alerts, timers = {}, {}, {}
    local frontmost = true
    local function timer(callback)
        local value = {callback = callback, stop = function() end}
        table.insert(timers, value)
        return value
    end
    local fake = {
        json = realHS.json, http = realHS.http, host = {uuid = function() return "test-session" end},
        alert = {show = function(message) table.insert(alerts, message) end},
        application = {frontmostApplication = function()
            return {bundleID = function() return frontmost and "com.google.Chrome" or "other.app" end}
        end},
        timer = {doAfter = function(_, callback) return timer(callback) end, doEvery = function(_, callback) return timer(callback) end},
        hotkey = {new = function() return {enable = function() end, disable = function() end} end,
            bind = function() return {} end},
        task = {new = function(path, callback, arguments)
            local task = {path = path, callback = callback, arguments = arguments, running = false}
            function task:setInput(input) self.input = input end
            function task:start() self.running = true; return true end
            function task:terminate() self.running = false end
            function task:isRunning() return self.running end
            function task:complete(status, result)
                self.running = false
                self.callback(status, type(result) == "table" and realHS.json.encode(result) or result)
            end
            table.insert(tasks, task)
            return task
        end}
    }
    local env = setmetatable({hs = fake}, {__index = _G})
    local module = assert(loadfile(root .. "hammerspoon/config/authenticator-login.lua", "t", env))()
    local target = {window = "1", tab = "2", url = "https://dash.cloudflare.com/two-factor"}
    local function ready()
        module.start()
        tasks[1]:complete(0, target)
        tasks[2]:complete(0, {page = {ok = true}})
        assert(tasks[3].path:match("camera%-otp.sh$"))
        assert(tasks[3].arguments[1] == "--account")
        assert(tasks[3].arguments[2] == "Cloudflare: mike.wagstaff@gmail.com")
    end
    return module, tasks, alerts, timers, ready, function() frontmost = false end
end
local function check(name, run)
    run()
    count = count + 1
end
check("complete flow", function()
    local m, tasks, alerts, _, ready = setup(); ready()
    tasks[3]:complete(0, "012345\n")
    assert(tasks[4].input:find("012345", 1, true))
    assert(not table.concat(tasks[4].arguments):find("012345", 1, true))
    tasks[4]:complete(0, {page = {ok = true}})
    assert(alerts[#alerts] == "Authenticator code submitted.")
end)
check("unknown host", function()
    local m, tasks, alerts = setup(); m.start()
    tasks[1]:complete(0, {url = "https://dash.cloudflare.com.attacker.example/two-factor"})
    assert(#tasks == 1 and alerts[#alerts]:find("No Authenticator"))
end)
check("HTTP rejected", function()
    local m, tasks, alerts = setup(); m.start()
    tasks[1]:complete(0, {url = "http://dash.cloudflare.com/two-factor"})
    assert(#tasks == 1 and alerts[#alerts]:find("No Authenticator"))
end)
check("second shortcut cancels and ignores late result", function()
    local m, tasks, alerts, _, ready = setup(); ready(); m.start()
    tasks[3]:complete(0, "012345\n")
    assert(#tasks == 3 and alerts[#alerts]:find("cancelled"))
end)
check("lost Chrome focus", function()
    local m, tasks, alerts, timers, ready, blur = setup(); ready(); blur(); timers[2].callback()
    assert(not tasks[3].running and alerts[#alerts]:find("lost focus"))
end)
check("invalid camera result", function()
    local m, tasks, alerts, _, ready = setup(); ready(); tasks[3]:complete(0, "12345\n")
    assert(#tasks == 3 and alerts[#alerts]:find("No matching code"))
end)
check("poll failure cancels camera", function()
    local m, tasks, alerts, timers, ready = setup(); ready(); timers[2].callback()
    tasks[4]:complete(0, {page = {ok = false, error = "Focus changed"}})
    assert(not tasks[3].running and alerts[#alerts] == "Focus changed")
end)
check("late cancelled poll cannot cancel submission", function()
    local m, tasks, alerts, timers, ready = setup(); ready(); timers[2].callback()
    tasks[3]:complete(0, "012345\n")
    tasks[4]:complete(15, "")
    assert(tasks[5].running)
    tasks[5]:complete(0, {page = {ok = true}})
    assert(alerts[#alerts] == "Authenticator code submitted.")
end)
check("camera test works outside Chrome and ignores captured output", function()
    local m, tasks, alerts, timers, _, blur = setup(); blur(); m.testCamera()
    assert(#tasks == 1 and tasks[1].arguments[1] == "--preview")
    assert(#timers == 1)
    tasks[1]:complete(0, "012345\n")
    assert(#tasks == 1 and not alerts[#alerts]:find("submitted"))
end)
check("camera test shortcut toggles off", function()
    local m, tasks = setup(); m.testCamera(); m.testCamera()
    assert(#tasks == 1 and not tasks[1].running)
end)
check("camera test timeout stops capture", function()
    local m, tasks, _, timers = setup(); m.testCamera(); timers[1].callback()
    assert(not tasks[1].running)
end)
print(count .. " controller checks passed")
