@CLOBBERBUILTINS OFF.

// Contingency detection and guidance.

FUNCTION abortConfigDefault {
	DECLARE PARAMETER key.
	DECLARE PARAMETER value.
	IF NOT abortConfig:HASKEY(key) { abortConfig:ADD(key, value). }
}

FUNCTION initAbortSystem {
	GLOBAL abortEnabled IS controls:HASKEY("abort").
	GLOBAL abortConfig IS LEXICON().
	IF abortEnabled {
		SET abortConfig TO controls["abort"].
		abortConfigDefault("enabled", TRUE).
		SET abortEnabled TO abortConfig["enabled"].
	} ELSE {
		abortConfig:ADD("enabled", FALSE).
	}
	abortConfigDefault("minLaunchTWR", 1.2).
	abortConfigDefault("launchTimeout", 2.0).
	abortConfigDefault("engineHealthThreshold", 0.95).
	abortConfigDefault("engineFailureDelay", 0.5).
	abortConfigDefault("thrustLossDetectThrottle", 0.05).
	abortConfigDefault("escapeSystem", "auto").
	abortConfigDefault("lesPartTag", "").
	abortConfigDefault("escapeGuidanceTime", 5.0).
	abortConfigDefault("escapeMinProgradeSpeed", 10.0).
	abortConfigDefault("rudEnabled", TRUE).
	abortConfigDefault("rudMinLostParts", 2).
	abortConfigDefault("rudMinDryMassFraction", 0.01).
	abortConfigDefault("rudMaxAngularRate", 15.0).
	abortConfigDefault("criticalPartTag", "").
	abortConfigDefault("spinEnabled", TRUE).
	abortConfigDefault("spinMaxAngularRate", 30.0).
	abortConfigDefault("spinFailureDelay", 1.0).
	abortConfigDefault("atoEnabled", TRUE).
	abortConfigDefault("atoReserve", 250.0).
	abortConfigDefault("orbitMargin", 10.0).
	abortConfigDefault("atoInfeasibleDelay", 1.0).
	abortConfigDefault("passiveAtoStage", -1).
	abortConfigDefault("atoPreserveMissionPlane", FALSE).

	LOCAL configuredEscape IS abortConfig["escapeSystem"]:TOLOWER.
	LOCAL hasCrew IS SHIP:CREW():LENGTH > 0.
	LOCAL selectedEscape IS configuredEscape.
	IF configuredEscape = "auto" {
		SET selectedEscape TO CHOOSE "crew" IF hasCrew ELSE "none".
	} ELSE IF configuredEscape = "crew" AND NOT hasCrew {
		SET selectedEscape TO "none".
	} ELSE IF LIST("crew", "payload", "none"):FIND(configuredEscape) < 0 {
		PRINT "Unknown escapeSystem '" + configuredEscape + "'; disabling escape guidance.".
		SET selectedEscape TO "none".
	}
	IF NOT abortEnabled { SET selectedEscape TO "none". }

	LOCAL lesTracked IS FALSE.
	IF abortEnabled AND abortConfig["lesPartTag"] <> "" {
		SET lesTracked TO SHIP:PARTSTAGGED(abortConfig["lesPartTag"]):LENGTH > 0.
	}

	GLOBAL abortState IS LEXICON(
		"mode", "nominal",
		"reason", "",
		"source", "",
		"manual", FALSE,
		"guidanceMode", "escape",
		"escapeSystem", selectedEscape,
		"escapeAvailable", selectedEscape <> "none",
		"lesTracked", lesTracked,
		"lesJettisoned", FALSE,
		"atoFailures", 0,
		"atoFailureSince", -1,
		"pendingStageOrdinal", -1,
		"emergencyStage", -1
	).
	GLOBAL abort_stagingGeneration IS 0.
	GLOBAL abort_structureChangeUntil IS 0.
	GLOBAL abort_engineIds IS LIST().
	GLOBAL abort_engineThrusts IS LIST().
	GLOBAL abort_engineFailureSince IS -1.
	GLOBAL abort_engineRecacheTime IS TIME:SECONDS.
	GLOBAL abort_engineNeedsRecache IS FALSE.
	GLOBAL abort_engineExpectedBy IS -1.
	GLOBAL abort_spinFailureSince IS -1.
	GLOBAL abort_liftoffGateStarted IS FALSE.
	GLOBAL abort_liftoffGateDeadline IS 0.
	GLOBAL abort_launchPadMass IS 0.
	LIST PARTS IN abort_parts.
	FOR part IN abort_parts {
		IF part:NAME:STARTSWITH("AM_MLP_") OR part:NAME:STARTSWITH("AM.MLP.") {
			SET abort_launchPadMass TO abort_launchPadMass + part:MASS.
		}
	}
	GLOBAL abort_escapeFacing IS LOOKDIRUP(SHIP:FACING:FOREVECTOR, SHIP:FACING:TOPVECTOR).

	IF abortEnabled { snapshotRudParts(). }
}

