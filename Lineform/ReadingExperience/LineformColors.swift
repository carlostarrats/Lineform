import AppKit

enum LineformColors {
    static let primaryText = color(hex: 0x1F1F1F)
    static let originalBackground = color(hex: 0xFFFFFF)
    static let paperBackground = color(hex: 0xF6F3ED)
    static let calmBackground = color(hex: 0xF2F4F5)
    static let inspectorLightBackground = color(hex: 0xFDFDFD)
    static let darkControlBackground = color(hex: 0x232323)

    private static func color(hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
