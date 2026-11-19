import Foundation

extension Bundle {
    /// LineformCore's own resource bundle (its String Catalog), i.e. `Bundle.module`.
    ///
    /// `Bundle.module` is internal, and a public function's default argument may only name public
    /// declarations, so public API that takes `in bundle: Bundle` defaults to this instead. The
    /// app's tests also load per-language `.lproj` folders from it.
    public static var lineformCore: Bundle { .module }
}