FUNCTION localTWR {
	LOCAL radius IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
	LOCAL localGravity IS SHIP:BODY:MU / radius^2.
	LOCAL vehicleMass IS MAX(0.001, SHIP:MASS - abort_launchPadMass).
	RETURN SHIP:THRUST / (vehicleMass * localGravity).
}

FUNCTION authorizeStructureChange {
	DECLARE PARAMETER duration IS 1.0.
	SET abort_structureChangeUntil TO MAX(abort_structureChangeUntil, TIME:SECONDS + duration).
}

FUNCTION markEscapeUnavailable {
	SET abortState["escapeAvailable"] TO FALSE.
}

FUNCTION updateLesState {
	IF abortEnabled AND abortState["lesTracked"] AND NOT abortState["lesJettisoned"] AND
		SHIP:PARTSTAGGED(abortConfig["lesPartTag"]):LENGTH = 0 {
		SET abortState["lesJettisoned"] TO TRUE.
		markEscapeUnavailable().
	}
}

FUNCTION snapshotRudParts {
	LIST PARTS IN currentParts.
	IF NOT (DEFINED rud_partData) {
		GLOBAL rud_partData IS LEXICON().
		GLOBAL rud_partCount IS 0.
		GLOBAL rud_totalDryMass IS 0.
	} ELSE {
		SET rud_partData TO LEXICON().
	}
	SET rud_partCount TO currentParts:LENGTH.
	SET rud_totalDryMass TO 0.
	FOR part IN currentParts {
		LOCAL isEngine IS FALSE.
		FOR moduleName IN part:MODULES {
			IF moduleName:CONTAINS("Engine") { SET isEngine TO TRUE. }
		}
		LOCAL isCritical IS abortConfig["criticalPartTag"] <> "" AND part:TAG = abortConfig["criticalPartTag"].
		rud_partData:ADD(part:UID, LEXICON(
			"title", part:TITLE,
			"dryMass", part:DRYMASS,
			"engine", isEngine,
			"critical", isCritical
		)).
		SET rud_totalDryMass TO rud_totalDryMass + part:DRYMASS.
	}
}

FUNCTION rudWatchdog {
	IF NOT abortEnabled OR NOT abortConfig["rudEnabled"] OR
		abortState["mode"] = "escape" OR abortState["mode"] = "escaped" { RETURN. }

	LIST PARTS IN currentParts.
	IF currentParts:LENGTH >= rud_partCount {
		IF currentParts:LENGTH > rud_partCount { snapshotRudParts(). }
		RETURN.
	}

	IF TIME:SECONDS <= abort_structureChangeUntil {
		snapshotRudParts().
		RETURN.
	}

	LOCAL currentIds IS LEXICON().
	FOR part IN currentParts { currentIds:ADD(part:UID, TRUE). }
	LOCAL lostCount IS 0.
	LOCAL lostDryMass IS 0.
	LOCAL lostEngine IS FALSE.
	LOCAL lostCritical IS FALSE.
	LOCAL lostNames IS "".
	FOR partId IN rud_partData:KEYS() {
		IF NOT currentIds:HASKEY(partId) {
			LOCAL lostPart IS rud_partData[partId].
			SET lostCount TO lostCount + 1.
			SET lostDryMass TO lostDryMass + lostPart["dryMass"].
			SET lostEngine TO lostEngine OR lostPart["engine"].
			SET lostCritical TO lostCritical OR lostPart["critical"].
			SET lostNames TO lostNames + lostPart["title"] + "; ".
		}
	}

	LOCAL lostMassFraction IS 0.
	IF rud_totalDryMass > 0 { SET lostMassFraction TO lostDryMass / rud_totalDryMass. }
	LOCAL angularRate IS SHIP:ANGULARVEL:MAG * CONSTANT:RADTODEG.
	LOCAL excessiveRotation IS angularRate >= abortConfig["rudMaxAngularRate"].
	LOCAL corroborated IS
		lostCount >= abortConfig["rudMinLostParts"] OR
		lostMassFraction >= abortConfig["rudMinDryMassFraction"] OR
		lostEngine OR lostCritical OR excessiveRotation.

	IF corroborated {
		IF EXISTS("rud.log") { DELETEPATH("rud.log"). }
		LOG "RUD detected at T+" + (TIME:SECONDS - liftoffTime:SECONDS) TO "rud.log".
		LOG "Lost parts: " + lostNames TO "rud.log".
		LOG "Lost dry-mass fraction: " + lostMassFraction TO "rud.log".
		LOG "Angular rate (deg/s): " + angularRate TO "rud.log".
		requestEscape("RAPID UNSCHEDULED DISASSEMBLY", "rud", FALSE).
	} ELSE {
		pushUIMessage("Unconfirmed structural anomaly", 5, PRIORITY_HIGH).
		snapshotRudParts().
	}
}

