--- === BatteryGraph ===
--- A battery usage history graph inset into the desktop

local canvas  = require("hs.canvas")
local battery = require("hs.battery")
local json    = require("hs.json")
local timer   = require("hs.timer")

local obj = {
    name      = "BatteryGraph",
    version   = "0.2",
    author    = "DoozyDak",
    homepage  = "https://github.com/DoozyDak/BatteryGraph.spoon"
}

obj.position          = { x = 20, y = 300 }
obj.rightMargin       = nil
obj.windowLevel       = nil
obj.width             = 280
obj.height            = 180
obj.backgroundColor   = { alpha = 0.3, white = 0 }
obj.backgroundBorder  = { alpha = 0.5 }
obj.cornerRadius      = 8
obj.lineColor         = { red = 0.2, green = 0.7, blue = 1, alpha = 0.85 }
obj.fillColor         = { red = 0.2, green = 0.7, blue = 1, alpha = 0.15 }
obj.gridColor         = { white = 1, alpha = 0.12 }
obj.textColor         = { white = 1, alpha = 0.6 }
obj.fontSize          = 10
obj.pollInterval      = 60
obj.maxHours          = 24
obj.demoData          = false

obj.__timer        = nil
obj.canvas         = nil
obj.__data         = {}
obj.__mutex        = false
obj.__clearPending = false
obj.__clearTimer   = nil

local margin = { top = 18, right = 36, bottom = 24, left = 34 }

local function dataPath()
    return obj.spoonPath .. "data.json"
end

local function loadData()
    local f = io.open(dataPath(), "r")
    if f then
        local ok, d = pcall(json.decode, f:read("*a"))
        f:close()
        if ok and type(d) == "table" then obj.__data = d end
    end
end

local function saveData()
    local f = io.open(dataPath(), "w")
    if f then
        f:write(json.encode(obj.__data))
        f:close()
    end
end

local function trimData()
    local cutoff = os.time() - obj.maxHours * 3600
    local out = {}
    for _, e in ipairs(obj.__data) do
        if e.t >= cutoff then table.insert(out, e) end
    end
    obj.__data = out
end

local function record()
    if obj.__mutex then return end
    obj.__mutex = true
    local pct = battery.percentage()
    if pct > 1 then pct = pct / 100 end
    pct = math.floor(pct * 100 + 0.5) / 100
    table.insert(obj.__data, { t = os.time(), p = pct })
    trimData()
    saveData()
    obj.__mutex = false
end

local function chartW() return obj.width - margin.left - margin.right end
local function chartH() return obj.height - margin.top - margin.bottom end

local function buildCanvas()
    obj.canvas = obj.canvas or canvas.new({ x = 0, y = 0, w = obj.width, h = obj.height })
    local lvl = obj.windowLevel or "desktopIcon"
    if type(lvl) == "string" then
        obj.canvas:level(canvas.windowLevels[lvl])
    else
        obj.canvas:level(lvl)
    end
    obj.canvas:behavior(canvas.windowBehaviors.canJoinAllSpaces)

    obj.canvas[1] = {
        type = "rectangle",
        action = "fill",
        fillColor = obj.backgroundColor,
        roundedRectRadii = { xRadius = obj.cornerRadius, yRadius = obj.cornerRadius },
        frame = { x = 0, y = 0, w = "100%", h = "100%" },
    }

    obj.canvas:mouseCallback(function(_, _, id)
        if id == "clearButton" then
            if obj.__clearPending then
                obj.__clearPending = false
                if obj.__clearTimer then obj.__clearTimer:stop(); obj.__clearTimer = nil end
                obj:clearData()
            else
                obj.__clearPending = true
                obj.__clearTimer = timer.doAfter(2, function()
                    obj.__clearPending = false
                    obj.__clearTimer = nil
                end)
            end
        end
    end)
    local xpos = obj.rightMargin and (hs.screen.mainScreen():fullFrame().w - obj.width - obj.rightMargin) or obj.position.x
    obj.canvas:frame({ x = xpos, y = obj.position.y, w = obj.width, h = obj.height })
    obj.canvas:show()
end

local function normalizeP(p)
    if not p then return 0 end
    if p > 1 then return p / 100 end
    return p
