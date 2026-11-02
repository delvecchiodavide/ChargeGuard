@testable import ChargeCore
import Foundation
import Testing

private func snapshot(_ percent: Int, plugged: Bool = true, temp: Double? = 30, full: Bool = false) -> BatterySnapshot {
    var s = BatterySnapshot()
    s.osPercent = percent
    s.isPluggedIn = plugged
    s.temperatureC = temp
    s.isFullyCharged = full
    return s
}

private func run(_ percent: Int, _ settings: ChargeSettings, _ state: inout PolicyState,
                 plugged: Bool = true, temp: Double? = 30, now: Date = Date()) -> ChargeDecision {
    ChargePolicy.evaluate(snapshot: snapshot(percent, plugged: plugged, temp: temp, full: percent >= 100),
                          settings: settings, state: &state, now: now)
}

@Suite struct LimiterTests {
    @Test func chargesBelowLimitAndStopsAtLimit() {
        var state = PolicyState()
        let settings = ChargeSettings()
        #expect(run(50, settings, &state) == ChargeDecision(chargingEnabled: true, adapterEnabled: true, state: .charging))
        #expect(run(80, settings, &state) == ChargeDecision(chargingEnabled: false, adapterEnabled: true, state: .limitReached))
    }

    @Test func withoutSailingResumesOnePercentBelowLimit() {
        var state = PolicyState()
        let settings = ChargeSettings()
        _ = run(80, settings, &state)
        #expect(run(80, settings, &state).chargingEnabled == false)
        #expect(run(79, settings, &state).chargingEnabled == true)
    }

    @Test func sailingHoldsUntilLowerBound() {
        var state = PolicyState()
        var settings = ChargeSettings()
        settings.sailingEnabled = true
        settings.sailingLowerBound = 72
        _ = run(80, settings, &state)
        let sailing = run(75, settings, &state)
        #expect(sailing.chargingEnabled == false)
        #expect(sailing.state == .sailing)
        #expect(run(72, settings, &state).chargingEnabled == true)
        #expect(run(76, settings, &state).chargingEnabled == true, "keeps charging back up to the limit")
    }

    @Test func aboveLimitAfterPlugInDoesNotCharge() {
        var state = PolicyState()
        #expect(run(92, ChargeSettings(), &state).chargingEnabled == false)
    }

    @Test func disabledLimiterAlwaysCharges() {
        var state = PolicyState()
        var settings = ChargeSettings()
        settings.limitEnabled = false
        #expect(run(95, settings, &state).chargingEnabled == true)
    }

    @Test func unpluggedReportsOnBattery() {
        var state = PolicyState()
        #expect(run(50, ChargeSettings(), &state, plugged: false).state == .onBattery)
    }
}

@Suite struct HeatTests {
    @Test func pausesAboveLimitAndResumesWithHysteresis() {
        var state = PolicyState()
        let settings = ChargeSettings() // 35 °C, hysteresis 3
        let hot = run(50, settings, &state, temp: 36)
        #expect(hot == ChargeDecision(chargingEnabled: false, adapterEnabled: true, state: .heatPaused))
        #expect(run(50, settings, &state, temp: 33).chargingEnabled == false, "still inside hysteresis")
        #expect(run(50, settings, &state, temp: 32).chargingEnabled == true)
    }

    @Test func heatOverridesTopUp() {
        var state = PolicyState()
        state.topUpActive = true
        #expect(run(85, ChargeSettings(), &state, temp: 40).chargingEnabled == false)
    }
}

@Suite struct ModeTests {
    @Test func dischargeDisablesAdapterThenHoldsAtLimit() {
        var state = PolicyState()
        state.dischargeRequested = true
        let settings = ChargeSettings()
        #expect(run(90, settings, &state) == ChargeDecision(chargingEnabled: false, adapterEnabled: false, state: .discharging))
        let done = run(80, settings, &state)
        #expect(done.adapterEnabled)
        #expect(!done.chargingEnabled)
        #expect(!state.dischargeRequested)
    }

    @Test func safetyFloorBeatsDischarge() {
        var state = PolicyState()
        state.dischargeRequested = true
        var settings = ChargeSettings()
        settings.chargeLimit = 20
        let d = run(4, settings, &state)
        #expect(d.adapterEnabled)
        #expect(d.chargingEnabled)
        #expect(!state.dischargeRequested)
    }

    @Test func topUpChargesToFullThenRestoresLimit() {
        var state = PolicyState()
        state.topUpActive = true
        let settings = ChargeSettings()
        #expect(run(85, settings, &state).state == .toppingUp)
        _ = run(100, settings, &state)
        #expect(!state.topUpActive)
        #expect(run(99, settings, &state).chargingEnabled == false, "back under the 80 % limit rules")
    }

    @Test func calibrationRunsAllPhases() {
        var state = PolicyState()
        state.calibration = .chargeToFull
        var settings = ChargeSettings()
        settings.calibrationHoldMinutes = 60
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        #expect(run(60, settings, &state, now: t0).chargingEnabled)
        _ = run(100, settings, &state, now: t0)
        #expect(state.calibration == .holdAtFull(until: t0.addingTimeInterval(3600)))

        _ = run(100, settings, &state, now: t0.addingTimeInterval(3601))
        #expect(state.calibration == .dischargeToLow)
        let discharging = run(50, settings, &state, now: t0.addingTimeInterval(4000))
        #expect(!discharging.adapterEnabled)

        _ = run(10, settings, &state, now: t0.addingTimeInterval(9000))
        #expect(state.calibration == .rechargeToFull)
        #expect(run(40, settings, &state).chargingEnabled)

        _ = run(100, settings, &state)
        #expect(state.calibration == nil)
        #expect(run(100, settings, &state).state == .limitReached)
    }
}

@Suite struct SettingsTests {
    @Test func normalizeKeepsSailingBelowLimit() {
        var settings = ChargeSettings()
        settings.chargeLimit = 60
        settings.sailingLowerBound = 70
        settings.normalize()
        #expect(settings.sailingLowerBound == 59)
    }
}
