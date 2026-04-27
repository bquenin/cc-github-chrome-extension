import Cocoa
import CommonCrypto

let HOME_DIR = "HOME_DIR_PLACEHOLDER"
let PRIMARY_URL_SCHEME = "agent-pr-review"
let REVIEW_SUPPORT_DIR_NAME = "AgentPRReview"
let LEGACY_REVIEW_SUPPORT_DIR_NAMES = ["GitHubPRReview", "ClaudeReview"]
let REVIEW_LOG_FILE_NAME = "agent-pr-review.log"
let WORKTREE_CLEANUP_MAX_AGE_SECONDS: TimeInterval = 60.0 * 24.0 * 60.0 * 60.0

enum ReviewCLI: String {
    case agent
    case claude
}

struct RepoCandidate {
    let path: String
    let score: Int
    let reasons: [String]
}

struct RemoteInfo {
    let name: String
    let identifier: String?
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

func agentTerminalShellCommand(launchPath: String, prKey: String, prompt: String, existingChatId: String?) -> String {
    let escapedPath = shellEscape(launchPath)
    let escapedPrompt = shellEscape(prompt)
    let escapedPrKey = shellEscape(prKey)
    let escapedExistingChatId = shellEscape(existingChatId ?? "")
    let escapedSessionMapPath = shellEscape(agentSessionMapPath())

    return """
    cd '\(escapedPath)' || { echo 'Failed to enter review workspace: \(escapedPath)'; return 1 2>/dev/null || true; }
    git fetch --all --prune || { echo 'git fetch failed; leaving this shell open for debugging.'; return 1 2>/dev/null || true; }

    chat_id='\(escapedExistingChatId)'
    if [[ -n "$chat_id" ]]; then
      echo "Resuming Cursor chat: $chat_id"
    else
      echo 'Creating Cursor chat...'
      chat_output_file="$(mktemp "${TMPDIR:-/tmp}/agent-pr-review-chat.XXXXXX")"
      agent create-chat 2>&1 | tee "$chat_output_file"
      create_chat_status=${pipestatus[1]}

      if [[ $create_chat_status -eq 0 ]]; then
        chat_id="$(AGENT_PR_REVIEW_CREATE_CHAT_OUTPUT_FILE="$chat_output_file" python3 - <<'PY'
    import os
    import re

    output_path = os.environ["AGENT_PR_REVIEW_CREATE_CHAT_OUTPUT_FILE"]
    with open(output_path, "r", encoding="utf-8") as handle:
        lines = [line.strip() for line in handle if line.strip()]
    if lines:
        last_line = lines[-1].strip(chr(34) + chr(39))
        match = re.search(r"[A-Za-z0-9_-]{8,}$", last_line)
        print(match.group(0) if match else last_line)
    PY
    )"
      else
        echo "agent create-chat failed with exit code $create_chat_status; launching without a saved chat."
      fi
      rm -f "$chat_output_file"

      if [[ -n "$chat_id" ]]; then
        AGENT_PR_REVIEW_MAP_PATH='\(escapedSessionMapPath)' AGENT_PR_REVIEW_PR_KEY='\(escapedPrKey)' AGENT_PR_REVIEW_CHAT_ID="$chat_id" python3 - <<'PY'
    import json
    import os

    path = os.environ["AGENT_PR_REVIEW_MAP_PATH"]
    pr_key = os.environ["AGENT_PR_REVIEW_PR_KEY"]
    chat_id = os.environ["AGENT_PR_REVIEW_CHAT_ID"]

    try:
        with open(path, "r", encoding="utf-8") as handle:
            sessions = json.load(handle)
        if not isinstance(sessions, dict):
            sessions = {}
    except Exception:
        sessions = {}

    sessions[pr_key] = chat_id
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp_path = f"{path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        json.dump(sessions, handle, indent=2, sort_keys=True)
        handle.write("\\n")
    os.replace(tmp_path, path)
    PY
        echo "Saved Cursor chat mapping: $chat_id"
      fi
    fi

    if [[ -n "$chat_id" ]]; then
      agent --resume "$chat_id" '\(escapedPrompt)'
    else
      agent '\(escapedPrompt)'
    fi
    """
}

func claudeTerminalShellCommand(launchPath: String, sessionId: String, prompt: String) -> String {
    let escapedPath = shellEscape(launchPath)
    let escapedPrompt = shellEscape(prompt)
    let escapedSessionId = shellEscape(sessionId)
    let escapedClaudeProjectsDir = shellEscape("\(HOME_DIR)/.claude/projects")

    return """
    cd '\(escapedPath)' || { echo 'Failed to enter review workspace: \(escapedPath)'; return 1 2>/dev/null || true; }
    git fetch --all --prune || { echo 'git fetch failed; leaving this shell open for debugging.'; return 1 2>/dev/null || true; }

    session_id='\(escapedSessionId)'
    if [[ -d '\(escapedClaudeProjectsDir)' ]] && [[ -n "$(/usr/bin/find '\(escapedClaudeProjectsDir)' -name "$session_id.jsonl" -type f -print -quit)" ]]; then
      echo "Resuming Claude session: $session_id"
      claude --resume "$session_id"
    else
      echo "Starting Claude session: $session_id"
      claude --session-id "$session_id" '\(escapedPrompt)'
    fi
    """
}

func safePathComponent(_ value: String) -> String {
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitizedScalars = value.unicodeScalars.map { scalar -> String in
        allowedCharacters.contains(scalar) ? String(scalar) : "_"
    }

    let sanitized = sanitizedScalars.joined()
    return sanitized.isEmpty ? "unknown" : sanitized
}

func normalizeRemoteIdentifier(_ remoteURL: String) -> String? {
    var trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    if trimmed.hasSuffix(".git") {
        trimmed.removeLast(4)
    }

    if trimmed.contains("://"),
       let components = URLComponents(string: trimmed),
       let host = components.host {
        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard pathParts.count >= 2 else {
            return nil
        }

        return ([host] + Array(pathParts.suffix(2))).joined(separator: "/")
    }

    if let atRange = trimmed.range(of: "@"),
       let colonRange = trimmed[atRange.upperBound...].range(of: ":") {
        let host = String(trimmed[atRange.upperBound..<colonRange.lowerBound])
        let path = trimmed[colonRange.upperBound...]
        let pathParts = path.split(separator: "/").map(String.init)

        guard pathParts.count >= 2 else {
            return nil
        }

        return ([host] + Array(pathParts.suffix(2))).joined(separator: "/")
    }

    let pathParts = trimmed
        .split(separator: "/")
        .map(String.init)
        .filter { !$0.isEmpty }

    guard pathParts.count >= 3 else {
        return nil
    }

    return ([pathParts[pathParts.count - 3]] + Array(pathParts.suffix(2))).joined(separator: "/")
}

func remoteInfos(for repoPath: String) -> [RemoteInfo] {
    let escapedPath = shellEscape(repoPath)
    let result = runShellCommand("git -C '\(escapedPath)' remote -v")

    guard result.status == 0 else {
        return []
    }

    var infos: [RemoteInfo] = []

    for line in result.stdout.split(separator: "\n") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3, fields[2] == "(fetch)" else {
            continue
        }

        let name = String(fields[0])
        let identifier = normalizeRemoteIdentifier(String(fields[1]))
        if !infos.contains(where: { $0.name == name }) {
            infos.append(RemoteInfo(name: name, identifier: identifier))
        }
    }

