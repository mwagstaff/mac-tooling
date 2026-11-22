-- Place the whites over Finder's own eyes on the MacBook's bottom Dock.
local eyes = {{x=0.285, r=0.142}, {x=0.695, r=0.151}}
local canvas, frame, tile
local lastMouse
local function circle(color)
    return {type="circle", action="fill", fillColor=color}
end

local function look()
    if not frame then return end
    local mouse = hs.mouse.absolutePosition()
    if lastMouse and mouse.x == lastMouse.x and mouse.y == lastMouse.y then return end
    lastMouse = mouse
    local size = frame.w * 0.765
    for i, eye in ipairs(eyes) do
        local cx = (frame.w-size)/2 + size*eye.x
        local cy = frame.h-frame.w + size*0.365
        local dx, dy = mouse.x-frame.x-cx, mouse.y-frame.y-cy
        -- Track nearby points smoothly and keep the whole pupil inside the rim.
        local travel = size*(eye.r-0.071)
        local scale = travel / math.max(size*0.55, math.sqrt(dx*dx+dy*dy))
        local px, py = cx + dx*scale, cy + dy*scale
        local pupil = (i-1)*4+3
        canvas[pupil].center = {x=px,y=py}
        canvas[pupil+1].center = {x=px-size*0.018,y=py-size*0.020}
    end
end

local function layout()
    local screen = hs.screen.primaryScreen()
    local bottom = screen:frame().y + screen:frame().h
    if not tile or not tile:isValid() then
        local dock = hs.application.get("com.apple.dock")
        local ax = dock and hs.axuielement.applicationElement(dock)
        local lists = ax and ax:childrenWithRole("AXList")
        for _, item in ipairs(lists and lists[1] and lists[1].AXChildren or {}) do
            local url = item.AXURL
            if url and url.filePath == "/System/Library/CoreServices/Finder.app" then tile=item; break end
        end
    end
    local f = tile and tile.AXFrame
    local visible = f and f.w > 0 and f.h >= f.w and math.abs(f.y-bottom) < 6
        and screen:fullFrame().y + screen:fullFrame().h - bottom > 12
        and hs.axuielement.systemElementAtPosition(f.x+f.w/2,f.y+f.h/2) == tile
    if not visible then
        if frame then canvas:hide(); frame=nil end
        return
    end
    if frame and frame.x==f.x and frame.y==f.y and frame.w==f.w and frame.h==f.h then return end
    if not canvas then
        canvas = hs.canvas.new(f):level(hs.canvas.windowLevels.dock+1)
            :behavior({"canJoinAllSpaces","stationary","ignoresCycle"})
    end
    local size = f.w*0.765
    local elements = {}
    for _, eye in ipairs(eyes) do
        local cx, cy = (f.w-size)/2 + size*eye.x, f.h-f.w + size*0.365
        local shadow = circle({white=0,alpha=0.27})
        shadow.center, shadow.radius = {x=cx,y=cy+size*0.017}, size*eye.r+0.4
        local white = circle({white=1})
        white.center, white.radius = {x=cx,y=cy}, size*eye.r
        local pupil = circle({white=0.065})
        pupil.center, pupil.radius = white.center, size*0.061
        local glint = circle({white=1,alpha=0.93})
        glint.center, glint.radius = white.center, size*0.016
        for _, element in ipairs({shadow,white,pupil,glint}) do table.insert(elements,element) end
    end
    canvas:frame(f):replaceElements(elements)
    frame, lastMouse = f, nil
    look()
    canvas:show()
end

-- Coalesce high-frequency mouse events; stationary eyes need no animation timer.
local repaint = hs.timer.delayed.new(1/60, look)
local event = hs.eventtap.event.types
local mouseWatcher = hs.eventtap.new({
    event.mouseMoved, event.leftMouseDragged, event.rightMouseDragged, event.otherMouseDragged,
}, function()
    if frame and not repaint:running() then repaint:start() end
    return false
end):start()
layout()
return {mouse=mouseWatcher, repaint=repaint, geometry=hs.timer.doEvery(1,layout)}
