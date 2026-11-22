import Foundation

public struct GitError: Error, Equatable {
    public let message: String
}

public struct RepoStatus: Equatable, Sendable {
    /// nil when HEAD is detached.
    public var branch: String?
    public var hasUpstream = false
    public var ahead = 0
    public var behind = 0
    public var staged = 0
    public var modified = 0
    public var untracked = 0
    /// Files with any uncommitted change (a file both staged and modified counts once).
    public var changes = 0
    /// Commit date of HEAD; nil in a repo with no commits yet.
    public var lastCommit: Date?
}

public enum Git {
    /// Direct children of `folder` that are git repos (`.git` dir, or file for worktrees), sorted by name.
    public static func repos(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func status(of repo: URL) async throws -> RepoStatus {
        // --no-optional-locks: don't fight editors over index.lock. -uall counts files inside new dirs
        // and overrides a user's showUntrackedFiles=no.
        let out = try await run(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "--untracked-files=all"], in: repo)
        var s = RepoStatus()
        var hasCommits = true
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3).map(String.init)
            switch f[0] {
            case "#" where f[1] == "branch.oid":
                hasCommits = f[2] != "(initial)"
            case "#" where f[1] == "branch.head":
                s.branch = f[2] == "(detached)" ? nil : f[2]
            case "#" where f[1] == "branch.ab": // absent when the upstream is unset or gone
                s.hasUpstream = true
                s.ahead = Int(f[2].dropFirst()) ?? 0
                s.behind = Int(f[3].dropFirst()) ?? 0
            case "1", "2", "u":
                let xy = Array(f[1])
                if xy[0] != "." { s.staged += 1 }
                if xy[1] != "." { s.modified += 1 }
                s.changes += 1
            case "?":
                s.untracked += 1
                s.changes += 1
            default: break
            }
        }
        if hasCommits {
            let ts = try await run(["log", "-1", "--format=%ct"], in: repo)
            s.lastCommit = Double(ts.trimmingCharacters(in: .whitespacesAndNewlines)).map(Date.init(timeIntervalSince1970:))
        }
        return s
    }

    public static func fetch(_ repo: URL) async throws {
        _ = try await run(["fetch", "--quiet"], in: repo)
    }

    /// Fast-forward only: a diverged branch fails with git's message and the repo is left untouched.
    public static func pull(_ repo: URL) async throws {
        _ = try await run(["pull", "--ff-only", "--quiet"], in: repo)
    }

    /// Plain `git push`, never forced: a diverged remote is rejected with git's message.
    public static func push(_ repo: URL) async throws {
        _ = try await run(["push", "--quiet"], in: repo)
    }

    /// Runs `body` for every item, at most `limit` at a time.
    public static func batch<T: Sendable>(_ items: [T], limit: Int = 4, _ body: @escaping @Sendable (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = items.makeIterator()
            for _ in 0..<limit { if let item = pending.next() { group.addTask { await body(item) } } }
            while await group.next() != nil {
                if let item = pending.next() { group.addTask { await body(item) } }
            }
        }
    }

    /// Runs git in `dir`. Never prompts: a repo needing credentials fails instead of hanging invisibly.
    static func run(_ args: [String], in dir: URL) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try runSync(args, in: dir) })
            }
        }
    }

    private static func runSync(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // ponytail: fixed 120s cap so a stalled fetch can't hang the batch forever; make it a setting if slow remotes need more.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { if p.isRunning { p.terminate() } }
        // Drain stderr concurrently so a chatty command can't fill the pipe and deadlock.
        nonisolated(unsafe) var errData = Data() // safe: read only after group.wait()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        if p.terminationReason == .uncaughtSignal {
            throw GitError(message: "git \(args.joined(separator: " ")) timed out")
        }
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: msg.isEmpty ? "git \(args.joined(separator: " ")) exited \(p.terminationStatus)" : msg)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}

extension RepoStatus {
    public var isDirty: Bool { changes > 0 }
    /// Only the active branch counts: commits to push, or a branch never pushed. A detached HEAD has nothing to push.
    public var hasUnpushed: Bool { ahead > 0 || (branch != nil && !hasUpstream) }
    public var isPending: Bool { isDirty || hasUnpushed }
}

/// Markdown list of the repos with pending work, one absolute path per line, meant to be pasted into a coding agent.
/// `scope` names where the repos come from: a folder path, or "todas as pastas".
public func pendingReport(scope: String, repos: [(url: URL, status: RepoStatus)]) -> String {
    let pending = repos.filter { $0.status.isPending }.sorted { $0.url.path < $1.url.path }
    guard !pending.isEmpty else { return "Nenhum repo com mudanças pendentes em \(scope).\n" }
    func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
    let lines = pending.map { url, s in
        var parts: [String] = []
        if s.changes > 0 { parts.append(count(s.changes, "arquivo não commitado", "arquivos não commitados")) }
        if s.ahead > 0 { parts.append(count(s.ahead, "commit não enviado", "commits não enviados")) }
        if s.branch != nil && !s.hasUpstream { parts.append("sem upstream") }
        if s.behind > 0 { parts.append(count(s.behind, "commit atrás do remoto", "commits atrás do remoto")) }
        return "- \(url.path) [\(s.branch ?? "detached")]: " + parts.joined(separator: ", ")
    }
    return "Repos com mudanças pendentes em \(scope) (\(pending.count)):\n\n" + lines.joined(separator: "\n") + "\n"
}
