import SwiftUI

// The Dashboard's process table, in a file of its own rather than beside
// its sampler: Tools/processtable-test.swift compiles DashboardProcesses.swift
// alone, and a view there pulls in the app's whole design layer with it.

/// The busiest processes, under the cards.
///
/// Ordered by processor use, because that is the question somebody opens a
/// monitor to ask. Memory sits beside it where the same process appears in
/// both readings -- see `DashboardProcesses.merge`.
struct BusiestProcesses: View {

    @ObservedObject var processes: DashboardProcesses

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("Busiest processes"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                // Sorting lives here rather than in clickable column
                // headings: a heading that sorts has to look like a control,
                // and three of them across a four-row table is more chrome
                // than the table.
                Picker(localized("Sort by"), selection: $processes.sort) {
                    ForEach(DashboardProcesses.Sort.allCases, id: \.self) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help(localized("Choose what orders the table"))
            }

            if processes.rows.isEmpty {
                // Never an empty box: the first CPU reading has nothing to
                // difference against, so for one refresh there is honestly
                // nothing to show.
                Text(processes.hasSampled ? localized("Nothing is busy")
                                          : localized("Measuring…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 16, verticalSpacing: 7) {
                    // Headings, so the two numeric columns say what they
                    // are. "% of one core" used to float at the top right
                    // over whichever column happened to be under it, which
                    // on this Mac was the memory column.
                    GridRow {
                        Text(localized("Process"))
                            .gridColumnAlignment(.leading)
                        Text(localized("% of one core"))
                            .gridColumnAlignment(.trailing)
                        Text(localized("Memory"))
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                    ForEach(processes.rows) { row in
                        GridRow {
                            Text(row.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .gridColumnAlignment(.leading)
                            // The same format the CPU popup uses for the
                            // same figure, so the two never disagree about
                            // a process by a decimal place.
                            // Monospaced digits on both numeric columns, so
                            // 9.1% and 45.7% put their decimal points in the
                            // same place down the column.
                            Text(String(format: "%.1f%%", row.cpu))
                                .monospacedDigit()
                                .foregroundStyle(tint(for: row.cpu))
                                .gridColumnAlignment(.trailing)
                            Text(row.memory.map { Readings.bytes($0) } ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    /// The same three colours the menu bar uses, on the same boundaries, so
    /// a figure that is amber here is amber there. Over 100% means more than
    /// one core, which is the point at which a process is worth noticing.
    private func tint(for cpu: Double) -> Color {
        Color(LoadBand.of(min(cpu / 100, 1)).color)
    }
}
