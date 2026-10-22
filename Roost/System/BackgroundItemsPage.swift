import AppKit
import SwiftUI

/// What starts by itself, and the evidence for each: what it runs, whether
/// that is still there, and who signed it.
///
/// `BackgroundItems` says why this lists and does not switch: the switches
/// are in System Settings ▸ Login Items, which is one button away at the top.
/// The one thing it does remove is a job of this user's whose program has
/// gone -- the plist is then an instruction launchd fails to follow at every
/// login, and it sits in a folder this user owns. Even that goes to the Bin
/// after a confirmation. A job in `/Library` belongs to every user or to the
/// system and needs an administrator to touch; it is revealed, not removed.
final class BackgroundItemsModel: ObservableObject {

    @Published private(set) var items: [BackgroundItems.Assessed] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    let home = FileManager.default.homeDirectoryForCurrentUser

    func load() {
        guard !loading else { return }
        loading = true
        let home = self.home
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = BackgroundItems.assessAll(home: home, appURL: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            })
            DispatchQueue.main.async { [weak self] in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    self?.items = found
                    self?.loading = false
                    self?.loaded = true
                }
            }
        }
    }

    /// Only a job of this user's, and only while its program is missing --
    /// checked again now, not as it was when the list was read.
    static func canRemove(_ item: BackgroundItems.Assessed) -> Bool {
        guard item.job.domain == .user else { return false }
        guard let executable = item.executable else { return item.job.bundleProgram != nil
            || item.job.program == nil }
        return BackgroundItems.isAbsent(executable.resolvingSymlinksInPath().path)
    }

    func remove(_ item: BackgroundItems.Assessed) {
        Alert.show(localized("Move %0 to the Bin?", item.job.plist.lastPathComponent),
                   localized("Its program is gone, so it fails at every login. It may stay loaded until you log out; after that it is not started again."),
                   style: .warning, actionTitle: localized("Move to Bin")) { [weak self] in
            // Read again from the disk: an updater may have rewritten the
            // plist since the list was read, to point at a program that is
            // there, and that plist is a working job.
            let appURL = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            guard let fresh = BackgroundItems.reassess(item.job.plist, domain: item.job.domain, appURL: appURL),
                  fresh.signature == .missing, Self.canRemove(fresh) else {
                Alert.show(localized("Left where it is"),
                           localized("Its program is there again, so it is no longer a broken job."))
                return
            }
            do {
                _ = try CheckUp.trashItem(item.job.plist)
                Log.info("Background items: moved \(item.job.plist.path) to the Bin")
                withAnimation { self?.items.removeAll { $0.job.plist == item.job.plist } }
            } catch {
                Alert.show(localized("%0 could not be moved", item.job.plist.lastPathComponent), error: error)
            }
        }
    }
}

