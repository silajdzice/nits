import os

/// Unified-log channels. Read them with:
///   log show --last 1h --info --predicate 'subsystem == "com.edhem.nits"'
enum Log {
    static let displays = Logger(subsystem: "com.edhem.nits", category: "displays")
    static let menu = Logger(subsystem: "com.edhem.nits", category: "menu")
}
