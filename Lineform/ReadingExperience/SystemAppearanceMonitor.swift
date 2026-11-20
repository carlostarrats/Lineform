import AppKit
import Combine

/// The Mac's own Light/Dark appearance, for Automatic Dark Mode. Read from
/// `NSApp.effectiveAppearance`, which follows System Settings because Lineform never sets
/// `NSApp.appearance` — only per-WINDOW appearances, which is why no view's `colorScheme` or
/// `effectiveAppearance` can answer this (they report the theme the window was forced to).
@MainActor
final class SystemAppearanceMonitor: ObservableObject {
    static let shared = SystemAppearanceMonitor()

    @Published private(set) var isDark: Bool
    private var observation: NSKeyValueObservation?

    private init() {
        isDark = Self.currentIsDark()
        observation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in
                let dark = SystemAppearanceMonitor.currentIsDark()
                if SystemAppearanceMonitor.shared.isDark != dark {
                    SystemAppearanceMonitor.shared.isDark = dark
                }
            }
        }
    }

    private static func currentIsDark() -> Bool {
        guard let appearance = NSApp?.effectiveAppearance else { return false }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