FUNCTION spinWatchdog {
	IF NOT abortEnabled OR NOT abortConfig["spinEnabled"] OR
		abortState["mode"] = "escape" OR abortState["mode"] = "escaped" {
		SET abort_spinFailureSince TO -1.
		RETURN.
	}

	IF NOT liftoffOccurred OR abortVehicleGrounded() OR TIME:SECONDS <= abort_structureChangeUntil {
		SET abort_spinFailureSince TO -1.
		RETURN.
	}

	// Ignore the commanded transition itself, then resume monitoring for a persistent tumble.
	IF rollTransitionStarted {
		LOCAL rollIgnoreDuration IS MAX(SETTINGS["rollTransitionTime"], abortConfig["spinFailureDelay"]).
		IF TIME:SECONDS < rollTransitionStartTime + rollIgnoreDuration {
			SET abort_spinFailureSince TO -1.
			RETURN.
		}
	}

	LOCAL angularRate IS SHIP:ANGULARVEL:MAG * CONSTANT:RADTODEG.
	IF angularRate >= abortConfig["spinMaxAngularRate"] {
		IF abort_spinFailureSince < 0 { SET abort_spinFailureSince TO TIME:SECONDS. }
		IF TIME:SECONDS >= abort_spinFailureSince + abortConfig["spinFailureDelay"] {
			requestEscape("EXCESSIVE VEHICLE ROTATION", "spin", FALSE).
		}
	} ELSE {
		SET abort_spinFailureSince TO -1.
	}
}

FUNCTION scheduleEngineBaselineRecache {
	DECLARE PARAMETER delay IS 2.0.
	IF NOT abortEnabled { RETURN. }
	SET abort_engineFailureSince TO -1.
	SET abort_engineRecacheTime TO MAX(abort_engineRecacheTime, TIME:SECONDS + delay).
	SET abort_engineNeedsRecache TO TRUE.
}

FUNCTION cacheEngineBaseline {
	DECLARE PARAMETER availableOnly IS FALSE.
	SET abort_engineIds TO LIST().
	SET abort_engineThrusts TO LIST().
	LIST ENGINES IN allEngines.
	FOR engine IN allEngines {
		IF engine:IGNITION AND engine:POSSIBLETHRUSTAT(0) > 0 AND
			(NOT availableOnly OR engine:AVAILABLETHRUSTAT(0) > 0) {
			abort_engineIds:ADD(engine:UID).
			abort_engineThrusts:ADD(engine:POSSIBLETHRUSTAT(0)).
		}
	}
	SET abort_engineFailureSince TO -1.
	SET abort_engineExpectedBy TO -1.
	SET abort_engineNeedsRecache TO FALSE.
	SET abort_engineRecacheTime TO TIME:SECONDS.
}

FUNCTION currentEngineHealth {
	IF abort_engineIds:LENGTH = 0 { RETURN 1.0. }
	LIST ENGINES IN allEngines.
	LOCAL expectedThrust IS 0.
	LOCAL matchedThrust IS 0.
	FROM { LOCAL i IS 0. } UNTIL i >= abort_engineIds:LENGTH STEP { SET i TO i + 1. } DO {
		SET expectedThrust TO expectedThrust + abort_engineThrusts[i].
		FOR engine IN allEngines {
			IF engine:UID = abort_engineIds[i] {
				SET matchedThrust TO matchedThrust + engine:AVAILABLETHRUSTAT(0).
				BREAK.
			}
		}
	}
	IF expectedThrust <= 0 { RETURN 1.0. }
	RETURN matchedThrust / expectedThrust.
}

