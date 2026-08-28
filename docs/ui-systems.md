# macOS menu bar — UI systems

How the popover looks and behaves, derived from the code that draws it:
`Z1MenuBar/DesignSystem.swift`, `Typography.swift`, `DotMatrix.swift`,
`SpeedDial.swift`, `MenuBarView.swift`, and `Z1Core/SolarClock.swift` +
`OpenMeteo.swift`. If this document and the code disagree, the code wins.

## 1. Design tokens

`Z1` (`DesignSystem.swift`) is the whole palette: black, one blue, three
greys.

```swift
enum Z1 {
    static let canvas = Color.black
    static let ink   = Color.white
    static let dim   = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.26)
    static let unlit = Color.white.opacity(0.06)
    static let hairline    = Color.white.opacity(0.11)
    static let hairlineLit = Color.white.opacity(0.30)
    static let live = Color(red: 0.29, green: 0.51, blue: 0.98)
}
```

The comment on the enum states the rule directly: *"Blue means one thing
only — the belt is moving. Nothing else on screen is allowed to be
coloured, because the moment a second hue appears the first one stops
meaning anything."* `Z1.live` is used exactly for that: the hero card's aura
while the belt runs, the day-goal progress capsule, the today card's inner
glow, and the almanac tile fill — every one of them a measure of motion or
progress, never decoration.

The white levels are not just a size scale, they encode *how a number was
obtained*, per the same doc comment: "full white was measured, half was
modelled, and unlit is present but unknown." In practice:

- **`ink`** — the primary reading: the speed readout, active labels, card
  titles.
- **`dim`** — secondary but still measured text (e.g. the "Stride" label,
  quit help text).
- **`faint`** — placeholders, disabled affordances, day-of-week letters,
  the "not connected" phase label — present but not the thing you came to
  read.
- **`unlit`** — the deliberately-dark state: the empty track of the
  day-goal capsule (`Z1.unlit` fill) and the dot-matrix grid's unlit dots,
  both of which are *there* but carry no value yet.

Elsewhere in the code this same measured/modelled distinction surfaces as
the `measured:` flag on `walkStat(_:_:measured:)` in `MenuBarView.swift`:
distance and elapsed time are measured (label shown plain), while steps and
kcal are modelled (label suffixed `"… est."`).

Cards are edge-drawn, not filled: `z1Card(radius:lit:)` overlays a
hairline stroke rather than filling a background, and `AuraCard` (the hero's
container) is described in its own doc comment as "a card lit from its own
edge: colour gathers at the border and falls away to black in the middle."

Type is `Z1Type` (`Typography.swift`): ABC Diatype (a Dinamo trial build,
named `ABCDiatypeUnlicensedTrial` on disk) in three weights — `light`,
`regular`, `medium` — each falling back to the system font at an equivalent
weight if the face isn't installed, so the app stays legible on a machine
that has never heard of Diatype.

## 2. SkyField

`SkyField` (`DesignSystem.swift`) is the popover's background: the real sky
outside, right now, redrawn from the sun's actual position.

### Solar-elevation keyframes

Sun position comes from `SolarClock` (`Z1Core/SolarClock.swift`), the
"classic Almanac for Computers algorithm (NOAA)", returning elevation and
azimuth in degrees for a given date/time and location. It **defaults to
Amersfoort, 52.156° N, 5.388° E** — the doc comment on `SolarClock` states
the point is "honesty of shape... not GPS precision."

`SkyField.sky` keys a 7-stop palette table to solar elevation, blending
continuously between adjacent stops:

| elevation | character |
|---|---|
| −18° | deep night, full star field (`stars: 1.0`) |
| −9° | late twilight, indigo horizon (`stars: 0.75`) |
| −4° | civil twilight, red-orange horizon (`stars: 0.35`) |
| 2° | sunrise/sunset, strong orange (`stars: 0.10`) |
| 8° | early morning/evening, blue climbing in (`stars: 0`) |
| 20° | full day blue (`stars: 0`) |
| 50° | high-day blue, brightest (`stars: 0`) |

Each stop carries `zenith`/`mid`/`horizon`/`glow` colours and a `stars`
weight; below −18° or above 50° the nearest table entry is used outright,
otherwise the two bracketing stops are linearly blended by `t`.

On top of that base blend, three more effects layer in, all gated by how
low the sun is (`lowSun = max(0, 1 - abs(elevation)/10)`, i.e. it only acts
within ±10° of the horizon):

- **day character** — a per-calendar-day deterministic seed (LCG on
  year/month/day) picks a `hueDrift` (−0.06…+0.05, rose→gold) and
  `vividness` for that day's horizon, so "some evenings burn orange, some go
  rose, some violet... deterministic, so the sky does not change its mind
  between glances."
