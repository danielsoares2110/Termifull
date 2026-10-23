//
//  PTY.swift
//  GlassTerm
//
//  forkpty(3)-based pseudo-terminal process with a non-blocking master fd.
//
//  Design notes (see ARCHITECTURE.md §2):
//  * The master fd is put in O_NONBLOCK mode. Each session owns exactly one
//    DispatchSourceRead on a private serial queue; the read handler loops
//    read(2) until EAGAIN/EINTR and forwards each chunk to the main queue.
//  * `write` is asynchronous: each call is enqueued on a dedicated serial
//    writer queue, which preserves ordering and never blocks the caller
//    (the main thread). Inside that queue the write loop handles partial
//    writes and EAGAIN (bounded poll(POLLOUT) between attempts). It holds the
//    state lock while writing, which guarantees the master fd cannot be
//    closed underneath an in-flight write.
//  * Exactly one place closes the master fd: the read source's cancel handler
//    (the documented-safe place to close a dispatch source's descriptor).
//  * Exactly one place reaps the child and delivers onExit: `finalize`.
//  * No Swift heap object is touched by the child between fork and execve:
//    every C string and the argv/envp pointer arrays are allocated in the
//    parent before forkpty().
//

import Foundation
import Darwin

enum PtyError: Error {
    case alreadyRunning
    case spawnFailed(Int32)   // errno from forkpty(3)
    case openFailed(Int32)    // errno from fcntl(2) on the master fd
}

final class PtyProcess {

    // MARK: - Public surface

    /// Data read from the master side. ALWAYS delivered on the main queue.
    var onData: ((Data) -> Void)?

    /// Exit status (raw waitpid status, e.g. 7 << 8 for `exit 7`).
    /// ALWAYS delivered on the main queue, at most once per session.
    var onExit: ((Int32) -> Void)?

    var pid: pid_t {
        stateLock.lock(); defer { stateLock.unlock() }
        return _pid
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _running
    }

