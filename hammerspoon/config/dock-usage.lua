-- Enabled per Mac via hs.settings. Dock geometry below is for a bottom Dock.
local providers = {
    codex = { bundle = "com.openai.codex", tint = {red=0.25, green=0.29, blue=0.63, alpha=0.56} },
    claude = { bundle = "com.anthropic.claudefordesktop", tint = {red=0.60, green=0.19, blue=0.07, alpha=0.56} },
}
local maxAge = 15 * 60
local function utc(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end

local function reading(window)
    if type(window) ~= "table" or window.isSyntheticPlaceholder then return end
    if window.resetsAt ~= nil and type(window.resetsAt) ~= "string" then return end
    local percent = window.usedPercent
    if type(percent) == "number" and percent >= 0 and percent <= 100 then
        return {percent=percent, reset=window.resetsAt}
    end
end

local function usageReadings(name, output)
    local rows = hs.json.decode(output)
    local row = type(rows) == "table" and rows[1]
    if not row or row.provider ~= name or row.error or not row.usage then return end
    local usage = row.usage
    if type(usage.updatedAt) ~= "string" then return end
    local week, session
    for _, slot in ipairs({"primary", "secondary"}) do
        local window = usage[slot]
        local minutes = type(window) == "table" and window.windowMinutes
        if minutes == 10080 then
            week = reading(window)
        elseif type(minutes) == "number" and minutes > 0 and minutes <= 1440 then
            session = reading(window)
        end
    end
    return usage.updatedAt, week, session
end

local signOutKey = "weeklyDockUsageClaudeSignOutNotified"

local function checkClaudeSignIn(p)
    local task = hs.task.new("/opt/homebrew/bin/claude", function(code, output)
        if p.timeout then p.timeout:stop(); p.timeout = nil end
        p.task = nil
        local status = hs.json.decode(output)
        if type(status) ~= "table" then return end
        if code == 0 and status.loggedIn == true then
            hs.settings.clear(signOutKey)
        elseif code == 1 and status.loggedIn == false and status.authMethod == "none"
            and not hs.settings.get(signOutKey) then
            hs.notify.new({
                title = "Claude CLI signed out",
                informativeText = "The usage badge is hidden. Run claude auth login in Terminal to restore it.",
                withdrawAfter = 0,
            }):send()
            hs.settings.set(signOutKey, true)
        end
    end, {"auth", "status"})
    p.task = task and task:start()
    if p.task then
        p.timeout = hs.timer.doAfter(10, function() task:terminate() end)
    end
end

local function fetch(name, p)
    if p.task then return end
    local task = hs.task.new("/opt/homebrew/bin/codexbar", function(code, output)
        if p.timeout then p.timeout:stop(); p.timeout = nil end
        p.task = nil
        p.week, p.session = nil, nil
        if code == 0 then
            p.updated, p.week, p.session = usageReadings(name, output)
        end
        if name == "claude" then
            if p.week or p.session then
                hs.settings.clear(signOutKey)
            else
                checkClaudeSignIn(p)
            end
        end
    end, {"usage", "--provider", name, "--source", "cli", "--json", "--no-credits"})
    if task then
        local env = task:environment()
        env.PATH = "/opt/homebrew/bin:" .. (env.PATH or "/usr/bin:/bin")
        task:setEnvironment(env)
        p.task = task:start()
    end
    if p.task then
        p.timeout = hs.timer.doAfter(180, function()
            p.week, p.session = nil, nil
            task:terminate()
        end)
    else
        p.week, p.session = nil, nil
    end
end

local function refresh()
    for name, p in pairs(providers) do fetch(name, p) end
end

local function draw(p, f, week, session, nativeBadge)
    local key = table.concat({f.x,f.y,f.w,f.h,tostring(week),tostring(session),tostring(nativeBadge)}, "/")
    if p.key == key then return end
    -- The AX frame includes padding and the running indicator below the icon.
    local size = f.w * 0.765
    local x, y = (f.w - size)/2, f.h - f.w
    local function box(left, top, width, height)
        return {x=x+size*left, y=y+size*top, w=size*width, h=size*height}
    end
    local function corners(r) return {xRadius=size*r,yRadius=size*r} end
    local elements = {
        {type="rectangle", action="clip", frame=box(0,0,1,1), roundedRectRadii=corners(0.23)},
    }
    if nativeBadge then
        -- Keep the real notification badge above even a completely full weekly tide.
        table.insert(elements,{type="segments", action="clip", closed=true, coordinates={
            {x=x,y=y},{x=x+size*0.59,y=y},{x=x+size*0.59,y=y+size*0.32},
            {x=x+size,y=y+size*0.32},{x=x+size,y=y+size},{x=x,y=y+size},
        }})
    end
    local ink = {red=p.tint.red*0.38, green=p.tint.green*0.38, blue=p.tint.blue*0.38, alpha=0.84}
    if week then
        local height = week / 100
        if height > 0 then
            table.insert(elements,{type="rectangle", action="fill", frame=box(0,1-height,1,height),
                fillGradient="linear", fillGradientAngle=90,
                fillGradientColors={p.tint,{white=1,alpha=0.22}}})
            table.insert(elements,{type="rectangle", action="fill", frame=box(0,1-height,1,math.min(height,0.015)),
                fillColor={white=1,alpha=0.62}})
        end
        local label = tostring(math.floor(week+0.5)) .. "%"
        local width = 0.105 + #label*0.124
        local pill = box(0.075,0.674,width,0.252)
        table.insert(elements,{type="rectangle",action="fill",frame=pill,
            roundedRectRadii=corners(0.126),fillColor=ink})
        table.insert(elements,{type="text",text=label,textAlignment="center",textFont="HelveticaNeue-Medium",
            textSize=size*0.208,textColor={white=1},frame=box(0.075,0.674,width,0.29)})
    end
    if session or (week and p.bundle == "com.openai.codex") then
        local center = {x=x+size*0.207,y=y+size*0.198}
        local bezel = size*0.123
        table.insert(elements,{type="circle",action="strokeAndFill",center=center,radius=bezel,
            fillColor=ink,strokeColor={white=1,alpha=0.85},strokeWidth=0.65})
        local radius = bezel - 1.15
        if not session then
            -- A dash distinguishes an unreported quota from a reported zero.
            table.insert(elements,{type="rectangle",action="fill",roundedRectRadii=corners(0.012),
                frame={x=center.x-radius*0.53,y=center.y-0.55,w=radius*1.06,h=1.1},fillColor={white=1}})
        elseif session == 100 then
            table.insert(elements,{type="circle",action="fill",center=center,radius=radius,fillColor={white=1}})
        elseif session > 0 then
            table.insert(elements,{type="arc",action="fill",center=center,radius=radius,
                startAngle=0,endAngle=session*3.6,arcRadii=true,fillColor={white=1}})
        end
    end
    if not p.canvas then
        p.canvas = hs.canvas.new(f):level(hs.canvas.windowLevels.dock+1)
            :behavior({"canJoinAllSpaces","stationary","ignoresCycle"})
    end
    p.canvas:frame(f):replaceElements(elements):show()
    p.key = key
end

local function layout()
    local dock = hs.application.get("com.apple.dock")
    local ax = dock and hs.axuielement.applicationElement(dock)
    local lists = ax and ax:childrenWithRole("AXList")
    local list = lists and lists[1]
    local screen = hs.screen.primaryScreen()
    local full, work = screen:fullFrame(), screen:frame()
    local bottom = work.y + work.h
    local now = os.time()
    for _, p in pairs(providers) do
        local shown = false
        local fresh = p.updated and p.updated >= utc(now-maxAge) and p.updated <= utc(now+60)
        local week = fresh and p.week and p.week.reset and p.week.reset > utc(now) and p.week.percent
        -- Claude's CLI can report a valid five-hour percentage without a reset timestamp.
        local session = fresh and p.session and (
            (p.session.reset and p.session.reset > utc(now))
            or (not p.session.reset and p.updated >= utc(now-360))
        ) and p.session.percent
        if list and (week or session)
            and full.y + full.h - bottom > 12 then
            if not p.tile or not p.tile:isValid() then
                local path = hs.application.pathForBundleID(p.bundle)
                for _, item in ipairs(list.AXChildren or {}) do
                    local url = item.AXURL
                    if url and url.filePath == path then p.tile = item; break end
                end
            end
            local f = p.tile and p.tile.AXFrame
            if f and f.w > 0 and math.abs(f.y-bottom) < 6 and f.h >= f.w then
                -- Hit-test the native tile, so hidden or covered Docks receive no overlay.
                local hit = hs.axuielement.systemElementAtPosition(f.x+f.w/2,f.y+f.h/2)
                if hit == p.tile then
                    local status = p.tile.AXStatusLabel
                    draw(p,f,week,session,status ~= nil and status ~= "")
                    shown = true
                end
            end
        end
        if not shown and p.canvas and p.key then p.canvas:hide(); p.key=nil end
    end
end

local timers = {
    hs.timer.doEvery(1,layout),
    hs.timer.doEvery(300,refresh),
    hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake then refresh() end
    end):start(),
}
refresh()
return {providers=providers, timers=timers}
