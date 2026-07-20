import Foundation

/// Write-temp-then-rename file writes. Every file write in the app goes through
/// here so a crash mid-write can never leave a corrupt or partial file.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        do {
            try data.write(to: tempURL, options: [])
            try synchronizeFile(at: tempURL)
            let result = tempURL.withUnsafeFileSystemRepresentation { temp in
                url.withUnsafeFileSystemRepresentation { dest in
                    rename(temp!, dest!)
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "Atomic rename failed: \(String(cString: strerror(errno)))",
                    NSFilePathErrorKey: url.path,
                ])
            }
            try synchronizeDirectory(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    static func synchronizeDirectory(at directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError(path: directory.path) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(path: directory.path) }
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(path: url.path) }
    }

    private static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(errno)),
                NSFilePathErrorKey: path,
            ]
        )
    }
}
