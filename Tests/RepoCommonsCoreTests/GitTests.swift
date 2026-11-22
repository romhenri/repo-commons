import Foundation
import Testing
@testable import RepoCommonsCore

// Integration tests: real git repos in a temp dir, a bare repo acts as the remote.

/// Isolates git from the developer's global/system config (gpgsign, showUntrackedFiles, ...).
private let isolateGit: Void = {
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    setenv("GIT_AUTHOR_NAME", "t", 1); setenv("GIT_AUTHOR_EMAIL", "t@t", 1)
    setenv("GIT_COMMITTER_NAME", "t", 1); setenv("GIT_COMMITTER_EMAIL", "t@t", 1)
}()

@discardableResult
private func sh(_ dir: URL, _ args: String...) throws -> String {
    _ = isolateGit
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = dir
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard p.terminationStatus == 0 else { throw GitError(message: "git \(args) failed: \(text)") }
    return text
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func write(_ dir: URL, _ name: String, _ text: String = "x") throws {
    try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

private func commit(_ dir: URL, _ name: String) throws {
    try write(dir, name, UUID().uuidString)
    try sh(dir, "add", name)
    try sh(dir, "commit", "-qm", name)
}

/// A bare remote with one commit on main, plus a clone of it. Returns (root, remote, clone).
private func clonedRepo() throws -> (URL, URL, URL) {
    let root = try tempDir()
    let remote = root.appendingPathComponent("remote.git")
    try sh(root, "init", "-q", "--bare", "-b", "main", remote.path)
    let seed = root.appendingPathComponent("seed")
    try sh(root, "clone", "-q", remote.path, seed.path)
    try commit(seed, "a")
    try sh(seed, "push", "-q", "origin", "HEAD:main")
    let clone = root.appendingPathComponent("clone")
    try sh(root, "clone", "-q", remote.path, clone.path)
    return (root, remote, clone)
}

@Test func findsOnlyFirstLevelReposSortedByName() throws {
    let folder = try tempDir()
    for name in ["beta", "Alpha"] {
        try sh(folder, "init", "-q", name)
    }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("plain"), withIntermediateDirectories: true)
    let nested = folder.appendingPathComponent("plain/deep")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try sh(nested, "init", "-q")
    try write(folder, "file.txt")

    let names = Git.repos(in: folder).map(\.lastPathComponent)
    #expect(names == ["Alpha", "beta"])
}

@Test func cleanCloneHasNoChangesAndIsInSync() async throws {
    let (_, _, clone) = try clonedRepo()
    let s = try await Git.status(of: clone)
    #expect(s.branch == "main")
    #expect(s.hasUpstream)
    #expect(s.changes == 0)
    #expect(s.ahead == 0 && s.behind == 0)
}

@Test func countsStagedModifiedAndUntrackedButNotIgnored() async throws {
    let (_, _, clone) = try clonedRepo()
    try write(clone, ".gitignore", "*.log\n")
    try write(clone, "debug.log")            // ignored: never counts
    try write(clone, "new.txt")              // untracked (.gitignore is untracked too)
    try write(clone, "a", "changed")         // tracked, modified in worktree
    try write(clone, "b")
    try sh(clone, "add", "b")                // staged

    let s = try await Git.status(of: clone)
    #expect(s.staged == 1)
    #expect(s.modified == 1)
    #expect(s.untracked == 2)
    #expect(s.changes == 4)
}

@Test func localCommitsAreAheadOfUpstream() async throws {
    let (_, _, clone) = try clonedRepo()
    try commit(clone, "c1")
    try commit(clone, "c2")
    let s = try await Git.status(of: clone)
    #expect(s.ahead == 2)
    #expect(s.unpushedBranches.isEmpty) // current branch is reported via ahead, not here
}

@Test func branchWithoutUpstreamIsFlagged() async throws {
    let (_, _, clone) = try clonedRepo()
    try sh(clone, "switch", "-qc", "feature")
    let s = try await Git.status(of: clone)
    #expect(s.branch == "feature")
    #expect(!s.hasUpstream)
}

@Test func otherLocalBranchesWithUnpushedWorkAreListed() async throws {
    let (_, _, clone) = try clonedRepo()
    try sh(clone, "switch", "-qc", "local-only")      // no upstream
    try sh(clone, "switch", "-q", "main")
    try sh(clone, "branch", "-q", "tracked", "origin/main")
    try sh(clone, "switch", "-q", "tracked")
    try commit(clone, "t1")                            // tracked is ahead of origin/main
    try sh(clone, "switch", "-qc", "synced", "origin/main") // tracked and in sync: not listed
    try sh(clone, "switch", "-q", "main")

    let s = try await Git.status(of: clone)
    #expect(s.unpushedBranches == ["local-only", "tracked"])
}

/// Pushes a new commit to the remote from a second clone.
private func pushFromElsewhere(_ root: URL, _ remote: URL, _ name: String) throws {
    let other = root.appendingPathComponent("other-\(UUID().uuidString)")
    try sh(root, "clone", "-q", remote.path, other.path)
    try commit(other, name)
    try sh(other, "push", "-q")
}

@Test func fetchRevealsRemoteCommitsAndPullFastForwards() async throws {
    let (root, remote, clone) = try clonedRepo()
    try pushFromElsewhere(root, remote, "remote-change")

    try await Git.fetch(clone)
    #expect(try await Git.status(of: clone).behind == 1)

    try await Git.pull(clone)
    let s = try await Git.status(of: clone)
    #expect(s.behind == 0)
    #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("remote-change").path))
}

@Test func divergedPullFailsWithoutTouchingTheRepo() async throws {
    let (root, remote, clone) = try clonedRepo()
    try pushFromElsewhere(root, remote, "theirs")
    try commit(clone, "mine")
    let head = try sh(clone, "rev-parse", "HEAD")

    await #expect(throws: GitError.self) { try await Git.pull(clone) }
    #expect(try sh(clone, "rev-parse", "HEAD") == head)
    #expect(try sh(clone, "status", "--porcelain").isEmpty)
}

@Test func failuresCarryGitsMessage() async throws {
    let folder = try tempDir()
    try sh(folder, "init", "-q", "lonely")
    do {
        try await Git.pull(folder.appendingPathComponent("lonely"))
        Issue.record("pull without upstream should fail")
    } catch let e as GitError {
        #expect(!e.message.isEmpty)
    }
}

@Test func batchRunsEveryItemWithAtMostFourAtOnce() async throws {
    actor Gauge { var now = 0, peak = 0, done: [Int] = []
        func enter() { now += 1; peak = max(peak, now) }
        func leave(_ i: Int) { now -= 1; done.append(i) } }
    let g = Gauge()
    await Git.batch(Array(0..<10)) { i in
        await g.enter()
        try? await Task.sleep(for: .milliseconds(20))
        await g.leave(i)
    }
    #expect(await g.peak == 4)
    #expect(await g.done.sorted() == Array(0..<10))
}

@Test func untrackedDirectoryCountsEachFile() async throws {
    let (_, _, clone) = try clonedRepo()
    let sub = clone.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try write(sub, "one"); try write(sub, "two")
    #expect(try await Git.status(of: clone).untracked == 2)
}

@Test func goneUpstreamIsTreatedAsNoUpstream() async throws {
    let (_, _, clone) = try clonedRepo()
    try sh(clone, "push", "-q", "origin", "HEAD:temp")
    try sh(clone, "switch", "-qc", "temp", "origin/temp")
    try commit(clone, "wip")
    try sh(clone, "switch", "-qc", "doomed", "origin/temp")
    try sh(clone, "push", "-q", "origin", "--delete", "temp")
    try sh(clone, "fetch", "-q", "--prune")

    let s = try await Git.status(of: clone)   // on doomed, upstream origin/temp is gone
    #expect(!s.hasUpstream)
    #expect(s.unpushedBranches == ["temp"])   // temp has unpushed work and a gone upstream
}

@Test func reportsLastCommitDateOfCurrentBranch() async throws {
    let (_, _, clone) = try clonedRepo()
    setenv("GIT_COMMITTER_DATE", "2020-01-02T03:04:05Z", 1)
    defer { unsetenv("GIT_COMMITTER_DATE") }
    try commit(clone, "dated")
    #expect(try await Git.status(of: clone).lastCommit == Date(timeIntervalSince1970: 1_577_934_245))
}

@Test func emptyRepoHasNoLastCommit() async throws {
    let folder = try tempDir()
    try sh(folder, "init", "-q", "empty")
    #expect(try await Git.status(of: folder.appendingPathComponent("empty")).lastCommit == nil)
}

@Test func pendingReportListsOnlyReposWithWorkToDo() {
    let folder = URL(fileURLWithPath: "/w")
    var dirty = RepoStatus(); dirty.branch = "main"; dirty.hasUpstream = true
    dirty.changes = 3; dirty.behind = 1
    var unpushed = RepoStatus(); unpushed.branch = "main"; unpushed.hasUpstream = true; unpushed.ahead = 1
    var noUpstream = RepoStatus(); noUpstream.branch = "feat/x"; noUpstream.unpushedBranches = ["old", "spike"]
    var clean = RepoStatus(); clean.branch = "main"; clean.hasUpstream = true; clean.behind = 4
    let detached = RepoStatus() // detached HEAD, nothing to push: not pending

    let report = pendingReport(scope: folder.path, repos: [
        (URL(fileURLWithPath: "/w/b"), unpushed),
        (URL(fileURLWithPath: "/w/a"), dirty),
        (URL(fileURLWithPath: "/w/c"), clean),
        (URL(fileURLWithPath: "/w/d"), noUpstream),
        (URL(fileURLWithPath: "/w/e"), detached),
    ])
    #expect(report == """
    Repos com mudanças pendentes em /w (3):

    - /w/a [main]: 3 arquivos não commitados, 1 commit atrás do remoto
    - /w/b [main]: 1 commit não enviado
    - /w/d [feat/x]: sem upstream, outras branches não enviadas: old, spike

    """)
}

@Test func pendingReportSaysWhenEverythingIsClean() {
    #expect(pendingReport(scope: "todas as pastas", repos: []) == "Nenhum repo com mudanças pendentes em todas as pastas.\n")
}
