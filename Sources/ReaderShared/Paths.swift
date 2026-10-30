import Darwin

/// Filesystem locations shared by the service and the client.
///
/// Resolved from the password database rather than $HOME so the client works
/// from `env -i` and the service works under launchd.
public enum Paths {
    public static var home: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            fatalError("no home directory for uid \(getuid())")
        }
        return String(cString: dir)
    }

    public static var socketDir: String { home + "/.local/state/messages-reader" }
    public static var socketPath: String { socketDir + "/messages-reader.sock" }
    public static var chatDB: String { home + "/Library/Messages/chat.db" }
    public static var addressBookRoot: String { home + "/Library/Application Support/AddressBook" }
}
