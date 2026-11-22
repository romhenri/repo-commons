import AppKit
import RepoCommonsCore
import SwiftUI

@main
struct RepoCommonsApp: App {
    @State private var store = Store()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
            do { try renderIcon(to: CommandLine.arguments[i + 1]); exit(0) } catch { print(error); exit(1) }
        }
        // Lets `swift run` (no .app bundle) show a regular window and Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = appIcon
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("repo-commons", id: "main") {
            ContentView().environment(store).frame(minWidth: 800, minHeight: 400)
        }
    }
}

struct Repo: Identifiable {
    let url: URL
    let folder: URL
    var status: RepoStatus?
    var result: String?
    var failed = false
    var busy = false
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isDirty: Bool { (status?.changes ?? 0) > 0 }
    var hasUnpushed: Bool {
        guard let s = status else { return false }
        return s.ahead > 0 || (s.branch != nil && !s.hasUpstream) || !s.unpushedBranches.isEmpty
    }

    // Sort keys for the table columns (missing values sort first).
    var branchKey: String { status?.branch ?? "" }
    var changesKey: Int { status?.changes ?? 0 }
    var aheadKey: Int { status?.ahead ?? 0 }
    var resultKey: String { result ?? "" }
    var lastCommitKey: Date { status?.lastCommit ?? .distantPast }
}

enum Op: String { case fetch, pull }

@MainActor @Observable
final class Store {
    private(set) var folders = (UserDefaults.standard.stringArray(forKey: "folders") ?? []).map { URL(fileURLWithPath: $0) }
    private(set) var repos: [Repo] = []
    private(set) var running = false
    /// Paths of repos the user chose to ignore: hidden from the dashboard and skipped by batch fetch/pull.
    private(set) var ignored = Set(UserDefaults.standard.stringArray(forKey: "ignored") ?? [])

    func isIgnored(_ url: URL) -> Bool { ignored.contains(url.path) }

    func setIgnored(_ urls: Set<URL>, _ value: Bool) {
        for url in urls {
            if value { ignored.insert(url.path) } else { ignored.remove(url.path) }
        }
        UserDefaults.standard.set(ignored.sorted(), forKey: "ignored")
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adicionar"
        guard panel.runModal() == .OK else { return }
        folders += panel.urls.filter { !folders.contains($0) }
        save()
        Task { await refresh() }
    }

    func remove(_ folder: URL) {
        folders.removeAll { $0 == folder }
        repos.removeAll { $0.folder == folder }
        save()
    }

    private func save() { UserDefaults.standard.set(folders.map(\.path), forKey: "folders") }

    /// Rescans folders and reloads every repo's status. Keeps the last fetch/pull result per repo.
    func refresh() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let previous = Dictionary(repos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<URL>() // a repo under two nested root folders is listed once
        repos = folders.flatMap { folder in
            Git.repos(in: folder).filter { seen.insert($0).inserted }.map { url in
                var repo = previous[url] ?? Repo(url: url, folder: folder)
                repo.busy = true
                return repo
            }
        }
        await Git.batch(repos.map(\.url)) { url in
            do {
                let status = try await Git.status(of: url)
                await self.update(url) {
                    $0.status = status
                    if $0.failed { $0.result = nil; $0.failed = false }
                }
            } catch {
                await self.update(url) { $0.result = Self.message(error); $0.failed = true }
            }
        }
    }

    func run(_ op: Op, in folder: URL?) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let targets = repos.filter { (folder == nil || $0.folder == folder) && !isIgnored($0.url) }.map(\.url)
        for url in targets { update(url) { $0.busy = true } }
        await Git.batch(targets) { url in
            var result = "\(op.rawValue) ok", failed = false
            do {
                switch op {
                case .fetch: try await Git.fetch(url)
                case .pull: try await Git.pull(url)
                }
            } catch {
                result = Self.message(error)
                failed = true
            }
            let status = try? await Git.status(of: url)
            await self.update(url) {
                $0.result = result
                $0.failed = failed
                if let status { $0.status = status }
            }
        }
    }

    private func update(_ url: URL, _ change: (inout Repo) -> Void) {
        guard let i = repos.firstIndex(where: { $0.url == url }) else { return }
        change(&repos[i])
        repos[i].busy = false
    }

    private nonisolated static func message(_ error: Error) -> String {
        (error as? GitError)?.message ?? error.localizedDescription
    }
}

enum Scope: Hashable { case all, folder(URL), ignored }

