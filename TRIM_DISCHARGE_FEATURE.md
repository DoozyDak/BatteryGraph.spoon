# Trim to Current Discharge Cycle — Feature Documentation

## Purpose

When the battery is **discharging** (current percentage < peak percentage), the graph should only show the portion of data from the **end of the most recent full charge** forward. This cuts off:
- Previous discharge cycles (from older days)
- The flat "at full charge" plateau (e.g., 85% held for hours after charging stopped)
- Any charging segments

The full history remains intact in `data.json` — only the **rendered view** is trimmed.

## Exact Code (lines 117–138 of `init.lua`)

```lua
    -- Trim data to current discharge cycle
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
```

## How It Works (Step by Step)

### 1. Shadow copy of the data

```lua
local data = obj.__data
local n = #data
```

`data` starts as a reference to the full `obj.__data` array. `n` is its length. If the trim condition is NOT met, this original reference is used for the rest of rendering.

### 2. Guard: need at least 2 points

```lua
if n >= 2 then
```

Trimming makes no sense with 0 or 1 data points.

### 3. Find the peak

```lua
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
```

- `curPct` = the most recent battery percentage (last entry), as an integer (e.g., 84)
- Scans ALL data to find the maximum percentage and its **last occurrence index** (`>=` ensures last, not first)
- `maxPct` = highest percentage in the data window (e.g., 85)
- `maxIdx` = index of the **last** occurrence of that peak

### 4. Condition: is the battery discharging now?

```lua
if curPct < maxPct then
```

Only trim if current < peak. If still at peak (charged/charging), show everything.

### 5. Rebuild data from after the peak

```lua
data = {}
for i = maxIdx + 1, n do
    table.insert(data, obj.__data[i])
end
n = #data
```

Creates a new array starting from the entry **right after** the last occurrence of the peak value. This:
- Removes the charge phase (values rising toward the peak)
- Removes the flat "holding at peak" section (e.g., 85% for hours)
- Keeps only the discharge tail (84%, 83%, 82%...) plus any minor gains during discharge

The local variable `n` is also updated to reflect the new length.

### 6. Everything after this uses the trimmed `data`

The rest of `render()` reads from the local `data` variable — grid lines, curve, change markers, all reference `data` and `n` instead of `obj.__data`.

## Key Implications

### On change markers

The marker step system counts `totalChanges` from the TRIMED `data`, not from `obj.__data`:

```lua
for _, e in ipairs(data) do   -- <--- trimmed data
    local p = math.floor(normalizeP(e.p) * 100 + 0.5)
    if prev ~= -1 and p ~= prev then totalChanges = totalChanges + 1 end
    prev = p
end
```

This means:
- Step depends on how many changes happen in the **current discharge window only**
- A short discharge window (< 15 changes) → step = 1 → every change gets a marker
- This is the current user-reported bug: charge events from earlier in the full history are NOT included in the count, so a 24h window with 50+ changes might only show ~10 changes after trimming → step drops to 1 → too many markers

### On the timer

The trim is **not persisted**. It runs every `pollInterval` seconds (default: 60) when `render()` is called. As the battery discharges further, `curPct` decreases and the start point automatically advances, progressively removing older data from the visible window.

## History

Added in session commit `0a42b55` (June 4, 2026). Initially used `>` for peak detection (first occurrence); changed to `>=` (last occurrence) within the same session after user reported the graph "clearing" when a new lower percentage first appeared.

## To Restore

Uncomment lines 117–138 in `init.lua`. The rest of the function uses the local `data` variable which will then refer to the trimmed array when discharging.