FUNCTION engineFailureWatchdog {
	IF NOT abortEnabled { RETURN. }
	IF controls:HASKEY("disableThrustWatchdog") AND controls["disableThrustWatchdog"] { RETURN. }
	IF abortState["mode"] = "escape" OR abortState["mode"] = "escaped" { RETURN. }

	IF stagingInProgress {
		scheduleEngineBaselineRecache().
		RETURN.
	}
	IF throttleSetting <= abortConfig["thrustLossDetectThrottle"] {
		SET abort_engineFailureSince TO -1.
		RETURN.
	}
	IF TIME:SECONDS < abort_engineRecacheTime { RETURN. }
	IF abort_engineExpectedBy >= 0 AND TIME:SECONDS >= abort_engineExpectedBy {
		SET abort_engineExpectedBy TO -1.
		IF throttleSetting > abortConfig["thrustLossDetectThrottle"] AND SHIP:THRUST < 0.001 {
			handleVehicleFailure("ENGINE IGNITION FAILURE", "engine", 0).
			RETURN.
		}
		cacheEngineBaseline().
		SET abort_engineNeedsRecache TO FALSE.
		RETURN.
	}
	IF abort_engineNeedsRecache {
		cacheEngineBaseline().
		SET abort_engineNeedsRecache TO FALSE.
		RETURN.
	}
	IF abort_engineIds:LENGTH = 0 {
		IF SHIP:AVAILABLETHRUST > 0 { cacheEngineBaseline(). }
		RETURN.
	}

	LOCAL health IS currentEngineHealth().
	LOCAL isPrelaunch IS SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED".
	LOCAL completeThrustLoss IS NOT isPrelaunch AND
		throttleSetting > abortConfig["thrustLossDetectThrottle"] AND SHIP:THRUST < 0.001.
	IF completeThrustLoss { SET health TO 0. }
	IF health < abortConfig["engineHealthThreshold"] OR completeThrustLoss {
		IF abort_engineFailureSince < 0 { SET abort_engineFailureSince TO TIME:SECONDS. }
		IF TIME:SECONDS >= abort_engineFailureSince + abortConfig["engineFailureDelay"] {
			IF isPrelaunch {
				requestPadShutdown().
			} ELSE {
				handleVehicleFailure("ENGINE MALFUNCTION", "engine", health).
			}
		}
	} ELSE {
		SET abort_engineFailureSince TO -1.
	}
}

FUNCTION abortSafeAltitude {
	LOCAL safeAltitude IS abortConfig["orbitMargin"].
	IF SHIP:BODY:ATM:EXISTS {
		SET safeAltitude TO SHIP:BODY:ATM:HEIGHT / 1000 + abortConfig["orbitMargin"].
	}
	RETURN safeAltitude.
}

FUNCTION setAbortOrbitTarget {
	LOCAL safeAltitude IS abortSafeAltitude().
	LOCAL achievedApoapsis IS MAX(safeAltitude, SHIP:ORBIT:APOAPSIS / 1000).
	SET mission["periapsis"] TO safeAltitude.
	SET mission["apoapsis"] TO achievedApoapsis.
	SET mission["altitude"] TO achievedApoapsis.
	IF NOT abortConfig["atoPreserveMissionPlane"] {
		SET mission["inclination"] TO SHIP:ORBIT:INCLINATION.
		SET mission["LAN"] TO SHIP:ORBIT:LAN.
	}
	SET upfgTarget TO targetSetup().
}

FUNCTION atoRequiredDeltaV {
	LOCAL state IS acquireState().
	LOCAL targetNormalVector IS targetNormal(mission["inclination"], mission["LAN"]).
	LOCAL desiredRadius IS rodrigues(state["radius"], -targetNormalVector, 20):NORMALIZED * upfgTarget["radius"].
	LOCAL desiredVelocity IS upfgTarget["velocity"] * VCRS(-targetNormalVector, desiredRadius):NORMALIZED.
	RETURN (desiredVelocity - state["velocity"]):MAG + abortConfig["atoReserve"].
}

FUNCTION estimateRemainingDeltaV {
	DECLARE PARAMETER startStage IS upfgStage.
	DECLARE PARAMETER useCurrentState IS TRUE.
	LOCAL availableDeltaV IS 0.
	LOCAL firstFutureStage IS startStage.
	IF useCurrentState {
		LOCAL currentMass IS SHIP:MASS * 1000.
		LOCAL elapsedBurn IS MAX(0, upfgInternal["tb"]).
		LOCAL currentEngineData IS getThrust(vehicle[startStage]["engines"]).
		LOCAL remainingBurn IS MAX(0, vehicle[startStage]["maxT"] - elapsedBurn).
		LOCAL currentDryMass IS vehicle[startStage]["massTotal"] - vehicle[startStage]["massFuel"].
		LOCAL massBasedFuel IS MAX(0, currentMass - currentDryMass).
		LOCAL remainingFuel IS MIN(vehicle[startStage]["massFuel"], massBasedFuel).
		IF vehicle[startStage]["mode"] = 1 {
			SET remainingFuel TO MIN(remainingFuel, currentEngineData[1] * remainingBurn).
		}
		SET remainingFuel TO MIN(currentMass * 0.999, remainingFuel).
		IF remainingFuel > 0 AND currentMass > remainingFuel {
			SET availableDeltaV TO currentEngineData[2] * CONSTANT:g0 * LN(currentMass / (currentMass - remainingFuel)).
		}
		SET firstFutureStage TO startStage + 1.
	}
	FROM { LOCAL i IS firstFutureStage. } UNTIL i >= vehicle:LENGTH STEP { SET i TO i + 1. } DO {
		LOCAL engineData IS getThrust(vehicle[i]["engines"]).
		IF engineData[1] > 0 AND vehicle[i]["massTotal"] > vehicle[i]["massFuel"] {
			SET availableDeltaV TO availableDeltaV + engineData[2] * CONSTANT:g0 *
				LN(vehicle[i]["massTotal"] / (vehicle[i]["massTotal"] - vehicle[i]["massFuel"])).
		}
	}
	RETURN availableDeltaV.
}

