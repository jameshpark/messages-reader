import Foundation
import Testing

/// Sources of the named targets, keyed by file name.
func sources(in targets: [String]) throws -> [(String, String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")
    var result: [(String, String)] = []
    for target in targets {
        let dir = root.appendingPathComponent(target)
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            result.append(("\(target)/\(file)", try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)))
        }
    }
    precondition(!result.isEmpty)
    return result
}

@Suite struct InvariantTests {
    /// Nothing can start a process, run AppleScript, load code, or reach the network.
    @Test func noProcessScriptingDynamicLoadingOrNetwork() throws {
        let forbidden = [
            "Process(", "NSTask", "NSAppleScript", "osascript", "posix_spawn", "execv", "execl", "fork(",
            "system(", "popen", "URLSession", "NSURLConnection", "AF_INET", "import Network", "NSWorkspace",
            "dlopen", "NSBundle(", "Bundle(path", "CFBundle",
        ]
        for (name, source) in try sources(in: ["ReaderCore", "ReaderShared", "messages-reader-service", "messages-read"]) {
            for token in forbidden {
                #expect(!source.contains(token), "\(name) contains \(token)")
            }
        }
    }

    @Test func clientNeverTouchesDatabases() throws {
        for (name, source) in try sources(in: ["messages-read", "ReaderShared"]) {
            #expect(!source.contains("import SQLite3") && !source.contains("import ReaderCore"), "\(name)")
        }
    }
}
