import SwiftUI

@main
struct LineformApp: App {
    init() {
        BundledFontRegistrar.registerFonts()
    }

    var body: some Scene {
        DocumentGroup(newDocument: LineformDocument()) { file in
            EditorContainerView(document: file.$document)
        }
        .commands {
            AppCommands()
        }
    }
}
