import Darwin
import Foundation

public struct ClientError: Error, CustomStringConvertible {
    public let description: String
    /// True when nothing is listening (missing socket or refused connection).
    public let unreachable: Bool
}

/// Send one request to the service socket and return its JSON response.
public func callService(op: String, args: [String: JSONValue], socketPath: String = Paths.socketPath)
    throws -> JSONValue
{
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ClientError(description: String(cString: strerror(errno)), unreachable: true) }
    defer { close(fd) }
    var tv = timeval(tv_sec: 60, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        throw ClientError(description: "socket path too long", unreachable: true)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else {
        let err = errno
        throw ClientError(
            description: "service not reachable at \(socketPath) (\(String(cString: strerror(err))))",
            unreachable: err == ENOENT || err == ECONNREFUSED)
    }

    var request = (["op": .string(op), "args": .object(args)] as JSONValue).encoded()
    request.append(0x0A)
    try request.withUnsafeBytes { buf in
        var sent = 0
        while sent < buf.count {
            let n = send(fd, buf.baseAddress! + sent, buf.count - sent, MSG_NOSIGNAL)
            guard n > 0 else { throw ClientError(description: String(cString: strerror(errno)), unreachable: false) }
            sent += n
        }
    }
    shutdown(fd, SHUT_WR)

    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = recv(fd, &chunk, chunk.count, 0)
        if n == 0 { break }
        guard n > 0 else { throw ClientError(description: String(cString: strerror(errno)), unreachable: false) }
        response.append(contentsOf: chunk[0..<n])
    }
    do {
        return try JSONValue.parse(response)
    } catch {
        throw ClientError(description: "invalid response from service", unreachable: false)
    }
}
