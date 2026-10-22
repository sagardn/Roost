import AppKit
import SwiftUI

/// The tool pages of the settings window, and the way between them.
///
/// Each tool used to be a window of its own, opened from a button on a hub
/// page. They are pages now, in the window that is already open, grouped in
/// the sidebar by what somebody came to do (`SettingsSelection.Tool`). The
/// standalone windows that other parts of the app still open -- Large files
/// from the Disk popup, the uninstaller, the AI clean-up -- draw the same
/// SwiftUI views with the same models, so a page and its window cannot
/// behave differently.
enum ToolPages {

    /// Clear of the transparent title bar the settings window draws over its
    /// pages, as the Large files view measured it when it was first embedded.
    static let top: CGFloat = 38

    /// A page's view, made once and kept by the settings window: its model
    /// holds a scan, and rebuilding the view on every visit would throw the
    /// scan away.
    static func make(_ tool: SettingsSelection.Tool) -> NSView {
        switch tool {
        case .checkUp:         return host(CheckUpView(model: CheckUpModel()))
        case .aiTools:         return host(AICleanupView(model: AICleanupModel(), embedded: true))
        case .largeFiles:      return host(CleanerView(model: CleanerModel(), embedded: true))
        case .duplicates:      return host(DuplicatesView(model: DuplicatesModel()))
        case .spaceMap:        return host(SpaceMapView(model: SpaceMapModel()))
        case .uninstaller:     return host(UninstallView(model: UninstallModel(), embedded: true))
        case .backgroundItems: return host(BackgroundItemsView(model: BackgroundItemsModel()))
        case .protection:      return host(ProtectionPage(model: ProtectionModel()))
        case .storage:
            // AppKit, like the module pages, and owned by the settings window
            // so it can refresh its disk figures on every visit.
            return NSView()
        }
    }

    private static func host<V: View>(_ view: V) -> NSView {
        let hosting = NSHostingView(rootView: view)
        // The pane decides the size. Left to its own sizing, a hosting view
        // asks for its content's ideal size, and the window would grow to
        // fit the space map's list.
        hosting.sizingOptions = []
        return hosting
    }

    /// Moves the settings window to a tool's page, by the same notification
    /// a sidebar click posts.
    static func open(_ tool: SettingsSelection.Tool) {
        NotificationCenter.default.post(name: .openModuleSettings, object: nil,
                                        userInfo: ["module": tool.rawValue])
    }

    /// To the Duplicates page, carrying a comparison already made.
    static func openDuplicates(reusing scan: Duplicates.Scan?) {
        DuplicatesModel.offered = scan
        open(.duplicates)
    }
}

// MARK: - Protection

final class ProtectionModel: ObservableObject {
    @Published private(set) var report: Protection.Report?
    @Published private(set) var reading = false

    /// Every visit: four short processes, 60 ms in all on an M2, and a
    /// setting changed in System Settings a moment ago should show here.
    func read() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = Protection.read()
            DispatchQueue.main.async {
                self?.report = report
                self?.reading = false
            }
        }
    }
}

/// macOS's own protections, on a page of their own.
///
/// The same rows the Check-up shows, read again on every visit. What this
/// page will not do is the subject of its last line: it is a report of what
/// macOS says, not a scanner, and saying so here is what keeps the sidebar
/// heading "Protection" from promising more than it is.
struct ProtectionPage: View {
    @ObservedObject var model: ProtectionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localized("macOS protections"))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text(localized("Whether the protections macOS ships with are switched on."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.reading { ProgressView().controlSize(.small) }
                    Button(localized("Check again")) { model.read() }.disabled(model.reading)
                }
                if let report = model.report {
                    ProtectionCard(report: report, showsHeading: false)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.035)))
                } else {
                    // The first read takes a moment; an empty page under a
                    // small header spinner looked like a page with nothing on it.
                    ProgressView(localized("Checking macOS protections…"))
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.035)))
                }
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.2").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(localized("What starts by itself, and who signed it, is under Background items."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Background items")) { ToolPages.open(.backgroundItems) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, ToolPages.top)
            .padding(.bottom, 24)
        }
        .onAppear { model.read() }
    }
}