FUNCTION nextPhysicalStage {
	DECLARE PARAMETER currentStage.
	FROM { LOCAL i IS currentStage + 1. } UNTIL i >= vehicle:LENGTH STEP { SET i TO i + 1. } DO {
		IF NOT vehicle[i]["isVirtualStage"] { RETURN i. }
	}
	RETURN -1.
}

FUNCTION physicalStageByOrdinal {
	DECLARE PARAMETER ordinal.
	LOCAL physicalIndex IS 0.
	FROM { LOCAL i IS 0. } UNTIL i >= vehicle:LENGTH STEP { SET i TO i + 1. } DO {
		IF NOT vehicle[i]["isVirtualStage"] {
			IF physicalIndex = ordinal { RETURN i. }
			SET physicalIndex TO physicalIndex + 1.
		}
	}
	RETURN -1.
}

FUNCTION resetAtoGuidance {
	DECLARE PARAMETER elapsedBurn IS 0.
	SET upfgState TO acquireState().
	SET upfgInternal TO setupUPFG().
	SET upfgInternal["tb"] TO elapsedBurn.
	SET upfgConverged TO FALSE.
	SET upfgEngaged TO FALSE.
	IF DEFINED usc_convergeFlags { usc_convergeFlags:CLEAR(). }
	IF DEFINED usc_lastSeenStage { SET usc_lastSeenStage TO -999. }
}

FUNCTION getAtoStageDelays {
	DECLARE PARAMETER stageIndex.
	IF NOT vehicle[stageIndex]:HASKEY("atoStaging") { RETURN getStageDelays(vehicle[stageIndex]). }
	RETURN getStagingDelays(vehicle[stageIndex], vehicle[stageIndex]["atoStaging"]).
}

FUNCTION atoStageCanActivate {
	DECLARE PARAMETER stageIndex.
	LOCAL staging IS vehicle[stageIndex]["staging"].
	IF vehicle[stageIndex]:HASKEY("atoStaging") { SET staging TO vehicle[stageIndex]["atoStaging"]. }
	RETURN staging["ignition"].
}

FUNCTION applyDegradedStageModel {
	DECLARE PARAMETER health.
	SET health TO MIN(1, MAX(0.01, health)).
	LOCAL elapsedBurn IS MAX(0, upfgInternal["tb"]).
	LOCAL stageIndex IS upfgStage.
	UNTIL stageIndex >= vehicle:LENGTH {
		LOCAL stageElapsed IS CHOOSE elapsedBurn IF stageIndex = upfgStage ELSE 0.
		LOCAL oldData IS getThrust(vehicle[stageIndex]["engines"]).
		LOCAL oldMaxT IS vehicle[stageIndex]["maxT"].
		LOCAL remainingBurn IS MAX(0, oldMaxT - stageElapsed).
		LOCAL remainingFuel IS vehicle[stageIndex]["massFuel"].
		IF stageIndex = upfgStage {
			LOCAL currentDryMass IS vehicle[stageIndex]["massTotal"] - vehicle[stageIndex]["massFuel"].
			SET remainingFuel TO MIN(remainingFuel, MAX(0, SHIP:MASS * 1000 - currentDryMass)).
			IF vehicle[stageIndex]["mode"] = 1 {
				SET remainingFuel TO MIN(remainingFuel, oldData[1] * remainingBurn).
			}
		}
		LOCAL degradedEngines IS LIST().
		FOR engine IN vehicle[stageIndex]["engines"] {
			LOCAL degradedEngine IS engine:COPY().
			SET degradedEngine["flow"] TO degradedEngine["flow"] * health.
			IF degradedEngine:HASKEY("thrust") { SET degradedEngine["thrust"] TO degradedEngine["thrust"] * health. }
			degradedEngines:ADD(degradedEngine).
		}
		SET vehicle[stageIndex]["engines"] TO degradedEngines.
		LOCAL degradedData IS getThrust(degradedEngines).
		IF vehicle[stageIndex]["mode"] = 2 {
			LOCAL stageMass IS CHOOSE SHIP:MASS * 1000 IF stageIndex = upfgStage ELSE vehicle[stageIndex]["massTotal"].
			IF degradedData[0] / stageMass < vehicle[stageIndex]["gLim"] * CONSTANT:g0 {
				SET vehicle[stageIndex]["mode"] TO 1.
			}
		}
		IF vehicle[stageIndex]["mode"] = 1 {
			SET vehicle[stageIndex]["maxT"] TO stageElapsed + remainingFuel / degradedData[1].
		} ELSE {
			LOCAL remainingStage IS vehicle[stageIndex]:COPY().
			SET remainingStage["massFuel"] TO remainingFuel.
			IF stageIndex = upfgStage { SET remainingStage["massTotal"] TO SHIP:MASS * 1000. }
			SET vehicle[stageIndex]["maxT"] TO stageElapsed + constAccBurnTime(remainingStage).
		}
		IF NOT vehicle[stageIndex]["followedByVirtual"] { BREAK. }
		SET stageIndex TO stageIndex + 1.
	}
	LOCAL newRemainingBurn IS MAX(0, vehicle[upfgStage]["maxT"] - elapsedBurn).
	rescheduleStagingEvents(upfgStage, newRemainingBurn).
	resetAtoGuidance(elapsedBurn).
	cacheEngineBaseline(TRUE).
}