    return infos
}

func preferredRemoteName(for repoPath: String, expectedRemote: String, logger: (String) -> Void) -> String? {
    let infos = remoteInfos(for: repoPath)

    if let exactMatch = infos.first(where: { $0.identifier == expectedRemote }) {
        logger("Using git remote \(exactMatch.name) for \(expectedRemote)")
        return exactMatch.name
    }

    if let origin = infos.first(where: { $0.name == "origin" }) {
        logger("Falling back to git remote origin for \(repoPath)")
        return origin.name
    }

    if let firstRemote = infos.first {
        logger("Falling back to git remote \(firstRemote.name) for \(repoPath)")
        return firstRemote.name
    }

    logger("No git remotes found for \(repoPath)")
    return nil
}

func worktreeRootDir(repoPath: String) -> String {
    "\(repoPath)/.agent-pr-review/worktrees"
}

func worktreePath(repoPath: String, prNumber: String) -> String {
    "\(worktreeRootDir(repoPath: repoPath))/pr-\(safePathComponent(prNumber))"
}

func worktreeBranchName(prNumber: String) -> String {
    "agent-pr-review/pr-\(safePathComponent(prNumber))"
}

func worktreeRemoteRef(remoteName: String, prNumber: String) -> String {
    "refs/remotes/\(remoteName)/agent-pr-review/pr-\(safePathComponent(prNumber))"
}

