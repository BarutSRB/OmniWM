import os

enum WMLog {
    static let ax = Logger(subsystem: "com.omniwm", category: "ax")
    static let layout = Logger(subsystem: "com.omniwm", category: "layout")
    static let focus = Logger(subsystem: "com.omniwm", category: "focus")
    static let input = Logger(subsystem: "com.omniwm", category: "input")
    static let config = Logger(subsystem: "com.omniwm", category: "config")
    static let ipc = Logger(subsystem: "com.omniwm", category: "ipc")
    static let workspace = Logger(subsystem: "com.omniwm", category: "workspace")
}
