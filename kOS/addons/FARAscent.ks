//  FARAscent.ks -- PEGAS Addon
//  Aerodynamically-informed atmospheric ascent guidance using kos-ferram (FAR).
//
//  Improves the passive (atmospheric) guidance phase by using real-time
//  aerodynamic data from Ferram Aerospace Research:
//    - Q-triggered adaptive pitchover (replaces fixed-time pitchover)
//    - Rate-limited, AoA-aware pitch ramp
//    - Dynamic pressure (max-Q) limiting
//    - Angle-of-attack safety enforcement
//    - Sideslip monitoring
//    - Real-time FAR telemetry display on PEGAS terminal
//
//  Two behavioral modes:
//    Full control    -- takes over the entire atmospheric phase when using
//                       the default gravity turn (no pitchProgram defined).
//    Corrections     -- applies AoA safety and q-limiting on top of an
//                       existing pitchProgram without replacing its schedule.
//
//  Requires: kos-ferram (https://github.com/giuliodondi/kOS-Ferram)
//  Without kos-ferram, degrades gracefully to a no-op.

GLOBAL addonName IS "FAR Ascent Guidance".
GLOBAL addonEnabled IS TRUE.

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

GLOBAL _farState IS LEXICON(
    "farAvailable",     FALSE,
    "hasPitchProgram",  FALSE,
    "phase",            0,
    "currentPitch",     90.0,
    "pitchoverStarted", FALSE,
    "wasVerbose",       FALSE,
    "lastRunTime",      0.0,
    "lastAoAWarning",   0.0,
    "lastAosWarning",   0.0,
    "lastQWarning",     0.0
).


//  --- Main hook: runs on every passive guidance tick ---
FUNCTION farAscentGuidance {
    //  Runtime kos-ferram availability check: if FAR goes away mid-flight,
    //  clear the override flag and let PEGAS passive guidance resume.
    IF NOT (ADDONS:HASADDON("FAR") AND ADDONS:FAR:AVAILABLE) {
        IF _farState["farAvailable"] {
            SET _farState["farAvailable"] TO FALSE.
            IF DEFINED farAscentOverridesPassive {
                SET farAscentOverridesPassive TO FALSE.
            }
            pushUIMessage("FAR: kos-ferram lost, reverting to PEGAS passive", 5, PRIORITY_HIGH).
        }
        RETURN.
    }
    IF NOT _farState["farAvailable"] { RETURN. }
    IF NOT farAscentConfig["enabled"] { RETURN. }

    IF TIME:SECONDS < liftoffTime:SECONDS { RETURN. }

    IF _farState["hasPitchProgram"] {
        farCorrectPitchProgram().
    } ELSE {
        farControlGravityTurn().
    }
}


