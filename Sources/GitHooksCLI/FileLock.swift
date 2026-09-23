import Darwin
import Foundation

/// An exclusive advisory lock on a file, held until the value is destroyed or the process exits.
struct FileLock: ~Copyable {
    private let descriptor: Int32

    /// Take the lock, waiting while another process holds it.
    /// - Parameters:
    ///   - path: The lock file, created if missing.
    ///   - waiting: Called once, before waiting, when another process holds the lock.
    /// - Throws: `Interrupted` when a signal interrupts the hook while it waits, or `HookError` when the file cannot be
    ///   opened or locked.
    init(path: String, waiting: () -> Void = {}) throws {
        descriptor = try Self.lockedDescriptor(path: path, waiting: waiting)
    }

    /// Take the lock only if no other process holds it.
    init?(ifAvailableAt path: String) {
        guard let descriptor = Self.descriptorIfAvailable(path) else { return nil }
        self.descriptor = descriptor
    }

    private static func descriptorIfAvailable(_ path: String) -> Int32? {
        guard let descriptor = try? openLockFile(path) else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    deinit {
        // Closing the descriptor releases the lock.
        close(descriptor)
    }

    private static func lockedDescriptor(path: String, waiting: () -> Void) throws -> Int32 {
        let descriptor = try openLockFile(path)
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }

        waiting()
        // Poll rather than block, so that a signal that arrives just before the wait still ends it.
        var interval = 0.001
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            guard error == EWOULDBLOCK || error == EINTR else {
                close(descriptor)
                throw HookError.message("Could not lock \(path): \(String(cString: strerror(error)))")
            }
            if let signal = Interruption.signal {
                close(descriptor)
                throw Interrupted(signal: signal)
            }
            Thread.sleep(forTimeInterval: interval)
            interval = min(interval * 2, 0.1)
        }
        return descriptor
    }

    private static func openLockFile(_ path: String) throws -> Int32 {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw HookError.message("Could not open \(path): \(String(cString: strerror(errno)))")
        }
        return descriptor
    }
}
