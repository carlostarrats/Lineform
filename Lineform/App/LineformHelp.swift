import AppKit
import Foundation

enum LineformHelp {
    static func openMarkdownGuide(bundle: Bundle = .main, workspace: NSWorkspace = .shared) {
        guard let url = bundle.url(forResource: "MarkdownGuide", withExtension: "md") else {
            return
        }

        workspace.open(url)
    }
}