//  --- FULL CONTROL mode (no pitchProgram): FAR-adaptive pitchover + gravity turn ---
FUNCTION farControlGravityTurn {
    LOCAL dynQ IS ADDONS:FAR:DYNPRES.
    LOCAL aoa IS ADDONS:FAR:AOA.
    LOCAL aos IS ADDONS:FAR:AOS.
    LOCAL mach IS ADDONS:FAR:MACH.
    LOCAL cl IS ADDONS:FAR:CL.
    LOCAL dragCoef IS ADDONS:FAR:CD.
    LOCAL now IS TIME:SECONDS.
    LOCAL elapsed IS now - liftoffTime:SECONDS.

    LOCAL az IS mission["launchAzimuth"].
    LOCAL surfAng IS 90.
    IF SHIP:VELOCITY:SURFACE:MAG > 1 {
        SET surfAng TO 90 - VANG(SHIP:UP:VECTOR, SHIP:VELOCITY:SURFACE).
    }

    farDisplay(dynQ, aoa, aos, mach, cl, dragCoef).
    farMonitor(dynQ, aoa, aos, now).

    LOCAL newPitch IS _farState["currentPitch"].
    LOCAL minTime IS controls["verticalAscentTime"].

    //  Shared locals used across phase blocks (kOS hoists IF-block LOCALS to function scope)
    LOCAL desiredPitch IS 90.0.
    LOCAL dt IS 0.02.
    LOCAL maxDelta IS 0.0.
    LOCAL delta IS 0.0.

    //  Phase 0: vertical ascent -- hold launch azimuth straight up
    IF _farState["phase"] = 0 {
        IF elapsed >= minTime {
            SET _farState["phase"] TO 1.
            SET _farState["pitchoverStarted"] TO TRUE.
            pushUIMessage("FAR: Pitchover at T+" + ROUND(elapsed, 1) + "s  q=" + ROUND(dynQ/1000, 1) + "kPa", 5, PRIORITY_NORMAL).
        }
        SET steeringVector TO aimAndRoll(HEADING(az, 90):VECTOR, steeringRoll).
    }

    //  Phase 1: adaptive pitchover ramp (q-modulated with time-based floor)
    IF _farState["phase"] = 1 {
        LOCAL qMin IS farAscentConfig["pitchoverStartQ"].
        LOCAL qMax IS farAscentConfig["pitchoverTargetQ"].
        LOCAL qFrac IS 0.0.
        IF qMax > qMin {
            SET qFrac TO (dynQ - qMin) / (qMax - qMin).
            SET qFrac TO MAX(0, MIN(1, qFrac)).
        }
        //  Time-based floor: pitchover always completes within 15 s even at zero q
        LOCAL timeFrac IS MIN((elapsed - minTime) / 15.0, 1.0).
        SET qFrac TO MAX(qFrac, timeFrac).

        //  Compute desired pitch from qFrac, then apply safety corrections.
        //  Hold the kick angle until the velocity vector drops below it,
        //  then blend smoothly toward prograde as qFrac rises.
        LOCAL kickPitch IS 90 - controls["pitchOverAngle"].
        SET desiredPitch TO kickPitch + qFrac * (surfAng - kickPitch).
        IF desiredPitch > kickPitch { SET desiredPitch TO kickPitch. }
        SET desiredPitch TO MAX(0, MIN(90, desiredPitch)).
        SET desiredPitch TO farClipAoA(desiredPitch, aoa, surfAng).
        SET desiredPitch TO farLimitQ(desiredPitch, dynQ).

        //  Rate-limit newPitch toward desiredPitch (after corrections)
        SET dt TO now - _farState["lastRunTime"].
        IF dt <= 0 { SET dt TO 0.02. }
        IF dt > 0.5 { SET dt TO 0.5. }
        SET maxDelta TO farAscentConfig["pitchRateLimit"] * dt.
        SET delta TO desiredPitch - newPitch.
        IF ABS(delta) > maxDelta {
            SET newPitch TO newPitch + maxDelta * (delta / ABS(delta)).
        } ELSE {
            SET newPitch TO desiredPitch.
        }

        IF qFrac >= 0.95 {
            SET _farState["phase"] TO 2.
            pushUIMessage("FAR: Gravity turn at T+" + ROUND(elapsed, 1) + "s", 5, PRIORITY_NORMAL).
        } ELSE IF elapsed - minTime > SETTINGS["pitchOverTimeLimit"] + 10 {
            //  Safety timeout: force transition if phase 1 stalls
            SET _farState["phase"] TO 2.
            pushUIMessage("FAR: Phase 1 timeout, forcing gravity turn", 5, PRIORITY_HIGH).
        }
    }

    //  Phase 2: gravity turn with q-limiting and AoA safety (rate-limited)
    IF _farState["phase"] = 2 {
        SET desiredPitch TO surfAng.
        SET desiredPitch TO MAX(0, MIN(90, desiredPitch)).
        SET desiredPitch TO farClipAoA(desiredPitch, aoa, surfAng).
        SET desiredPitch TO farLimitQ(desiredPitch, dynQ).

        SET dt TO now - _farState["lastRunTime"].
        IF dt <= 0 { SET dt TO 0.02. }
        IF dt > 0.5 { SET dt TO 0.5. }
        SET maxDelta TO farAscentConfig["pitchRateLimit"] * dt.
        SET delta TO desiredPitch - newPitch.
        IF ABS(delta) > maxDelta {
            SET newPitch TO newPitch + maxDelta * (delta / ABS(delta)).
        } ELSE {
            SET newPitch TO desiredPitch.
        }
    }

    //  Clamp and apply
    SET newPitch TO MAX(0, MIN(90, newPitch)).
    SET _farState["currentPitch"] TO newPitch.

    IF _farState["phase"] > 0 {
        SET steeringVector TO aimAndRoll(HEADING(az, newPitch):VECTOR, steeringRoll).
    }
    SET _farState["lastRunTime"] TO now.
}


