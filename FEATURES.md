# BatteryGraph.spoon — Feature Analysis

## Overview

A desktop widget for Hammerspoon that records and graphs battery percentage over time. Polls `hs.battery` every 60 seconds and renders a scrolling line chart directly on the macOS desktop via `hs.canvas`.

---

## 1. Data Collection & Persistence

- **Battery percentage polling** — calls `hs.battery.percentage()` every `pollInterval` seconds (default: 60)
- **Rounding** — raw float is rounded to the nearest whole percent via `math.floor(pct * 100 + 0.5) / 100` to avoid floating-point noise
- **Disk persistence** — recorded data is saved to `data.json` in the Spoon's directory. `loadData()` / `saveData()` survive Hammerspoon restarts
- **Data window** — `trimData()` prunes entries older than `maxHours` (default: 24) before each save
- **Mutex guard** — `__mutex` flag prevents overlapping poll cycles

---

## 2. Trim to Current Discharge Cycle

When the battery is **discharging** (current % < peak % in the data window), only the portion from **after the last occurrence of the peak** is rendered.

**How it works:**
1. Find the highest percentage in `obj.__data` and its **last** index (`>=` ensures last, not first)
2. If current percentage equals that peak, show everything (charged/charging)
3. If current < peak (discharging), rebuild `data` starting from `maxIdx + 1`, discarding the charge phase, the flat-at-peak plateau, and any prior discharge cycles

**Effect:** The graph auto-advances as the battery drains — the flat 85% hold and previous cycles disappear once it drops to 84%.

**Persistence:** The full history remains in `data.json` — only the rendered view is trimmed each `pollInterval`.

**Edge case:** With < 2 data points after trimming, shows a status message instead of the graph.

---

## 3. Graph Rendering

- **Canvas-based** — uses `hs.canvas.new()` at `desktopIcon` window level (can join all spaces)
- **Background** — rounded rectangle with configurable fill/border/corner radius
- **Y-axis grid** — 5 horizontal lines (0%, 25%, 50%, 75%, 100%) with percentage labels aligned right on the 25–100% lines
- **X-axis time labels** — 4 evenly spaced labels across the visible data. Format: `"H:MMa"` (e.g., `"9:15a"`) on hour changes, minutes only on same-hour labels
- **Line graph** — stroke curve connecting all data points (stroke width 2)
- **Fill under curve** — semi-transparent filled polygon beneath the line

### Status messages (when < 2 data points)

| Condition | Message |
|---|---|
| `n == 0` (no data) | "Collecting data…" |
| `n == 1` (only 1 point) | "Awaiting next data point (1 min)…" |

After the next poll cycle completes, the graph renders normally.

### Change Markers

Vertical white lines drawn at every Nth battery change event (both gain and drop).

**Step formula** — exponential scaling:

```lua
local step = math.max(1, math.floor((totalChanges / 20) ^ 1.3))
```

| Changes | Step | ~Markers |
|---|---|---|
| 10 | 1 | 10 |
| 30 | 1 | 30 |
| 40 | 2 | 20 |
| 60 | 4 | 15 |
| 80 | 6 | 13 |
| 100 | 8 | 12 |
| 121 | 10 | 12 |
| 150 | 13 | 11 |
| 200 | 19 | 10 |

**Marker placement:**
- `step == 1` → every change gets a line
- `step > 1` → lines at change indices 1, 1+step, 1+2step, ... (via `changeIdx % step == 1`)
- One line per unique integer percentage value, not one per oscillation
- Count is computed from the **trimmed** data window (current discharge only)

---

## 4. Clear Data Button

- **"×"** in the bottom-left corner of the graph
- **Two-click confirmation** — first click sets a 2-second pending window; second click within that window executes the clear. Pending expires after 2 seconds if no second click.
- When triggered:
  1. Empties `obj.__data`
  2. Saves empty data to `data.json`
  3. Immediately polls battery and records one fresh data point
  4. Re-renders the graph (shows "Awaiting next data point (1 min)…" until the next poll)
- Also callable programmatically: `spoon.BatteryGraph:clearData()`

---

## 5. Demo Mode

- `obj.demoData = true` — generates synthetic data for testing: a descending curve from 95% to 5% with sinusoidal noise, spanning `maxHours` at 10-minute intervals
- Seeds `math.random` with `os.time()` for varied data each run

---

## 6. Configuration

All configurable from `init.lua` before calling `:start()`:

| Property | Default | Description |
|---|---|---|
| `position` | `{ x = 20, y = 300 }` | Absolute position (used unless `rightMargin` set) |
| `rightMargin` | `nil` | If set, positions from right edge instead of `position.x` |
| `windowLevel` | `nil` | Canvas level (default: `desktopIcon`) |
| `width` | `280` | Canvas width in points |
| `height` | `180` | Canvas height in points |
| `backgroundColor` | `{ alpha = 0.3, white = 0 }` | Background fill |
| `backgroundBorder` | `{ alpha = 0.5 }` | Border (nil = no border) |
| `cornerRadius` | `8` | Corner rounding |
| `lineColor` | `{ red = 0.2, green = 0.7, blue = 1, alpha = 0.85 }` | Line stroke |
| `fillColor` | `{ red = 0.2, green = 0.7, blue = 1, alpha = 0.15 }` | Under-curve fill |
| `gridColor` | `{ white = 1, alpha = 0.12 }` | Grid and axis lines |
| `textColor` | `{ white = 1, alpha = 0.6 }` | Label text |
| `fontSize` | `10` | Label font size (Menlo) |
| `pollInterval` | `60` | Seconds between polls |
| `maxHours` | `24` | Hours of data retained in `data.json` |
| `demoData` | `false` | Use synthetic data |

---

## 7. Lifecycle

### `:start()`
1. Loads persisted data from `data.json`
2. If `demoData` is true, generates synthetic data
3. Builds the canvas with mouse callback
4. Calls `update()` (record + render)
5. Starts a repeating timer at `pollInterval`

### `:stop()`
1. Stops the timer
2. Hides the canvas

### `:clearData()`
1. Clears `obj.__data`
2. Saves empty data
3. Records one fresh battery reading
4. Re-renders the graph

### `update()`
1. `record()` — polls battery, saves to `data.json`, trims old entries
2. `render()` — rebuilds canvas elements from scratch each cycle

---

## 8. Positioning

- **Absolute** — set `position.x` / `position.y`
- **Right-edge aligned** — set `rightMargin` (points from right edge of main screen), overrides `position.x`

---

## 9. Files

| File | Purpose |
|---|---|
| `init.lua` | Spoon implementation (393 lines, all Lua — no Moonscript) |
| `data.json` | Persisted battery data (auto-created/updated) |
| `FEATURES.md` | This file |
| `TRIM_DISCHARGE_FEATURE.md` | Full documentation of the trim feature |

---

## 10. What It Does NOT Do

- Does NOT read `pmset` or `ioreg` — uses `hs.battery` API
- Does NOT measure Watts, mA, mAh, voltage, or temperature
- Does NOT have right-click tooltips or hover interactions
- Does NOT have per-direction marker spacing (charge and discharge share the same step)
