import SwiftUI

@main
struct LineformApp: App {
    @NSApplicationDelegateAdaptor(LineformAppDelegate.self) private var appDelegate
    @StateObject private var textFormatMenuState = LineformTextFormatMenuState.shared

    init() {
        BundledFontRegistrar.registerFonts()
        NSWindow.allowsAutomaticWindowTabbing = false
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
            AppCommands(textFormatMenuState: textFormatMenuState)
        }
        // Settings deliberately has NO `Settings { }` scene: it presents as a
        // Muse-style in-window modal (SettingsModal, same chrome as the Info
        // modal) via the Settings… item AppCommands adds to the app menu (⌘,).
    }
}

enum LineformWindowDefaults {
    static let defaultWidth: CGFloat = 1_360
    static let defaultHeight: CGFloat = 840
}