//  --- CORRECTION mode (pitchProgram defined): apply safety modifiers on top ---
FUNCTION farCorrectPitchProgram {
    LOCAL dynQ IS ADDONS:FAR:DYNPRES.
    LOCAL aoa IS ADDONS:FAR:AOA.
    LOCAL aos IS ADDONS:FAR:AOS.
    LOCAL mach IS ADDONS:FAR:MACH.
    LOCAL cl IS ADDONS:FAR:CL.
    LOCAL dragCoef IS ADDONS:FAR:CD.
    LOCAL now IS TIME:SECONDS.

    farDisplay(dynQ, aoa, aos, mach, cl, dragCoef).
    farMonitor(dynQ, aoa, aos, now).

    LOCAL surfAng IS 90.
    IF SHIP:VELOCITY:SURFACE:MAG > 1 {
        SET surfAng TO 90 - VANG(SHIP:UP:VECTOR, SHIP:VELOCITY:SURFACE).
    }

    //  Extract current pitch from PEGAS's already-set steeringVector
    LOCAL curPitch IS 90 - VANG(SHIP:UP:VECTOR, steeringVector:VECTOR).
    SET curPitch TO MAX(0, MIN(90, curPitch)).
    SET curPitch TO farClipAoA(curPitch, aoa, surfAng).
    SET curPitch TO farLimitQ(curPitch, dynQ).

    //  Rate-limit toward corrected pitch
    LOCAL dt IS now - _farState["lastRunTime"].
    IF dt <= 0 { SET dt TO 0.02. }
    IF dt > 0.5 { SET dt TO 0.5. }
    LOCAL maxDelta IS farAscentConfig["pitchRateLimit"] * dt.
    LOCAL oldPitch IS _farState["currentPitch"].
    LOCAL delta IS curPitch - oldPitch.
    IF ABS(delta) > maxDelta {
        SET curPitch TO oldPitch + maxDelta * (delta / ABS(delta)).
    }
    SET _farState["currentPitch"] TO curPitch.

    SET curPitch TO MAX(0, MIN(90, curPitch)).
    SET steeringVector TO aimAndRoll(HEADING(mission["launchAzimuth"], curPitch):VECTOR, steeringRoll).
    SET _farState["lastRunTime"] TO now.
}


//  --- Warnings: emit PEGAS UI messages for safety-limit violations ---
FUNCTION farMonitor {
    DECLARE PARAMETER dynQ, aoa, aos, now.
    LOCAL aoaInterval IS 3.
    LOCAL aosInterval IS 5.
    LOCAL qInterval IS 2.

    IF farAscentConfig["aoaLimitingEnabled"] AND ABS(aoa) > farAscentConfig["maxAoA"] {
        IF now - _farState["lastAoAWarning"] > aoaInterval {
            pushUIMessage("FAR: AoA " + ROUND(aoa, 1) + "deg > " + ROUND(farAscentConfig["maxAoA"], 1) + "deg limit", 3, PRIORITY_HIGH).
            SET _farState["lastAoAWarning"] TO now.
        }
    }
    IF farAscentConfig["sideslipWarningEnabled"] AND ABS(aos) > farAscentConfig["maxSideslip"] {
        IF now - _farState["lastAosWarning"] > aosInterval {
            pushUIMessage("FAR: Sideslip " + ROUND(aos, 1) + "deg", 5, PRIORITY_HIGH).
            SET _farState["lastAosWarning"] TO now.
        }
    }
    IF farAscentConfig["qLimitingEnabled"] AND dynQ > farAscentConfig["maxQ"] {
        IF now - _farState["lastQWarning"] > qInterval {
            pushUIMessage("FAR: q=" + ROUND(dynQ/1000, 1) + "kPa > " + ROUND(farAscentConfig["maxQ"]/1000, 1) + "kPa limit", 3, PRIORITY_HIGH).
            SET _farState["lastQWarning"] TO now.
        }
    }
}


//  --- Safety functions: return corrected pitch value ---

FUNCTION farClipAoA {
    DECLARE PARAMETER pitch, aoa, surfAng.
    IF NOT farAscentConfig["aoaLimitingEnabled"] { RETURN pitch. }
    IF ABS(aoa) <= farAscentConfig["maxAoA"] { RETURN pitch. }
    LOCAL gain IS farAscentConfig["aoaCorrectionGain"].
    RETURN pitch - gain * aoa.
}

FUNCTION farLimitQ {
    DECLARE PARAMETER pitch, dynQ.
    IF NOT farAscentConfig["qLimitingEnabled"] { RETURN pitch. }
    IF farAscentConfig["maxQ"] <= 0 { RETURN pitch. }
    IF dynQ <= farAscentConfig["maxQ"] { RETURN pitch. }
    LOCAL excess IS (dynQ - farAscentConfig["maxQ"]) / farAscentConfig["maxQ"].
    RETURN pitch + MIN(excess * 10.0, 10.0).
}


