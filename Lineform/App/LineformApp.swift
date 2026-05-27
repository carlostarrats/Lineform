import SwiftUI

@main
struct LineformApp: App {
    @StateObject private var textFormatMenuState = LineformTextFormatMenuState.shared

    init() {
        BundledFontRegistrar.registerFonts()
    }

    var body: some Scene {
        DocumentGroup(newDocument: LineformDocument()) { file in
            EditorContainerView(document: file.$document)
        }
        .commands {
            AppCommands(textFormatMenuState: textFormatMenuState)
        }
    }
}
