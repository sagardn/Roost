import SwiftUI
import AppKit

/// The pieces the popup, the combined tile and the history window share, so
/// an entry looks the same wherever it is listed.

// MARK: - Thumbnails

/// Thumbnails, decoded once and kept while memory allows.
///
/// A list redraws its rows on every change to the history; decoding a PNG
/// from disk on each redraw is the kind of work that makes a popup stutter
/// when something is copied while it is open.
final class ClipboardThumbnails {
    static let shared = ClipboardThumbnails()
    private let cache = NSCache<NSURL, NSImage>()

    init() { cache.countLimit = 300 }

    func image(at url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

// MARK: - Kind

extension ClipboardEntry.Kind {
    var symbol: String {
        switch self {
        case .text:     return "text.alignleft"
        case .url:      return "link"
        case .richText: return "textformat"
        case .image:    return "photo"
        case .files:    return "doc"
        }
    }

    var title: String {
        switch self {
        case .text:     return localized("Text")
        case .url:      return localized("Link")
        case .richText: return localized("Formatted text")
        case .image:    return localized("Image")
        case .files:    return localized("Files")
        }
    }
}

enum ClipboardFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "Just now" for the last minute, which the formatter would call
    /// "in 0 sec." or "12 sec. ago" -- precision nobody reading a list wants.
    static func age(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return localized("Just now") }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static func title(_ entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image:
            return entry.pixelSize.map { localized("Image, %0", $0) } ?? localized("Image")
        case .files:
            let count = entry.fileURLs?.count ?? 0
            let first = entry.fileURLs?.first.flatMap(URL.init(string:))?.lastPathComponent ?? ""
            return count > 1 ? localized("%0 and %1 more", first, "\(count - 1)") : first
        default:
            return ClipboardPreview.line(entry.text ?? "")
        }
    }

    static func detail(_ entry: ClipboardEntry) -> String {
        var parts = [entry.kind.title]
        if let text = entry.text, entry.kind == .text || entry.kind == .richText {
            let extra = ClipboardPreview.extraLines(text)
            if extra > 0 { parts.append(localized("+%0 lines", "\(extra)")) }
        }
        if let source = entry.sourceName { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Row

/// One entry in a list: a thumbnail or a kind icon, the first line, what it
/// is and where from, when, and whether it is pinned.
struct ClipboardRow: View {
    let entry: ClipboardEntry
    var isHighlighted = false
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(ClipboardFormat.title(entry))
                    .font(compact ? .callout : .body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(ClipboardFormat.detail(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ClipboardFormat.age(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(localized("Pinned"))
                }
            }
        }
        .padding(.vertical, compact ? 4 : 5)
        .padding(.horizontal, compact ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private var spoken: String {
        [entry.kind.title, ClipboardFormat.title(entry), ClipboardFormat.age(entry.date),
         entry.isPinned ? localized("Pinned") : nil, entry.sourceName]
            .compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder
    private var leading: some View {
        let side: CGFloat = compact ? 26 : 32
        if entry.kind == .image, ClipboardSettings.showImagePreviews,
           let image = ClipboardThumbnails.shared.image(at: ClipboardService.shared.thumbnailURL(entry)) {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        } else {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: compact ? 12 : 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
        }
    }
}

// MARK: - Status

/// Monitoring on, off or blocked, as a symbol and a word.
struct ClipboardStatusLabel: View {
    let status: ClipboardService.Status

    var body: some View {
        switch status {
        case .on:      StatusBadge(text: localized("Recording copies"), tone: .calm)
        case .off:     StatusBadge(text: localized("History is off"), tone: .neutral)
        case .blocked: StatusBadge(text: localized("Blocked by macOS"), tone: .warning)
        }
    }
}

/// What to show instead of a list, and the one thing that would change it.
struct ClipboardEmptyState: View {
    @ObservedObject var service: ClipboardService
    let hasQuery: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !hasQuery {
                switch service.status {
                case .off:
                    Button(localized("Turn On…")) { ClipboardActions.enableMonitoring() }
                case .blocked:
                    Button(localized("Privacy & Security…")) { ClipboardActions.openPrivacySettings() }
                case .on:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var symbol: String {
        if hasQuery { return "magnifyingglass" }
        switch service.status {
        case .off:     return "pause.circle"
        case .blocked: return "hand.raised"
        case .on:      return "doc.on.clipboard"
        }
    }

    private var message: String {
        if !service.isLoaded { return localized("Loading…") }
        if hasQuery { return localized("Nothing matches") }
        switch service.status {
        case .off:
            return service.history.entries.isEmpty
                ? localized("Clipboard history is off. Turn it on to keep what you copy.")
                : localized("History is off, so nothing new is being kept.")
        case .blocked:
            return localized("macOS is set not to let Roost read the clipboard.")
        case .on:
            return localized("Copy something, and it appears here.")
        }
    }
}