//  --- Terminal display: FAR telemetry below PEGAS table (rows 35-38) ---
FUNCTION farDisplay {
    DECLARE PARAMETER dynQ, aoa, aos, mach, cl, dragCoef.

    LOCAL clearLine IS "                                        ".

    //  Clear compact status row (always needed)
    PRINT clearLine AT (2, 35).

    //  Verbose telemetry -- optional (rows 36-38)
    IF farAscentConfig["verboseLogging"] {
        PRINT clearLine AT (2, 36).
        PRINT clearLine AT (2, 37).
        PRINT clearLine AT (2, 38).
    } ELSE IF _farState["wasVerbose"] {
        //  Clear leftover verbose rows when transitioning from verbose to compact
        PRINT clearLine AT (2, 36).
        PRINT clearLine AT (2, 37).
        PRINT clearLine AT (2, 38).
    }
    SET _farState["wasVerbose"] TO farAscentConfig["verboseLogging"].

    //  Compact status line -- always shown (row 35)
    textPrint("FAR | q=" + ROUND(dynQ/1000, 1) + " AoA=" + ROUND(aoa, 1) + " AoS=" + ROUND(aos, 1) + " M=" + ROUND(mach, 2), 35, 2, 42, "L").

    //  Verbose telemetry -- optional (rows 36-38)
    IF farAscentConfig["verboseLogging"] {
        LOCAL ld IS 0.
        IF dragCoef > 0 { SET ld TO cl / dragCoef. }
        textPrint("FAR | CL=" + ROUND(cl, 3) + " CD=" + ROUND(dragCoef, 4) + " LD=" + ROUND(ld, 2), 36, 2, 42, "L").
        textPrint("FAR | Ph=" + _farState["phase"] + " P=" + ROUND(_farState["currentPitch"], 1), 37, 2, 42, "L").
    }
}


//  --- Initialization hook: detect kos-ferram, report mode ---
FUNCTION farAscentInit {
    //  Self-defense: ensure required PEGAS keys exist with sane defaults.
    IF NOT controls:HASKEY("verticalAscentTime") { controls:ADD("verticalAscentTime", 5). }
    IF NOT controls:HASKEY("pitchOverAngle") { controls:ADD("pitchOverAngle", 10). }
    IF NOT mission:HASKEY("launchAzimuth") { mission:ADD("launchAzimuth", 90). }
    IF NOT SETTINGS:HASKEY("pitchOverTimeLimit") { SETTINGS:ADD("pitchOverTimeLimit", 20). }

    //  This flag tells PEGAS atmospheric steering to stay idle in full-control mode.
    GLOBAL farAscentOverridesPassive IS FALSE.

    IF ADDONS:HASADDON("FAR") AND ADDONS:FAR:AVAILABLE {
        IF NOT farAscentConfig["enabled"] {
            pushUIMessage("FAR Ascent Guidance: disabled by config.", 3, PRIORITY_NORMAL).
            SET _farState["farAvailable"] TO FALSE.
            SET _farState["currentPitch"] TO 90.0.
            SET _farState["lastRunTime"] TO liftoffTime:SECONDS.
            RETURN.
        }
        SET _farState["farAvailable"] TO TRUE.
        SET _farState["hasPitchProgram"] TO controls:HASKEY("pitchProgram").
        LOCAL modeStr IS "full control".
        IF _farState["hasPitchProgram"] { SET modeStr TO "correcting pitch program". }
        pushUIMessage("FAR Ascent Guidance: active (" + modeStr + ")", 5, PRIORITY_NORMAL).
        IF NOT _farState["hasPitchProgram"] {
            SET farAscentOverridesPassive TO TRUE.
        }
    } ELSE {
        pushUIMessage("FAR Ascent Guidance: kos-ferram not available, addon inactive.", 5, PRIORITY_NORMAL).
        SET _farState["farAvailable"] TO FALSE.
    }
    SET _farState["phase"] TO 0.
    SET _farState["pitchoverStarted"] TO FALSE.
    SET _farState["wasVerbose"] TO FALSE.
    SET _farState["currentPitch"] TO 90.0.
    SET _farState["lastRunTime"] TO liftoffTime:SECONDS.
}


//  --- Register hooks ---
registerHook(farAscentInit@, "init").
registerHook(farAscentGuidance@, "passivePost").
