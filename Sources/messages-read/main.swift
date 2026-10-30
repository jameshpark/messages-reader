// messages-read: command-line client for the messages-reader service.
// Talks only to the service's Unix socket; it never opens a database itself.

import Darwin
import Foundation
import ReaderShared

let usage = """
    usage: messages-read [--json] <command> [args]

      check                                   can the service read Messages?
      recent [--hours N] [--limit N]          recent messages across all chats
      search TEXT [--days N] [--limit N]      messages containing text
      thread TARGET [--limit N]               phone, email, contact name, or chat:<id>
      contact QUERY [--limit N]               look up contacts by name, phone or email
      chats [--limit N]                       most recently active chats
      attachments [TARGET] [--days N] [--limit N]   attachment metadata only

      --json   print the raw JSON result
    """

struct Command {
    let positionals: [(name: String, required: Bool)]
    let options: Set<String>
}

let commands: [String: Command] = [
    "check": Command(positionals: [], options: []),
    "recent": Command(positionals: [], options: ["hours", "limit"]),
    "search": Command(positionals: [("query", true)], options: ["days", "limit"]),
    "thread": Command(positionals: [("target", true)], options: ["limit"]),
    "contact": Command(positionals: [("query", true)], options: ["limit"]),
    "chats": Command(positionals: [], options: ["limit"]),
    "attachments": Command(positionals: [("target", false)], options: ["days", "limit"]),
]

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(usage)\nmessages-read: error: \(message)\n".utf8))
    exit(2)
}

func parse(_ argv: [String]) -> (op: String, args: [String: JSONValue], json: Bool) {
    var json = false
    var op: String?
    var positionals: [String] = []
    var options: [String: JSONValue] = [:]
    var i = 0
    while i < argv.count {
        let a = argv[i]
        i += 1
        if a == "-h" || a == "--help" {
            print(usage)
            exit(0)
        } else if a == "--json" {
            json = true
        } else if a.hasPrefix("--") {
            var name = String(a.dropFirst(2))
            var value: String?
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            guard let op, commands[op]!.options.contains(name) else { usageError("unknown option \(a)") }
            if value == nil {
                guard i < argv.count else { usageError("\(a) needs a value") }
                value = argv[i]
                i += 1
            }
            guard let n = Int(value!) else { usageError("\(a) must be an integer") }
            options[name] = .int(n)
        } else if op == nil {
            guard commands[a] != nil else {
                usageError("unknown command '\(a)' (choose from \(commands.keys.sorted().joined(separator: ", ")))")
            }
            op = a
        } else {
            positionals.append(a)
        }
    }
    guard let op else { usageError("a command is required") }
    let spec = commands[op]!
    if positionals.count > spec.positionals.count { usageError("too many arguments") }
    for (idx, p) in spec.positionals.enumerated() {
        if idx < positionals.count {
            options[p.name] = .string(positionals[idx])
        } else if p.required {
            usageError("\(p.name) is required")
        }
    }
    return (op, options, json)
}

func when(_ v: JSONValue?) -> String {
    String((v?.string ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
}

func who(_ row: JSONValue) -> String {
    if row["from_me"]?.bool == true { return "me" }
    let handle = row["sender"]?.string ?? "?"
    if let name = row["sender_name"]?.string { return "\(name) <\(handle)>" }
    return handle
}

func chatLabel(_ v: JSONValue?) -> String {
    v?.int.map { "chat:\($0)" } ?? "chat:None"
}

func printMessages(_ rows: [JSONValue]) {
    for row in rows {
        var text = row["text"]?.string ?? ""
        let files = (row["attachments"]?.array ?? []).compactMap(\.string)
        if !files.isEmpty {
            text = (text.isEmpty ? "" : text + " ") + files.map { "[attachment: \($0)]" }.joined(separator: " ")
        }
        if row["truncated"]?.bool == true { text += " [truncated]" }
        var prefix = "\(when(row["date"]))  \(chatLabel(row["chat_id"]))  \(who(row))"
        if let kind = row["kind"]?.string, kind != "message" { prefix += " (\(kind))" }
        print("\(prefix): " + text.replacingOccurrences(of: "\n", with: "\n    "))
    }
}

func plain(_ v: JSONValue?) -> String {
    switch v {
    case .string(let s)?: return s
    case .int(let i)?: return String(i)
    case .bool(let b)?: return b ? "True" : "False"
    case .null?, nil: return "None"
    default: return String(decoding: v!.encoded(), as: UTF8.self)
    }
}

func printResult(_ op: String, _ result: JSONValue) {
    if op == "check" {
        for (k, v) in (result.object ?? [:]).sorted(by: { $0.key < $1.key }) { print("\(k): \(plain(v))") }
        return
    }
    let rows = result["rows"]?.array ?? []
    switch op {
    case "recent", "search", "thread":
        printMessages(rows)
    case "contact":
        for c in rows {
            let handles = ((c["phones"]?.array ?? []) + (c["emails"]?.array ?? [])).compactMap(\.string)
            print("\(plain(c["name"])): " + handles.joined(separator: ", "))
        }
        if let total = result["total"]?.int, total > rows.count { print("... \(total - rows.count) more") }
    case "chats":
        for c in rows {
            let people = (c["participants"]?.array ?? []).map { p in
                p["name"]?.string.map { "\($0) <\(plain(p["handle"]))>" } ?? plain(p["handle"])
            }.joined(separator: ", ")
            let name = c["name"]?.string
            let label = name ?? (people.isEmpty ? plain(c["identifier"]) : people)
            print("\(chatLabel(c["chat_id"]))  \(when(c["last_message_at"]))  \(label)"
                + (name != nil ? "  [\(people)]" : ""))
        }
    case "attachments":
        for a in rows {
            print("\(when(a["date"]))  \(chatLabel(a["chat_id"]))  \(who(a))  \(plain(a["name"]))  "
                + "\(plain(a["mime_type"]))  \(plain(a["bytes"])) bytes")
        }
    default:
        break
    }
    if result["truncated"]?.bool == true { print("[output truncated to the size cap]") }
}

let (op, args, asJSON) = parse(Array(CommandLine.arguments.dropFirst()))
let response: JSONValue
do {
    response = try callService(op: op, args: args)
} catch {
    FileHandle.standardError.write(Data("messages-read: \(error)\n".utf8))
    exit(3)
}
guard response["ok"]?.bool == true else {
    FileHandle.standardError.write(Data("messages-read: \(plain(response["error"]))\n".utf8))
    exit(1)
}
if asJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try! encoder.encode(response["result"] ?? .null))
    print()
} else {
    printResult(op, response["result"] ?? .null)
}
exit(0)
