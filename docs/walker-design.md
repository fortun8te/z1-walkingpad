# The walker

A small dot-matrix man who walks when the belt walks.

He is not a progress indicator. He is the answer to "is this thing on?", asked
from across the room — and the reason the answer is worth having is that a
number can be stale without looking stale, whereas a man who has stopped moving
is unmistakably a man who has stopped moving.

Three files, all under `macos/Sources/Z1MenuBar/Walker/`:

| file | what it is |
|---|---|
| `WalkerSprites.swift` | the frames, as literal dot grids |
| `WalkerState.swift` | pure state machine — no views, no timers, no `Date` |
| `WalkerView.swift` | SwiftUI `Canvas` renderer + the one place a clock touches him |

Nothing is wired into `MenuBarView` yet. `WalkerPreviewStrip` renders the whole
set for inspection.

---

## The figure

22 cells wide, 26 tall, strict side view, facing right. One canonical skeleton,
obeyed by every pose:

```
row  0…4   head        cols  9…13     (nose pushes to 14 on rows 2–3)
row  5     neck        cols 10…11
row  6…9   chest       cols  8…13     (shoulders one cell FORWARD)
row 10…14  belly/hip   cols  8…12     (hips one cell BACK → the lean)
row 15…25  legs        11 rows → ~5.5 cells of horizontal reach
shoulder joint         (11, 7)
hip joint              (10, 14)
ground                 row 25
```

Two earlier attempts drove the figure from a joint-angle rig and the silhouettes
never read. At 22×26 there are not enough cells for an angle to land where you
meant it — a two-degree change either does nothing or moves a whole limb. So
every frame is hand-authored cell by cell, and the skeleton above is pinned
rather than derived. Inconsistency between poses is the specific thing that
sank the previous rounds.

Three decisions carry most of the character:

**The nose.** Rows 2–3 push one cell past the face. A symmetrical head is a
circle, and a circle has no facing — the first draft read as a lollipop. That
two-cell brow is the only thing in the sprite that says which way he is walking.

**The neck.** A 2-cell pinch between a 5-wide jaw and a 6-wide shoulder. It was
originally 3 wide under a 3-wide jaw on a 5-wide chest, which is to say the
head, neck and body were all the same width and there was no neck at all — just
a column with a face on it. A neck only exists as a contrast.

**The lean.** Shoulders sit one cell forward of the hips, in every frame,
including the seated ones. One cell is all a 2–5° lean amounts to at this scale,
and it is the difference between a man walking and a man being dragged along
upright. Walking is controlled falling forward; a vertical torso reads as
marching.

### Ink

`0` empty · `1` dither dot (45% alpha) · `2` solid dot.

Dots are diamonds, not squares or circles. A diamond screen is the least
conspicuous orientation to the eye, and diamonds join their neighbours gradually
as they grow rather than snapping shut at 50% the way round dots do — which is
what keeps the dissolve reading as a ramp instead of a step. Solid dots are
drawn at 106% of the cell pitch so orthogonal neighbours overlap; a diamond
inscribed exactly in its cell covers only half of it and meets its neighbour at
a single point, and at 100% the man came out as loose weave rather than a figure.

**Depth is carried by ink, not by outline.** The near arm and leg are solid; the
far arm and leg are dither. In a strict side view at 1-bit there is no tone
available to separate two overlapping legs, so the dither *is* the tone. The
near limb is always the same physical leg — across the cycle the poses swap, the
ink never does. A figure whose solid leg alternates reads as turning round rather
than walking.

The one caveat: a two-cell limb drawn entirely in dither is fragile. The dither
dot has to stay near the pitch (93%) so it still connects along a limb. At 73%
the back leg disintegrated into disconnected beads and read as grit rather than
a leg.

### The dissolving edge

Subtractive, not additive. The outermost ring of the body is *demoted* from solid
to dither. Growing dither outward instead draws a fuzzy outline around a hard
shape — the man looks traced, and the silhouette inflates by a cell in every
direction.

Four rules keep it from eating the figure:

- The checkerboard is anchored to the **grid**, `(col + row) % 2`, never to the
  body. A cell that dithers in one frame dithers in every frame it appears in,
  so the rim cannot crawl. This matters more than it sounds: scroll a
  checkerboard by one cell and every dot inverts — the whole area flashes.
