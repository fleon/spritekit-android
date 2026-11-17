#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// `Bundle.main`'s Info.plist values, as Android has them. The main bundle
/// here is `/system/bin` (the process is `app_process`), which has no
/// Info.plist, so the title's version line read "Version ()". The app's
/// `MainActivity` puts the APK's `versionName` and `versionCode` in the
/// environment before the Swift libraries load (`SKA_VERSION_NAME`,
/// `SKA_VERSION_CODE`), and this answers with them under Apple's
/// keys.
///
/// It shadows Foundation's `infoDictionary`: a member declared in a module
/// takes precedence over the same member of a module it imports, so the
/// game's `Bundle.main.infoDictionary` reaches this with no edit. Other
/// bundles (a language's `.lproj`) have no Info.plist here either.
public extension Bundle {
    var infoDictionary: [String: Any]? {
        let environment = ProcessInfo.processInfo.environment
        var info: [String: Any] = ["CFBundleIdentifier": AppIdentity.current.bundleIdentifier, "CFBundleName": AppIdentity.current.name]
        if let name = environment["SKA_VERSION_NAME"] { info["CFBundleShortVersionString"] = name }
        if let code = environment["SKA_VERSION_CODE"] { info["CFBundleVersion"] = code }
        return info
    }

    func object(forInfoDictionaryKey key: String) -> Any? {
        infoDictionary?[key]
    }
}
#endif
