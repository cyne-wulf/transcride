import Foundation

/// The push-to-media primitives shared by `AtomicFile` and the live recording
/// journals. On APFS a plain `fsync` only reaches the drive's volatile cache;
/// `F_FULLFSYNC` is the one call that forces both the data and the file-size
/// metadata onto permanent storage, which is what makes a grow-only journal's
/// duration survive power loss.
enum FileDurability {
    /// The strongest guarantee a barrier actually achieved. Some file systems
    /// (network shares, certain external enclosures) reject `F_FULLFSYNC`.
    enum AchievedLevel: Comparable, Sendable {
        /// Plain `fsync(2)`: data reached the device, possibly only its cache.
        case fsync
        /// `F_BARRIERFSYNC`: ordered ahead of later writes, not yet durable.
        case barrier
        /// `F_FULLFSYNC`: data and metadata are on permanent storage.
        case full
    }

    /// Pushes everything written to `fileDescriptor` toward permanent storage,
    /// degrading through `F_FULLFSYNC` → `F_BARRIERFSYNC` → `fsync`. Returns
    /// the level that succeeded, or nil when even `fsync` failed.
    @discardableResult
    static func barrier(fileDescriptor: Int32) -> AchievedLevel? {
        if fcntl(fileDescriptor, F_FULLFSYNC) != -1 { return .full }
        if fcntl(fileDescriptor, F_BARRIERFSYNC) != -1 { return .barrier }
        if fsync(fileDescriptor) == 0 { return .fsync }
        return nil
    }

    /// Best effort: fsyncs a directory so a rename or file creation recorded
    /// inside it becomes durable.
    static func syncDirectory(at url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            _ = fsync(descriptor)
        }
    }
}
