import SwiftUI

/// One set of interval choices and formatting for setup and profile editing.
enum SyncScheduleInterval {
    static let presets = [1, 2, 5, 10, 15, 30, 60, 120, 360, 720, 1_440, 10_080, 20_160]

    enum Unit: Int, CaseIterable, Identifiable {
        case minutes = 1, hours = 60, days = 1_440, weeks = 10_080
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .minutes: return "Minutes"
            case .hours: return "Hours"
            case .days: return "Days"
            case .weeks: return "Weeks"
            }
        }
    }

    static func label(for minutes: Int) -> String {
        for (size, name) in [(10_080, "week"), (1_440, "day"), (60, "hour"), (1, "minute")] {
            if minutes >= size && minutes % size == 0 {
                let value = minutes / size
                return "\(value) \(name)\(value == 1 ? "" : "s")"
            }
        }
        return "\(minutes) minutes"
    }

    static func minutes(quantity: String, unit: Unit) -> Int? {
        guard let value = Int(quantity.trimmingCharacters(in: .whitespaces)), value > 0,
              value <= SyncProfile.maximumSyncIntervalMinutes / unit.rawValue else { return nil }
        return value * unit.rawValue
    }
}

struct SyncScheduleControls: View {
    @Binding var syncOnLocalChanges: Bool
    @Binding var intervalMinutes: Int
    @Binding var isValid: Bool
    @State private var custom = false
    @State private var quantity = "5"
    @State private var unit: SyncScheduleInterval.Unit = .minutes

    private var selection: Binding<Int> {
        Binding(get: { custom ? -1 : intervalMinutes }, set: { value in
            custom = value == -1
            if custom {
                loadCustomValue()
            } else {
                intervalMinutes = value
                isValid = true
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Automatic Sync", selection: $syncOnLocalChanges) {
                Text("On local changes + schedule").tag(true)
                Text("Schedule only").tag(false)
            }
            .pickerStyle(.menu)

            Picker("Sync Interval", selection: selection) {
                ForEach(SyncScheduleInterval.presets, id: \.self) { minutes in
                    Text(SyncScheduleInterval.label(for: minutes)).tag(minutes)
                }
                Text("Custom…").tag(-1)
            }
            .pickerStyle(.menu)

            if custom {
                HStack {
                    TextField("Amount", text: $quantity)
                        .frame(width: 90)
                        .accessibilityLabel("Custom sync interval amount")
                    Picker("Unit", selection: $unit) {
                        ForEach(SyncScheduleInterval.Unit.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Custom sync interval unit")
                }
                .onChange(of: quantity) { _ in validateCustomValue() }
                .onChange(of: unit) { _ in validateCustomValue() }
                if !isValid {
                    Text("Enter a whole-number interval from 1 minute to 365 days.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(syncOnLocalChanges
                 ? "Local changes also trigger a sync after a short delay."
                 : "Files and the remote are checked only when the interval is due. Sync Now runs immediately and restarts the interval. Failed attempts also restart the interval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            custom = !SyncScheduleInterval.presets.contains(intervalMinutes)
            loadCustomValue()
        }
    }

    private func loadCustomValue() {
        unit = SyncScheduleInterval.Unit.allCases.reversed().first {
            intervalMinutes >= $0.rawValue && intervalMinutes % $0.rawValue == 0
        } ?? .minutes
        quantity = String(intervalMinutes / unit.rawValue)
        isValid = true
    }

    private func validateCustomValue() {
        guard let minutes = SyncScheduleInterval.minutes(quantity: quantity, unit: unit) else {
            isValid = false
            return
        }
        intervalMinutes = minutes
        isValid = true
    }
}
