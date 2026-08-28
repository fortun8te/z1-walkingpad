# Z1 sensors and auto-speed feasibility

## What is confirmed

The Z1 exposes only belt speed, belt distance, elapsed time, and a cumulative
step counter over Bluetooth. It exposes no heart rate, accelerometer,
gyroscope, deck zone, or front/back position value. The manual's Hall-signal
fault confirms motor rotation feedback, which explains speed and distance but
does not locate the walker.

The step counter increments under load and is probably derived from deck/load
or motor dynamics. Its exact physical sensor and real Z1 error percentage have
not been proven. The earlier 20–40% claim was generic low-speed research, not a
Z1 measurement.

Official Z1 specifications list app/remote speed adjustment and explicitly do
not promise foot-sensitive speed control. The generic firmware still contains
a device-mode value, but that is not proof that the Z1 has the three-zone
hardware used by other WalkingPad models.

## What to measure

Run 5–10 minute trials at 1.6, 2.0, 2.5, 3.0, 4.0, and 5.0 km/h. For each,
record manually counted steps, raw Z1 steps, and belt distance. Repeat each
speed three times. That gives the Z1-specific error curve and a trustworthy
personal stride calibration.

## Auto-speed decision

Bluetooth telemetry alone cannot safely implement “front speeds up, back slows
down.” Cadence can estimate drift, but its error accumulates and it never gives
an absolute position. Do not let that estimate command a moving belt.

The safe design is an external position sensor—preferably two short-range ToF
sensors aimed at the front and rear zones, or a local camera pose tracker—with:

- a wide neutral zone and several seconds of hysteresis;
- changes limited to 0.1 km/h every 5 seconds;
- a user-set maximum speed;
- immediate slowdown/stop when position, Bluetooth, or the sensor is lost;
- a physical safety key and remote always taking priority.

The hidden device mode may be explored only as an empty-belt hardware test with
an immediate stop path. It must remain experimental until this exact Z1 and
firmware demonstrate real front/middle/rear response.

Sources: [official Z1 product page](https://www.walkingpad.com/products/walkingpad-z1-white-folding-treadmill),
[Z1 manual](https://contents.mediadecathlon.com/s1226129/k%2472912a380fff4ffed160ab42bf548a90/kingsmith%20Z1.pdf), and
[WalkingPad Netherlands Z1 specification](https://www.walkingpad.nl/en/collections/folding-treadmills/products/kingsmith-walkingpad-z1-foldable-treadmill).