- The dissolve is **directional**, never radial. Only the trailing edge — his
  back, and the top — gives way. Dissolving evenly on all sides reads as
  corroded; a hard leading edge fraying behind reads as moving.
- **The head never dissolves.** It carries the facing.
- A cell is only demoted where there is deep mass behind it (≥8 of 9 neighbours
  solid). Limbs are two cells wide and are *all* edge; a 50% pattern on a
  two-cell limb removes half of it. At ≥7 the whole back edge went ragged and,
  with the far arm already in dither on that same side, his back half turned to
  grey mush. The dissolve has to nibble, not chew.

---

## The frames

19 in total.

### Walk cycle — 8 frames

Contact → down → passing → up, twice. The second half is the first half with the
**poses** swapped, not the ink.

| # | phase | what it is |
|---|---|---|
| 0 | contact | legs at max separation, both feet down — the only such frame |
| 1 | down | lowest point, front knee flexed to absorb the landing |
| 2 | passing | support leg straight, swing knee up and forward |
| 3 | up | push-off, support heel lifted, swing leg reaching |
| 4–7 | | as 0–3, legs reversed |

Rules that the frames actually obey, each of which was a correction to a draft:

- **The bob is one cell, not two.** A walking body's centre of mass travels about
  2.7% of its height — on a 26-cell figure, two-thirds of one cell. The first
  draft used ±1 and he bounced like he was on the moon. Only the *down* frames
  are low; the *up* frame earns its height from a straight support leg and a
  lifted heel, not from a Y offset.
- **Feet are authored in absolute rows.** A planted foot that rides the body's
  bob is exactly what makes a small walk cycle skate.
- **Arms swing half what the legs do**, extreme at contact. But the swing is
  drawn wider than anatomy: the torso is five cells deep, and an honest arm would
  spend the whole cycle buried inside the chest and simply not exist. Each arm is
  a clean 45° stroke that steps further out of the body on every row — an earlier
  version put the upper arm where a real one goes, so all that emerged was a
  two-cell nub near the hip and the man read as having wide hips rather than arms.
- **The swing leg at passing is two rows shorter than the support leg**, with its
  foot clearing the ground by two rows. Equal-length legs at the passing frame is
  the single biggest cause of a small walk reading as floating.
- **Feet land 13 cells apart** at contact (≈10 heel-to-heel), which is the
  measured step length for a figure this tall. A timid stride reads as shuffling.

### Idle and fidgets — 6 frames

`stand`, `stand-breath`, `watch`, `drink`, `type-a`, `type-b`.

Standing alternates with a one-cell breath. A character that stops dead reads as
a crashed animation.

The watch frame's watch is a single **empty** cell at the wrist. At 1-bit a hole
reads as an object, where an extra dot would just read as a fatter arm.

Typing draws no desk. The pose has to carry it, so the tell is two hands level
with each other at waist height with the elbows tucked — nothing else in the set
puts both arms forward at the same height, so it cannot be confused with a walk
frame.

### Seated — 2 frames

`sit`, `sleep`. The seated body is the canonical body dropped 3 rows: same head,
same neck, same trunk, same lean. Only the legs are re-authored, folded into a Z.

The thigh sits *below* the trunk rather than beside it. The first attempt
overlapped the two across the same rows and the result was a single nine-cell
rectangle — a lump, not a man in a chair. Seated side view only reads if the hip
is a corner: trunk stops, thigh starts, and the thigh runs four clear cells past
the front of the chest.

`sleep` slumps the head forward off its neck and adds two Z's. The Z's are the
only glyphs in the sprite set, and they are what makes "asleep" read as different
from "sitting very still" — which at 22×26 it otherwise would not. Both Z's are
the same 3×3 glyph stacked in one column, so they read as one rising over the
other rather than as two bits of debris.

### Rising — 3 frames

`rise1`, `rise2`, `rise3`. The middle beat is the one that matters: nobody can
stand up without first throwing their chest out over their feet, and skipping
that is what makes get-up animations look like a character being winched
upright. The feet also travel backward under the body between beats 1 and 2 —
you cannot rise over feet left out in front of you.

