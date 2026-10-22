import SwiftUI
import AppKit

/// The Battery health card: how much of its design capacity the battery still
/// holds, how many cycles it has done, the system's word for its condition,
/// and what it is doing now.
///
/// Maximum capacity leads, and is labelled as such under the figure: it and
/// the charge are both percentages of a battery, and a card that showed
/// "100%" bare would be read as "fully charged" by most people. The charge is
/// a supporting row, with its own label.
///
/// Not a button, unlike the module cards: there is no Roost page for the
/// battery. The way on is System Settings ▸ Battery, which says so.
struct BatteryCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let condition = model.health?.condition.map(BatteryHealth.describe(condition:))
        let tone = Self.tone(condition?.tone)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GlyphTile(glyph: .named("Battery"), size: 18)
                Text(DashboardCard.battery.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(capacityText)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(localized("Maximum capacity"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                Spacer(minLength: 4)
                StatusBadge(text: condition?.title ?? conditionPlaceholder, tone: tone)
                    .fixedSize()
                    .help(model.health?.condition.map { localized("Reported by macOS as “%0”", $0) } ?? "")
            }

            if let capacity = model.health?.maximumCapacity {
                FillGauge(fraction: min(Double(capacity), 100) / 100, tone: tone)
                    .padding(.vertical, 4)
            } else {
                Color.clear.frame(height: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                // A bare 312 had no scale to read it against; Apple's rating
                // for its notebook batteries is the scale (support article
                // "Determine battery cycle count for Mac notebooks").
                fact(localized("Cycle count"), model.health?.cycleCount.map(String.init) ?? placeholder)
                    .help(localized("One cycle is 100% of the battery's charge used, in any number of goes. Apple rates recent Mac notebook batteries for 1,000 cycles."))
                if let charge = model.charge {
                    fact(localized("Charge"), "\(charge.percent)%")
                    fact(localized("Power"), charge.state.title)
                }
            }
            .font(.callout)

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(localized("Battery Settings…")) { Self.openBatterySettings() }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help(localized("Opens System Settings"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: MetricCard.height - RoostMetrics.cardInset * 2,
               alignment: .topLeading)
        .surface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DashboardCard.battery.title)
    }

    private var capacityText: String {
        model.health?.maximumCapacity.map { "\($0)%" } ?? "—"
    }

    /// Before the report is back, "Reading…"; once it is back without the
    /// figure, "Not reported" -- never a number that was not given.
    private var placeholder: String {
        model.healthRead ? localized("Not reported") : localized("Reading…")
    }

    private var conditionPlaceholder: String { placeholder }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }

    private static func tone(_ tone: BatteryHealth.Tone?) -> StatusTone {
        switch tone {
        case .good:      return .calm
        case .attention: return .warning
        case .failure:   return .critical
        default:         return .neutral
        }
    }

    static func openBatterySettings() {
        for address in ["x-apple.systempreferences:com.apple.Battery-Settings.extension",
                        "x-apple.systempreferences:com.apple.preference.battery"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}
