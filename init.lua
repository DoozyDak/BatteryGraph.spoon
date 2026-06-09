--- === BatteryGraph ===
--- A battery usage history graph inset into the desktop

local canvas  = require("hs.canvas")
local battery = require("hs.battery")
local json    = require("hs.json")
local timer   = require("hs.timer")
local webview = require("hs.webview")
local hotkey  = require("hs.hotkey")

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
obj.demoData          = false  -- @deprecated: no longer maintained; may be removed in future versions
obj.trimToDischarge   = true
obj.gapMinutes        = 30

obj.__timer        = nil
obj.canvas         = nil
obj.__data         = {}
obj.__mutex        = false
obj.__clearPending = false
obj.__clearTimer   = nil
obj.__tooltipIdx   = nil
obj.__cursorIdx    = nil
obj.__gapMode      = nil
obj.__historyWebview = nil
obj.__historyCloseCanvas = nil
obj.__panLeftHotkey = nil
obj.__panRightHotkey = nil

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

local function normalizeP(p)
    if not p then return 0 end
    if p > 1 then return p / 100 end
    return p
end

local function getDisplayData()
    local data = obj.__data
    if not obj.trimToDischarge or #data < 2 then return data end
    local n = #data
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
        local out = {}
        for i = maxIdx + 1, n do
            table.insert(out, data[i])
        end
        return out
    end
    return data
end

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

    obj.canvas:mouseCallback(function(_, message, id, ...)
        if id == "clearButton" then
            if message == "mouseUp" then
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
        elseif id == "hoverArea" then
            local function showGapInfo(g)
                local function fmtTime(t)
                    local hh = tonumber(os.date("%I", t))
                    local mm = os.date("%M", t)
                    local ap = os.date("%p", t):lower():sub(1, 1)
                    return ("%d:%s%s"):format(hh, mm, ap)
                end
                local prePct = math.floor(normalizeP(g.pre.p) * 100 + 0.5)
                local postPct = math.floor(normalizeP(g.post.p) * 100 + 0.5)
                local txt = ("%s %d%%  →  %s %d%%"):format(fmtTime(g.pre.t), prePct, fmtTime(g.post.t), postPct)
                local tw = 180
                local tx = math.max(0, math.min(obj.width - tw, g.x - tw / 2))
                if obj.__tooltipIdx and obj.canvas:elementCount() >= obj.__tooltipIdx then
                    local el = obj.canvas[obj.__tooltipIdx]
                    el.text = txt
                    el.textColor = { white = 1, alpha = 0.95 }
                    el.frame = { x = tx, y = 2, w = tw, h = obj.fontSize + 4 }
                end
                if obj.__cursorIdx and obj.canvas:elementCount() >= obj.__cursorIdx then
                    local cl = obj.canvas[obj.__cursorIdx]
                    local hCh = obj.height - margin.top - margin.bottom
                    cl.coordinates = { { x = g.x, y = margin.top }, { x = g.x, y = margin.top + hCh } }
                    cl.strokeColor = { white = 1, alpha = 0.3 }
                end
            end

            if message == "mouseUp" then
                local x = select(1, ...)
                local gapThreshold = 4
                obj.__gapMode = nil
                if obj.__gapInfo then
                    for _, g in ipairs(obj.__gapInfo) do
                        if math.abs(x - g.x) <= gapThreshold then
                            obj.__gapMode = g
                            showGapInfo(g)
                            break
                        end
                    end
                end
            elseif message == "mouseMove" then
                local x = select(1, ...)
                local gapThreshold = 4

                if obj.__gapMode and math.abs(x - obj.__gapMode.x) <= gapThreshold then
                    showGapInfo(obj.__gapMode)
                    return
                end
                obj.__gapMode = nil

                local hData = getDisplayData()
                local hn = #hData
                if hn < 2 then return end
                local hCw = obj.width - margin.left - margin.right
                local relX = x - margin.left
                local idx = math.max(1, math.min(hn, math.floor(relX / hCw * (hn - 1)) + 1))
                local e = hData[idx]
                if e then
                    local hh = tonumber(os.date("%I", e.t))
                    local mm = os.date("%M", e.t)
                    local ap = os.date("%p", e.t):lower():sub(1, 1)
                    local pct = math.floor(normalizeP(e.p) * 100 + 0.5)
                    local txt = ("%d:%s%s  %d%%"):format(hh, mm, ap, pct)
                    local cx = margin.left + (idx - 1) / (hn - 1) * hCw
                    local tw = 130
                    local tx = cx - tw / 2
                    if tx < 0 then tx = 0 end
                    if tx + tw > obj.width then tx = obj.width - tw end
                    if obj.__tooltipIdx and obj.canvas:elementCount() >= obj.__tooltipIdx then
                        local el = obj.canvas[obj.__tooltipIdx]
                        el.text = txt
                        el.textColor = { white = 1, alpha = 0.95 }
                        el.frame = { x = tx, y = 2, w = tw, h = obj.fontSize + 4 }
                    end
                    if obj.__cursorIdx and obj.canvas:elementCount() >= obj.__cursorIdx then
                        local cl = obj.canvas[obj.__cursorIdx]
                        local hCh = obj.height - margin.top - margin.bottom
                        cl.coordinates = { { x = cx, y = margin.top }, { x = cx, y = margin.top + hCh } }
                        cl.strokeColor = { white = 1, alpha = 0.3 }
                    end
                end
            elseif message == "mouseExit" then
                obj.__gapMode = nil
                if obj.__tooltipIdx and obj.canvas:elementCount() >= obj.__tooltipIdx then
                    local el = obj.canvas[obj.__tooltipIdx]
                    el.text = ""
                    el.textColor = { white = 1, alpha = 0 }
                end
                if obj.__cursorIdx and obj.canvas:elementCount() >= obj.__cursorIdx then
                    local cl = obj.canvas[obj.__cursorIdx]
                    cl.coordinates = { { x = 0, y = 0 }, { x = 0, y = 0 } }
                    cl.strokeColor = { white = 1, alpha = 0 }
                end
            end
        end
    end)
    local xpos = obj.rightMargin and (hs.screen.mainScreen():fullFrame().w - obj.width - obj.rightMargin) or obj.position.x
    obj.canvas:frame({ x = xpos, y = obj.position.y, w = obj.width, h = obj.height })
    obj.canvas:show()
