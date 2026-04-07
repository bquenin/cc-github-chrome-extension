import Cocoa
import CommonCrypto

let HOME_DIR = "HOME_DIR_PLACEHOLDER"

// Generate a deterministic UUID v5 from a namespace UUID + a string
func uuidV5(namespace: UUID, name: String) -> UUID {
    let nsBytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
    let nameBytes = Array(name.utf8)
    var input = nsBytes + nameBytes

    // SHA-1 hash
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    CC_SHA1(&input, CC_LONG(input.count), &hash)

    // Set version (5) and variant bits
    hash[6] = (hash[6] & 0x0F) | 0x50  // version 5
    hash[8] = (hash[8] & 0x3F) | 0x80  // variant 10

    let uuid = UUID(uuid: (
        hash[0], hash[1], hash[2], hash[3],
        hash[4], hash[5], hash[6], hash[7],
        hash[8], hash[9], hash[10], hash[11],
        hash[12], hash[13], hash[14], hash[15]
    ))
    return uuid
}

// Check if a claude session with the given ID exists
func sessionExists(_ sessionId: String) -> Bool {
    // Claude stores sessions under ~/.claude/projects/
    // We check by trying to find a matching session file
    let findProc = Process()
    findProc.executableURL = URL(fileURLWithPath: "/usr/bin/find")
    findProc.arguments = ["\(HOME_DIR)/.claude/projects", "-name", "\(sessionId).jsonl", "-type", "f"]
    let pipe = Pipe()
    findProc.standardOutput = pipe
    findProc.standardError = FileHandle.nullDevice
    try? findProc.run()
    findProc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !output.isEmpty
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func log(_ msg: String) {
        let logFile = "\(HOME_DIR)/Applications/claude-review.log"
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: logFile) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logFile, contents: line.data(using: .utf8))
        }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
            log("ERROR: no URL in event")
            NSApplication.shared.terminate(nil)
            return
        }
        log("Received URL: \(urlString)")

        let scheme = "claude-review://"
        guard urlString.hasPrefix(scheme) else {
            NSApplication.shared.terminate(nil)
            return
        }
        // ghPath is already normalized: host/owner/repo/pull/number
        let ghPath = String(urlString.dropFirst(scheme.count))
        let prURL = "https://\(ghPath)"

        // Extract repo name: host/owner/repo/pull/123 -> repo is parts[2]
        let parts = ghPath.split(separator: "/")
        let repoName = parts.count >= 3 ? String(parts[2]) : ""
        log("Repo name: \(repoName)")

        // Generate a deterministic session UUID from the normalized PR path
        // Use owner/repo/pull/number as the key (strip the host for portability)
        let prKey = parts.count >= 5 ? parts[1...4].joined(separator: "/") : ghPath
        let namespace = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")! // URL namespace
        let sessionId = uuidV5(namespace: namespace, name: prKey)
        let sessionIdStr = sessionId.uuidString.lowercased()
        log("Session ID: \(sessionIdStr) (from key: \(prKey))")

        // Search for the repo under ~/code using find
        let codeDir = "\(HOME_DIR)/code"
        var repoPath: String? = nil

        if !repoName.isEmpty {
            let findProc = Process()
            findProc.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            findProc.arguments = [codeDir, "-maxdepth", "2", "-type", "d", "-name", repoName]
            let pipe = Pipe()
            findProc.standardOutput = pipe
            findProc.standardError = FileHandle.nullDevice
            try? findProc.run()
            findProc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                let candidate = String(line)
                if FileManager.default.fileExists(atPath: "\(candidate)/.git") {
                    repoPath = candidate
                    break
                }
            }
        }

        log("Repo path: \(repoPath ?? "NOT FOUND")")

        // Check if a session already exists for this PR
        let hasExistingSession = sessionExists(sessionIdStr)
        log("Existing session: \(hasExistingSession)")

        let shellCmd: String
        if let repoPath = repoPath {
            let escapedPath = repoPath.replacingOccurrences(of: "'", with: "'\\''")
            if hasExistingSession {
                // Resume existing session
                shellCmd = "cd '\(escapedPath)' && claude --resume '\(sessionIdStr)'"
            } else {
                // Start new session with deterministic ID
                let prompt = "Please review this PR: \(prURL). Switch to the local PR branch to help. Consider existing PR comments and review feedback as context for your review."
                let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
                shellCmd = "cd '\(escapedPath)' && claude --session-id '\(sessionIdStr)' '\(escapedPrompt)'"
            }
        } else {
            shellCmd = "echo 'Repository \(repoName) not found under ~/code. Clone it first, then retry.'"
        }

        // Escape backslashes and double quotes for AppleScript string embedding
        let asCmd = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        log("Shell command: \(shellCmd)")

        // Use osascript to open a new iTerm2 tab
        let script = """
        tell application "iTerm2"
            activate
            tell current window
                set newTab to (create tab with default profile)
                tell current session of newTab
                    write text "\(asCmd)"
                end tell
            end tell
        end tell
        """

        log("Running AppleScript...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        try? process.run()
        process.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        log("osascript exit code: \(process.terminationStatus), stderr: \(errStr)")

        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
