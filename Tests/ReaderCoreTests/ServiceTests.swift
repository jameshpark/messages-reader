import Darwin
import Foundation
import Testing
@testable import ReaderCore
@testable import ReaderShared

@Suite struct ValidateTests {
    @Test(arguments: [
        ("[]", "JSON object"),
        (#"{"op": "send", "args": {"to": "x", "text": "hi"}}"#, "unknown op"),
        (#"{"op": "send_message"}"#, "unknown op"),
        (#"{"op": "delete"}"#, "unknown op"),
        (#"{"op": "sql", "args": {"query": "DELETE FROM message"}}"#, "unknown op"),
        (#"{"op": 5}"#, "unknown op"),
        (#"{"op": "check", "extra": 1}"#, "unknown request fields"),
        (#"{"op": "recent", "args": {"hours": 1, "send": true}}"#, "unknown args"),
        (#"{"op": "recent", "args": []}"#, "args must be"),
        (#"{"op": "recent", "args": {"limit": "5"}}"#, "integer"),
        (#"{"op": "recent", "args": {"limit": true}}"#, "integer"),
        (#"{"op": "recent", "args": {"limit": 501}}"#, "between"),
        (#"{"op": "recent", "args": {"hours": 0}}"#, "between"),
        (#"{"op": "search", "args": {}}"#, "query is required"),
        (#"{"op": "search", "args": {"query": "   "}}"#, "1-200"),
        (#"{"op": "search", "args": {"query": "\#(String(repeating: "x", count: 201))"}}"#, "1-200"),
        (#"{"op": "search", "args": {"query": "a\u0000b"}}"#, "control characters"),
        (#"{"op": "thread", "args": {"target": 5}}"#, "must be a string"),
    ])
    func rejects(_ json: String, _ message: String) throws {
        let request = try JSONValue.parse(Data(json.utf8))
        let error = #expect(throws: RequestError.self) { try validate(request) }
        #expect(error?.description.contains(message) == true, "\(String(describing: error))")
    }

    @Test func appliesDefaultsAndStrips() throws {
        #expect(try validate(["op": "search", "args": ["query": "  hi  "]])
            == Request(op: "search", ints: ["days": 365, "limit": 50], strings: ["query": "hi"]))
        #expect(try validate(["op": "attachments"])
            == Request(op: "attachments", ints: ["days": 30, "limit": 50], strings: [:]))
    }

    @Test func encodeResponseDropsOldestRowsToFit() throws {
        let rows: [JSONValue] = (0..<50).map { ["id": .int($0), "text": .string(String(repeating: "x", count: 100))] }
        let response: JSONValue = ["ok": true, "result": ["rows": .array(rows)]]
        let newestFirst = try JSONValue.parse(encodeResponse(op: "recent", response, limit: 2000))
        #expect(newestFirst["result"]?["truncated"] == true && newestFirst["result"]?.rows.first?["id"] == 0)
        let oldestFirst = try JSONValue.parse(encodeResponse(op: "thread", response, limit: 2000))
        #expect(oldestFirst["result"]?.rows.last?["id"] == 49)
        #expect(encodeResponse(op: "thread", response, limit: 2000).count <= 2000)
    }

    @Test func serviceMainRejectsArguments() {
        #expect(serviceMain(["--send"]) == 2)
    }
}

/// A server bound in a fresh short temp dir, serving on a background thread.
final class Running {
    let fixture = makeFixture()
    let root = makeTempDir()
    let path: String
    let server: SocketServer

    init() throws {
        path = root + "/state/s.sock"
        server = try SocketServer.bind(store: fixture.store, path: path)
        let server = self.server
        Thread.detachNewThread { server.serveForever() }
    }

    deinit {
        server.close()
        removeTree(root)
        removeTree(fixture.dir)
    }

    func raw(_ payload: Data) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        try connectUnix(fd, path)
        // The server may answer and close before an oversized payload is fully sent.
        payload.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        shutdown(fd, SHUT_WR)
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while case let n = recv(fd, &chunk, chunk.count, 0), n > 0 { out.append(contentsOf: chunk[0..<n]) }
        return try JSONValue.parse(out)
    }
}

func connectUnix(_ fd: Int32, _ path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { throw SetupError(description: "connect: \(errno)") }
}

func mode(_ path: String) -> (mode: mode_t, uid: uid_t) {
    var st = stat()
    precondition(lstat(path, &st) == 0)
    return (st.st_mode & 0o7777, st.st_uid)
}

@Suite struct SocketTests {
    @Test func socketAndDirectoryAreOwnerOnly() throws {
        let r = try Running()
        #expect(mode(r.path).mode == 0o600)
        #expect(mode(r.root + "/state").mode == 0o700 && mode(r.root + "/state").uid == getuid())
    }

    @Test func endToEndOps() throws {
        let r = try Running()
        #expect(try callService(op: "check", args: [:], socketPath: r.path)["result"]?["full_disk_access"] == true)
        let thread = try callService(op: "thread", args: ["target": "Alex Rivera"], socketPath: r.path)
        #expect(thread["ok"] == true && thread["result"]?.rows[2]["text"] == "decoded body 100% real")
        #expect(try callService(op: "chats", args: ["limit": 2], socketPath: r.path)["result"]?.rows.first?["chat_id"] == 13)
    }

    @Test(arguments: [
        (Data(#"{"op": "send", "args": {"to": "+15551230001", "text": "hi"}}"#.utf8) + [0x0A], "unknown op"),
        (Data(#"{"op": "check""#.utf8), "one line of JSON"),
        (Data([0xFF, 0xFE, 0x0A]), "one line of JSON"),
        (Data(), "one line of JSON"),
        (Data((#"{"op": "search", "args": {"query": ""# + String(repeating: "a", count: 5000) + #""}}"#).utf8) + [0x0A],
         "larger than"),
    ])
    func socketRejectsBadRequests(_ payload: Data, _ message: String) throws {
        let r = try Running()
        let response = try r.raw(payload)
        #expect(response["ok"] == false && response["error"]?.string?.contains(message) == true, "\(response)")
    }

    @Test func serviceErrorsReachTheClient() throws {
        let r = try Running()
        #expect(try callService(op: "thread", args: ["target": "Alex"], socketPath: r.path) == [
            "ok": false, "error": "2 contacts match 'Alex'; run `contact` and pass a phone number or email",
        ])
    }

    @Test func peerUIDIsTheConnectingUser() throws {
        let r = try Running()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        try connectUnix(fd, r.path)
        var uid: uid_t = 0, gid: gid_t = 0
        #expect(getpeereid(fd, &uid, &gid) == 0 && uid == getuid())
    }

    @Test func aClientThatHangsUpBeforeTheReplyDoesNotKillTheService() throws {
        let r = try Running()
        for _ in 0..<20 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try connectUnix(fd, r.path)
            close(fd)
        }
        usleep(300_000)
        #expect(try callService(op: "check", args: [:], socketPath: r.path)["ok"] == true)
    }

    @Test func clientReportsMissingSocketAsUnreachable() {
        let error = #expect(throws: ClientError.self) {
            try callService(op: "check", args: [:], socketPath: "/private/tmp/mr-no-such-dir/s.sock")
        }
        #expect(error?.unreachable == true)
    }
}

/// Socket setup: the service holds Full Disk Access, so nothing it does to the
/// filesystem may follow a path another process can swap.
@Suite struct BindTests {
    let root = makeTempDir()
    let store = Store(chatDB: { "/nonexistent/chat.db" }, addressBooks: { [] })

    @Test func refusesANonSocketInTheWay() throws {
        defer { removeTree(root) }
        try "not a socket".write(toFile: root + "/s.sock", atomically: false, encoding: .utf8)
        let error = #expect(throws: SetupError.self) { try SocketServer.bind(store: store, path: root + "/s.sock") }
        #expect(error?.description.contains("not a socket") == true)
    }

    @Test func tightensALooseDirectory() throws {
        defer { removeTree(root) }
        chmod(root, 0o755)
        try SocketServer.bind(store: store, path: root + "/s.sock").close()
        #expect(mode(root).mode == 0o700)
    }

    @Test func refusesASymlinkedDirectory() throws {
        defer { removeTree(root) }
        makeDir(root + "/real")
        symlink(root + "/real", root + "/link")
        let error = #expect(throws: SetupError.self) {
            try SocketServer.bind(store: store, path: root + "/link/s.sock")
        }
        #expect(error?.description.contains("not a plain directory") == true)
        #expect(!FileManager.default.fileExists(atPath: root + "/real/s.sock"))
    }

    // Regression (chmod symlink race): a symlink at the socket name must not
    // redirect any permission change or write to its target.
    @Test func refusesASymlinkAtTheSocketName() throws {
        defer { removeTree(root) }
        let victim = root + "/victim"
        try "protected".write(toFile: victim, atomically: false, encoding: .utf8)
        chmod(victim, 0o644)
        symlink(victim, root + "/s.sock")
        let error = #expect(throws: SetupError.self) { try SocketServer.bind(store: store, path: root + "/s.sock") }
        #expect(error?.description.contains("not a socket") == true)
        #expect(mode(victim).mode == 0o644)
        #expect(try String(contentsOfFile: victim, encoding: .utf8) == "protected")
    }

    // Regression (chmod symlink race): permissions are only ever changed
    // through a verified descriptor, so swapping a path after bind can't
    // redirect them. Checked on the source because the race window is gone,
    // not just narrow.
    @Test func neverChangesPermissionsThroughAPath() throws {
        let pathChmod = try NSRegularExpression(pattern: #"(?<![A-Za-z_])(chmod|lchmod|chown|lchown|fchmodat|fchownat)\s*\("#)
        for (name, source) in try sources(in: ["ReaderCore", "ReaderShared", "messages-reader-service"]) {
            let range = NSRange(source.startIndex..., in: source)
            #expect(pathChmod.firstMatch(in: source, range: range) == nil, "\(name) changes permissions by path")
        }
    }

    @Test func closeOnlyRemovesItsOwnSocketEvenIfTheDirectoryIsSwapped() throws {
        defer { removeTree(root) }
        let server = try SocketServer.bind(store: store, path: root + "/state/s.sock")
        rename(root + "/state", root + "/moved")
        makeDir(root + "/other")
        try "someone else's file".write(toFile: root + "/other/s.sock", atomically: false, encoding: .utf8)
        symlink(root + "/other", root + "/state")
        server.close()
        #expect(try String(contentsOfFile: root + "/other/s.sock", encoding: .utf8) == "someone else's file")
        #expect(!FileManager.default.fileExists(atPath: root + "/moved/s.sock"))
    }
}
