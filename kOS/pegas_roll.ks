@CLOBBERBUILTINS OFF.

// Roll control library.

// Build a roll reference from the launch plane. At zero degrees, the vehicle's
// top points uprange when vertical and remains in the launch plane afterward.
FUNCTION launchRelativeRollVector {
	DECLARE PARAMETER aimVec.
	DECLARE PARAMETER angle.

	LOCAL aimUnit IS aimVec:NORMALIZED.
	LOCAL surfaceUp IS UP:VECTOR:NORMALIZED.
	LOCAL downrange IS HEADING(mission["launchAzimuth"], 0):VECTOR:NORMALIZED.
	LOCAL crossTrack IS VCRS(surfaceUp, downrange).
	IF crossTrack:MAG < 0.001 {
		RETURN SHIP:FACING:TOPVECTOR.
	}
	SET crossTrack TO crossTrack:NORMALIZED.

	// Select the cross-track sign that makes zero roll point uprange at liftoff.
	IF VDOT(VCRS(crossTrack, surfaceUp), downrange) > 0 {
		SET crossTrack TO -crossTrack.
	}

	LOCAL zeroRollTop IS VCRS(crossTrack, aimUnit).
	IF zeroRollTop:MAG < 0.001 {
		// This only occurs if guidance aims cross-track; keep the frame tied uprange.
		SET zeroRollTop TO -downrange + aimUnit*VDOT(downrange, aimUnit).
	}
	IF zeroRollTop:MAG < 0.001 {
		SET zeroRollTop TO SHIP:FACING:TOPVECTOR.
	}

	RETURN rodrigues(zeroRollTop:NORMALIZED, aimUnit, -angle).
}

// Measure the current vehicle roll in the launch-relative frame.
FUNCTION currentLaunchRelativeRoll {
	DECLARE PARAMETER aimVec.

	LOCAL aimUnit IS aimVec:NORMALIZED.
	LOCAL zeroRollTop IS launchRelativeRollVector(aimVec, 0).
	SET zeroRollTop TO zeroRollTop - aimUnit*VDOT(zeroRollTop, aimUnit).
	LOCAL currentTop IS SHIP:FACING:TOPVECTOR - aimUnit*VDOT(SHIP:FACING:TOPVECTOR, aimUnit).
	IF zeroRollTop:MAG < 0.001 OR currentTop:MAG < 0.001 { RETURN 0. }

	SET zeroRollTop TO zeroRollTop:NORMALIZED.
	SET currentTop TO currentTop:NORMALIZED.
	LOCAL angle IS VANG(zeroRollTop, currentTop).
	IF VDOT(VCRS(zeroRollTop, currentTop), aimUnit) > 0 {
		SET angle TO -angle.
	}
	SET angle TO MOD(angle, 360).
	IF angle < 0 { SET angle TO angle + 360. }
	RETURN angle.
}

// Set a new roll target. Sequence events use this too, so they supersede a pending program.
FUNCTION commandRoll {
	DECLARE PARAMETER angle.

	SET steeringRoll TO MOD(angle, 360).
	IF steeringRoll < 0 { SET steeringRoll TO steeringRoll + 360. }
	SET rollControlActive TO TRUE.
	SET rollProgramComplete TO TRUE.
	SET rollTransitionStarted TO FALSE.
}

// Activate the configured roll command once its post-liftoff time is reached.
FUNCTION rollProgramControl {
	IF rollProgramComplete OR NOT controls:HASKEY("rollTime") { RETURN. }
	IF NOT liftoffOccurred { RETURN. }
	IF TIME:SECONDS < liftoffTime:SECONDS + controls["rollTime"] { RETURN. }

	commandRoll(controls["rollAngle"]).
	pushUIMessage("Rolling to " + steeringRoll + " degrees.").
}

// Add a visible flight-plan marker without duplicating roll execution.
FUNCTION spawnRollProgramMessage {
	IF NOT controls:HASKEY("rollTime") { RETURN. }

	insertEvent(LEXICON(
		"time", controls["rollTime"],
		"type", "print",
		"fpMessage", "ROLL PROGRAM: " + controls["rollAngle"] + " degrees",
		"isHidden", FALSE
	)).
}

// Add roll to a pitch/yaw aim vector, blending from the current orientation when activated.
FUNCTION steerWithRoll {
	DECLARE PARAMETER aimVec.
	IF aimVec:MAG < 0.001 { RETURN SHIP:FACING. }

	IF NOT rollControlActive {
		RETURN LOOKDIRUP(aimVec, SHIP:FACING:TOPVECTOR).
	}

	IF NOT rollTransitionStarted {
		SET rollTransitionStartAngle TO currentLaunchRelativeRoll(aimVec).
		SET rollTransitionStartTime TO TIME:SECONDS.
		SET rollTransitionStarted TO TRUE.
	}

	LOCAL commandedRoll IS steeringRoll.
	IF SETTINGS["rollTransitionTime"] > 0 {
		LOCAL transitionProgress IS (TIME:SECONDS - rollTransitionStartTime) / SETTINGS["rollTransitionTime"].
		IF transitionProgress < 1 {
			LOCAL rollDelta IS steeringRoll - rollTransitionStartAngle.
			IF rollDelta > 180 { SET rollDelta TO rollDelta - 360. }
			IF rollDelta < -180 { SET rollDelta TO rollDelta + 360. }
			SET commandedRoll TO rollTransitionStartAngle + rollDelta*transitionProgress.
		}
	}
	LOCAL targetTop IS launchRelativeRollVector(aimVec, commandedRoll).
	RETURN LOOKDIRUP(aimVec, targetTop).
}

// Terminal guidance cannot execute a pending roll because it must arrest all rotation.
FUNCTION closeRollProgram {
	IF NOT rollProgramComplete AND controls:HASKEY("rollTime") {
		SET rollProgramComplete TO TRUE.
		pushUIMessage("Roll time was not reached before terminal guidance; roll skipped.", 5, PRIORITY_HIGH).
	}
}
