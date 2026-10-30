import Darwin
import Foundation
import ReaderShared

public let maxConcurrentRequests = 4
let connectionTimeoutSeconds = 30

public struct SetupError: Error, CustomStringConvertible {
    public let description: String
}

private func errnoText() -> String { String(cString: strerror(errno)) }

/// Serializes socket setup: umask and the working directory are process-wide.
private let setupLock = NSLock()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

/// Unix-socket server answering the fixed set of read-only requests.
///
/// The service holds Full Disk Access, so every filesystem change it makes
/// (mkdir, chmod, unlink, bind) goes through descriptors for directories it
/// has verified, never through a path another process could swap.
public final class SocketServer {
    let store: Store
    let listenFD: Int32
    let dirFD: Int32
    let sockName: String
    let sockInode: ino_t
    private let slots = DispatchSemaphore(value: maxConcurrentRequests)
    private let state = NSLock()
    private var closed = false
    private var serving = false

    private init(store: Store, listenFD: Int32, dirFD: Int32, sockName: String, sockInode: ino_t) {
        self.store = store
        self.listenFD = listenFD
        self.dirFD = dirFD
        self.sockName = sockName
        self.sockInode = sockInode
    }

    public static func bind(store: Store, path: String) throws -> SocketServer {
        setupLock.lock()
        defer { setupLock.unlock() }
        let url = URL(fileURLWithPath: path)
        let dirFD = try openDirNoFollow(url.deletingLastPathComponent().path)
        do {
            var st = stat()
            guard fstat(dirFD, &st) == 0, st.st_uid == getuid() else {
                throw SetupError(description: "\(url.deletingLastPathComponent().path) must be owned by uid \(getuid())")
            }
            guard fchmod(dirFD, 0o700) == 0 else { throw SetupError(description: "fchmod: \(errnoText())") }
            let name = url.lastPathComponent
            if fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFSOCK else {
                    throw SetupError(description: "\(path) exists and is not a socket")
                }
                guard unlinkat(dirFD, name, 0) == 0 else { throw SetupError(description: "unlink: \(errnoText())") }
            }
            let fd = try bindInside(dirFD: dirFD, name: name)
            guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                Darwin.close(fd)
                throw SetupError(description: "stat socket: \(errnoText())")
            }
            return SocketServer(store: store, listenFD: fd, dirFD: dirFD, sockName: name, sockInode: st.st_ino)
        } catch {
            Darwin.close(dirFD)
            throw error
        }
    }

    /// Open a directory, creating missing parts, refusing a symlink at any step.
    static func openDirNoFollow(_ directory: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open("/", flags)
        guard fd >= 0 else { throw SetupError(description: "open /: \(errnoText())") }
        for part in directory.split(separator: "/").map(String.init) {
            _ = mkdirat(fd, part, 0o700)
            let child = openat(fd, part, flags)
            let err = errnoText()
            Darwin.close(fd)
            guard child >= 0 else {
                throw SetupError(description: "\(directory): \(part) is not a plain directory (\(err))")
            }
            fd = child
        }
        return fd
    }

    /// bind() takes a path, so bind a bare name from inside the verified
    /// directory; umask makes the socket 0600 as it is created.
    private static func bindInside(dirFD: Int32, name: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetupError(description: "socket: \(errnoText())") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let nameBytes = Array(name.utf8)
        guard nameBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SetupError(description: "socket name too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: nameBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let cwd = open(".", O_RDONLY | O_CLOEXEC)
        let oldMask = umask(0o177)
        let rc: Int32
        let err: String
        if fchdir(dirFD) == 0 {
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            err = errnoText()
        } else {
            rc = -1
            err = errnoText()
        }
        umask(oldMask)
        if cwd >= 0 {
            _ = fchdir(cwd)
            Darwin.close(cwd)
        }

        guard rc == 0 else {
            Darwin.close(fd)
            throw SetupError(description: "bind: \(err)")
        }
        guard listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw SetupError(description: "listen: \(errnoText())")
        }
        return fd
    }

    private var isClosed: Bool {
        state.lock()
        defer { state.unlock() }
        return closed
    }

    /// Accept connections until `close()` is called. The loop owns the
    /// listening descriptor while it runs, so a closed server never polls or
    /// accepts on a descriptor number that has since been reused.
    public func serveForever() {
        state.lock()
        if closed || serving {
            state.unlock()
            return
        }
        serving = true
        state.unlock()
        defer { Darwin.close(listenFD) }
        while !isClosed {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 200) > 0, !isClosed else { continue }
            let conn = accept(listenFD, nil, nil)
            guard conn >= 0 else { continue }
            DispatchQueue.global().async { self.handle(conn) }
        }
    }

    /// Stop accepting, and remove the socket if it is still the one we created.
    public func close() {
        state.lock()
        defer { state.unlock() }
        if closed { return }
        closed = true
        if !serving { Darwin.close(listenFD) }
        var st = stat()
        if fstatat(dirFD, sockName, &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_ino == sockInode {
            unlinkat(dirFD, sockName, 0)
        }
        Darwin.close(dirFD)
    }

    func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: connectionTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let started = DispatchTime.now()
        var op: String?
        let response: JSONValue
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 || uid != getuid() {
            response = ["ok": false, "error": "permission denied"]
        } else if slots.wait(timeout: .now()) == .timedOut {
            response = ["ok": false, "error": "busy, retry shortly"]
        } else {
            defer { slots.signal() }
            switch readRequest(fd) {
            case .line(let data):
                (op, response) = handleRequest(store, data)
            case .tooLarge:
                response = ["ok": false, "error": .string("request larger than \(maxRequestBytes) bytes")]
            case .ioError:
                log("op=None status=io-error")
                return
            }
        }
        // Log only the op and outcome: never request args or message contents.
        let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        log("op=\(op ?? "None") ok=\(response["ok"]?.bool ?? false) ms=\(ms)")
        let data = encodeResponse(op: op, response)
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                // MSG_NOSIGNAL, not SO_NOSIGPIPE: setsockopt fails once the peer has gone.
                let n = send(fd, buf.baseAddress! + sent, buf.count - sent, MSG_NOSIGNAL)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    enum ReadResult { case line(Data), tooLarge, ioError }

    func readRequest(_ fd: Int32) -> ReadResult {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: maxRequestBytes + 1)
        while !buf.contains(0x0A) {
            let n = recv(fd, &chunk, maxRequestBytes + 1 - buf.count, 0)
            if n < 0 { return .ioError }
            if n == 0 { break }
            buf += chunk[0..<n]
            if buf.count > maxRequestBytes { return .tooLarge }
        }
        if let nl = buf.firstIndex(of: 0x0A) { buf = Array(buf[..<nl]) }
        return .line(Data(buf))
    }
}

/// Entry point for the service binary.
public func serviceMain(_ args: [String]) -> Int32 {
    if !args.isEmpty {
        FileHandle.standardError.write(Data("messages-reader-service takes no arguments\n".utf8))
        return 2
    }
    signal(SIGPIPE, SIG_IGN)
    let server: SocketServer
    do {
        server = try SocketServer.bind(store: Store(), path: Paths.socketPath)
    } catch {
        log("startup failed: \(error)")
        return 1
    }
    // launchd stops the job with SIGTERM.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    term.setEventHandler {
        server.close()
        exit(0)
    }
    term.resume()
    log("listening on \(Paths.socketPath)")
    server.serveForever()
    return 0
}
