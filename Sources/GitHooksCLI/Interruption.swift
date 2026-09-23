import Darwin
import Synchronization

/// The number of the signal that interrupted the hook, or 0.
///
/// The signal handler writes it; commands read it.
private let interruptingSignal = Atomic<Int32>(0)

/// Lets a hook stop cleanly when the user presses Ctrl-C, the terminal closes, or something sends it SIGTERM.
///
/// Without handlers, the signal ends the hook at once: its build keeps running, and its temporary worktree and lint
/// snapshot stay on disk. With them, the command that is running stops, `Interrupted` propagates, and the cleanup on
/// its way runs before the hook exits. Every wait in the hook checks `signal` at least ten times a second.
enum Interruption {
    static let handledSignals = [SIGINT, SIGTERM, SIGHUP]

    /// Record the handled signals instead of exiting on them.
    ///
    /// The waits in the hook poll `signal`, so interrupted system calls restart as usual.
    static func install() {
        // Initialize the lazy global here: its one-time initialization is not safe inside a signal handler.
        _ = interruptingSignal.load(ordering: .relaxed)
        for signal in handledSignals {
            var action = sigaction()
            // The handler only stores the signal number: an atomic store is safe in a signal handler.
            action.__sigaction_u.__sa_handler = { interruptingSignal.store($0, ordering: .relaxed) }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            sigaction(signal, &action, nil)
        }
    }

    /// The signal that interrupted the hook, if one did.
    static var signal: Int32? {
        let signal = interruptingSignal.load(ordering: .relaxed)
        return signal == 0 ? nil : signal
    }

    /// Throw `Interrupted` if a signal interrupted the hook.
    static func check() throws {
        if let signal {
            throw Interrupted(signal: signal)
        }
    }
}

/// A signal interrupted the hook.
///
/// The hook exits with status 128 + `signal` once the cleanup has run.
struct Interrupted: Error {
    let signal: Int32
}
