import Darwin
import Foundation

/// An exclusive advisory lock on a file, held until the value is destroyed or the process exits.
struct FileLock: ~Copyable {
    private let descriptor: Int32

    /// Take the lock, waiting while another process holds it.
    /// - Parameters:
    ///   - path: The lock file, created if missing.
    ///   - waiting: Called once, before waiting, when another process holds the lock.
    /// - Throws: `Interrupted` when a signal interrupts the wait, or `HookError` when the file cannot be opened.
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
        while flock(descriptor, LOCK_EX) != 0 {
            let error = errno
            // The signal handlers do not restart system calls, so an interruption ends the wait.
            if error == EINTR, let signal = Interruption.signal {
                close(descriptor)
                throw Interrupted(signal: signal)
            }
            guard error == EINTR else {
                close(descriptor)
                throw HookError.message("Could not lock \(path): \(String(cString: strerror(error)))")
            }
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
