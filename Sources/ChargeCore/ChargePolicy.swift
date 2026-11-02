import Foundation

/// Pure decision function: (battery reading, settings, latches) -> what the
/// hardware should do. No I/O, so every rule is unit-testable.
///
/// Priority, highest first:
///   1. Hard safety floor  — never keep the adapter off below 5 %.
///   2. Calibration        — owns both switches while running.
///   3. Forced discharge   — adapter off until the limit is reached.
///   4. Heat protection    — inhibits charging (adapter stays on).
///   5. Top-up             — one-shot charge to 100 %.
///   6. Limiter + sailing  — hysteresis around the limit.
public enum ChargePolicy {
    public static let hardFloorPercent = 5

    public static func evaluate(snapshot: BatterySnapshot,
                                settings: ChargeSettings,
                                state: inout PolicyState,
                                now: Date = Date()) -> ChargeDecision {
        let percent = snapshot.percent(useHardware: settings.useHardwarePercentage)
        let isFull = percent >= 100 || snapshot.isFullyCharged
        let plugged = snapshot.isPluggedIn

        updateHeatLatch(snapshot: snapshot, settings: settings, state: &state)

        // 1. Safety floor: whatever the mode, give the Mac its adapter back.
        if percent <= Double(hardFloorPercent) {
            state.dischargeRequested = false
            if state.calibration == .dischargeToLow { state.calibration = .rechargeToFull }
            return ChargeDecision(chargingEnabled: !state.heatPaused, adapterEnabled: true,
                                  state: label(plugged: plugged, wantsCharge: true, charging: !state.heatPaused,
                                               isFull: isFull, state: state, percent: percent, settings: settings))
        }

        // 2. Calibration: 100 % -> hold -> low target -> 100 % -> back to the limit.
        if let phase = state.calibration {
            switch phase {
            case .chargeToFull where isFull:
                state.calibration = .holdAtFull(until: now.addingTimeInterval(Double(settings.calibrationHoldMinutes) * 60))
            case .holdAtFull(let until) where now >= until:
                state.calibration = .dischargeToLow
            case .dischargeToLow where percent <= Double(settings.calibrationLowTarget):
                state.calibration = .rechargeToFull
            case .rechargeToFull where isFull:
                state.calibration = nil
                // Calibration done; at 100 % the limiter now holds the charge.
                state.holdingAtLimit = true
            default:
                break
            }
            if let phase = state.calibration {
                let discharging = phase == .dischargeToLow
                return ChargeDecision(chargingEnabled: !discharging && !state.heatPaused,
                                      adapterEnabled: !discharging,
                                      state: .calibrating(phase))
            }
        }

        let limit = Double(settings.chargeLimit)

        // 3. Forced discharge down to the limit, then stop and hold there.
        if state.dischargeRequested {
            if percent > limit {
                return ChargeDecision(chargingEnabled: false, adapterEnabled: false,
                                      state: plugged ? .discharging : .onBattery)
            }
            state.dischargeRequested = false
            state.holdingAtLimit = true
        }

        // 5. Top-up ends by itself once full.
        if state.topUpActive && isFull { state.topUpActive = false }

        // 6. Limiter with hysteresis.
        let wantsCharge: Bool
        if state.topUpActive || !settings.limitEnabled {
            wantsCharge = true
        } else {
            let resumeAt = settings.sailingEnabled ? Double(settings.sailingLowerBound) : limit - 1
            if percent >= limit {
                state.holdingAtLimit = true
            } else if percent <= resumeAt {
                state.holdingAtLimit = false
            }
            wantsCharge = !state.holdingAtLimit
        }

        // 4. Heat overrides any wish to charge.
        let charging = wantsCharge && !state.heatPaused
        return ChargeDecision(chargingEnabled: charging, adapterEnabled: true,
                              state: label(plugged: plugged, wantsCharge: wantsCharge, charging: charging,
                                           isFull: isFull, state: state, percent: percent, settings: settings))
    }

    private static func updateHeatLatch(snapshot: BatterySnapshot, settings: ChargeSettings,
                                        state: inout PolicyState) {
        guard settings.heatProtectionEnabled, let temp = snapshot.temperatureC else {
            state.heatPaused = false
            return
        }
        if temp >= settings.heatLimitC {
            state.heatPaused = true
        } else if temp <= settings.heatLimitC - settings.heatHysteresisC {
            state.heatPaused = false
        }
    }

    private static func label(plugged: Bool, wantsCharge: Bool, charging: Bool, isFull: Bool,
                              state: PolicyState, percent: Double, settings: ChargeSettings) -> ChargeState {
        guard plugged else { return .onBattery }
        if state.heatPaused && wantsCharge && !isFull { return .heatPaused }
        if charging { return isFull ? .full : (state.topUpActive ? .toppingUp : .charging) }
        if isFull && !settings.limitEnabled { return .full }
        return percent >= Double(settings.chargeLimit) ? .limitReached : .sailing
    }
}