func ensureParentDirectory(for path: String) {
    let parentDir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
}

func ensureGlobalStateIgnored() {
    let fileManager = FileManager.default
    let configuredExcludeResult = runShellCommand("git config --global --get core.excludesfile")
    let configuredExcludePath = configuredExcludeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let excludePath = configuredExcludePath.isEmpty ? "\(HOME_DIR)/.config/git/ignore" : configuredExcludePath
    let excludeParentPath = (excludePath as NSString).deletingLastPathComponent
    try? fileManager.createDirectory(atPath: excludeParentPath, withIntermediateDirectories: true, attributes: nil)

    let ignoreEntry = ".agent-pr-review/"
    if let data = fileManager.contents(atPath: excludePath),
       let existing = String(data: data, encoding: .utf8),
       existing.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ignoreEntry }) {
        return
    }

    let line = "\n\(ignoreEntry)\n"
    if let handle = FileHandle(forWritingAtPath: excludePath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(toFile: excludePath, atomically: true, encoding: .utf8)
    }
}

func cursorProjectDirName(for workspacePath: String) -> String {
    let trimmedPath = workspacePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var components: [String] = []
    var current = ""

    for scalar in trimmedPath.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            current.append(String(scalar))
        } else if !current.isEmpty {
            components.append(current)
            current = ""
        }
    }

    if !current.isEmpty {
        components.append(current)
    }

    return components.isEmpty ? "workspace" : components.joined(separator: "-")
}

func trustCursorWorkspace(_ workspacePath: String, logger: (String) -> Void) {
    let fileManager = FileManager.default
    let projectDir = "\(HOME_DIR)/.cursor/projects/\(cursorProjectDirName(for: workspacePath))"
    let trustFile = "\(projectDir)/.workspace-trusted"
    let trustedAt = ISO8601DateFormatter().string(from: Date())
    let trustObject = [
        "trustedAt": trustedAt,
        "workspacePath": workspacePath
    ]

    guard JSONSerialization.isValidJSONObject(trustObject),
          let data = try? JSONSerialization.data(withJSONObject: trustObject, options: [.prettyPrinted, .sortedKeys]) else {
        logger("Failed to create Cursor workspace trust payload for \(workspacePath)")
        return
    }

    do {
        try fileManager.createDirectory(atPath: projectDir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: URL(fileURLWithPath: trustFile), options: .atomic)
        logger("Trusted Cursor workspace at \(workspacePath)")
    } catch {
        logger("Failed to trust Cursor workspace at \(workspacePath): \(error.localizedDescription)")
    }
}

func branchExists(repoPath: String, branchName: String) -> Bool {
    let escapedRepoPath = shellEscape(repoPath)
    let escapedBranchName = shellEscape(branchName)
    let result = runShellCommand("git -C '\(escapedRepoPath)' show-ref --verify --quiet 'refs/heads/\(escapedBranchName)'")
    return result.status == 0
}