FUNCTION activateEmergencyAtoStage {
	DECLARE PARAMETER stageIndex.
	IF stageIndex < 0 OR stageIndex >= vehicle:LENGTH { RETURN FALSE. }
	IF vehicle[stageIndex]["isVirtualStage"] { RETURN FALSE. }
	IF NOT atoStageCanActivate(stageIndex) { RETURN FALSE. }
	SET abort_stagingGeneration TO abort_stagingGeneration + 1.
	SET abortState["emergencyStage"] TO stageIndex.
	SET throttleSetting TO 0.
	SET throttleDisplay TO 0.
	SET upfgStage TO stageIndex.
	SET stagingInProgress TO TRUE.
	SET prestageHold TO FALSE.
	SET poststageHold TO FALSE.
	SET activeGuidanceMode TO TRUE.
	rescheduleStagingEvents(stageIndex, getAtoStageDelays(stageIndex) + vehicle[stageIndex]["maxT"], stageIndex - 1).
	resetAtoGuidance().
	internalEvent_staging().
	RETURN TRUE.
}

FUNCTION activatePendingAtoStage {
	IF abortState["pendingStageOrdinal"] < 0 { RETURN FALSE. }
	LOCAL stageIndex IS physicalStageByOrdinal(abortState["pendingStageOrdinal"]).
	SET abortState["pendingStageOrdinal"] TO -1.
	RETURN activateEmergencyAtoStage(stageIndex).
}

FUNCTION attemptAbortToOrbit {
	DECLARE PARAMETER health.
	IF NOT abortEnabled OR NOT abortConfig["atoEnabled"] OR
		stagingInProgress OR NOT liftoffOccurred { RETURN FALSE. }
	IF flightPhase = "terminal" {
		IF SHIP:ORBIT:PERIAPSIS / 1000 >= abortSafeAltitude() {
			setAbortOrbitTarget().
			SET abortState["mode"] TO "ato".
			SET abortState["reason"] TO "ENGINE MALFUNCTION".
			SET abortState["source"] TO "engine".
			SET throttleSetting TO 0.
			SET throttleDisplay TO 0.
			cacheEngineBaseline(TRUE).
			pushUIMessage("ENGINE FAILURE - SAFE ORBIT ACHIEVED", 10, PRIORITY_CRITICAL).
			RETURN TRUE.
		}
		RETURN FALSE.
	}

	LOCAL savedMission IS mission:COPY().
	LOCAL savedTarget IS upfgTarget:COPY().
	setAbortOrbitTarget().
	LOCAL requiredDeltaV IS atoRequiredDeltaV().
	LOCAL selectedPlan IS "none".
	LOCAL selectedStage IS -1.

	IF activeGuidanceMode AND upfgStage >= 0 {
		LOCAL currentData IS getThrust(vehicle[upfgStage]["engines"]).
		LOCAL radius IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
		LOCAL localGravity IS SHIP:BODY:MU / radius^2.
		IF health > 0 AND currentData[0] * health > 0 AND
			estimateRemainingDeltaV(upfgStage, TRUE) >= requiredDeltaV {
			SET selectedPlan TO "continue".
		} ELSE {
			SET selectedStage TO nextPhysicalStage(upfgStage).
			IF selectedStage >= 0 AND atoStageCanActivate(selectedStage) {
				LOCAL stagingLoss IS localGravity * getAtoStageDelays(selectedStage).
				IF estimateRemainingDeltaV(selectedStage, FALSE) >= requiredDeltaV + stagingLoss {
					SET selectedPlan TO "stage".
				}
			}
		}
	} ELSE {
		LOCAL stageOrdinal IS abortConfig["passiveAtoStage"].
		IF stageOrdinal < 0 {
			SET stageOrdinal TO CHOOSE 0 IF atoStageCanActivate(0) ELSE 1.
		}
		IF stageOrdinal < vehicle:LENGTH AND atoStageCanActivate(stageOrdinal) {
			LOCAL passiveGravity IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
			LOCAL passiveLoss IS passiveGravity * getAtoStageDelays(stageOrdinal).
			IF estimateRemainingDeltaV(stageOrdinal, FALSE) >= requiredDeltaV + passiveLoss {
				SET selectedPlan TO "pending".
				SET selectedStage TO stageOrdinal.
			}
		}
	}

	IF selectedPlan = "none" {
		SET mission TO savedMission.
		SET upfgTarget TO savedTarget.
		RETURN FALSE.
	}

	SET abortState["mode"] TO "ato".
	SET abortState["reason"] TO "ENGINE MALFUNCTION".
	SET abortState["source"] TO "engine".
	SET abortState["atoFailures"] TO 0.
	SET abortState["atoFailureSince"] TO -1.
	IF selectedPlan = "continue" {
		SET abortState["emergencyStage"] TO -1.
		applyDegradedStageModel(health).
	} ELSE IF selectedPlan = "stage" {
		activateEmergencyAtoStage(selectedStage).
	} ELSE {
		SET abortState["pendingStageOrdinal"] TO selectedStage.
	}
	pushUIMessage("ENGINE FAILURE - ABORT TO ORBIT", 10, PRIORITY_CRITICAL).
	callHooks("abortToOrbit").
	RETURN TRUE.
}

