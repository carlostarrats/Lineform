import SwiftUI

@main
struct LineformApp: App {
    @StateObject private var textFormatMenuState = LineformTextFormatMenuState.shared

    init() {
        BundledFontRegistrar.registerFonts()
        LineformApp.configureDockIcon()
    }

    var body: some Scene {
        DocumentGroup(newDocument: LineformDocument()) { file in
            EditorContainerView(document: file.$document)
        }
        .commands {
            AppCommands(textFormatMenuState: textFormatMenuState)
        }
    }

    private static func configureDockIcon() {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else {
            return
        }

        NSApplication.shared.applicationIconImage = icon
    }
}