struct BackgroundItemsView: View {
    @ObservedObject var model: BackgroundItemsModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(localized("Background items"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Spacer()
                    Button(localized("Login Items settings…")) { SettingsLink.loginItems.open() }
                }
                Text(localized("Programs macOS starts by itself, at login or at startup. The switches for them are in System Settings."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localized("Login items added by apps are only shown by System Settings; macOS gives other apps no way to list them."))
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.top, ToolPages.top).padding(.bottom, 12)
            Divider().opacity(0.6)
            if model.loading && !model.loaded {
                ProgressView().frame(maxHeight: .infinity)
            } else if model.items.isEmpty {
                Text(localized("Nothing in the launch agent and daemon folders."))
                    .foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(BackgroundItems.Domain.allCases, id: \.self) { domain in
                            let rows = model.items.filter { $0.job.domain == domain }
                            if !rows.isEmpty {
                                Text(domain.title).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(rows, id: \.job.plist) { item in JobRow(item: item, model: model) }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Cheap -- a few dozen plists and their signatures -- so it reads on
        // every visit rather than showing a list from last time.
        .onAppear { model.load() }
    }
}

private struct JobRow: View {
    let item: BackgroundItems.Assessed
    @ObservedObject var model: BackgroundItemsModel

    private var signature: (text: String, tint: Color) {
        switch item.signature {
        case .apple:                return (localized("Signed by Apple"), CleanerTint.calm)
        case .developer(let team):  return (localized("Signed by %0", item.signer ?? team), CleanerTint.calm)
        case .adHoc:                return (localized("Signed locally"), .secondary)
        case .unsigned:             return (localized("Not signed"), CleanerTint.warning)
        case .broken:               return (localized("Signature does not match"), CleanerTint.critical)
        case .missing:              return (localized("Program is missing"), CleanerTint.warning)
        case .unreadable:           return (localized("Program cannot be checked"), .secondary)
        }
    }

    private func words(_ concern: BackgroundItems.Concern) -> String {
        switch concern {
        case .programMissing:  return localized("Its program is gone, so launchd fails to start it.")
        case .unsigned:        return localized("Nobody has signed its program. Usually a script or tool you installed — check you recognise it.")
        case .brokenSignature: return localized("Its program has changed since it was signed. Check where it came from.")
        case .runsScript:      return localized("It hands a script to a shell; the shell is Apple's, the script is not checked by anyone.")
        }
    }

    /// "every 3600 s" made a person do the arithmetic; this says "1 hour".
    private static let interval: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter
    }()

    /// `icon(forFile:)` is a Launch Services lookup and the list is lazy, so
    /// a row scrolled back into view would otherwise ask again.
    private static let icons = NSCache<NSString, NSImage>()

    /// The app's own icon where the job belongs to one; otherwise the
    /// program's, which Finder draws as the generic executable -- honest
    /// about it being a bare tool rather than dressing it as an app.
    private var icon: NSImage? {
        guard let url = item.app ?? item.executable,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let key = url.path as NSString
        if let hit = Self.icons.object(forKey: key) { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.icons.setObject(image, forKey: key)
        return image
    }

    private var schedule: String {
        var parts: [String] = []
        if item.job.runsAtLoad { parts.append(localized("at login")) }
        if item.job.keepsAlive { parts.append(localized("kept running")) }
        if let interval = item.job.interval, let every = Self.interval.string(from: TimeInterval(interval)) {
            parts.append(localized("every %0", every))
        }
        if item.job.disabledInPlist { parts.append(localized("disabled")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "questionmark.square.dashed").resizable().scaledToFit()
                        .foregroundStyle(.tertiary).padding(4)
                }
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            details
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(item.concerns.isEmpty ? Color.primary.opacity(0.035) : CleanerTint.warning.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(BackgroundItems.title(of: item)).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if !schedule.isEmpty {
                    Text(schedule).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(signature.text).font(.system(size: 11, weight: .semibold)).foregroundStyle(signature.tint)
                    .lineLimit(1)
                    .help(signatureHelp)
            }
            // The label and the path are the evidence, kept for whoever
            // wants to check; they are no longer what the row is called.
            Text(item.job.label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text(item.executable?.path ?? item.job.program ?? localized("No program named"))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            ForEach(item.concerns, id: \.self) { concern in
                Label(words(concern), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(CleanerTint.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(localized("Show plist")) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.job.plist])
                }
                if let executable = item.executable,
                   FileManager.default.fileExists(atPath: executable.path) {
                    Button(localized("Show program")) {
                        NSWorkspace.shared.activateFileViewerSelecting([executable])
                    }
                }
                if BackgroundItemsModel.canRemove(item) {
                    Button(localized("Move to Bin…")) { model.remove(item) }
                }
            }
            .controlSize(.small)
            .padding(.top, 3)
        }
    }

    /// The team ID, for whoever wants to check it against the developer's.
    private var signatureHelp: String {
        if case .developer(let team) = item.signature { return localized("Team ID %0", team) }
        return ""
    }
}
