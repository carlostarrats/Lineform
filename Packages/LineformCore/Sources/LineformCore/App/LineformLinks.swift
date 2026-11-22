import Foundation

/// The web pages both apps link to: the guide, the privacy policy and the terms of use. The
/// Mac's Help menu (`AppMenuConfiguration`) forwards to these; the iPhone's Menu sheet opens them
/// from its Document section.
public enum LineformLinks {
    public static let privacyPolicyURL = "https://lineform.app/privacy"
    public static let termsOfUseURL = "https://lineform.app/terms"
    public static let guideURL = "https://lineform.app/info/"
}