/// Sidebar row whose icon carries the brand orange instead of the system accent.
struct BrandLabel: View {
    let title: String
    let icon: String
    var body: some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(Color.brand) }
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var scope: Scope? = .all
    @State private var selection = Set<URL>()
    @State private var onlyDirty = false
    @State private var onlyUnpushed = false
    @State private var sortOrder = [KeyPathComparator(\Repo.name)]

    private var folder: URL? {
        if case .folder(let url) = scope { return url }
        return nil
    }

    private var visible: [Repo] {
        store.repos.filter {
            if scope == .ignored { return store.isIgnored($0.url) }
            return !store.isIgnored($0.url)
                && (folder == nil || $0.folder == folder)
                && (!onlyDirty || $0.isDirty)
                && (!onlyUnpushed || $0.hasUnpushed)
        }
        .sorted(using: sortOrder)
    }

    private var ignoredCount: Int { store.repos.filter { store.isIgnored($0.url) }.count }

    var body: some View {
        NavigationSplitView {
            List(selection: $scope) {
                BrandLabel(title: "Todas", icon: "square.stack.3d.up").tag(Scope.all)
                Section("Pastas") {
                    ForEach(store.folders, id: \.self) { folder in
                        BrandLabel(title: folder.lastPathComponent, icon: "folder")
                            .help(folder.path)
                            .tag(Scope.folder(folder))
                            .contextMenu {
                                Group {
                                    Button("Fetch") { Task { await store.run(.fetch, in: folder) } }
                                    Button("Pull") { Task { await store.run(.pull, in: folder) } }
                                }
                                .disabled(store.running)
                                Divider()
                                Button("Remover") {
                                    if scope == .folder(folder) { scope = .all }
                                    store.remove(folder)
                                }
                            }
                    }
                }
                if ignoredCount > 0 {
                    Section {
                        BrandLabel(title: "Ignorados", icon: "eye.slash")
                            .badge(ignoredCount)
                            .tag(Scope.ignored)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .onChange(of: ignoredCount) { if ignoredCount == 0, scope == .ignored { scope = .all } }
        } detail: {
            if store.folders.isEmpty {
                ContentUnavailableView {
                    Label("Nenhuma pasta", systemImage: "folder.badge.plus")
                } description: {
                    Text("Adicione pastas que contêm repositórios git.")
                } actions: {
                    Button("Adicionar pasta…") { store.addFolders() }
                }
            } else {
                table
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle("Só sujos", isOn: $onlyDirty)
                Toggle("Só unpushed", isOn: $onlyUnpushed)
                Button("Adicionar pasta", systemImage: "folder.badge.plus") { store.addFolders() }
                Group {
                    Button("Atualizar", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        .keyboardShortcut("r")
                    Button("Fetch", systemImage: "arrow.down.circle") { Task { await store.run(.fetch, in: folder) } }
                        .help(folder == nil ? "Fetch em todos os repos" : "Fetch nos repos desta pasta")
                    Button("Pull", systemImage: "arrow.down.to.line") { Task { await store.run(.pull, in: folder) } }
                        .help(folder == nil ? "Pull (ff-only) em todos os repos" : "Pull (ff-only) nos repos desta pasta")
                }
                .disabled(store.running || scope == .ignored)
            }
        }
        .task { await store.refresh() }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repo", value: \.name) { repo in
                HStack {
                    Text(repo.name)
                    if repo.busy { ProgressView().controlSize(.small) }
                }
            }
            TableColumn("Branch", value: \.branchKey) { repo in
                if let s = repo.status {
                    let noUpstream = s.branch != nil && !s.hasUpstream
                    Text((s.branch ?? "(detached)") + (noUpstream ? "  · sem upstream" : ""))
                        .foregroundStyle(noUpstream ? Color.orange : .primary)
                }
            }
            TableColumn("Mudanças", value: \.changesKey) { repo in
                if let s = repo.status, s.changes > 0 {
                    Text("\(s.changes)")
                        .foregroundStyle(.orange)
                        .help("\(s.staged) staged · \(s.modified) modified · \(s.untracked) untracked")
                }
            }
            .width(70)
            TableColumn("↑ ↓", value: \.aheadKey) { repo in
                if let s = repo.status {
                    HStack {
                        Text("↑\(s.ahead) ↓\(s.behind)")
                            .foregroundStyle(s.ahead > 0 ? .orange : .secondary)
                        if !s.unpushedBranches.isEmpty {
                            Text("+\(s.unpushedBranches.count) branch")
                                .font(.caption)
                                .padding(.horizontal, 4)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .help("Unpushed: " + s.unpushedBranches.joined(separator: ", "))
                        }
                    }
                }
            }
            TableColumn("Status", value: \.resultKey) { repo in
                if let result = repo.result {
                    // git prints hints around the real error; show the fatal/error line when there is one.
                    let lines = result.split(separator: "\n")
                    Text(lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.first ?? "")
                        .foregroundStyle(repo.failed ? .red : .secondary)
                        .help(result)
                }
            }
            TableColumn("Último commit", value: \.lastCommitKey) { repo in
                if let date = repo.status?.lastCommit {
                    // UI strings are hardcoded Portuguese, so dates follow suit regardless of bundle localizations.
                    let ptBR = Locale(identifier: "pt_BR")
                    Text(date, format: Date.RelativeFormatStyle(presentation: .named, locale: ptBR))
                        .foregroundStyle(.secondary)
                        .help(date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: ptBR)))
                }
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            ForEach(openers, id: \.bundleID) { opener in
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: opener.bundleID) {
                    Button(opener.title) {
                        NSWorkspace.shared.open(Array(urls), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    }
                }
            }
            Button("Copiar path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            if scope == .ignored {
                Button("Deixar de ignorar") { store.setIgnored(urls, false) }
            } else {
                Button("Ignorar") { store.setIgnored(urls, true) }
            }
        } primaryAction: { urls in
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    /// "Open with" targets in the row context menu; an app missing from this Mac is simply not listed.
    private let openers = [
        (title: "Abrir no Terminal", bundleID: "com.apple.Terminal"),
        (title: "Abrir com Code", bundleID: "com.microsoft.VSCode"),
        (title: "Abrir com Zed", bundleID: "dev.zed.Zed"),
    ]
}
