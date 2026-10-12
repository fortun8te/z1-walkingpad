# macOS app — UI systems

How the window looks and why. The code wins where this and it disagree:
`Theme.swift`, `Components.swift`, `DotMatrix.swift`, `SpeedDial.swift`,
`RootView.swift`, `Pages.swift`, `WeekCard.swift` and `MainWindow.swift` in
`macos/Sources/Z1App`.

## Rules

These are settled with Michael. Change them only on his say-so.

- **Lean.** The app tracks this walk's time and distance and today's minutes
  against one goal. No steps, kcal, records, badges or extra history views
  (Michael, October 2026). Remove such things outright; do not hide them.
- **One small window.** 320 × 414, fixed, Dock icon, normal menu bar. Not a
  menu-bar app. Now, History and Settings swap inside it (⌘1–⌘3). Nothing
  resizes and nothing animates when content changes.
- **Translucent, never grey.** The window body is a behind-window blur
  (`NSVisualEffectView`) tinted by `Theme.ground`: near-black at 86 % in dark,
  warm off-white at 55 % in light, so the desktop shows through without dark
  mode turning grey. No sky, gradients, glow, weather or day/night.
- **One colour.** Blue means the belt is moving, or progress toward the day's
  goal. Amber means a command failed. Nothing else is coloured.
- **Ticks are the one progress idiom.** The speed ruler and the daily goal are
  rows of ticks. No filled progress bars.
- **The speed readout is a 5×7 dot-matrix panel.** Unlit dots stay visible.
  The panel stays dark until the pad has reported a speed, rather than show a
  0,0 nobody measured.
- **Every number is full ink.** If an estimate ever comes back, it says "est."
  in its label and is never greyed, which reads as disabled.
- **Fixed sizes.** The live slot under Start is 36 pt whatever it holds
  (time and distance, a status line, an error with Retry). Chosen chips and
  tabs keep the same font weight. Never `minimumScaleFactor`.
- **No speed preset chips. No sounds.** The ruler gives a haptic detent per
  0.1, nothing else.
- **Liquid Glass on chrome and controls.** The tab bar, Start/Stop, − / +
  and Retry are glass on macOS 26 (interactive glass, fixed sizes) and flat
  capsules before it. Cards, the panel, the ruler and the bars are matte.
- **The build is quiet.** Settings ends with one caption line in the faintest
  ink, `Z1 2.0 (build 202610131200)`, and the About panel shows the same
  numbers. Nothing else on the pages mentions a version.
- **Locale.** Numbers follow the user's region: `3,4 km/h` and `3.120 steps`
  in the Netherlands, never a mix of both conventions.

### Why the Now page is not built from stock controls

On 12 October 2026 a pass swapped the panel, ruler and tick progress for an SF
numeral, a `Slider` and a `ProgressView`, and moved History and Settings into
separate windows. It was reverted: progress went grey, the panel's character
went, the stock switches rendered grey on near-black, and the extra windows
broke the one-window app. Native is right for chrome, menus, alerts and text
fields. The readout, ruler and ticks are the product.

## The speed control

- The **readout** shows the speed last asked for until the belt reaches it,
  so a tap or a typed value reads at once. Otherwise, and at a standstill, it
  shows the belt's own speed.
- On the **ruler** the bright line is the speed asked for. While the belt
  moves, the ticks up to the belt's actual speed are blue, so a change shows
  as the blue filling up to the line while the belt ramps. At a standstill the
  ticks up to the line are ink.
- **Input:** − / + or ← / → nudge 0.1; ↑ / ↓ move 0.5; press or drag anywhere on the ruler; click the panel and type (3 then 5
  is 3,5, Return sets it, Esc cancels).
- **At a standstill** every input queues the speed for Start ("Starts at 3,0
  km/h"), because the pad only accepts speed changes while the belt moves.

## Tokens

| Token | Use |
| --- | --- |
| `ground`, `surface` | The tint over the window's blur; card fills (slightly see-through). |
| `onInk` | Solid marks on ink, such as an on switch's knob. |
| `ink` | Every number and title. |
| `dim`, `faint` | Units and captions, labels under numbers. |
| `track`, `wash`, `barRest`, `unlitDot` | Unlit ticks, empty cells, resting bars, dark dots. |
| `hairline` | The one border, 0.75 pt. |
| `selection`, `control` | Chosen chip or tab; the fill behind a compact field. |
| `accent` | The blue. |
| `trouble` | The amber. |

Type is SF Pro at 11 / 13 / 15 / 22 pt, sentence case, no tracking. Spacing
is 16 outside, 12 between blocks, 8 between related items.

## Checking a change

The preview harness opens the window with no Bluetooth and a scratch
history. See `PreviewHarness.swift` for every switch.

```bash
cd macos
swift build --scratch-path .build-frontend --product Z1App
Z1_PREVIEW=1 Z1_PREVIEW_DEMO=1 Z1_PREVIEW_SPEED=3.4 Z1_PREVIEW_APPEARANCE=dark \
  .build-frontend/debug/Z1App -z1.hasSeenIntro 1
# prints Z1_PREVIEW_WINDOW <n>; then: screencapture -o -l <n> now-dark.png
```

Check both appearances and at least these states: walking, idle, offline,
a queued speed (`Z1_PREVIEW_QUEUED=3`), a failed command
(`Z1_PREVIEW_ERROR=stop`), typing (`Z1_PREVIEW_TYPED=3`), and every page
(`Z1_PREVIEW_PAGE`). The window is translucent, so a capture picks up
whatever is behind it.
