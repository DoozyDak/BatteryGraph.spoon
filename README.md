# BatteryGraph.spoon

A Hammerspoon Spoon that records and graphs battery percentage over time on your macOS desktop.

![Screenshot](BatteryGraph.png)

## Features

- **Live graph** — polls `hs.battery` every 60s and draws a scrolling line chart on the desktop
- **Continuous curve** — smooth line across all data points with no visual breaks
- **Gap markers** — red vertical indicators show where time gaps (sleep, offline periods) occurred; adjacent gaps automatically merge into one marker
- **Change markers** — vertical lines at battery change events with auto-scaling density (`(changes/20)^1.3`)
- **Trim to discharge** — automatically cuts off previous charge cycles once the battery starts draining
- **Disk persistence** — survives restarts via `data.json`
- **Configurable** — colors, sizes, position, polling interval, and more

## Interactions

**Hover over the chart:**
- Shows **time and percentage** of the hovered data point at the top (e.g., `10:20am  64%`)
- Displays a **white vertical cursor line** at the hovered point's x-position
- Both disappear when the mouse leaves the chart area

**Click near a red gap marker** (within ~4px):
- Shows **gap range** instead: start and end times with percentages on both sides (e.g., `10:20am 64% → 11:25am 57%`)
- The cursor line snaps to the gap marker
- Gap info persists while the cursor stays near the gap marker; reverts to normal hover when you move away

**Click the "×" button** (bottom-left corner):
- **Two-click confirmation**: first click arms it (2-second window), second click within that window clears all data
- Resets data and records one fresh battery reading
- Data is saved to `data.json`

## Installation

```lua
hs.loadSpoon("BatteryGraph")
spoon.BatteryGraph:start()
```

Or via SpoonInstall:

```lua
spoon.SpoonInstall:andUse("BatteryGraph", {
    repo = "DoozyDak/BatteryGraph.spoon",
    start = true,
})
```

## Usage

In your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("BatteryGraph")
spoon.BatteryGraph.rightMargin = 20
spoon.BatteryGraph:start()
```

## Configuration

| Property | Default | Description |
|---|---|---|
| `position` | `{ x = 20, y = 300 }` | Canvas position (ignored if `rightMargin` set) |
| `rightMargin` | `nil` | Distance from right edge (overrides `position.x`) |
| `windowLevel` | `nil` | `"desktopIcon"`, `"normal"`, etc. |
| `width` / `height` | `280` / `180` | Canvas size |
| `backgroundColor` | `{ alpha = 0.3, white = 0 }` | Background fill |
| `lineColor` | `{ red = 0.2, green = 0.7, blue = 1, alpha = 0.85 }` | Graph line color |
| `fillColor` | `{ red = 0.2, green = 0.7, blue = 1, alpha = 0.15 }` | Area fill under curve |
| `gridColor` | `{ white = 1, alpha = 0.12 }` | Grid line color |
| `textColor` | `{ white = 1, alpha = 0.6 }` | Label color |
| `fontSize` | `10` | Label font size |
| `pollInterval` | `60` | Seconds between battery readings |
| `maxHours` | `24` | Hours of history to keep |
| `trimToDischarge` | `true` | Show only current discharge cycle when battery is draining |
| `gapMinutes` | `30` | Minimum gap (minutes) between consecutive readings that triggers a gap marker |

## Data Storage

Battery readings are stored in `~/.hammerspoon/Spoons/BatteryGraph.spoon/data.json` (excluded from git via `.gitignore`).

## License

MIT
