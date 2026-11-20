// The Mac/iPhone seam. Every UI-framework import in LineformCore lives in this folder, each
// inside its own platform branch, so the rest of the package names only these aliases.
// Typealiases, not wrappers: on macOS they ARE the AppKit types, so the Mac app's call sites
// and values do not change.
#if os(macOS)
import AppKit

public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformImage = NSImage
public typealias PlatformEdgeInsets = NSEdgeInsets
/// AppKit's paragraph style. Same name on both platforms, but declared by the UI framework.
public typealias PlatformMutableParagraphStyle = NSMutableParagraphStyle
#else
import UIKit

public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformImage = UIImage
public typealias PlatformEdgeInsets = UIEdgeInsets
/// UIKit's paragraph style.
public typealias PlatformMutableParagraphStyle = NSMutableParagraphStyle
#endif
