import Foundation
import ReaderShared

// Protocol: the client sends one JSON object on one line,
// {"op": "<name>", "args": {...}}, and gets one JSON line back,
// {"ok": true, "result": {...}} or {"ok": false, "error": "..."}.
// Only the ops in `ops` exist; there is no way to send, write or delete.

public let maxRequestBytes = 4096
public let maxResponseBytes = 4 * 1024 * 1024

enum Arg {
    case int(default: Int, lo: Int, hi: Int)
    case string(maxLength: Int, required: Bool)
}

let ops: [String: [String: Arg]] = [
    "check": [:],
    "recent": ["hours": .int(default: 24, lo: 1, hi: 24 * 365), "limit": .int(default: 50, lo: 1, hi: 500)],
    "search": [
        "query": .string(maxLength: 200, required: true),
        "days": .int(default: 365, lo: 1, hi: 3650), "limit": .int(default: 50, lo: 1, hi: 200),
    ],
    "thread": ["target": .string(maxLength: 320, required: true), "limit": .int(default: 50, lo: 1, hi: 500)],
    "contact": ["query": .string(maxLength: 200, required: true), "limit": .int(default: 10, lo: 1, hi: 50)],
    "chats": ["limit": .int(default: 30, lo: 1, hi: 200)],
    "attachments": [
        "target": .string(maxLength: 320, required: false),
        "days": .int(default: 30, lo: 1, hi: 3650), "limit": .int(default: 50, lo: 1, hi: 200),
    ],
]

/// thread rows are oldest-first; everything else is newest-first.
let oldestFirstOps: Set<String> = ["thread"]

public struct Request: Equatable {
    public let op: String
    public let ints: [String: Int]
    public let strings: [String: String]
}

public func validate(_ request: JSONValue) throws -> Request {
    guard let obj = request.object else { throw RequestError("request must be a JSON object") }
    let extra = Set(obj.keys).subtracting(["op", "args"])
    if !extra.isEmpty { throw RequestError("unknown request fields: \(extra.sorted())") }
    guard let op = obj["op"]?.string, let spec = ops[op] else {
        throw RequestError("unknown op; allowed: \(ops.keys.sorted())")
    }
    let rawArgs = obj["args"] ?? .object([:])
    guard let args = rawArgs.object else { throw RequestError("args must be a JSON object") }
    let unknown = Set(args.keys).subtracting(spec.keys)
    if !unknown.isEmpty { throw RequestError("unknown args for \(op): \(unknown.sorted())") }
    var ints: [String: Int] = [:]
    var strings: [String: String] = [:]
    for (name, rule) in spec {
        let value = args[name] ?? .null
        switch rule {
        case .int(let def, let lo, let hi):
            if value.isNull { ints[name] = def; continue }
            guard let i = value.int else { throw RequestError("\(name) must be an integer") }
            guard lo <= i && i <= hi else { throw RequestError("\(name) must be between \(lo) and \(hi)") }
            ints[name] = i
        case .string(let maxLength, let required):
            if value.isNull {
                if required { throw RequestError("\(name) is required") }
                continue
            }
            guard let raw = value.string else { throw RequestError("\(name) must be a string") }
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty && s.unicodeScalars.count <= maxLength else {
                throw RequestError("\(name) must be 1-\(maxLength) characters")
            }
            if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                throw RequestError("\(name) must not contain control characters")
            }
            strings[name] = s
        }
    }
    return Request(op: op, ints: ints, strings: strings)
}

func dispatch(_ store: Store, _ r: Request) throws -> JSONValue {
    switch r.op {
    case "check": return store.check()
    case "recent": return try store.recent(hours: r.ints["hours"]!, limit: r.ints["limit"]!)
    case "search":
        return try store.search(query: r.strings["query"]!, days: r.ints["days"]!, limit: r.ints["limit"]!)
    case "thread": return try store.thread(target: r.strings["target"]!, limit: r.ints["limit"]!)
    case "contact": return store.contact(query: r.strings["query"]!, limit: r.ints["limit"]!)
    case "chats": return try store.chats(limit: r.ints["limit"]!)
    case "attachments":
        return try store.attachments(target: r.strings["target"], days: r.ints["days"]!, limit: r.ints["limit"]!)
    default: throw RequestError("unknown op; allowed: \(ops.keys.sorted())")
    }
}

public func handleRequest(_ store: Store, _ raw: Data) -> (op: String?, response: JSONValue) {
    var op: String?
    do {
        guard let request = try? JSONValue.parse(raw) else {
            throw RequestError("request must be one line of JSON")
        }
        let r = try validate(request)
        op = r.op
        return (op, ["ok": true, "result": try dispatch(store, r)])
    } catch let e as RequestError {
        return (op, ["ok": false, "error": .string(e.description)])
    } catch {
        return (op, ["ok": false, "error": "internal error"])
    }
}

/// Serialize, dropping the oldest rows until the response fits the size cap.
public func encodeResponse(op: String?, _ response: JSONValue, limit: Int = maxResponseBytes) -> Data {
    var response = response
    while true {
        var data = response.encoded()
        data.append(0x0A)
        if data.count <= limit { return data }
        guard case .object(var outer) = response, case .object(var result)? = outer["result"],
            case .array(var rows)? = result["rows"], !rows.isEmpty
        else {
            var tooLarge = (["ok": false, "error": "response too large"] as JSONValue).encoded()
            tooLarge.append(0x0A)
            return tooLarge
        }
        let drop = max(1, rows.count / 4)
        if let op, oldestFirstOps.contains(op) {
            rows.removeFirst(drop)
        } else {
            rows.removeLast(drop)
        }
        result["rows"] = .array(rows)
        result["truncated"] = true
        outer["result"] = .object(result)
        response = .object(outer)
    }
}