FUNCTION handleVehicleFailure {
	DECLARE PARAMETER reason.
	DECLARE PARAMETER source.
	DECLARE PARAMETER health IS 0.
	IF source = "engine" {
		IF attemptAbortToOrbit(health) { RETURN. }
		updateLesState().
		IF abortState["lesJettisoned"] {
			requestEscape(reason, source, FALSE, "ballistic").
			RETURN.
		}
	}
	requestEscape(reason, source, FALSE).
}

FUNCTION requestEscape {
	DECLARE PARAMETER reason.
	DECLARE PARAMETER source.
	DECLARE PARAMETER isManual IS FALSE.
	DECLARE PARAMETER guidanceMode IS "escape".
	IF NOT abortEnabled { RETURN. }
	IF abortState["mode"] = "escape" OR abortState["mode"] = "escaped" { RETURN. }
	SET abortState["mode"] TO "escape".
	SET abortState["reason"] TO reason.
	SET abortState["source"] TO source.
	SET abortState["manual"] TO isManual.
	SET abortState["guidanceMode"] TO guidanceMode.
	SET abort_escapeFacing TO LOOKDIRUP(SHIP:FACING:FOREVECTOR, SHIP:FACING:TOPVECTOR).
	SET throttleSetting TO 0.
	SET throttleDisplay TO 0.
	SET abort_stagingGeneration TO abort_stagingGeneration + 1.
	IF NOT ABORT { ABORT ON. }
	RCS ON.
	LOCAL abortLabel IS CHOOSE "BALLISTIC ABORT" IF guidanceMode = "ballistic" ELSE "ESCAPE".
	pushUIMessage(reason + " - " + abortLabel, 10, PRIORITY_CRITICAL).
	callHooks("abortEscape").
}

FUNCTION requestPadShutdown {
	IF abortState["mode"] = "escape" OR abortState["mode"] = "escaped" { RETURN. }
	SET abortState["mode"] TO "escape".
	SET abortState["reason"] TO "PAD ENGINE START FAILURE".
	SET abortState["source"] TO "pad".
	SET abortState["manual"] TO FALSE.
	SET abortState["guidanceMode"] TO "pad".
	SET throttleSetting TO 0.
	SET throttleDisplay TO 0.
	SET SHIP:CONTROL:FORE TO 0.
	SET abort_stagingGeneration TO abort_stagingGeneration + 1.
	pushUIMessage("PAD ENGINE START FAILURE - THROTTLE IDLE", 10, PRIORITY_CRITICAL).
}

FUNCTION abortInputWatchdog {
	IF NOT abortEnabled { RETURN. }
	IF ABORT AND abortState["mode"] <> "escape" AND abortState["mode"] <> "escaped" {
		requestEscape("MANUAL ABORT", "manual", TRUE).
	}
}

FUNCTION contingencyWatchdog {
	IF NOT abortEnabled { RETURN. }
	updateLesState().
	abortInputWatchdog().
	IF abortState["mode"] = "escape" { RETURN. }
	rudWatchdog().
	IF abortState["mode"] = "escape" { RETURN. }
	spinWatchdog().
	IF abortState["mode"] = "escape" { RETURN. }
	engineFailureWatchdog().
}