end

local function render()
    if not obj.canvas then buildCanvas() end

    local data = getDisplayData()
    local n = #data

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

    -- Build continuous data curve (no gaps in the line, but gaps detected for markers)
    local gapSeconds = obj.gapMinutes * 60
    local coords = {}
    local gapMarkers = {}
    local gapBoundaries = {}
    for i, e in ipairs(data) do
        local x = margin.left + (i - 1) / (n - 1) * cw
        local y = margin.top + ch * (1 - normalizeP(e.p))
        if #coords > 0 then
            local gap = e.t - data[i - 1].t
            if gap > gapSeconds then
                local last = coords[#coords]
                table.insert(gapMarkers, { x = last.x, y = last.y })
                table.insert(gapBoundaries, { preIdx = i - 1, postIdx = i })
            end
        end
        table.insert(coords, { x = x, y = y })
    end

    -- Merge adjacent gaps (consecutive boundaries with no non-gap point between)
    if #gapBoundaries > 1 then
        local mergedMarkers = {}
        local mergedBoundaries = {}
        local i = 1
        while i <= #gapBoundaries do
            local startIdx = i
            while i < #gapBoundaries and gapBoundaries[i].postIdx == gapBoundaries[i + 1].preIdx do
                i = i + 1
            end
            table.insert(mergedMarkers, gapMarkers[startIdx])
            table.insert(mergedBoundaries, { preIdx = gapBoundaries[startIdx].preIdx, postIdx = gapBoundaries[i].postIdx })
            i = i + 1
        end
        gapMarkers = mergedMarkers
        gapBoundaries = mergedBoundaries
    end

    -- Draw continuous curve
    if #coords >= 2 then
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
    end

    -- Draw gap markers (red vertical lines at gap boundaries)
    local gapColor = { red = 1, green = 0.3, blue = 0.3, alpha = 0.5 }
    for _, m in ipairs(gapMarkers) do
        add {
            type = "segments",
            action = "stroke",
            strokeColor = gapColor,
            strokeWidth = 1.5,
            coordinates = { { x = m.x, y = margin.top + ch }, { x = m.x, y = m.y } },
            closed = false,
        }
    end
    obj.__gapInfo = nil
    if #gapMarkers > 0 then
        obj.__gapInfo = {}
        for i, boundary in ipairs(gapBoundaries) do
            table.insert(obj.__gapInfo, {
                x = gapMarkers[i].x,
                pre = data[boundary.preIdx],
                post = data[boundary.postIdx],
            })
        end
    end

    -- X-axis labels: first + last, fill to ~5 with evenly spaced midpoints
    local labelIdxs = { 1, n }
    local minFillDist = math.max(2, math.floor(n / 20))
    while #labelIdxs < 5 do
        local maxGap = 0
        local insertAt = 0
        for i = 1, #labelIdxs - 1 do
            local gap = labelIdxs[i + 1] - labelIdxs[i]
            if gap > maxGap and gap >= minFillDist * 2 then
                maxGap = gap
                insertAt = i
            end
        end
        if insertAt == 0 then break end
        local mid = math.floor((labelIdxs[insertAt] + labelIdxs[insertAt + 1]) / 2)
        table.insert(labelIdxs, insertAt + 1, mid)
    end
    local prevHour = -1
    for _, idx in ipairs(labelIdxs) do
        local t = data[idx].t
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
        local cx = margin.left + (idx - 1) / (n - 1) * cw
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
    add {
        id = "hoverArea",
        type = "rectangle",
        action = "fill",
        fillColor = { alpha = 0.01 },
        frame = { x = margin.left, y = margin.top, w = cw, h = ch },
        trackMouseUp = true,
        trackMouseMove = true,
        trackMouseEnterExit = true,
    }
    while obj.canvas:elementCount() > 1 do
        obj.canvas:removeElement(obj.canvas:elementCount())
    end
    obj.canvas:appendElements(table.unpack(elems))
    obj.canvas:appendElements({
        id = "tooltip",
        type = "text",
        text = "",
        textFont = "Menlo",
        textSize = obj.fontSize,
        textColor = { white = 1, alpha = 0 },
        frame = { x = 0, y = 2, w = obj.width, h = obj.fontSize + 4 },
        textAlignment = "center",
    })
    obj.__tooltipIdx = obj.canvas:elementCount()
    obj.canvas:appendElements({
        id = "cursorLine",
        type = "segments",
        action = "stroke",
        strokeColor = { white = 1, alpha = 0 },
        strokeWidth = 0.5,
        closed = false,
        coordinates = { { x = 0, y = 0 }, { x = 0, y = 0 } },
    })
    obj.__cursorIdx = obj.canvas:elementCount()

    local xpos = obj.rightMargin and (hs.screen.mainScreen():fullFrame().w - obj.width - obj.rightMargin) or obj.position.x
    obj.canvas:frame({ x = xpos, y = obj.position.y, w = obj.width, h = obj.height })
    obj.canvas:show()
end

local function generateDemoData()  -- @deprecated
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

local function buildHistoryHTML(data)
    local jsonData = json.encode(data)
    return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>BatteryGraph — Full History</title>
 <style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#1a1a1a;color:#ccc;font-family:-apple-system,BlinkMacSystemFont,sans-serif;overflow:hidden;width:100vw;height:100vh;-webkit-user-select:none;user-select:none;touch-action:none}
#wrap{width:100%;height:100%;padding:16px}
#help{position:fixed;bottom:6px;left:50%;transform:translateX(-50%);color:#444;font-size:10px;z-index:100;pointer-events:none;white-space:nowrap}
</style>
</head>
<body>
<div id="wrap"><canvas id="chart"></canvas></div>
<div id="help">scroll/pinch to zoom · arrow keys to pan · shift+drag to zoom area</div>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2.2.0/dist/chartjs-plugin-zoom.min.js"></script>
<script>
var raw=]] .. jsonData .. [[;
var pts=raw.map(function(d){return{x:d.t*1000,y:Math.round(d.p*100)}});
if(pts.length===0){
  document.getElementById('chart').remove();
  document.getElementById('wrap').textContent='No data available.';
  document.getElementById('wrap').style.cssText='display:flex;align-items:center;justify-content:center;height:100%;font-size:16px;color:#666';
  }else{
    try{Chart.register(ChartZoom)}catch(e){}
  try{
  var lo=pts[0].x,hi=pts[pts.length-1].x;
  window.chart=new Chart(document.getElementById('chart'),{
    type:'line',
    data:{datasets:[{label:'Battery %',data:pts,borderColor:'rgba(51,179,255,0.85)',backgroundColor:'rgba(51,179,255,0.15)',fill:true,pointRadius:0,pointHitRadius:8,borderWidth:2,tension:0}]},
    options:{
      responsive:true,maintainAspectRatio:false,animation:false,
      interaction:{mode:'nearest',intersect:false},
      scales:{
        x:{type:'linear',min:lo+(hi-lo)*0.3,max:hi,grid:{color:'rgba(255,255,255,0.06)'},ticks:{color:'#999',font:{size:11},maxTicksLimit:10,callback:function(v){var d=new Date(v);return d.getHours()+":"+(d.getMinutes()<10?"0":"")+d.getMinutes()}}},
        y:{min:0,max:100,grid:{color:'rgba(255,255,255,0.06)'},ticks:{color:'#999',font:{size:11},callback:function(v){return v+"%"}}}
      },
      plugins:{
        legend:{display:false},
        tooltip:{backgroundColor:"rgba(0,0,0,0.85)",titleColor:"#ccc",bodyColor:"#fff",cornerRadius:6,padding:10,callbacks:{title:function(it){return new Date(it[0].parsed.x).toLocaleString()},label:function(it){return it.parsed.y+"%"}}},
        zoom:{limits:{x:{min:lo,max:hi}},zoom:{wheel:{enabled:true,speed:0.1},pinch:{enabled:true},mode:"x",drag:{enabled:true,modifierKey:"shift"}},pan:{enabled:true,mode:"x"}}
      }
    }
  });
  }catch(e){
    document.getElementById('chart').remove();
    document.getElementById('wrap').textContent='Chart error: '+e.message;
  }
}
</script>
</body>
</html>]]
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

