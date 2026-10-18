import SwiftUI
import AppKit

/// What the popup knows about its own opening: which app to paste into, and
/// a counter that moves every time it opens, so the view can put the cursor
/// back in the search field and the highlight back at the top.
final class ClipboardPopupState: ObservableObject {
    @Published var opened = 0
    /// The app in front when the popup opened. The popup does not activate
    /// Roost, so this is still the app the person was in.
    var target: NSRunningApplication?
    var close: () -> Void = {}
}

/// The menu bar popup: the latest copies, a search across all of them, and
/// the way to everything else.
///
/// A few entries, not the history: the popup is for the thing copied a
/// minute ago. Browsing is the history window's job, one click away.
struct ClipboardPopupView: View {
    @ObservedObject var service: ClipboardService
    @ObservedObject var state: ClipboardPopupState
    /// The cut-down form the combined popup's tile uses: no search, three
    /// rows, the same actions.
    var tile = false

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searching: Bool

    private var shown: [ClipboardEntry] {
        let limit = tile ? 3 : max(3, ClipboardSettings.popupCount)
        return Array(service.history.matching(query, filter: .all).prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tile { search }
            HStack {
                ClipboardStatusLabel(status: service.status)
                Spacer()
                Text(localized("%0 kept", "\(service.history.entries.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let problem = service.problem { problemBanner(problem) }

            if shown.isEmpty {
                ClipboardEmptyState(service: service, hasQuery: !query.isEmpty)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        ClipboardRow(entry: entry, isHighlighted: !tile && index == highlighted, compact: true)
                            .onTapGesture { use(entry) }
                            .onHover { if $0 { highlighted = index } }
                            .help(localized("Click to copy it back to the clipboard"))
                            .contextMenu { menu(for: entry) }
                    }
                }
            }

            Divider()
            HStack {
                Button(localized("View All…")) {
                    state.close()
                    ClipboardHistoryWindow.present(over: state.target)
                }
                .help(localized("Open the full clipboard history"))
                Spacer()
                if service.status == .off, !service.history.entries.isEmpty {
                    Button(localized("Turn On…")) { ClipboardActions.enableMonitoring() }
                }
            }
            .controlSize(.small)
        }
        .frame(width: PopupMetrics.contentWidth, alignment: .leading)
        .onChange(of: state.opened) {
            query = ""
            highlighted = 0
            // A turn later: the popup is ordered in after `willShow`, and a
            // field cannot take focus in a window that is not yet key -- the
            // first render showed the gear holding it instead.
            DispatchQueue.main.async { searching = !tile }
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(localized("Search clipboard"), text: $query)
                .textFieldStyle(.plain)
                .focused($searching)
                .onSubmit { if shown.indices.contains(highlighted) { use(shown[highlighted]) } }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(shown.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onChange(of: query) { highlighted = 0 }
                .accessibilityLabel(localized("Search clipboard"))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
    }

    private func problemBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: StatusTone.warning.symbol)
                .foregroundStyle(StatusTone.warning.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                service.dismissProblem()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(localized("Dismiss"))
            .accessibilityLabel(localized("Dismiss"))
        }
    }

    @ViewBuilder
    private func menu(for entry: ClipboardEntry) -> some View {
        Button(localized("Copy")) { use(entry) }
        Button(entry.isPinned ? localized("Unpin") : localized("Pin")) {
            service.setPinned(entry.id, !entry.isPinned)
        }
        Divider()
        Button(localized("Delete"), role: .destructive) { service.delete(entry.id) }
    }

    private func use(_ entry: ClipboardEntry) {
        let target = state.target
        state.close()
        ClipboardActions.use(entry.id, pasteInto: target)
    }
}
