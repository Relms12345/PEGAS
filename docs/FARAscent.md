## FAR Ascent Guidance Addon

A PEGAS addon that uses real-time aerodynamic data from Ferram Aerospace Research (FAR)
to improve the atmospheric ascent phase. It replaces the default time-based gravity turn with
a q-modulated pitchover and adds angle-of-attack (AoA) and dynamic pressure (q) safety enforcement.

Requires [kos-ferram](https://github.com/giuliodondi/kOS-Ferram). Without it the addon degrades
to a no-op.

### Installation

Copy `FARAscent.ks` into the `kOS/addons/` directory. PEGAS auto-detects it.

To disable the addon, edit `FARAscent.ks` and set `farAscentConfig["enabled"]` to `FALSE`.
(The `addonEnabled` global is reset by PEGAS's `scanAddons` each run; editing the addon
file directly is the only reliable method.)

### Behavioral modes

The addon detects which atmospheric mode your boot file uses and adapts:

| PEGAS configuration | Addon behavior |
|---|---|
| Default gravity turn (`verticalAscentTime` + `pitchOverAngle`) | **Full control** — takes over the entire atmospheric phase. PEGAS's built-in passive steering is disabled while the addon is active. The pitchover kick angle comes from `pitchOverAngle`, but the ramp timing and rate are driven by dynamic pressure. |
| Pitch program (`pitchProgram` lexicon) | **Correction mode** — leaves the pitch schedule intact but applies AoA/q safety modifiers on top, with rate limiting to prevent single-tick jumps. |

The addon registers two kOS hooks:
- `"init"` — detects kos-ferram availability, reports operating mode, initializes state.
- `"passivePost"` — runs after PEGAS's atmospheric steering each tick in the passive guidance loop. In full-control mode, PEGAS's own steering is suppressed so the addon is the sole atmospheric controller.

It stops contributing when the passive loop breaks for UPFG pre-convergence, at which point
the vehicle is above sensible atmosphere anyway.

### Full control mode detail

The atmospheric ascent is managed by a three-phase state machine:

**Phase 0 — vertical ascent.** The rocket holds the launch azimuth straight up until
`verticalAscentTime` elapses. No q-gating on start (the pitchover always begins on schedule;
q modulates only the rate).

**Phase 1 — adaptive pitchover ramp.** Once the pitchover begins, the commanded pitch starts
from `90 - pitchOverAngle` degrees (the initial kick) and blends toward the surface prograde
angle. The blend fraction `qFrac` is driven by dynamic pressure:

```
qFrac = (q - pitchoverStartQ) / (pitchoverTargetQ - pitchoverStartQ)   [clamped 0..1]
```

A time-based floor ensures progress even when q is negligible (very low TWR or upper atmosphere):

```
timeFrac = min((elapsed - verticalAscentTime) / 15.0, 1.0)
qFrac = max(qFrac, timeFrac)
```

The kick angle is held until the surface velocity vector drops below it, then the pitch blends
toward prograde as `qFrac` rises. AoA and q safety corrections are applied, and the actual pitch
is rate-limited toward the corrected target (`pitchRateLimit` deg/s). This ordering prevents
correction bias from accumulating across ticks.

The phase transitions to Phase 2 when `qFrac >= 0.95`. A safety timeout forces the
transition after `verticalAscentTime + pitchOverTimeLimit + 10s` if the primary condition
is not met (e.g., sustained high-q preventing convergence).

**Phase 2 — gravity turn.** The rocket tracks surface prograde at the launch azimuth. AoA and
q corrections are applied, followed by rate limiting to smooth tick-to-tick changes.

### Correction mode detail

When a `pitchProgram` is defined, the addon reads PEGAS's already-computed `steeringVector`,
extracts the commanded pitch angle, applies `farClipAoA` and `farLimitQ` corrections, then
rate-limits the result toward the corrected value to prevent single-tick jumps. The pitch
schedule itself is not altered.

### Safety functions

**AoA limiting** (`farClipAoA`). When actual FAR AoA exceeds `maxAoA`, the commanded pitch is
biased toward the velocity vector using:

```
corrected = pitch - gain * aoa
```

`aoaCorrectionGain = 0` means no correction; `1.0` means full snap to prograde (zero AoA).
The default `0.5` blends halfway. The correction is applied only when the limit is exceeded.

**Dynamic pressure limiting** (`farLimitQ`). When `q > maxQ`, the commanded pitch is biased
upward by `min((q - maxQ) / maxQ * 10, 10)` degrees (capped at +10 deg) to climb through
dense regions faster. The division by `maxQ` makes the correction proportional to the relative
excess; the +10 deg cap is reached when `q >= 2 * maxQ`.

**Sideslip monitoring.** When sideslip exceeds `maxSideslip`, a warning is emitted to the
PEGAS message box (rate-limited to once per 5 seconds).

All three limit conditions (AoA, q, sideslip) generate warnings through the PEGAS message
system. Warning rate limits are 3s for AoA, 2s for q, and 5s for sideslip. Disabling a
limit via its `*Enabled` config key also suppresses the corresponding warning.

### Terminal display

The addon writes to the free area below the PEGAS table (rows 35–38). A compact status
line is always visible:

```
FAR | q=12.3 AoA=2.1 AoS=0.3 M=1.45
```

When `verboseLogging` is enabled, two additional rows appear:

```
FAR | CL=0.012 CD=0.0456 LD=0.27
FAR | Ph=1 P=72.3
```

When verbose mode is disabled, rows 36–38 are cleared once (on transition) and then left
free for other output.

### Configuration

All parameters live in the `farAscentConfig` lexicon at the top of `FARAscent.ks`.
To change defaults, edit the addon file directly. (Boot file overrides are not supported:
PEGAS's `scanAddons` unconditionally runs the addon file, which redefines the config lexicon.)

```kerboscript
GLOBAL farAscentConfig IS LEXICON(
    "enabled",                  TRUE,
    "verboseLogging",           FALSE,

    "pitchoverStartQ",          2500,
    "pitchoverTargetQ",         10000,
    "pitchRateLimit",           8.0,

    "aoaLimitingEnabled",       TRUE,
    "maxAoA",                   5.0,
    "aoaCorrectionGain",        0.5,

    "qLimitingEnabled",         TRUE,
    "maxQ",                     18000,

    "sideslipWarningEnabled",   TRUE,
    "maxSideslip",              2.0
).
```

| Key | Default | Unit | Description |
|---|---|---|---|
| `enabled` | `TRUE` | — | Master switch |
| `verboseLogging` | `FALSE` | — | Print extra FAR telemetry (CL, CD, L/D, phase, pitch) below the table |
| `pitchoverStartQ` | 2500 | Pa | Dynamic pressure at which q fraction begins rising |
| `pitchoverTargetQ` | 10000 | Pa | Dynamic pressure at which q fraction reaches 1.0 |
| `pitchRateLimit` | 8.0 | deg/s | Maximum pitch change per second (all phases) |
| `aoaLimitingEnabled` | `TRUE` | — | Enable AoA correction and warnings |
| `maxAoA` | 5.0 | deg | Angle of attack above which correction is applied |
| `aoaCorrectionGain` | 0.5 | — | Correction strength (0 = none, 1 = snap to prograde) |
| `qLimitingEnabled` | `TRUE` | — | Enable dynamic pressure limiting and warnings |
| `maxQ` | 18000 | Pa | Dynamic pressure above which the pitch is biased upward |
| `sideslipWarningEnabled` | `TRUE` | — | Enable sideslip warnings |
| `maxSideslip` | 2.0 | deg | Sideslip threshold for warning |

### Tuning notes

The defaults are balanced for stock (1x) and 2.5x scale (JNSQ, KSRSS). Fine-tuning per scale:

**Dynamic pressure thresholds (`pitchoverStartQ`, `pitchoverTargetQ`)**

These define the q window over which the pitchover ramps from vertical to prograde.
A 15-second time floor ensures completion even at negligible q, so these values mainly
set *how aggressively* q drives the ramp.

| Scale | Typical max-Q | `pitchoverStartQ` | `pitchoverTargetQ` |
|-------|--------------|-------------------|---------------------|
| Stock 1x | 5–15 kPa | 2000–3000 Pa | 6000–12000 Pa |
| 2.5x | 15–25 kPa | 3000–5000 Pa | 10000–18000 Pa |
| RSS/RO 10x | 25–45 kPa | 5000–8000 Pa | 15000–25000 Pa |

Keep `pitchoverStartQ` low enough that the rocket's q reaches it within a few seconds
of the pitchover kick. Set `pitchoverTargetQ` near the expected max-Q so the ramp
completes around the q peak.

**Dynamic pressure limit (`maxQ`)**

Set slightly below your vehicle's structural failure point. The correction adds up to
+10 degrees pitch above this limit, peaking when `q >= 2 * maxQ`.

| Scale | Typical structural limit | Suggested `maxQ` |
|-------|------------------------|-------------------|
| Stock 1x | 15–25 kPa | 15000–20000 Pa |
| 2.5x | 20–35 kPa | 18000–25000 Pa |
| RSS/RO 10x | 30–50 kPa | 25000–35000 Pa |

**Angle of attack (`maxAoA`, `aoaCorrectionGain`)**

FAR vehicles typically fail above 5–8 degrees AoA. Set `maxAoA` conservatively at 3–5
degrees. `aoaCorrectionGain = 0.5` blends the pitch halfway toward prograde; increase
to 0.7–0.8 for more aggressive correction on delicate vehicles. Set to 0 to disable
AoA correction without disabling warnings (use `aoaLimitingEnabled` for that).

**Pitch rate limit (`pitchRateLimit`)**

Controls how fast pitch can change in any direction. Lower values prevent abrupt
attitude changes that could cause high-AoA transients.

| Scale | Suggested | Rationale |
|-------|-----------|-----------|
| Stock 1x | 8–12 deg/s | Thin atmosphere, fast ascent |
| 2.5x | 5–8 deg/s | Moderate atmosphere, moderate pace |
| RSS/RO 10x | 3–5 deg/s | Thick atmosphere, slow careful ascent |

High-TWR rockets may need lower limits to avoid overshoot during the pitchover kick.
