import SwiftUI

@main
struct LineformApp: App {
    @NSApplicationDelegateAdaptor(LineformAppDelegate.self) private var appDelegate
    @StateObject private var textFormatMenuState = LineformTextFormatMenuState.shared
    private let updaterController = LineformUpdaterController.shared

    init() {
        BundledFontRegistrar.registerFonts()
        LineformApp.configureDockIcon()
    }

    var body: some Scene {
        DocumentGroup(newDocument: LineformDocument()) { file in
            EditorContainerView(document: file.$document)
        }
        .defaultSize(
            width: LineformWindowDefaults.defaultWidth,
            height: LineformWindowDefaults.defaultHeight
        )
        .commands {
            AppCommands(
                textFormatMenuState: textFormatMenuState,
                updaterController: updaterController
            )
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

enum LineformWindowDefaults {
    static let defaultWidth: CGFloat = 1_360
    static let defaultHeight: CGFloat = 840
}