end

local function render()
    if not obj.canvas then buildCanvas() end

    local data = obj.__data
    local n = #data
    if n >= 2 then
        local curPct = math.floor(normalizeP(data[n].p) * 100 + 0.5)
        local maxPct = 0
        local maxIdx = 0
        for i, e in ipairs(data) do
            local p = math.floor(normalizeP(e.p) * 100 + 0.5)
            if p >= maxPct then
                maxPct = p
                maxIdx = i
            end
        end
        if curPct < maxPct then
            data = {}
            for i = maxIdx + 1, n do
                table.insert(data, obj.__data[i])
            end
            n = #data
        end
    end

    local cw, ch = chartW(), chartH()

    local pct = 0
    if n > 0 then pct = math.floor(normalizeP(data[n].p) * 100 + 0.5) end

    local elems = {}

    local function add(e) table.insert(elems, e) end

    if n < 2 then
        add {
            type = "text",
            text = n == 0 and "Collecting data…" or "Awaiting next data point (1 min)…",
            textFont = "Menlo",
            textSize = obj.fontSize,
            textColor = obj.textColor,
            frame = { x = margin.left, y = math.floor(obj.height / 2), w = 220, h = 24 },
        }
        add {
            id = "clearButton",
            type = "text",
            text = "×",
            textFont = "Menlo",
            textSize = 12,
            textColor = { white = 1, alpha = 0.3 },
            frame = { x = 4, y = obj.height - 16, w = 14, h = 14 },
            trackMouseUp = true,
        }
        while obj.canvas:elementCount() > 1 do
            obj.canvas:removeElement(obj.canvas:elementCount())
        end
        obj.canvas:appendElements(table.unpack(elems))
        local xpos = obj.rightMargin and (hs.screen.mainScreen():fullFrame().w - obj.width - obj.rightMargin) or obj.position.x
        obj.canvas:frame({ x = xpos, y = obj.position.y, w = obj.width, h = obj.height })
        obj.canvas:show()
        return
    end

    -- Y-axis grid lines (0%, 25%, 50%, 75%, 100%) with labels on 25–100%
    for i = 0, 4 do
        local y = margin.top + ch * (1 - i / 4)
        add {
            type = "segments",
            action = "stroke",
            strokeColor = obj.gridColor,
            strokeWidth = 0.5,
            coordinates = { { x = margin.left, y = y }, { x = margin.left + cw, y = y } },
            closed = false,
        }
        if i > 0 then
            add {
                type = "text",
                text = tostring(i * 25) .. "%",
                textFont = "Menlo",
                textSize = obj.fontSize,
                textColor = obj.textColor,
                frame = { x = 2, y = y - (obj.fontSize + 2) / 2, w = margin.left - 6, h = obj.fontSize + 2 },
                textAlignment = "right",
            }
        end
    end

    -- X-axis time labels
    local prevHour = -1
    for i = 0, 4 do
        local di = math.max(1, math.floor(1 + (n - 1) * i / 4))
        local t  = data[di].t
        local hh = os.date("%I", t)
        local mm = os.date("%M", t)
        local curHour = tonumber(hh)
        local ap = os.date("%p", t):lower():sub(1, 1)
        if curHour == 12 then ap = os.date("%p", t):lower():sub(1, 1) end
        local text
        if curHour ~= prevHour then
            text = ("%d:%s%s"):format(curHour, mm, ap)
            prevHour = curHour
        else
            text = mm
        end
        local cx = margin.left + cw * i / 4
        local labelW = 48
        local labelH = obj.fontSize + 4
        local frameX = cx - labelW / 2
        if frameX < 0 then frameX = 0 end
        if frameX + labelW > obj.width then frameX = obj.width - labelW end
        add {
            type = "text",
            text = text,
            textFont = "Menlo",
            textSize = obj.fontSize,
            textColor = obj.textColor,
            frame = { x = frameX, y = margin.top + ch + 2, w = labelW, h = labelH },
            textAlignment = "center",
        }
    end

    -- Build data curve coordinates
    local coords = {}
    for i, e in ipairs(data) do
        local x = margin.left + (i - 1) / (n - 1) * cw
        local y = margin.top + ch * (1 - normalizeP(e.p))
        table.insert(coords, { x = x, y = y })
    end

    -- Fill under curve
    local fillCoords = {}
    table.insert(fillCoords, { x = coords[1].x, y = margin.top + ch })
    for _, pt in ipairs(coords) do
        table.insert(fillCoords, { x = pt.x, y = pt.y })
    end
    table.insert(fillCoords, { x = coords[#coords].x, y = margin.top + ch })

    add {
        type = "segments",
        action = "fill",
        fillColor = obj.fillColor,
        coordinates = fillCoords,
        closed = true,
    }

    add {
        type = "segments",
        action = "stroke",
        strokeColor = obj.lineColor,
        strokeWidth = 2,
        coordinates = coords,
        closed = false,
    }

    -- Change markers: vertical line at every Nth change event (gain or drop)
    local totalChanges = 0
    local prev = -1
    for _, e in ipairs(data) do
        local p = math.floor(normalizeP(e.p) * 100 + 0.5)
        if prev ~= -1 and p ~= prev then totalChanges = totalChanges + 1 end
        prev = p
    end
    if totalChanges > 0 then
        local step = math.max(1, math.floor((totalChanges / 20) ^ 1.3))
        local changeIdx = 0
        local prevPct = -1
        for i, e in ipairs(data) do
            local curPct = math.floor(normalizeP(e.p) * 100 + 0.5)
            if prevPct ~= -1 and curPct ~= prevPct then
                changeIdx = changeIdx + 1
                if step == 1 or changeIdx % step == 1 then
                    local x = margin.left + (i - 1) / (n - 1) * cw
                    local y = margin.top + ch * (1 - normalizeP(e.p))
                    add {
                        type = "segments",
                        action = "stroke",
                        strokeColor = { white = 1, alpha = 0.2 },
                        strokeWidth = 0.5,
                        coordinates = { { x = x, y = margin.top + ch }, { x = x, y = y } },
                        closed = false,
                    }
                end
            end
            prevPct = curPct
        end
    end

    add {
        id = "clearButton",
        type = "text",
        text = "×",
        textFont = "Menlo",
        textSize = 12,
        textColor = { white = 1, alpha = 0.3 },
        frame = { x = 4, y = obj.height - 16, w = 14, h = 14 },
        trackMouseUp = true,
    }

    while obj.canvas:elementCount() > 1 do
        obj.canvas:removeElement(obj.canvas:elementCount())
    end
    obj.canvas:appendElements(table.unpack(elems))

    local xpos = obj.rightMargin and (hs.screen.mainScreen():fullFrame().w - obj.width - obj.rightMargin) or obj.position.x
    obj.canvas:frame({ x = xpos, y = obj.position.y, w = obj.width, h = obj.height })
    obj.canvas:show()
end

local function generateDemoData()
    local now = os.time()
    local data = {}
    local interval = 600
    local points = math.floor(obj.maxHours * 3600 / interval)
    for i = points, 0, -1 do
        local frac = i / points
        local base = 0.95 - frac * 0.75
        local p = base + math.sin(frac * math.pi * 6) * 0.02 + (math.random() - 0.5) * 0.01
        p = math.max(0.05, math.min(1, p))
        table.insert(data, { t = now - i * interval, p = p })
    end
    obj.__data = data
    saveData()
end

local function update()
    record()
    render()
end

--- BatteryGraph:start()
function obj:start()
    self = self or obj
    loadData()
    if obj.demoData then
        math.randomseed(os.time())
        generateDemoData()
    end
    buildCanvas()
    update()
    if obj.__timer then obj.__timer:stop() end
    obj.__timer = timer.doEvery(obj.pollInterval, update)
    return self
end

--- BatteryGraph:clearData()
--- Clears all recorded battery data and re-renders the graph
function obj:clearData()
    obj.__data = {}
    saveData()
    record()
    render()
    return self
end

--- BatteryGraph:stop()
function obj:stop()
    self = self or obj
    if obj.__timer then obj.__timer:stop(); obj.__timer = nil end
    if obj.canvas then obj.canvas:hide() end
    return self
end

return obj
