import Cocoa
import CommonCrypto

let HOME_DIR = "HOME_DIR_PLACEHOLDER"
let PRIMARY_URL_SCHEME = "agent-pr-review"
let LEGACY_URL_SCHEMES = ["github-pr-review", "claude-review"]
let REVIEW_SUPPORT_DIR_NAME = "AgentPRReview"
let LEGACY_REVIEW_SUPPORT_DIR_NAMES = ["GitHubPRReview", "ClaudeReview"]
let REVIEW_LOG_FILE_NAME = "agent-pr-review.log"

enum ReviewCLI: String {
    case agent
    case claude
}

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

func shellEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

func defaultShellPath() -> String {
    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let extraPaths = [
        "\(HOME_DIR)/.local/bin",
        "\(HOME_DIR)/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    return ([envPath] + extraPaths)
        .filter { !$0.isEmpty }
        .joined(separator: ":")
}

func runShellCommand(_ command: String) -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = defaultShellPath()
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return (1, "", error.localizedDescription)
    }

    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    return (process.terminationStatus, stdout, stderr)
}

func reviewSupportDir() -> String {
    "\(HOME_DIR)/Library/Application Support/\(REVIEW_SUPPORT_DIR_NAME)"
}

func legacyReviewSupportDirs() -> [String] {
    LEGACY_REVIEW_SUPPORT_DIR_NAMES.map { "\(HOME_DIR)/Library/Application Support/\($0)" }
}

func ensureReviewSupportDir() {
    let fileManager = FileManager.default
    let targetDir = reviewSupportDir()

    if !fileManager.fileExists(atPath: targetDir) {
        for legacyDir in legacyReviewSupportDirs() where fileManager.fileExists(atPath: legacyDir) {
            try? fileManager.moveItem(atPath: legacyDir, toPath: targetDir)
            break
        }
    }

    try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true, attributes: nil)
}

func reviewLogPath() -> String {
    "\(reviewSupportDir())/\(REVIEW_LOG_FILE_NAME)"
}

func agentSessionMapPath() -> String {
    "\(reviewSupportDir())/agent-session-map.json"
}

func loadAgentSessionMap() -> [String: String] {
    ensureReviewSupportDir()
    let path = agentSessionMapPath()
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data, options: []),
          let sessions = object as? [String: String] else {
        return [:]
    }

    return sessions
}

func saveAgentSessionMap(_ sessions: [String: String]) {
    ensureReviewSupportDir()

    guard JSONSerialization.isValidJSONObject(sessions),
          let data = try? JSONSerialization.data(withJSONObject: sessions, options: [.prettyPrinted, .sortedKeys]) else {
        return
    }

    try? data.write(to: URL(fileURLWithPath: agentSessionMapPath()), options: .atomic)
}

