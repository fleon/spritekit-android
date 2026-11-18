import Foundation
import Testing
@testable import PlatformShim

// User defaults under launch arguments, as Apple keeps them. Measured on a
// Mac (macOS 27.2) with a tool launched as `tool -k fromArg`:
//
//   before   object(k) fromArg   argument domain k fromArg   saved k nil
//   set k    object(k) fromArg   argument domain k fromArg   saved k written
//   (disk)   { k = written; }
//   next launch, no argument: object(k) written
//   argument domain set again without k: object(k) is the saved value
//   removeVolatileDomain(argument domain): no change (only a set replaces it)
//
// The suite below runs those cases on the host, against Apple's own
// Foundation, and the shim's pieces against them. The argument domain is
// the process's, so the suite runs alone and puts it back.

private func scratchDefaults() -> (UserDefaults, String) {
    let name = "saved-defaults-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
}

/// Runs `body` with `arguments` as the argument domain, then restores it.
private func withArguments(_ arguments: [String: Any], in defaults: UserDefaults, _ body: () throws -> Void) rethrows {
    let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(saved.merging(arguments) { $1 }, forName: UserDefaults.argumentDomain)
    defer {
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
    }
    try body()
}

/// User defaults whose volatile domains behave as corelibs' do on Android:
/// `setVolatileDomain` merges into the domain already there rather than
/// replacing it, and reads look in the argument domain first.
private final class CorelibsVolatileDefaults: UserDefaults {
    private var domains: [String: [String: Any]] = [:]

    override func volatileDomain(forName domainName: String) -> [String: Any] {
        domains[domainName] ?? [:]
    }

    override func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {
        domains[domainName, default: [:]].merge(domain) { $1 }
    }

    override func removeVolatileDomain(forName domainName: String) {
        domains[domainName] = nil
    }

    override func object(forKey defaultName: String) -> Any? {
        domains[UserDefaults.argumentDomain]?[defaultName] ?? super.object(forKey: defaultName)
    }
}

@Suite("Saved defaults under launch arguments", .serialized)
struct SavedDefaultsTests {
    @Test("Apple saves a value set under an argument and keeps reading the argument")
    func appleKeepsDomainsApart() throws {
        let (defaults, name) = scratchDefaults()
        try withArguments(["k": "fromArg"], in: defaults) {
            defaults.set("written", forKey: "k")
            #expect(defaults.string(forKey: "k") == "fromArg")
            #expect(defaults.persistentDomain(forName: name)?["k"] as? String == "written")

            // Removing the argument domain leaves it as it was on Apple.
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            #expect(defaults.string(forKey: "k") == "fromArg")

            // The argument domain set again without the key: the saved value shows.
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments.removeValue(forKey: "k")
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            #expect(defaults.string(forKey: "k") == "written")
        }
    }

    @Test("What's saved holds the app's values, a key under an argument included, and no arguments")
    func storedValues() throws {
        let (defaults, name) = scratchDefaults()
        defaults.set("plain", forKey: "plain")
        try withArguments(["k": "fromArg", "onlyArgument": "x"], in: defaults) {
            defaults.set("written", forKey: "k")
            let before = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            let stored = SavedDefaults.stored(in: defaults, persistentDomain: name)
            // Read without touching the argument domain.
            #expect(NSDictionary(dictionary: defaults.volatileDomain(forName: UserDefaults.argumentDomain)).isEqual(to: before))
            #expect(stored["k"] as? String == "written")
            #expect(stored["plain"] as? String == "plain")
            #expect(stored["onlyArgument"] == nil)
            // And the arguments are back in place for the rest of the run.
            #expect(defaults.string(forKey: "k") == "fromArg")
            #expect(defaults.string(forKey: "onlyArgument") == "x")
        }
    }

    @Test("On corelibs too: a key under an argument is saved, the arguments aren't")
    func storedValuesOnCorelibs() throws {
        let name = "saved-defaults-corelibs-" + UUID().uuidString
        let defaults = try #require(CorelibsVolatileDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defaults.setVolatileDomain(["k": "fromArg", "onlyArgument": "x"], forName: UserDefaults.argumentDomain)
        defaults.set("written", forKey: "k")
        let stored = SavedDefaults.stored(in: defaults, persistentDomain: name)
        #expect(stored["k"] as? String == "written")
        #expect(stored["onlyArgument"] == nil)
        #expect(defaults.string(forKey: "k") == "fromArg")
        // Nothing removed from, or merged into, the argument domain.
        #expect(defaults.volatileDomain(forName: UserDefaults.argumentDomain).count == 2)
    }

    @Test("A synced key passed as an argument is adopted: it leaves the argument domain, its value saved")
    func adoptionOnCorelibs() throws {
        let name = "saved-defaults-adopt-" + UUID().uuidString
        let defaults = try #require(CorelibsVolatileDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defaults.setVolatileDomain(["player": "fromArg", "SafeAreaInsets": "62,0,34,0"], forName: UserDefaults.argumentDomain)
        let engine = SyncEngine(defaults: defaults, cloud: MemoryCloud(), now: { 100 }) { _ in }
        engine.start(syncing: [["player": .latest]], adoptingLaunchArguments: true)

        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        #expect(arguments["player"] == nil)
        #expect(arguments["SafeAreaInsets"] as? String == "62,0,34,0")
        #expect(defaults.string(forKey: "player") == "fromArg")
        #expect(SavedDefaults.stored(in: defaults, persistentDomain: name)["player"] as? String == "fromArg")
    }
}
