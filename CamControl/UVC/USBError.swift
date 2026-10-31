//
//  USBError.swift
//  Error thrown when a USB operation fails.
//
//  Carries a human-readable message plus the Mach/IOKit return code (0 when no
//  code is available). Formatted as "<message> [<mach error string>, code <code>]".
//

import IOKit

struct USBError: Error, CustomStringConvertible {
    /// Error message (without the code suffix).
    let message: String
    /// Mach/IOKit error code, or 0 if no code is available.
    let code: IOReturn

    init(message: String, code: IOReturn = 0) {
        self.message = message
        self.code = code
    }

    var description: String {
        guard code != 0 else { return message }
        return "\(message) [\(String(cString: mach_error_string(code))), code \(code)]"
    }

    /// Throws a `USBError` if `code` indicates an error.
    ///
    /// - Parameters:
    ///   - code: Mach/IOKit return code
    ///   - message: additional information for the error message
    static func check(_ code: IOReturn, _ message: @autoclosure () -> String) throws {
        if code != 0 {
            throw USBError(message: message(), code: code)
        }
    }
}