---

## The state machine

`WalkerState` is a struct. It has no views, no timers, and never asks what time
it is: time arrives as `dt` on `advance(dt:input:)`. That is what makes it
testable — a whole evening runs in a loop.

```
WalkerInput { beltRunning, speedKmh, hour, secondsIdle }
```

### States

| state | meaning |
|---|---|
| `walking` | belt moving, his legs matched to it |
| `catchingUp` | belt moving, his legs not matched to it yet |
| `pausing` | belt stopped, but only just — he is still on his feet |
| `sitting` | belt still long enough that the chair came in |
| `sleeping` | late, and he has been sitting a while |
| `standingUp` | getting up; three beats, not skippable |

### Transitions

```
        belt moves
  sitting ─────────► standingUp ──(3 beats)──► catchingUp ──► walking
  sleeping ─┘                                       ▲   │
                                                    └───┘  speed changes
  walking ──belt stops──► pausing ──45s──► sitting ──120s + late──► sleeping
```

`pausing` exists because of the 45-second delay before the chair arrives.
Standing there for a moment after the belt stops is what a person does, and it
gives the fidgets somewhere to live — most idle time would otherwise be spent
seated, where the standing fidget frames would be wrong bodies.

Night is 23:00–06:00. He only nods off from `sitting`, never straight from
walking.

### Cadence, and catching up

```
spm  = clamp(60 + 11 × speedKmh, 50…160)
fps  = spm / 15
```

Anchored on the measured figure that ordinary walking is 110–120 steps a minute
at about 4.5 km/h, and that cadence rises roughly linearly with speed over the
range a walking pad covers. The cycle is eight frames covering **two** steps, so
each step is four frames and `fps = spm/60 × 4`.

| speed | cadence | ms/frame |
|---|---|---|
| 2 km/h | 82 spm | 183 |
| 4 km/h | 104 spm | 144 |
| 4.5 km/h | 110 spm | 137 |
| 6 km/h | 126 spm | 119 |

which puts normal walking squarely in the 125–170 ms band that hand-animated
walk cycles use.

Cadence *chases* its target rather than snapping to it, on a 1.6 s exponential.
A real person takes a few steps to settle into a new belt speed. While cadence
is more than 6 spm from target he reads as `catchingUp`. This is the whole of
"catches up after speed changes" — there is no separate mechanism.

The cycle phase is a `Double` in cycles, wrapped, so a speed change never makes
him skip or repeat a foot. When he stops, phase parks at 0 — a contact frame —
so the next walk starts from a real key.

### Randomness

Seeded LCG (`WalkerRandom`), same constants as the sky field. Never
`Double.random`. The fidgets have to be reproducible or the animation cannot be
debugged: "he drank at the wrong moment" is not a bug report you can act on
unless you can replay it.

---

## Verified

`WalkerSprites` and `WalkerState` depend only on Foundation, so they compile and
run standalone. A simulated session confirms:

- a full arc — `pausing → catchingUp → walking → pausing → sitting`
- a mid-walk speed change (2 → 6 km/h) produces a fresh `catchingUp` spell
- belt off at 23:00 reaches `sleeping` via `sitting`
- identical seeds produce identical fidget sequences
- all 8 walk frames are reached during a walk

Plus static invariants on the grids themselves: every frame touches the ground
row, no two adjacent frames share a silhouette, per-frame change is even around
the cycle, mass stays within 30% across frames, and the near leg never fades
below 40% of the leg mass.

---

## Known gaps

- **No seated fidgets.** Every fidget pose is drawn on the standing body, so
  fidgets are gated to `pausing`. A seated typing frame is the obvious next
  sprite.
- **No desk or chair.** The brief calls for the chair gliding in and the standing
  desk lowering. The state machine has the transitions and the timings; the
  furniture is not drawn.
- **Not wired into `MenuBarView`.** Deliberate.
- **`secondsIdle` is carried but barely used.** It is plumbed through for a
  future "he notices you came back" behaviour.
- The `up` frames are the weakest of the eight and would be the first to drop if
  the cycle is ever reduced to six.