func parseAgentChatId(from output: String) -> String? {
    let lines = output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard let lastLine = lines.last else {
        return nil
    }

    if let range = lastLine.range(of: #"[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) {
        return String(lastLine[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    return lastLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
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
        ensureReviewSupportDir()
        let logFile = reviewLogPath()
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

        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme,
              ([PRIMARY_URL_SCHEME] + LEGACY_URL_SCHEMES).contains(scheme),
              let host = components.host else {
            log("ERROR: invalid URL")
            NSApplication.shared.terminate(nil)
            return
        }
        log("Accepted URL scheme: \(scheme)")

        let cliValue = components.queryItems?.first(where: { $0.name == "cli" })?.value ?? ReviewCLI.agent.rawValue
        let reviewCLI = ReviewCLI(rawValue: cliValue) ?? .agent
        let pathParts = components.path.split(separator: "/").map(String.init)

        guard pathParts.count == 4,
              pathParts[2] == "pull",
              Int(pathParts[3]) != nil else {
            log("ERROR: invalid PR path")
            NSApplication.shared.terminate(nil)
            return
        }

        let parts = [host] + pathParts
        let ghPath = parts.joined(separator: "/")
        let prURL = "https://\(ghPath)"

        // Extract repo name: host/owner/repo/pull/123 -> repo is parts[2]
        let repoName = parts[2]
        log("Repo name: \(repoName)")
        log("Selected CLI: \(reviewCLI.rawValue)")

        // Generate a deterministic session UUID from the normalized PR path
        // Use owner/repo/pull/number as the key (strip the host for portability)
        let prKey = parts[1...4].joined(separator: "/")
        let namespace = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")! // URL namespace
        let sessionId = uuidV5(namespace: namespace, name: prKey)
        let sessionIdStr = sessionId.uuidString.lowercased()
        log("Claude session ID: \(sessionIdStr) (from key: \(prKey))")

        // Search for the repo under ~/code using find
        let codeDir = "\(HOME_DIR)/code"
        var repoPath: String? = nil

        if !repoName.isEmpty {
            let findProc = Process()
            findProc.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            findProc.arguments = [codeDir, "-maxdepth", "4", "-type", "d", "-name", repoName]
            let pipe = Pipe()
            findProc.standardOutput = pipe
            findProc.standardError = FileHandle.nullDevice
            try? findProc.run()
            findProc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let candidates = output.split(separator: "\n")
                .map(String.init)
                .filter { FileManager.default.fileExists(atPath: "\($0)/.git") }
            // Prefer paths containing "/prod/" over "/preprod/" or others
            repoPath = candidates.first(where: { $0.contains("/prod/") }) ?? candidates.first
        }

        log("Repo path: \(repoPath ?? "NOT FOUND")")

        // Check if a Claude session already exists for this PR
        let hasExistingClaudeSession = sessionExists(sessionIdStr)
        log("Existing Claude session: \(hasExistingClaudeSession)")

        let shellCmd: String
        if let repoPath = repoPath {
            let escapedPath = shellEscape(repoPath)
            let fetchCmd = "cd '\(escapedPath)' && git fetch --all --prune"
            let isGhes = host.contains("github.intuit.com")
            let skillHint = isGhes ? " This PR is on GitHub Enterprise (github.intuit.com) - use the ghes skill for all GitHub operations instead of the default gh CLI." : ""
            let prompt = "Please review this PR: \(prURL). Switch to the local PR branch to help. Consider existing PR comments and review feedback as context for your review.\(skillHint)"
            let escapedPrompt = shellEscape(prompt)

            switch reviewCLI {
            case .claude:
                if hasExistingClaudeSession {
                    shellCmd = "\(fetchCmd) && claude --resume '\(sessionIdStr)'"
                } else {
                    shellCmd = "\(fetchCmd) && claude --session-id '\(sessionIdStr)' '\(escapedPrompt)'"
                }
            case .agent:
                var agentSessions = loadAgentSessionMap()
                let existingChatId = agentSessions[prKey]
                log("Existing Cursor chat: \(existingChatId ?? "NONE")")

                if let existingChatId = existingChatId, !existingChatId.isEmpty {
                    shellCmd = "\(fetchCmd) && agent --resume '\(shellEscape(existingChatId))'"
                } else {
                    let createChatResult = runShellCommand("agent create-chat")
                    let trimmedStdout = createChatResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedStderr = createChatResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    log("agent create-chat exit code: \(createChatResult.status), stdout: \(trimmedStdout), stderr: \(trimmedStderr)")

                    if createChatResult.status == 0,
                       let chatId = parseAgentChatId(from: createChatResult.stdout),
                       !chatId.isEmpty {
                        agentSessions[prKey] = chatId
                        saveAgentSessionMap(agentSessions)
                        log("Created Cursor chat: \(chatId)")
                        shellCmd = "\(fetchCmd) && agent --resume '\(shellEscape(chatId))' '\(escapedPrompt)'"
                    } else {
                        log("Falling back to launching Cursor without a mapped chat")
                        shellCmd = "\(fetchCmd) && agent '\(escapedPrompt)'"
                    }
                }
            }
        } else {
            shellCmd = "printf 'Repository %s not found under ~/code. Clone it first, then retry.\\n' '\(shellEscape(repoName))'"
        }

        // Escape backslashes and double quotes for AppleScript string embedding
        let asCmd = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        log("Shell command: \(shellCmd)")

        // Use osascript to open a new iTerm2 tab (or window if iTerm2 isn't running)
        let script = """
        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(asCmd)"
                end tell
            else
                tell current window
                    set newTab to (create tab with default profile)
                    tell current session of newTab
                        write text "\(asCmd)"
                    end tell
                end tell
            end if
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