    var masterFD: Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return _masterFD
    }

    // MARK: - Private state

    private static let readChunkSize = 65536

    private let stateLock = NSLock()

    private var _pid: pid_t = -1
    private var _masterFD: Int32 = -1
    private var _running = false
    private var _started = false
    private var _exiting = false        // finalize() in progress
    private var _reaped = false         // child has been waitpid(2)-ed (pid is stale)
    private var _exitDelivered = false  // onExit has been (or is about to be) dispatched
    private var _generation: UInt64 = 0 // bumped per session; stales queued handlers
    private var _readSource: DispatchSourceRead?

    private let readQueue = DispatchQueue(label: "com.glassterm.pty.read")
    private let writeQueue = DispatchQueue(label: "com.glassterm.pty.write")
    private let queueKey = DispatchSpecificKey<UInt8>()

    init() {
        readQueue.setSpecific(key: queueKey, value: 1)
        writeQueue.setSpecific(key: queueKey, value: 2)
    }

    deinit {
        terminate()
    }

    // MARK: - Spawning

    func start(shell: String,
               args: [String],
               environment: [String: String],
               workingDirectory: String,
               cols: Int,
               rows: Int) throws {

        stateLock.lock()
        let busy = _running || _masterFD >= 0
        stateLock.unlock()
        if busy { throw PtyError.alreadyRunning }

        // ---- Pre-allocate every C string the child needs (before fork!) ----
        let shellBase = (shell as NSString).lastPathComponent
        var argStrings: [String] = ["-" + shellBase, "-l"]   // login shell
        argStrings.append(contentsOf: args)

        let envStrings: [String] = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        let argc = argStrings.count
        let envc = envStrings.count

        let argvBuf = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argc + 1)
        let envpBuf = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envc + 1)
        for (i, s) in argStrings.enumerated() { argvBuf[i] = strdup(s) }
        argvBuf[argc] = nil
        for (i, s) in envStrings.enumerated() { envpBuf[i] = strdup(s) }
        envpBuf[envc] = nil

        let shellBuf: UnsafeMutablePointer<CChar>? = strdup(shell)
        let cwdBuf: UnsafeMutablePointer<CChar>? = strdup(workingDirectory)

        // Parent-side cleanup. The child never returns here (execve or _exit).
        defer {
            for i in 0..<argc { free(argvBuf[i]) }
            for i in 0..<envc { free(envpBuf[i]) }
            argvBuf.deallocate()
            envpBuf.deallocate()
            free(shellBuf)
            free(cwdBuf)
        }

        // Darwin: forkpty(int *amaster, char *name, struct termios *termp,
        //                struct winsize *winp)  — termp is the third argument.
        var ws = winsize(ws_row: UInt16(clamping: max(1, rows)),
                         ws_col: UInt16(clamping: max(1, cols)),
                         ws_xpixel: 0,
                         ws_ypixel: 0)

        var master: Int32 = -1
        let childPID = forkpty(&master, nil, nil, &ws)

        if childPID < 0 {
            throw PtyError.spawnFailed(errno)
        }

        if childPID == 0 {
            // ---- Child: raw C memory + libc only until execve ----
            if cwdBuf != nil { _ = chdir(cwdBuf) }
            if shellBuf != nil { _ = execve(shellBuf, argvBuf, envpBuf) }
            _exit(127)
        }

        // ---- Parent ----
        guard master >= 0 else {
            _ = kill(childPID, SIGKILL)
            _ = waitpid(childPID, nil, 0)
            throw PtyError.spawnFailed(EIO)
        }

        // Non-blocking master: reads must never block the reader queue and
        // writes must never block the main thread.
        let currentFlags = fcntl(master, F_GETFL, 0)
        if currentFlags < 0 || fcntl(master, F_SETFL, currentFlags | O_NONBLOCK) < 0 {
            let failure = errno
            _ = kill(childPID, SIGKILL)
            _ = waitpid(childPID, nil, 0)
            close(master)
            throw PtyError.openFailed(failure)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        // The only place the master fd is closed, and it happens exactly once.
        source.setCancelHandler {
            close(master)
        }

        stateLock.lock()
        _generation &+= 1
        let generation = _generation
        _pid = childPID
        _masterFD = master
        _running = true
        _started = true
        _exiting = false
        _reaped = false
        _exitDelivered = false
        _readSource = source
        stateLock.unlock()

        source.setEventHandler { [weak self] in
            self?.handleReadable(generation: generation)
        }
        source.resume()
    }

    // MARK: - Reading (runs on readQueue)

    private func handleReadable(generation: UInt64) {
        stateLock.lock()
        let isCurrent = (_generation == generation)
        let fd = _masterFD
        stateLock.unlock()

        guard isCurrent, fd >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: PtyProcess.readChunkSize)

        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }

            if count > 0 {
                let chunk = Data(buffer[0..<count])
                DispatchQueue.main.async { [weak self] in
                    self?.onData?(chunk)
                }
                continue                       // drain until EAGAIN
            }

            if count == 0 {
                finalize(generation: generation)   // EOF: slave side closed
                return
            }

            let failure = errno
            if failure == EINTR { continue }
            if failure == EAGAIN || failure == EWOULDBLOCK { return }
            // EIO and anything else means the pty is gone.
            finalize(generation: generation)
            return
        }
    }

    // MARK: - Exit path (runs on readQueue)

    /// Reaps the child, closes the master and delivers `onExit` — once.
    private func finalize(generation: UInt64) {
        stateLock.lock()
        guard _generation == generation, !_exiting else {
            stateLock.unlock()
            return
        }
        _exiting = true
        _running = false
        let childPID = _pid
        let source = _readSource
        _readSource = nil
        _masterFD = -1            // no further writes/resizes target this fd
        stateLock.unlock()

        // Closing happens in the cancel handler (exactly once).
        source?.cancel()

        var status: Int32 = 0
        if childPID > 0 {
            var rawStatus: Int32 = 0
            var result = waitpid(childPID, &rawStatus, WNOHANG)
            if result == 0 {
                // Slave side is gone but the child still lives (e.g. it closed its
                // tty and kept running). Give it a bounded moment, then escalate so
                // this queue can never hang on an orphaned process.
                let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                while true {
                    usleep(5_000)
                    result = waitpid(childPID, &rawStatus, WNOHANG)
                    if result != 0 { break }
                    if DispatchTime.now().uptimeNanoseconds >= deadline {
                        _ = kill(childPID, SIGKILL)
                        result = waitpid(childPID, &rawStatus, 0)  // bounded: SIGKILL is fatal
                        break
                    }
                }
            }
            if result == childPID {
                status = rawStatus
            } else if result < 0 && errno == ECHILD {
                status = 0
            }
        }

        stateLock.lock()
        _reaped = true
        _pid = -1
        _exitDelivered = true
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onExit?(status)
        }
    }

    // MARK: - Writing

    /// Queues `data` for the child. Partial writes and EAGAIN are handled on a
    /// dedicated serial writer queue, so the caller (typically the main thread)
    /// never blocks and chunk ordering is preserved.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [weak self] in
            self?.performWrite(data)
        }
    }

    private func performWrite(_ data: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let fd = _masterFD
        guard fd >= 0 else { return }

        var offset = 0
        let total = data.count

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < total {
                let written = Darwin.write(fd, base + offset, total - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 {
                    let failure = errno
                    if failure == EINTR { continue }
                    if failure == EAGAIN || failure == EWOULDBLOCK {
                        // Back-pressure: wait (bounded) for writability, still on
                        // the writer queue and under the state lock, so the fd
                        // cannot be closed underneath us.
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let ready = Darwin.poll(&descriptor, 1, 50)
                        if ready < 0 && errno != EINTR { return }
                        continue
                    }
                    return   // EPIPE / EBADF: the pty is gone; exit path will follow
                }
                return
            }
        }
    }

    // MARK: - Window size

    func resize(cols: Int, rows: Int) {
        guard cols >= 1, rows >= 1 else { return }

        stateLock.lock()
        let fd = _masterFD
        let childPID = _pid
        stateLock.unlock()

        guard fd >= 0 else { return }   // before start / after exit: no-op

        var ws = winsize(ws_row: UInt16(clamping: rows),
                         ws_col: UInt16(clamping: cols),
                         ws_xpixel: 0,
                         ws_ypixel: 0)
        if ioctl(fd, TIOCSWINSZ, &ws) == 0, childPID > 0 {
            _ = kill(childPID, SIGWINCH)
        }
    }

    // MARK: - Termination

    /// Idempotent: SIGHUP, a ~300 ms grace period, then SIGKILL. Joins the reader
    /// queue so the master fd is closed and `onExit` is delivered exactly once.
    func terminate() {
        stateLock.lock()
        let childPID = _pid
        let wasStarted = _started
        let alreadyDelivered = _exitDelivered
        let alreadyReaped = _reaped
        let generation = _generation
        stateLock.unlock()

        guard wasStarted else { return }

        if childPID > 0 && !alreadyDelivered && !alreadyReaped {
            _ = kill(childPID, SIGHUP)

            let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                stateLock.lock()
                let done = _exitDelivered || _reaped
                stateLock.unlock()
                if done { break }
                usleep(2_000)
            }

            stateLock.lock()
            let done = _exitDelivered || _reaped
            let stillAlivePID = _reaped ? -1 : _pid
            stateLock.unlock()

            if !done, stillAlivePID > 0 {
                _ = kill(stillAlivePID, SIGKILL)
            }
        }

        // Join the reader: this finalizes (reap + close + onExit) if the reader
        // has not already done so, and flushes the source's cancel handler.
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            readQueue.sync { self.finalize(generation: generation) }
            readQueue.sync { }
        } else {
            finalize(generation: generation)
        }
    }
}
