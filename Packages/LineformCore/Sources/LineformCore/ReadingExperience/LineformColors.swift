import CoreGraphics

public enum LineformColors {
    public static let primaryText = color(hex: 0x1F1F1F)
    public static let originalBackground = color(hex: 0xFFFFFF)
    public static let paperBackground = color(hex: 0xF6F3ED)
    public static let calmBackground = color(hex: 0xF2F4F5)
    public static let inspectorLightBackground = color(hex: 0xFDFDFD)
    public static let darkControlBackground = color(hex: 0x1A1A1A)

    private static func color(hex: Int) -> PlatformColor {
        PlatformColor.lineformSRGB(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
