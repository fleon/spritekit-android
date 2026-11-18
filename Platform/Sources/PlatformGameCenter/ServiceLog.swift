import Foundation
#if !SPRITEKIT_SHIM
import os
#endif

/// Apple's unified log under the game's subsystem; on Android, errors to
/// standard output.
struct ServiceLog {
    #if SPRITEKIT_SHIM
    init(subsystem: String, category: String) {}

    func debug(_ message: @autoclosure () -> String) {}

    func info(_ message: @autoclosure () -> String) {}

    func error(_ message: @autoclosure () -> String) {
        print("[GameCenter] \(message())")
    }
    #else
    private let logger: Logger

    init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }

    func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }
    #endif
}