- **scattered-cloud glow** — cloud cover between 0.15 and 0.65 at a low sun
  brightens and warms the horizon (the "pink evenings" case), peaking near
  40% cover.
- **season warmth** — a sine curve over day-of-year (`sin((dayOfYear-172)/365
  * 2π + π/2)`, +1 at midsummer, −1 at midwinter) nudges the blues warmer or
  cooler.

### Amersfoort default

Both `SolarClock()` (used inside `SkyField.sky` and `.body` for sun
position) and `OpenMeteo.snapshot(latitude:longitude:...)` default to
**52.156, 5.388** — Amersfoort. `SkyField` never overrides these defaults.

### Weather integration

`SkyField` takes an optional `WeatherSnapshot?`; a hidden simulator
(`UserDefaults` keys `z1.skySimHour`, `z1.skySimDate`, `z1.skySimWeather`)
can substitute any hour or synthetic condition for testing, documented in
the source as "the only honest way to verify a dawn without setting an
alarm."

- **Cloud mutes the field.** `let mute = 1 - 0.42 * cloud` scales nearly
  every layer in `SkyField.body` — the vertical gradient stops, the sun
  disc's opacity, and the goal-progress glow described below — so overcast
  genuinely flattens the whole window rather than just adding a grey
  layer on top. (A separate flat grey veil, `opacity(0.16 * cloud)`, is
  layered in as well, so overcast reads as *a presence*, per the code
  comment, not an absence of light.)
- **Precipitation rendering.** When `weather.isRaining || weather.isSnowing`,
  a `Canvas` draws 34 rain streaks (slanted 0.8pt strokes, falling fast) or
  46 snow specks (drifting ellipses, falling slow) at 20fps, using a
  deterministic per-flake formula seeded by index so paths don't jitter
  between redraws.
- **Moon phase on clear nights.** The moon disc (see below) only renders
  when `sky.stars * clearness > 0.35`, where `clearness = 1 - 0.85 * cloud`
  — i.e. it survives scattered cloud but vanishes under a closed deck. When
  stars are strong (`sky.stars > 0.5`), a full moon additionally silvers the
  field colours: `moonlight = MoonPhase.illumination(at:) * clearness *
  sky.stars`, and above `moonlight > 0.1` the mid and horizon colours blend
  toward a pale silver-blue.

### The lift formula

The "goal glow" — the warm light gathering at the bottom of the window as
the day's goal fills — is a `RadialGradient` anchored just below the
window's bottom edge:

```swift
sky.glow.opacity((0.15 + 0.40 * min(intensity, 1)) * mute)
```

That is a **0.15 floor plus up to 0.40 more scaled by goal progress**
(`intensity`, passed in from `viewModel.goalProgress ?? 0` — today's
fraction of the daily goal, 0…1), all multiplied by the same cloud `mute`
factor described above. The code comment names it directly: "Walking warms
the horizon — the goal glow, in the sky's own hue." The whole `SkyField` is
wrapped in `.animation(.smooth(duration: 0.9), value: intensity)`, so the
glow eases rather than snapping when the goal fraction changes.

### Grain / stars determinism

Both the star field (`SkyField.stars`, 300 points) and the separate
`NightField.grain` speckle (340 points, defined in the same file but not
currently referenced by `MenuBarView`) use a fixed-seed linear congruential
generator (`seed = 0x9E3779B97F4A7C15`, multiplier
`6364136223846793005`) rather than `Double.random`, specifically so the
speckle is "part of the design rather than noise that dances on every state
change" — the field is pixel-identical between two opens of the popover at
the same conditions. Star brightness additionally thins toward the horizon
(`1 - depth * 0.75`) to mimic how a real sky's glow washes faint stars out
near the ground.

### Falling stars

A single shooting star (`SkyField.fallingStar`) fires only when
`sky.stars > 0.3` (dark enough): the first one 4 seconds after the popover
appears, then every 23 seconds on a repeating timer
(`SkyField.scheduleStar`). Each firing (`fireStar()`) increments a
`shootSeed` that re-seeds the streak's start position (5 horizontal slots ×
3 vertical slots, derived from `shootSeed % 5` / `% 3`) and drives a
`keyframeAnimator` opacity curve — rise to 0.9 over 0.25s, hold near 0.7,
fade to 0 by 0.9s total — while the streak itself translates along a fixed
diagonal offset over the same 0.9s `easeIn` animation. The source comment
notes this replaced an earlier build where "an opacity bug kept every star
at 0," i.e. the feature existed but was invisible until fixed.

## 3. The almanac card

`todayCard` in `MenuBarView.swift` is the "day's standing as one object":
a header (day title + goal fraction), a thin goal-progress capsule
(`dayGoalLine`), the tile strip, four walk stats, and one footer line — all
inside a single card so "the card never changes size, the interface never
moves" when you switch days.

### Week / month tile strip

