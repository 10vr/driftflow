import Foundation

/// Runs main-actor code from an AppKit callback that is already on the main thread (a timer, a
/// notification observed on `.main`, an event monitor, a menu action).
///
/// `MainActor.assumeIsolated` does the same, but first asks the Swift runtime which executor is
/// current, and that check crashed Driftflow on macOS 26 (EXC_BAD_ACCESS in
/// swift_task_isMainExecutorImpl, from the permission timer). Asking the thread is enough here.
func onMainThread<T>(_ body: @MainActor () -> T) -> T {
    precondition(Thread.isMainThread, "onMainThread called off the main thread")
    return withoutActuallyEscaping(body) { body in
        unsafeBitCast(body, to: (() -> T).self)()
    }
}
