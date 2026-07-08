import Foundation

/// Dead-simple diagnostic log for development: appends timestamped lines to
/// `<container>/Library/Application Support/transcride-debug.log`.
enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "transcride-debug.log")
    }()

    static func append(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
