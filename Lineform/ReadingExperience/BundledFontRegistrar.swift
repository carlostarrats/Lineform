import CoreText
import Foundation

enum BundledFontRegistrar {
    static let fontFileNames = [
        "AtkinsonHyperlegible-Regular.ttf",
        "AtkinsonHyperlegible-Bold.ttf",
        "AtkinsonHyperlegible-Italic.ttf",
        "AtkinsonHyperlegible-BoldItalic.ttf",
        "OpenDyslexic-Regular.otf",
        "OpenDyslexic-Bold.otf",
        "OpenDyslexic-Italic.otf",
        "OpenDyslexic-BoldItalic.otf",
    ]

    static func registerFonts(bundle: Bundle = .main) {
        for fileName in fontFileNames {
            guard let url = bundle.url(forResource: fileName, withExtension: nil, subdirectory: "Fonts") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