--- BatteryGraph:showFullHistory()
--- @deprecated Popup window graph is deprecated. This method may be removed in a future version.
--- Opens an interactive full-history chart in a centered popup window
function obj:showFullHistory()
    if obj.__historyWebview then
        local ok = pcall(obj.__historyWebview.show, obj.__historyWebview)
        if ok then return end
        obj.__historyWebview = nil
    end
    local screen = hs.screen.mainScreen()
    local sf = screen:fullFrame()
    local w, h = 720, 480
    local x = sf.x + (sf.w - w) / 2
    local y = sf.y + (sf.h - h) / 2
    local wv = webview.new({ x = x, y = y, w = w, h = h }, {
        allowGestures = true,
        allowNewWindows = false,
        developerExtras = false,
    })
    wv:windowStyle("utility")
    wv:windowTitle("BatteryGraph — Full History")
    wv:html(buildHistoryHTML(getDisplayData()))
    wv:show()
    obj.__historyWebview = wv

    local function panDir(dir)
        if not obj.__historyWebview then return end
        local amt = dir == "left" and "-100" or "100"
        obj.__historyWebview:evaluateJavaScript("window.chart&&window.chart.pan({x:" .. amt .. "},'default')", nil)
    end
    local function focused()
        local fw = hs.window.focusedWindow()
        return fw and obj.__historyWebview:hswindow() and fw:id() == obj.__historyWebview:hswindow():id()
    end
    obj.__panLeftHotkey = hotkey.bind({}, "left", function()
        if focused() then panDir("left") end
    end)
    obj.__panRightHotkey = hotkey.bind({}, "right", function()
        if focused() then panDir("right") end
    end)

    local cc = canvas.new({ x = x + w - 22, y = y + 4, w = 18, h = 18 })
    cc:level(canvas.windowLevels.floating)
    cc:behavior(canvas.windowBehaviors.canJoinAllSpaces)
    cc[1] = {
        type = "text",
        text = "−",
        textFont = "Menlo",
        textSize = 14,
        textColor = { white = 1, alpha = 0.6 },
        frame = { x = 0, y = 0, w = 18, h = 18 },
        textAlignment = "center",
        trackMouseUp = true,
    }
    cc:mouseCallback(function()
        obj:closeFullHistory()
    end)
    cc:show()
    obj.__historyCloseCanvas = cc
end

--- BatteryGraph:closeFullHistory()
--- @deprecated Popup window graph is deprecated. This method may be removed in a future version.
--- Closes the full-history popup if open
function obj:closeFullHistory()
    if obj.__panLeftHotkey then obj.__panLeftHotkey:delete(); obj.__panLeftHotkey = nil end
    if obj.__panRightHotkey then obj.__panRightHotkey:delete(); obj.__panRightHotkey = nil end
    if obj.__historyWebview then
        obj.__historyWebview:delete()
        obj.__historyWebview = nil
    end
    if obj.__historyCloseCanvas then
        obj.__historyCloseCanvas:delete()
        obj.__historyCloseCanvas = nil
    end
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
    obj:closeFullHistory()
    return self
end

return obj
