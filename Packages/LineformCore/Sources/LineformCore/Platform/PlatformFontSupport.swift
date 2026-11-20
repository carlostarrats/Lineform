#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum PlatformFontTrait: Sendable {
    case bold
    case italic
}

/// `font` with `trait` added.
///
/// macOS: `NSFontManager.shared.convert(_:toHaveTrait:)`, the call the Mac renderer has always
/// made. iOS: the font's descriptor with the trait added to its existing symbolic traits, or
/// `font` itself when no such face exists.
public func lineformFont(_ font: PlatformFont, adding trait: PlatformFontTrait) -> PlatformFont {
    #if os(macOS)
    return NSFontManager.shared.convert(font, toHaveTrait: trait == .bold ? .boldFontMask : .italicFontMask)
    #else
    let added: UIFontDescriptor.SymbolicTraits = trait == .bold ? .traitBold : .traitItalic
    let traits = font.fontDescriptor.symbolicTraits.union(added)
    guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
    return UIFont(descriptor: descriptor, size: font.pointSize)
    #endif
}