func worktreeIsClean(_ path: String) -> Bool {
    let escapedPath = shellEscape(path)
    let result = runShellCommand("git -C '\(escapedPath)' status --porcelain")
    return result.status == 0 && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func cleanupStaleWorktrees(repoPath: String, currentWorktreePath: String, logger: (String) -> Void) {
    let fileManager = FileManager.default
    let rootDir = worktreeRootDir(repoPath: repoPath)
    var isDirectory: ObjCBool = false

    guard fileManager.fileExists(atPath: rootDir, isDirectory: &isDirectory),
          isDirectory.boolValue,
          let entries = try? fileManager.contentsOfDirectory(atPath: rootDir) else {
        return
    }

    let escapedRepoPath = shellEscape(repoPath)
    let now = Date()

    for entry in entries where entry.hasPrefix("pr-") {
        let path = "\(rootDir)/\(entry)"
        var entryIsDirectory: ObjCBool = false

        guard path != currentWorktreePath,
              fileManager.fileExists(atPath: path, isDirectory: &entryIsDirectory),
              entryIsDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modifiedAt) >= WORKTREE_CLEANUP_MAX_AGE_SECONDS else {
            continue
        }

        guard worktreeIsClean(path) else {
            logger("Skipping stale worktree cleanup because it has local changes: \(path)")
            continue
        }

        let escapedPath = shellEscape(path)
        let removeResult = runShellCommand("git -C '\(escapedRepoPath)' worktree remove '\(escapedPath)'")
        if removeResult.status == 0 {
            logger("Removed stale clean worktree at \(path)")
        } else {
            logger("Failed to remove stale worktree at \(path): \(removeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

func updateExistingWorktree(path: String, branchName: String, remoteRef: String, logger: (String) -> Void) {
    let escapedPath = shellEscape(path)
    let escapedBranchName = shellEscape(branchName)
    let escapedRemoteRef = shellEscape(remoteRef)

    guard worktreeIsClean(path) else {
        logger("Worktree has local changes; leaving current checkout unchanged at \(path)")
        return
    }

    let branchExistsInWorktree = runShellCommand("git -C '\(escapedPath)' show-ref --verify --quiet 'refs/heads/\(escapedBranchName)'").status == 0
    let checkoutCommand = branchExistsInWorktree
        ? "git -C '\(escapedPath)' checkout '\(escapedBranchName)'"
        : "git -C '\(escapedPath)' checkout -b '\(escapedBranchName)' '\(escapedRemoteRef)'"

    let checkoutResult = runShellCommand(checkoutCommand)
    if checkoutResult.status != 0 {
        logger("Failed to prepare worktree branch \(branchName): \(checkoutResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        return
    }

    let mergeResult = runShellCommand("git -C '\(escapedPath)' merge --ff-only '\(escapedRemoteRef)'")
    if mergeResult.status != 0 {
        logger("Worktree branch \(branchName) is not fast-forwardable; leaving current checkout unchanged")
    }
}

func prepareWorktree(repoPath: String, remoteName: String, prNumber: String, logger: (String) -> Void) -> String? {
    let worktreeDir = worktreePath(repoPath: repoPath, prNumber: prNumber)
    let branchName = worktreeBranchName(prNumber: prNumber)
    let remoteRef = worktreeRemoteRef(remoteName: remoteName, prNumber: prNumber)
    let escapedRepoPath = shellEscape(repoPath)
    let escapedRemoteName = shellEscape(remoteName)
    let escapedRemoteRef = shellEscape(remoteRef)
    let escapedWorktreeDir = shellEscape(worktreeDir)
    let prRefspec = "+refs/pull/\(prNumber)/head:\(remoteRef)"
    let escapedPrRefspec = shellEscape(prRefspec)

    let pruneResult = runShellCommand("git -C '\(escapedRepoPath)' worktree prune")
    if pruneResult.status != 0 {
        logger("git worktree prune failed: \(pruneResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    let fetchResult = runShellCommand("git -C '\(escapedRepoPath)' fetch '\(escapedRemoteName)' '\(escapedPrRefspec)'")
    if fetchResult.status != 0 {
        logger("Failed to fetch PR \(prNumber) into a worktree ref: \(fetchResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }

    ensureGlobalStateIgnored()
    cleanupStaleWorktrees(repoPath: repoPath, currentWorktreePath: worktreeDir, logger: logger)
    ensureParentDirectory(for: worktreeDir)

    if FileManager.default.fileExists(atPath: worktreeDir) {
        logger("Reusing worktree at \(worktreeDir)")
        updateExistingWorktree(path: worktreeDir, branchName: branchName, remoteRef: remoteRef, logger: logger)
        return worktreeDir
    }

    let addCommand: String
    if branchExists(repoPath: repoPath, branchName: branchName) {
        addCommand = "git -C '\(escapedRepoPath)' worktree add '\(escapedWorktreeDir)' '\(shellEscape(branchName))'"
    } else {
        addCommand = "git -C '\(escapedRepoPath)' worktree add -b '\(shellEscape(branchName))' '\(escapedWorktreeDir)' '\(escapedRemoteRef)'"
    }

    let addResult = runShellCommand(addCommand)
    if addResult.status != 0 {
        logger("Failed to create PR worktree at \(worktreeDir): \(addResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }

    logger("Created worktree at \(worktreeDir)")
    updateExistingWorktree(path: worktreeDir, branchName: branchName, remoteRef: remoteRef, logger: logger)
    return worktreeDir
}

func selectRepoPath(from candidates: [String], host: String, owner: String, repoName: String, logger: (String) -> Void) -> String? {
    guard !candidates.isEmpty else {
        return nil
    }

    let expectedRemote = "\(host)/\(owner)/\(repoName)"
    let scoredCandidates = candidates.map { path -> RepoCandidate in
        var score = 0
        var reasons: [String] = []

        let remotes = remoteInfos(for: path).compactMap(\.identifier)
        if remotes.contains(expectedRemote) {
            score += 100
            reasons.append("exact remote match")
        }

        if path.contains("/\(owner)/\(repoName)") {
            score += 20
            reasons.append("owner/repo path")
        }

        if path.contains("/prod/") {
            score += 10
            reasons.append("prod path")
        }

        return RepoCandidate(path: path, score: score, reasons: reasons)
    }
    .sorted { lhs, rhs in
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }

        return lhs.path < rhs.path
    }

    for candidate in scoredCandidates {
        let reasonSummary = candidate.reasons.isEmpty ? "fallback order" : candidate.reasons.joined(separator: ", ")
        logger("Repo candidate: \(candidate.path) [score=\(candidate.score)] \(reasonSummary)")
    }

    if scoredCandidates.count > 1,
       scoredCandidates[0].score == scoredCandidates[1].score {
        logger("Multiple equally ranked repo candidates found; choosing lexicographically first")
    }

    return scoredCandidates.first?.path
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

    func launchITerm(shellCmd: String) -> Bool {
        let script = """
        on run argv
            set shellCommand to item 1 of argv

        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                set newWindow to (create window with default profile)
                tell current session of newWindow
                        write text shellCommand
                end tell
            else
                tell current window
                    set newTab to (create tab with default profile)
                    tell current session of newTab
                            write text shellCommand
                    end tell
                end tell
            end if
        end tell
        end run
        """

        log("Running AppleScript...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, shellCmd]
        let errPipe = Pipe()
        process.standardError = errPipe
        try? process.run()
        process.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        log("osascript exit code: \(process.terminationStatus), stderr: \(errStr)")
        return process.terminationStatus == 0
    }

    func writePendingShellCommand(_ shellCmd: String, to path: String) -> Bool {
        do {
            try "\(shellCmd)\n".write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            log("Failed to write pending shell command to \(path): \(error.localizedDescription)")
            return false
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
              scheme == PRIMARY_URL_SCHEME,
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
        let owner = parts[1]
        let repoName = parts[2]
        let prNumber = parts[4]
        log("Repo name: \(repoName)")
        log("Selected CLI: \(reviewCLI.rawValue)")

        // Generate a deterministic session UUID from the normalized PR path
        // Use owner/repo/pull/number as the key (strip the host for portability)
        let prKey = parts[1...4].joined(separator: "/")
        let namespace = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")! // URL namespace
        let sessionId = uuidV5(namespace: namespace, name: prKey)
        let sessionIdStr = sessionId.uuidString.lowercased()
        log("Claude session ID: \(sessionIdStr) (from key: \(prKey))")

        ensureReviewSupportDir()
        let pendingCommandPath = "\(reviewSupportDir())/pending-\(safePathComponent(prKey))-\(UUID().uuidString.lowercased()).zsh"
        let escapedPendingCommandPath = shellEscape(pendingCommandPath)
        let pendingShellCmd = "cmd_file='\(escapedPendingCommandPath)'; echo 'Preparing PR review for \(shellEscape(prURL))...'; deadline=$((SECONDS + 120)); while [[ ! -s \"$cmd_file\" && $SECONDS -lt $deadline ]]; do sleep 0.1; done; if [[ ! -s \"$cmd_file\" ]]; then echo 'Timed out waiting for Agent PR Review to prepare the session.'; else source \"$cmd_file\"; rm -f \"$cmd_file\"; fi"
        let openedPendingTerminal = launchITerm(shellCmd: pendingShellCmd)

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
            repoPath = selectRepoPath(from: candidates, host: host, owner: owner, repoName: repoName, logger: log)
        }

        log("Repo path: \(repoPath ?? "NOT FOUND")")

        let shellCmd: String
        if let repoPath = repoPath {
            let expectedRemote = "\(host)/\(owner)/\(repoName)"
            let remoteName = preferredRemoteName(for: repoPath, expectedRemote: expectedRemote, logger: log)
            let worktreePath = remoteName.flatMap { remoteName in
                prepareWorktree(repoPath: repoPath, remoteName: remoteName, prNumber: prNumber, logger: log)
            }
            let launchPath = worktreePath ?? repoPath
            if worktreePath == nil {
                log("Falling back to the canonical repo checkout at \(repoPath)")
            }

            let isGhes = host.contains("github.intuit.com")
            let skillHint = isGhes ? " This PR is on GitHub Enterprise (github.intuit.com) - use the ghes skill for all GitHub operations instead of the default gh CLI." : ""
            let workspaceHint = worktreePath == nil
                ? "You are already in the local repo checkout for this PR."
                : "You are already in a dedicated local git worktree for this PR."
            let prompt = "Please review this PR: \(prURL). \(workspaceHint) Consider existing PR comments and review feedback as context for your review.\(skillHint)"

            switch reviewCLI {
            case .claude:
                shellCmd = claudeTerminalShellCommand(
                    launchPath: launchPath,
                    sessionId: sessionIdStr,
                    prompt: prompt
                )
            case .agent:
                let agentSessions = loadAgentSessionMap()
                let existingChatId = agentSessions[prKey]
                log("Existing Cursor chat: \(existingChatId ?? "NONE")")
                trustCursorWorkspace(launchPath, logger: log)
                shellCmd = agentTerminalShellCommand(
                    launchPath: launchPath,
                    prKey: prKey,
                    prompt: prompt,
                    existingChatId: existingChatId
                )
            }
        } else {
            shellCmd = "printf 'Repository %s not found under ~/code. Clone it first, then retry.\\n' '\(shellEscape(repoName))'"
        }

        log("Shell command: \(shellCmd)")

        if openedPendingTerminal {
            if writePendingShellCommand(shellCmd, to: pendingCommandPath) {
                log("Wrote pending shell command to \(pendingCommandPath)")
            } else {
                _ = launchITerm(shellCmd: shellCmd)
            }
        } else {
            _ = launchITerm(shellCmd: shellCmd)
        }

        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