`tileStrip` renders `viewModel.weekDays` (7 tiles, `almanacLens == .week`)
or `viewModel.monthDays` (30 tiles, `.month`) — tapping the day title
toggles between the two lenses and resets the selection to today. In week
mode, tiles are taller (32pt), spaced 3pt apart, and each carries a narrow
weekday-letter label underneath; in month mode, tiles are shorter (44pt,
same as the row height — no separate row), spaced 1.5pt apart, unlabelled.
Tapping a tile sets `selectedDay` (or clears it back to nil/"today" if the
tapped day is already today), which re-renders the whole card — stats,
progress bar, and footer — for that day.

### Per-day goal-progress glow

Each tile's fill opacity is computed from that day's goal fraction:

```swift
Z1.live.opacity(day.isEmpty ? 0.04 : 0.12 + 0.60 * progress)
```

— a near-invisible 0.04 for a day with no walk at all, otherwise a 0.12
floor rising to 0.72 at a fully-met goal. The code comment calls this out
as a deliberate simplification: "Flat: one opacity per day, read at a
glance. The per-tile gradient made every bar a guess." The selected tile
additionally gets a brighter, thicker stroke
(`Z1.ink.opacity(0.7)`, 1pt vs the usual 0.7pt hairline).

### Footer line precedence

`almanacFooter(_:)` picks exactly one line, in this order, falling through
to the next only when the previous returns nothing:

1. **Equivalence** — `Equivalence.daily(forMeters: totals.distanceM)`, e.g.
   `"≈ the Vondelpark, end to end"`. Returns `nil` below its smallest entry
   (0.7 km), which is what lets the chain fall through.
2. **Month journey line** — only when `almanacLens == .month` *and* no day
   is explicitly selected (i.e. the month overview showing today):
   `Equivalence.journeyLine(totalMeters: viewModel.lifetimeDistanceM)`, a
   cumulative "Amsterdam → Leiden · 15 km to Den Haag"-style line. The code
   comment explains why this one applies even on an unwalked day: "the
   lifetime odometer is that view's identity."
3. **Today flavor** — if the day in question is today (and step 1 found no
   equivalence, i.e. distance is under 0.7 km): `Equivalence.flavor(...)`,
   either "N.n km to `<next equivalence>`" or a time-of-day line ("The belt
   is warmest before the day gets loud", etc.), deterministic per hour.
4. **Narrative** — otherwise (a past day short of any equivalence):
   `Equivalence.narrative(for:)`, a run-level summary across the current
   lens's days: `"Walked N of M days · X min avg · Y km"`, or `"No walks yet
   in this window"` if none of the days in range have a walk.

## 4. Speed dial and dot-matrix hero

### Speed dial

`SpeedDial` (`SpeedDial.swift`) replaces "the old slider-plus-field-plus-
steppers arrangement, where the speed lived in three places at once and
none of them was obviously *the* control." It draws one tick per 0.1 km/h
step across the pad's speed range (1.6–6.4 km/h from the BLE spec, passed
in as `viewModel.speedRange`): `tickCount = span/step + 1`. Whole km/h
ticks stand taller (0.80 of the track height) than passed sub-ticks (0.62)
or upcoming ticks (0.44), so the scale stays readable as a ruler and not
just a texture. Ticks up to the current value are lit
(`Z1.ink.opacity(0.92)`); the rest are a faint `Color.white.opacity(0.16)`.
A bright 1.6pt indicator line tracks the live value on top.

Dragging calls `speed(atX:width:)`, which rounds to the nearest 0.1 km/h
step, and fires a macOS trackpad haptic (`NSHapticFeedbackManager...
.perform(.alignment, ...)`) once per new detent crossed — `tickHaptic(_:)`
de-dupes by comparing against the last detent so a stationary finger
doesn't repeat-fire. The whole dial dims to 0.35 opacity and stops
responding when `enabled` is false (i.e. `viewModel.isConnected == false`).

### Dot-matrix hero

`DotMatrixText` (`DotMatrix.swift`) draws numerals as a 5×7 (digits) or 2×7
(separators) dot grid, hand-set so, per the source comment, "a 4 and a 1
cannot be confused at a glance." It always occupies its full grid size
whether or not `lit` is true — its own doc comment: "the readout reads as a
physical panel whose segments are being lit, not as text that happens to be
dotty. It also means the block never changes size as the digits change."

The hero card in `MenuBarView.swift` passes
`lit: viewModel.isConnected` — i.e. **the grid goes fully unlit (all dots at
the faint `unlit` colour, no bright digits) whenever the app is not
connected to the pad** (`viewModel.isConnected` is `status.phase == .ready`),
which is the moment there is no live speed to show. Connected but stationary
still shows a lit `"0.0"`; only disconnection blanks it. Tapping the lit
grid (only while connected) switches to an inline `TextField` for typing an
exact speed.
