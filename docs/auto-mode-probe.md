# Hidden auto-mode probe

The Z1 reports a generic device-mode property (`property 10`). The known
firmware labels the mode bits as manual (`0`), auto (`1`), and sleep (`2`), but
the Z1 has not been shown to contain the front/back sensors needed for that
feature.

`scripts/auto_mode_probe.py` is deliberately read-only. It:

1. Finds the Z1 and enables telemetry notifications.
2. Performs the normal vendor unlock handshake.
3. Reads all properties and decodes property 10.
4. Watches for speed or a “started” event, then reads machine status so the
   idle gate is explicit.

It does not request FTMS control, start/stop/pause the belt, change speed, or
write property 10. Running it while the pad is powered on but empty is the
safest next step:

```bash
cd /Users/michael/z1-walkingpad
./.venv/bin/python scripts/auto_mode_probe.py
```

Expected output includes `mode_name`, `mode_raw`, `belt_seen_moving`, and
`idle_gate_passed`. The gate is only true when the pad reports a stopped state
and no speed/status signal showed motion; a silent telemetry stream is not
treated as proof of idle. If the mode is already `auto`, that still does not
prove front/back tracking; watch whether the pad behaves differently only
after a separate, supervised experiment.

## What is needed for a real experiment

The owner must be beside the powered-on pad, with the belt completely empty,
the safety key accessible, and the physical remote ready to stop it. The first
test should only determine whether the hidden mode is accepted and whether an
empty belt remains stopped. It must not be treated as usable while walking
until a person has confirmed that front/middle/back position changes cause
small, bounded speed changes and that removing BLE control or position input
causes a stop/slowdown.

Do not use the generic mode value as proof of a sensor. If the read-only probe
reports `manual`, the Z1 likely has no active auto mode. If it reports
`auto`, the feature is still unverified.