FUNCTION atoFeasibilityWatchdog {
	IF NOT abortEnabled { RETURN. }
	IF abortState["mode"] = "ato" AND NOT stagingInProgress AND DEFINED upfgBurnFeasible {
		LOCAL marginFeasible IS estimateRemainingDeltaV(upfgStage, TRUE) >=
			upfgInternal["vgo"]:MAG + abortConfig["atoReserve"].
		IF upfgBurnFeasible AND marginFeasible {
			SET abortState["atoFailures"] TO 0.
			SET abortState["atoFailureSince"] TO -1.
		} ELSE {
			SET abortState["atoFailures"] TO abortState["atoFailures"] + 1.
			IF abortState["atoFailureSince"] < 0 { SET abortState["atoFailureSince"] TO TIME:SECONDS. }
			IF TIME:SECONDS >= abortState["atoFailureSince"] + abortConfig["atoInfeasibleDelay"] {
				LOCAL nextStage IS nextPhysicalStage(upfgStage).
				IF nextStage >= 0 AND atoStageCanActivate(nextStage) {
					LOCAL radius IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
					LOCAL localGravity IS SHIP:BODY:MU / radius^2.
					LOCAL requiredDeltaV IS upfgInternal["vgo"]:MAG + abortConfig["atoReserve"] +
						localGravity * getAtoStageDelays(nextStage).
					IF estimateRemainingDeltaV(nextStage, FALSE) >= requiredDeltaV {
						SET abortState["atoFailures"] TO 0.
						SET abortState["atoFailureSince"] TO -1.
						activateEmergencyAtoStage(nextStage).
						pushUIMessage("ATO MARGIN LOW - EMERGENCY STAGING", 10, PRIORITY_CRITICAL).
						RETURN.
					}
				}
				updateLesState().
				IF abortState["lesJettisoned"] {
					requestEscape("ABORT TO ORBIT INFEASIBLE", "ato", FALSE, "ballistic").
				} ELSE {
					requestEscape("ABORT TO ORBIT INFEASIBLE", "ato", FALSE).
				}
			}
		}
	}
}

FUNCTION abortVehicleGrounded {
	LOCAL vesselSituation IS SHIP:STATUS.
	RETURN vesselSituation = "PRELAUNCH" OR vesselSituation = "LANDED" OR vesselSituation = "SPLASHED".
}

FUNCTION executeEscapeGuidance {
	IF abortState["guidanceMode"] = "pad" {
		SET abortState["mode"] TO "escaped".
		RETURN.
	}
	SET throttleSetting TO 0.
	SET throttleDisplay TO 0.
	SET SHIP:CONTROL:FORE TO 0.
	RCS ON.
	LOCAL initialFacing IS abort_escapeFacing.
	LOCAL lastGuidanceFacing IS initialFacing.
	LOCAL lastFlightDirection IS V(0, 0, 0).
	SET steeringVector TO lastGuidanceFacing.
	LOCK THROTTLE TO throttleSetting.
	LOCK STEERING TO steeringVector.
	LOCAL guidanceEnabled IS abortState["escapeAvailable"] OR abortState["guidanceMode"] = "ballistic".
	IF NOT guidanceEnabled {
		SET abortState["mode"] TO "escaped".
		RETURN.
	}
	LOCAL escapePhaseEnd IS TIME:SECONDS.
	IF abortState["guidanceMode"] <> "ballistic" {
		SET escapePhaseEnd TO escapePhaseEnd + abortConfig["escapeGuidanceTime"].
	}
	UNTIL TIME:SECONDS >= escapePhaseEnd AND abortVehicleGrounded() {
		IF abortState["guidanceMode"] <> "ballistic" AND
			abortState["escapeSystem"] = "crew" AND SHIP:CREW():LENGTH = 0 { BREAK. }
		IF SHIP:VELOCITY:SURFACE:MAG >= abortConfig["escapeMinProgradeSpeed"] {
			SET lastFlightDirection TO SHIP:VELOCITY:SURFACE:NORMALIZED.
		}
		IF lastFlightDirection:MAG > 0 {
			LOCAL guidanceDirection IS lastFlightDirection.
			IF abortState["guidanceMode"] = "ballistic" OR TIME:SECONDS >= escapePhaseEnd {
				SET guidanceDirection TO -guidanceDirection.
			}
			SET lastGuidanceFacing TO LOOKDIRUP(guidanceDirection, SHIP:FACING:TOPVECTOR).
		}
		SET steeringVector TO lastGuidanceFacing.
		refreshUI().
		WAIT 0.
	}
	SET abortState["mode"] TO "escaped".
}
