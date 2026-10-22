import SwiftUI

/// The buttons the cleanup windows share. Out of LargeFilesWindow.swift,
/// where they started, because they are not the Disk Cleaner's: the AI and
/// Uninstall windows draw with them too.

/// The one action on a screen, lit from within.
struct GlowButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var compact = false
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                Text(title)
                    .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 26)
            .frame(height: compact ? 30 : 40)
            .background(
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.85), tint],
                                              startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: tint.opacity(enabled ? (hovering ? 0.55 : 0.35) : 0),
                    radius: hovering ? 14 : 9, y: 3)
            .scaleEffect(hovering && enabled ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }
}

struct CleanerLink: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A tool page before it has looked at anything: what it does, what it will
/// not do, and the button that starts it.
///
/// Every tool page opens on one of these rather than scanning. They are
/// pages in the settings window now, and a click in the sidebar is somebody
/// looking around -- reading every folder they own because of it would be a
/// beach ball they did not ask for, and the first a new Mac's owner hears
/// of it would be macOS asking whether Roost may read their Documents.
struct ToolHero: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    var note: String?
    let button: String
    var secondary: (title: String, action: () -> Void)?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.gradient))
                .shadow(color: tint.opacity(0.35), radius: 12, y: 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            GlowButton(title: button, symbol: "play.fill", tint: tint, action: action)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
            if let secondary {
                CleanerLink(title: secondary.title, symbol: "folder", action: secondary.action)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
