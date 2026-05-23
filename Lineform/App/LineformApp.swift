import SwiftUI

@main
struct LineformApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: LineformDocument()) { file in
            EditorContainerView(document: file.$document)
        }
        .commands {
            AppCommands()
        }
    }
}
