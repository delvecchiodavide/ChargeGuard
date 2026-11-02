import SwiftUI
import ChargeCore

struct MenuBarIcon: View {
    let state: ChargeState
    let percent: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: Self.symbolName(for: state, percent: percent))
            Text("\(percent)%")
                .monospacedDigit()
                .font(.system(size: 12))
        }
    }

    static func symbolName(for state: ChargeState, percent: Int) -> String {
        switch state {
        case .onBattery:
            if percent < 10 {
                return "battery.0percent"
            }
            if percent < 38 {
                return "battery.25percent"
            }
            if percent < 63 {
                return "battery.50percent"
            }
            if percent < 88 {
                return "battery.75percent"
            }
            return "battery.100percent"
        case .charging, .toppingUp:
            return "battery.100percent.bolt"
        case .full:
            return "battery.100percent"
        case .limitReached, .sailing:
            return "powerplug.fill"
        case .discharging:
            return "arrow.down.circle"
        case .heatPaused:
            return "thermometer.sun.fill"
        case .calibrating(_):
            return "gauge.with.dots.needle.33percent"
        }
    }
}
