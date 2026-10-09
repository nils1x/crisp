import Foundation

/// Breadcrumbs for "Crisp vanished from the menu bar". macOS does not always keep a crash
/// report for a menu bar app, so record why the process went away in a file we control:
/// a signal or uncaught exception writes the reason and backtrace, a normal quit writes
/// a clean-exit marker that overwrites it. An empty or stale file after a disappearance
/// means the process was killed from outside (replaced bundle, logout, `pkill`).
enum CrashLog {
    private static var url: URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.nils.crisp", isDirectory: true)
        guard let base else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("exit.log")
    }

    static func install() {
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(signalNumber, SIG_IGN)
            signal(signalNumber, crashSignalHandler)
        }
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
    }

    static func noteCleanExit() {
        write("clean exit at \(Date())")
    }

    static func record(_ text: String) {
        write(text)
    }

    private static func write(_ text: String) {
        guard let url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Signal handlers cannot capture context, so the handlers stay plain C functions.
private func crashSignalHandler(_ number: Int32) {
    let stack = Thread.callStackSymbols.joined(separator: "\n")
    CrashLog.record("signal \(number)\n\(stack)")
    exit(number)
}

private func uncaughtExceptionHandler(_ exception: NSException) {
    CrashLog.record("exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                    + exception.callStackSymbols.joined(separator: "\n"))
}
