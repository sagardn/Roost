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
