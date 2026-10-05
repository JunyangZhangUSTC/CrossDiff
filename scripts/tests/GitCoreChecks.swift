import Foundation
import Darwin
@testable import CrossDiffCore

@main struct GitCoreChecks {
    static var passed = 0
    static func expect(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: " + name) }
        passed += 1; print("✓ " + name)
    }
    static func expectError(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: " + name) } catch { passed += 1; print("✓ " + name) }
    }
    @discardableResult static func git(_ args: [String], at directory: URL, input: Data? = nil) throws -> Data {
        let p = Process(), output = Pipe(), incoming = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = directory
        p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "CrossDiff Fixture"; env["GIT_AUTHOR_EMAIL"] = "fixture@example.com"
        env["GIT_COMMITTER_NAME"] = "CrossDiff Fixture"; env["GIT_COMMITTER_EMAIL"] = "fixture@example.com"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env; p.standardOutput = output; p.standardError = FileHandle.standardError
        p.standardInput = input == nil ? FileHandle.nullDevice : incoming
        try p.run()
        if let input { try incoming.fileHandleForWriting.write(contentsOf: input); try incoming.fileHandleForWriting.close() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitError.commandFailed }
        return bytes
    }
    static func value(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines) }
    static func write(_ text: String, _ path: String, _ directory: URL) throws { try Data(text.utf8).write(to: directory.appendingPathComponent(path)) }

    static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count > 1 else { fatalError("Project-local fixture directory required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString)
        let workingRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        guard root.resolvingSymlinksInPath().path.hasPrefix(workingRoot.path + "/") else { fatalError("Fixtures must be project-local") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q", "--initial-branch=main", "--template="], at: root)
        try write("Original 中文 👩🏽‍💻\r\nLine two\r\n", "README.md", root)
        try write("unchanged\n", "keep.txt", root)
        try write("deleted\n", "delete.txt", root)
        try write((0..<100).map { "line \($0) original\n" }.joined(), "before.txt", root)
        try write("#!/bin/sh\nexit 0\n", "mode.sh", root)
        try write("", "empty.txt", root)
        try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent("data.bin"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "README.md")
        try git(["add", "--all"], at: root); try git(["commit", "-qm", "Initial 中文"], at: root)
        let initial = value(try git(["rev-parse", "HEAD"], at: root))
        try git(["update-index", "--add", "--cacheinfo", "160000," + initial + ",vendor/lib"], at: root)
        try git(["commit", "-qm", "Pin submodule"], at: root)
        let base = value(try git(["rev-parse", "HEAD"], at: root))
        try git(["branch", "baseline"], at: root)
        try git(["tag", "-a", "v1", "-m", "Annotated tag"], at: root)
        try write("Modified 中文 👩🏽‍💻\r\nLine two\r\n", "README.md", root)
        try FileManager.default.moveItem(at: root.appendingPathComponent("before.txt"), to: root.appendingPathComponent("after.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        let unusual = "中文\t带空格\n文件.txt"
        try write("new content\n", unusual, root)
        try Data([0, 9, 2, 255]).write(to: root.appendingPathComponent("data.bin"))
        try git(["add", "--all"], at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("mode.sh").path)
        try git(["update-index", "--chmod=+x", "mode.sh"], at: root)
        try git(["commit", "-qm", "Second changes"], at: root)
        let head = value(try git(["rev-parse", "HEAD"], at: root))
        let repo = try GitRepository.open(root)
        expect(!repo.isBare && !repo.isRemoteCache, "Local repository opens read-only")
        let refs = try repo.references()
        expect(refs.contains { $0.name == "baseline" && $0.objectID == base }, "Branches list with immutable commit IDs")
        expect(refs.contains { $0.name == "v1" && $0.objectID == base && $0.kind == .tag }, "Annotated tags peel to commit IDs")
        expect(try repo.resolve("HEAD~1") == base, "Explicit relative revision resolves")
        let history = try repo.commits(limit: 2)
        expect(history.count == 2 && history[0].objectID == head && history[0].subject == "Second changes", "NUL-separated history preserves commit fields")
        let comparison = try repo.compare(left: "baseline", right: "main")
        expect(comparison.leftCommit.objectID == base && comparison.rightCommit.objectID == head, "Comparison pins both immutable commits")
        expect(comparison.files.contains { $0.kind == .renamed && $0.left?.path == "before.txt" && $0.right?.path == "after.txt" && $0.similarity == 100 }, "Git rename detection pairs stored blobs")
        expect(comparison.files.contains { $0.path == "mode.sh" && $0.kind == .modified && $0.left?.objectID == $0.right?.objectID }, "Executable-bit-only change is visible")
        expect(comparison.files.contains { $0.path == "delete.txt" && $0.kind == .deleted }, "Deleted file remains visible")
        expect(comparison.files.contains { Data($0.path.utf8) == Data(unusual.utf8) && $0.kind == .added }, "Tabs, newlines and Unicode paths remain lossless")
        expect(comparison.files.contains { $0.path == "keep.txt" && $0.kind == .unchanged }, "All-file tree includes unchanged files")
        expect(comparison.files.contains { $0.path == "vendor/lib" && $0.left?.kind == .submodule }, "Submodule pointer is not recursively opened")
        let readme = comparison.rightTree.first { $0.path == "README.md" }!
        expect(GitBlobText.decode(try repo.readBlob(entry: readme)) == "Modified 中文 👩🏽‍💻\r\nLine two\r\n", "Blob content preserves Unicode and CRLF")
        let link = comparison.rightTree.first { $0.path == "link" }!
        expect(GitBlobText.decode(try repo.readBlob(entry: link)) == "README.md", "Symlink preview reads target text without following it")
        let empty = comparison.rightTree.first { $0.path == "empty.txt" }!
        expect(try repo.readBlob(entry: empty).isEmpty, "Empty blobs remain previewable")
        let binary = comparison.rightTree.first { $0.path == "data.bin" }!
        expect(GitBlobText.decode(try repo.readBlob(entry: binary)) == nil, "Binary data is not decoded as lossy text")
        expectError("Blob size budget enforced before reading") { _ = try repo.readBlob(entry: readme, maximumBytes: 2) }
        let withoutRenames = try repo.compare(left: base, right: head, options: .init(detectRenames: false))
        expect(withoutRenames.files.contains { $0.path == "before.txt" && $0.kind == .deleted } && withoutRenames.files.contains { $0.path == "after.txt" && $0.kind == .added }, "Rename detection can be disabled")
        let swapped = try repo.compare(left: head, right: base)
        expect(swapped.files.contains { Data($0.path.utf8) == Data(unusual.utf8) && $0.kind == .deleted }, "Swapping endpoints reverses additions and deletions")

        // A divergent branch demonstrates merge-base comparison without checkout side effects.
        try git(["checkout", "-qb", "feature", base], at: root)
        try write("feature\n", "feature.txt", root)
        try git(["add", "feature.txt"], at: root); try git(["commit", "-qm", "Feature"], at: root)
        let feature = value(try git(["rev-parse", "HEAD"], at: root))
        try git(["checkout", "-q", "main"], at: root)
        let mergeBase = try repo.compare(left: "main", right: "feature", options: .init(useMergeBase: true))
        expect(mergeBase.mergeBaseObjectID == base && mergeBase.leftCommit.objectID == base && mergeBase.rightCommit.objectID == feature, "Merge-base comparison selects common ancestor")
        try write("USER UNSAVED\n", "README.md", root)
        try write("USER UNTRACKED\n", "untracked.txt", root)
        let statusBefore = try git(["status", "--porcelain=v1", "-z"], at: root)
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let headBefore = try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))
        _ = try repo.compare(left: base, right: head)
        _ = try repo.commits(); _ = try repo.readBlob(entry: readme)
        expect(try Data(contentsOf: root.appendingPathComponent("README.md")) == Data("USER UNSAVED\n".utf8), "Dirty working file is untouched")
        expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore && Data(contentsOf: root.appendingPathComponent(".git/HEAD")) == headBefore, "Index and HEAD remain byte-identical")
        expect(try git(["status", "--porcelain=v1", "-z"], at: root) == statusBefore, "Tracked and untracked working state remains identical")
        expectError("Local repositories cannot be refreshed") { try repo.refresh(remote: GitRemote.parse("https://github.com/example/example")) }
        for revision in ["--output=evil", "HEAD:README.md", "HEAD..main", "HEAD\nmain", "main@{0}", "missing-branch"] {
            expectError("Reject invalid revision: " + revision.debugDescription) { _ = try repo.resolve(revision) }
        }
        expectError("Cancellation before process launch") { _ = try repo.references(isCancelled: { true }) }
        var cancellationChecks = 0
        expectError("Cancellation while Git is running") { _ = try repo.references(isCancelled: { cancellationChecks += 1; return cancellationChecks > 1 }) }
        expectError("Process output has hard byte limit") { _ = try GitProcess.run(at: root, arguments: ["log", "--all"], maximumBytes: 8) }
        expectError("Process deadline is enforced") { _ = try GitProcess.run(at: root, arguments: ["log", "--all"], timeout: -1) }

        let bareRoot = root.appendingPathComponent("bare.git")
        try git(["clone", "--quiet", "--bare", "--no-local", root.path, bareRoot.path], at: root)
        let bareRepo = try GitRepository.open(bareRoot)
        expect(try bareRepo.isBare && !bareRepo.isRemoteCache && bareRepo.resolve("main") == head, "Existing bare repositories open read-only")
        expectError("Unmarked bare repository cannot become a remote cache") { _ = try GitRepository.openCache(bareRoot, remote: GitRemote.parse("https://github.com/example/example.git")) }
        let worktreeRoot = root.appendingPathComponent("linked-worktree")
        try git(["worktree", "add", "--quiet", "--detach", worktreeRoot.path, base], at: root)
        expect(try GitRepository.open(worktreeRoot).resolve("HEAD") == base, "Linked Git worktrees resolve their own HEAD")

        let hookMarker = root.appendingPathComponent("must-not-execute")
        let helper = root.appendingPathComponent("evil-helper.sh")
        try write("#!/bin/sh\ntouch '\(hookMarker.path)'\nexit 1\n", helper.lastPathComponent, root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try git(["config", "diff.external", helper.path], at: root)
        try git(["config", "core.fsmonitor", helper.path], at: root)
        try git(["config", "diff.fixture.textconv", helper.path], at: root)
        try write("*.md diff=fixture\n", ".gitattributes", root)
        _ = try repo.compare(left: base, right: head); _ = try repo.readBlob(entry: readme)
        expect(!FileManager.default.fileExists(atPath: hookMarker.path), "External diff, fsmonitor and textconv helpers never execute")

        let emptyRoot = root.appendingPathComponent("empty-repository")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try git(["init", "-q", "--template="], at: emptyRoot)
        expect(try GitRepository.open(emptyRoot).commits().isEmpty, "Empty repository reports no commits")
        let nonRepo = root.appendingPathComponent("not-repository")
        // Prevent parent discovery from turning a plain folder inside our fixture into a repository.
        expectError("Nonexistent folder is rejected") { _ = try GitRepository.open(nonRepo) }
        try remoteChecks()

        // Construct raw tree entries to test names APFS cannot store side by side.
        let blob = value(try git(["hash-object", "-w", "--stdin"], at: root, input: Data("x".utf8)))
        let composed = "café.txt", decomposed = "cafe\u{301}.txt"
        let treeInput = Data(("100644 blob " + blob + "\t" + composed + "\0" + "100644 blob " + blob + "\t" + decomposed + "\0").utf8)
        let tree = value(try git(["mktree", "-z"], at: root, input: treeInput))
        let rawTree = try repo.tree(objectID: tree)
        expect(rawTree.count == 2 && Set(rawTree.map(\.id)).count == 2, "Unicode-normalization-distinct Git paths remain distinct")
        var invalidPath = Data(("100644 blob " + blob + "\t").utf8); invalidPath.append(0xFF); invalidPath.append(0)
        let invalidTree = value(try git(["mktree", "-z"], at: root, input: invalidPath))
        expectError("Non-UTF8 filename fails explicitly without partial tree") { _ = try repo.tree(objectID: invalidTree) }
        let utf16 = Data([0xFF, 0xFE]) + "中文\r\n".data(using: .utf16LittleEndian)!
        expect(GitBlobText.decode(utf16) == "中文\r\n", "BOM UTF-16 text decoding")
        let combinedText = "e\u{301} 👩🏽‍💻\r\n"
        expect(GitBlobText.decode(Data([0xEF, 0xBB, 0xBF]) + Data(combinedText.utf8)).map { Data($0.utf8) } == Data(combinedText.utf8), "UTF-8 BOM and combining characters remain byte-exact")
        expect(GitBlobText.decode(Data([1, 2, 3, 127])) == nil, "Non-NUL binary controls route to hexadecimal preview")
        expect(GitBlobText.decode(Data([0xFF, 0xFE, 0, 0, 65, 0, 0, 0])) == nil, "UTF-32 is not misclassified as UTF-16")
        try batchInputChecks(root: root)
        try indexMetadataChecks(root: root)
        try localSourceChecks(root: root)
        try largeSourceChecks(root: root)
        if ProcessInfo.processInfo.environment["CROSSDIFF_GIT_NETWORK_CHECK"] == "1" {
            let remote = try GitRemote.parse("https://github.com/octocat/Hello-World.git")
            let cache = root.appendingPathComponent("remote-cache.git")
            let downloaded = try GitRepository.clone(remote: remote, to: cache)
            expect(try downloaded.isBare && downloaded.isRemoteCache && !downloaded.references().isEmpty, "Public HTTPS clone loads an app-owned bare cache")
            let reopened = try GitRepository.openCache(cache, remote: remote)
            expect(reopened.isRemoteCache, "App-owned remote cache reopens with marker validation")
            try reopened.refresh(remote: remote)
            expect(!(try reopened.commits()).isEmpty, "Reopened cache refreshes atomically without checkout")
            expectError("Different remote cannot claim existing cache") { _ = try GitRepository.openCache(cache, remote: GitRemote.parse("https://github.com/example/example.git")) }
            expectError("Clone does not overwrite existing directory") { _ = try GitRepository.clone(remote: remote, to: cache) }
            let marker = cache.appendingPathComponent("crossdiff-cache.json")
            let markerBytes = try Data(contentsOf: marker)
            try FileManager.default.removeItem(at: marker)
            expectError("Refresh revalidates cache ownership before writing") { try reopened.refresh(remote: remote) }
            try markerBytes.write(to: marker)
            let moved = root.appendingPathComponent("moved-cache.git")
            try FileManager.default.moveItem(at: cache, to: moved)
            try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: moved)
            expectError("Refresh rejects a cache path replaced by a symlink") { try reopened.refresh(remote: remote) }
            try FileManager.default.removeItem(at: cache)
            try FileManager.default.moveItem(at: moved, to: cache)
        }
        print("All \(passed) Git core checks passed.")
    }
    static func batchInputChecks(root: URL) throws {
        let bytes = Data(repeating: 65, count: GitProcess.maximumInput)
        let expected = value(try git(["hash-object", "--stdin"], at: root, input: bytes))
        let actual = value(try GitProcess.run(at: root, arguments: ["hash-object", "--stdin"], input: bytes))
        expect(actual == expected, "Bounded stdin transmits all bytes and closes before waiting for Git")
        let empty = try GitProcess.run(at: root, arguments: ["cat-file", "--batch-check"], input: Data())
        expect(empty.isEmpty, "Empty batch stdin delivers EOF")
        let missing = String(repeating: "0", count: 40)
        let requests = Data(String(repeating: missing + "\n", count: 390).utf8)
        let replies = try GitProcess.run(at: root, arguments: ["cat-file", "--batch-check"], input: requests)
        expect(replies == Data(String(repeating: missing + " missing\n", count: 390).utf8), "Larger output drains while batch stdin is written without pipe deadlock")
        expectError("Oversized process stdin fails before launching Git") {
            _ = try GitProcess.run(at: root, arguments: ["hash-object", "--stdin"], input: Data(repeating: 0, count: GitProcess.maximumInput + 1))
        }
        expectError("Batch stdin respects cancellation") {
            _ = try GitProcess.run(at: root, arguments: ["cat-file", "--batch-check"], input: requests, isCancelled: { true })
        }
        expectError("Batch stdin respects deadline") {
            _ = try GitProcess.run(at: root, arguments: ["cat-file", "--batch-check"], input: requests, timeout: 0)
        }
        for _ in 0..<8 {
            do { _ = try GitProcess.run(at: root, arguments: ["version"], input: bytes) }
            catch GitError.commandFailed { }
        }
        expect(true, "Early Git exit with pending stdin cannot terminate the host via SIGPIPE")
    }
    static func indexMetadataChecks(root parent: URL) throws {
        let root = parent.appendingPathComponent("index-metadata-batches")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main", "--template="], at: root)
        var expected: [String: Int] = [:]
        for n in 0..<263 {
            let path = n == 262 ? "中文\t含换行\n.txt" : "file-\(n).txt"
            let content = "\(n) 👩🏽‍💻 " + String(repeating: "x", count: n)
            try write(content, path, root); expected[path] = content.utf8.count
        }
        try write("", "empty.txt", root); expected["empty.txt"] = 0
        let linkTargets = ["link": "file-0.txt", "unicode-link": "不存在的目录/👩🏽‍💻\n.txt", "long-link": String(repeating: "long/", count: 100) + "target"]
        for (path, target) in linkTargets {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: target)
            expected[path] = target.utf8.count
        }
        try git(["add", "--all"], at: root)
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let objectsBefore = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent(".git/objects").path).sorted()
        let repo = try GitRepository.open(root)
        let snapshot = try repo.compareSources(left: .commit("HEAD"), right: .index)
        expect(snapshot.rightTree.count == expected.count && snapshot.rightTree.allSatisfy { expected[$0.path] == $0.size }, "Multiple metadata batches preserve byte sizes, empty blobs, symlinks and unusual paths")
        let working = try repo.compareSources(left: .index, right: .workingTree)
        expect(working.changedFiles.isEmpty, "Working symlink buffers preserve short, Unicode and long targets without following them")
        for (path, target) in linkTargets {
            let entry = working.rightTree.first { $0.path == path }!
            expect(try repo.readContent(entry: entry, in: working.rightSnapshot) == Data(target.utf8), "Symlink preview returns exact target bytes: " + path)
        }
        expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore && FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent(".git/objects").path).sorted() == objectsBefore, "Metadata queries leave the source index and object database byte-identical")
        let oid = snapshot.rightTree.first { $0.path == "file-0.txt" }!.objectID
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/objects/" + oid.prefix(2) + "/" + oid.dropFirst(2)))
        do {
            _ = try repo.compareSources(left: .commit("HEAD"), right: .index)
            fatalError("Missing staged object was accepted")
        } catch GitError.missingObject { }
        expect(true, "Missing staged blob fails explicitly instead of silently assigning zero size")
    }
    static func localSourceChecks(root parent: URL) throws {
        let root = parent.appendingPathComponent("local-sources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main", "--template="], at: root)
        try write("committed\r\n", "mixed.txt", root)
        try write("keep\n", "keep.txt", root)
        try write("staged deletion\n", "removed.txt", root)
        try write("unstaged deletion\n", "gone.txt", root)
        try write("exact rename original\n", "old-name.txt", root)
        try write("#!/bin/sh\nexit 0\n", "executable.sh", root)
        try write("ignored.txt\nskipdir/\n", ".gitignore", root)
        try git(["add", "--all"], at: root); try git(["commit", "-qm", "Source baseline"], at: root)
        try write("staged\r\n", "mixed.txt", root)
        try write("staged new\n", "staged.txt", root)
        try git(["add", "mixed.txt", "staged.txt"], at: root)
        try git(["rm", "-q", "removed.txt"], at: root)
        try write("working 👩🏽‍💻 e\u{301}\r\n", "mixed.txt", root)
        try write("working new\n", "staged.txt", root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("old-name.txt"), to: root.appendingPathComponent("new-name.txt"))
        try write("untracked\n", "new.txt", root)
        try write("ignored contents\n", "ignored.txt", root)
        try write("excluded contents\n", "private.txt", root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        try write("private.txt\n", ".git/info/exclude", root)
        try write("intent is not staged\n", "intent.txt", root)
        try git(["add", "-N", "intent.txt"], at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("executable.sh").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("symbolic").path, withDestinationPath: "mixed.txt")
        let repo = try GitRepository.open(root)
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let headBefore = try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))
        let objectsBefore = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent(".git/objects").path).sorted()
        let staged = try repo.compareSources(left: .commit("HEAD"), right: .index)
        expect(staged.leftSnapshot.commit != nil && staged.rightSnapshot.commit == nil && staged.rightSnapshot.source == .index, "Staging metadata does not pretend to be a commit")
        expect(staged.changedFiles.contains { $0.path == "mixed.txt" && $0.kind == .modified }, "HEAD to index shows staged modification")
        expect(staged.changedFiles.contains { $0.path == "removed.txt" && $0.kind == .deleted }, "HEAD to index shows staged deletion")
        expect(!staged.rightTree.contains { $0.path == "intent.txt" }, "Intent-to-add placeholder is not staged content")
        let stageEntry = staged.rightTree.first { $0.path == "mixed.txt" }!
        expect(GitBlobText.decode(try repo.readContent(entry: stageEntry, in: staged.rightSnapshot)) == "staged\r\n", "Staged detail reads index blob despite subsequent working edits")
        let working = try repo.compareSources(left: .index, right: .workingTree)
        expect(working.leftSnapshot.commit == nil && working.rightSnapshot.commit == nil && working.exactRenamesOnly, "Local snapshots have explicit source metadata and exact-only renames")
        expect(working.changedFiles.contains { $0.path == "mixed.txt" && $0.kind == .modified }, "Index to working tree shows unstaged modification independently")
        expect(working.changedFiles.contains { $0.path == "gone.txt" && $0.kind == .deleted }, "Index to working tree shows unstaged deletion")
        expect(working.changedFiles.contains { $0.path == "intent.txt" && $0.kind == .added }, "Intent-to-add remains working content")
        expect(working.changedFiles.contains { $0.kind == .renamed && $0.left?.path == "old-name.txt" && $0.right?.path == "new-name.txt" && $0.similarity == 100 }, "Working-tree exact-content rename pairs untracked destination")
        expect(working.changedFiles.contains { $0.path == "new.txt" && $0.kind == .added }, "Optional untracked file is included")
        expect(!working.rightTree.contains { ["ignored.txt", "private.txt"].contains($0.path) }, "Repository ignore and info/exclude rules hide untracked content")
        expect(working.changedFiles.contains { $0.path == "executable.sh" && $0.kind == .modified && $0.right?.mode == "100755" }, "Working-tree executable bit changes remain visible")
        let workingEntry = working.rightTree.first { $0.path == "mixed.txt" }!
        expect(GitBlobText.decode(try repo.readContent(entry: workingEntry, in: working.rightSnapshot)).map { Data($0.utf8) } == Data("working 👩🏽‍💻 e\u{301}\r\n".utf8), "Working detail preserves raw Unicode and CRLF")
        let linkEntry = working.rightTree.first { $0.path == "symbolic" }!
        expect(GitBlobText.decode(try repo.readContent(entry: linkEntry, in: working.rightSnapshot)) == "mixed.txt", "Working symlink reads link bytes without following target")
        try git(["config", "core.filemode", "false"], at: root)
        let fileModeIgnored = try repo.compareSources(left: .index, right: .workingTree)
        expect(fileModeIgnored.files.contains { $0.path == "executable.sh" && $0.kind == .unchanged }, "core.filemode=false preserves tracked index modes")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("new.txt").path)
        let newModeIgnored = try repo.compareSources(left: .index, right: .workingTree)
        expect(newModeIgnored.rightTree.contains { $0.path == "new.txt" && $0.mode == "100644" }, "core.filemode=false treats new files as nonexecutable")
        try git(["config", "core.filemode", "true"], at: root)
        let trackedOnly = try repo.compareSources(left: .index, right: .workingTree, includeUntracked: false)
        expect(!trackedOnly.rightTree.contains { ["new.txt", "symbolic", "new-name.txt"].contains($0.path) }, "Untracked files can be excluded")
        expect(trackedOnly.rightTree.contains { $0.path == "intent.txt" }, "Intent-to-add stays tracked even when untracked files are hidden")
        let commitsOnly = try repo.compareSources(left: .commit("HEAD"), right: .commit("HEAD"))
        expect(commitsOnly.changedFiles.isEmpty && !commitsOnly.exactRenamesOnly, "New source API preserves commit-only comparison")
        expectError("Merge-base mode rejects index or working sources") { _ = try repo.compareSources(left: .index, right: .workingTree, options: .init(useMergeBase: true)) }
        expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore && Data(contentsOf: root.appendingPathComponent(".git/HEAD")) == headBefore, "Local snapshot capture leaves index and HEAD byte-identical")
        expect(try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent(".git/objects").path).sorted() == objectsBefore, "Working hashes do not write Git objects")
        try write("working changed again\n", "mixed.txt", root)
        expectError("Changing working file invalidates previously captured detail") { _ = try repo.readContent(entry: workingEntry, in: working.rightSnapshot) }
        expect(GitBlobText.decode(try repo.readContent(entry: stageEntry, in: staged.rightSnapshot)) == "staged\r\n", "Old staged snapshot remains immutable after working changes")
        try git(["add", "mixed.txt"], at: root)
        expect(GitBlobText.decode(try repo.readContent(entry: stageEntry, in: staged.rightSnapshot)) == "staged\r\n", "Old staged snapshot remains immutable after a new git add")
        let refresh = try repo.compareSources(left: .commit("HEAD"), right: .index)
        expect(refresh.rightSnapshot.identity != staged.rightSnapshot.identity, "Refreshing index creates a new content identity")
        // Missing skip-worktree paths represent sparse checkout, not deleted files.
        try git(["update-index", "--skip-worktree", "keep.txt"], at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("keep.txt"))
        let sparse = try repo.compareSources(left: .index, right: .workingTree, includeUntracked: false)
        let sparseEntry = sparse.rightTree.first { $0.path == "keep.txt" }!
        expect(sparse.files.contains { $0.path == "keep.txt" && $0.kind == .unchanged }, "Sparse missing files retain the pinned index blob")
        expect(GitBlobText.decode(try repo.readContent(entry: sparseEntry, in: sparse.rightSnapshot)) == "keep\n", "Sparse file detail reads pinned index content")
        // A clean filter configured in the repository must never execute during raw capture.
        let marker = root.appendingPathComponent("filter-must-not-run")
        let script = root.appendingPathComponent("filter.sh")
        try write("#!/bin/sh\ntouch '\(marker.path)'\ncat\n", script.lastPathComponent, root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try git(["config", "filter.fixture.clean", script.path], at: root)
        try git(["config", "filter.fixture.smudge", script.path], at: root)
        try write("*.txt filter=fixture\n", ".gitattributes", root)
        _ = try repo.compareSources(left: .index, right: .workingTree)
        expect(!FileManager.default.fileExists(atPath: marker.path), "Working capture executes no clean or smudge filters")
        // Index stages 1/2 must fail explicitly, rather than selecting an arbitrary side.
        let blob = stageEntry.objectID
        try git(["update-index", "--index-info"], at: root, input: Data(("0 " + String(repeating: "0", count: 40) + "\tconflict.txt\n100644 " + blob + " 1\tconflict.txt\n100644 " + blob + " 2\tconflict.txt\n").utf8))
        expectError("Unmerged index stages are not silently guessed") { _ = try repo.compareSources(left: .commit("HEAD"), right: .index) }

        let emptyRoot = parent.appendingPathComponent("unborn-sources")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main", "--template="], at: emptyRoot)
        try write("first staged\n", "first.txt", emptyRoot)
        try git(["add", "first.txt"], at: emptyRoot)
        let emptyRepo = try GitRepository.open(emptyRoot)
        let firstStage = try emptyRepo.compareSources(left: .commit("HEAD"), right: .index)
        expect(firstStage.leftSnapshot.isEmptyBaseline && firstStage.leftSnapshot.commit == nil && firstStage.leftTree.isEmpty && firstStage.changedFiles.count == 1, "Unborn HEAD is an explicit empty baseline against index")
        try write("first working\n", "first.txt", emptyRoot)
        let firstWork = try emptyRepo.compareSources(left: .commit("HEAD"), right: .workingTree)
        expect(firstWork.leftSnapshot.isEmptyBaseline && firstWork.rightTree.count == 1, "Unborn repository working content compares without a commit")
        expectError("Unknown revision never becomes an empty baseline") { _ = try emptyRepo.compareSources(left: .commit("not-a-revision"), right: .workingTree) }
        let bare = try GitRepository.open(parent.appendingPathComponent("bare.git"))
        expectError("Bare repository rejects local sources") { _ = try bare.compareSources(left: .commit("HEAD"), right: .index) }
        // Nonblocking file access must reject FIFOs rather than waiting for a writer.
        let fifo = emptyRoot.appendingPathComponent("first.txt")
        try FileManager.default.removeItem(at: fifo)
        guard mkfifo(fifo.path, 0o600) == 0 else { throw GitError.commandFailed }
        expectError("Special working files fail promptly") { _ = try emptyRepo.compareSources(left: .index, right: .workingTree) }
        try FileManager.default.removeItem(at: fifo)
        try write("first working\n", "first.txt", emptyRoot)
        // Replacing a tracked parent directory with a symlink cannot redirect reads.
        let folder = emptyRoot.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("inside\n", "folder/inside.txt", emptyRoot)
        try git(["add", "folder/inside.txt"], at: emptyRoot)
        let elsewhere = parent.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try write("outside\n", "inside.txt", elsewhere)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        expectError("Symlink parent replacement cannot redirect working reads") { _ = try emptyRepo.compareSources(left: .index, right: .workingTree, includeUntracked: false) }

        let shaRoot = parent.appendingPathComponent("sha256-sources")
        try FileManager.default.createDirectory(at: shaRoot, withIntermediateDirectories: true)
        try git(["init", "-q", "--object-format=sha256", "--initial-branch=main", "--template="], at: shaRoot)
        try write("SHA-256 Git blob\n", "file.txt", shaRoot)
        try git(["add", "file.txt"], at: shaRoot)
        let shaRepo = try GitRepository.open(shaRoot)
        let sha = try shaRepo.compareSources(left: .index, right: .workingTree)
        expect(sha.leftTree.first?.objectID.utf8.count == 64 && sha.changedFiles.isEmpty, "SHA-256 repositories use matching native Git blob identities")
        let shaBaseline = try shaRepo.compareSources(left: .commit("HEAD"), right: .index)
        expect(shaBaseline.leftSnapshot.isEmptyBaseline && shaBaseline.changedFiles.count == 1, "SHA-256 unborn HEAD uses the correct empty tree")
        try git(["commit", "-qm", "SHA baseline"], at: shaRoot)
        let pinned = value(try git(["rev-parse", "HEAD"], at: shaRoot))
        try git(["update-index", "--add", "--cacheinfo", "160000," + pinned + ",vendor/submodule"], at: shaRoot)
        let gitlink = try shaRepo.compareSources(left: .index, right: .workingTree)
        expect(gitlink.files.contains { $0.path == "vendor/submodule" && $0.kind == .unchanged && $0.right?.kind == .submodule }, "Local sources keep submodule pointers without opening missing directories")
    }
    final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedBytes: UInt64 = 0
        private var storedFiles = 0
        func receive(_ value: GitScanProgress) {
            lock.lock(); defer { lock.unlock() }
            storedBytes = value.bytesRead; storedFiles = value.filesScanned
        }
        var bytes: UInt64 { lock.lock(); defer { lock.unlock() }; return storedBytes }
        var files: Int { lock.lock(); defer { lock.unlock() }; return storedFiles }
    }
    static func largeSourceChecks(root parent: URL) throws {
        let root = parent.appendingPathComponent("large-streaming-sources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main", "--template="], at: root)
        let sizes: [UInt64] = [600 * 1024 * 1024 + 17, 600 * 1024 * 1024 + 31]
        for (index, size) in sizes.enumerated() {
            let file = root.appendingPathComponent("large-\(index).bin")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw GitError.commandFailed }
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: size)
            try handle.seek(toOffset: size - 1)
            try handle.write(contentsOf: Data([UInt8(0xA5 + index)]))
            try handle.close()
            var stat = Darwin.stat()
            guard lstat(file.path, &stat) == 0 else { throw GitError.commandFailed }
            expect(UInt64(stat.st_blocks) * 512 < 1024 * 1024, "Large scan fixture uses sparse allocation for file \(index)")
        }
        let repo = try GitRepository.open(root), metrics = ProgressRecorder()
        let objectFiles = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent(".git/objects").path).sorted()
        let started = ProcessInfo.processInfo.systemUptime
        let comparison = try repo.compareSources(left: .index, right: .workingTree, progress: { metrics.receive($0) })
        let total = sizes.reduce(0, +)
        expect(comparison.rightTree.count == 2 && comparison.changedFiles.count == 2, "Working scan accepts files above 256 MiB and total above 1 GiB")
        expect(metrics.bytes == total && metrics.files == 2, "Progress proves every large-file byte was read: \(total) bytes")
        for entry in comparison.rightTree {
            let expected = value(try git(["hash-object", "--no-filters", "--", entry.path], at: root))
            expect(expected == entry.objectID, "Large streaming hash matches native Git through the final byte: " + entry.path)
        }
        expect(try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent(".git/objects").path).sorted() == objectFiles, "Large scans do not store generated Git objects")
        expectError("Large scan does not remove the separate detail-preview byte limit") {
            _ = try repo.readContent(entry: comparison.rightTree[0], in: comparison.rightSnapshot, maximumBytes: 2 * 1024 * 1024)
        }
        print(String(format: "Large scan measured %.2f seconds; %.2f GiB actually read.", ProcessInfo.processInfo.systemUptime - started, Double(metrics.bytes) / Double(1024 * 1024 * 1024)))
        let cancelledMetrics = ProgressRecorder(), cancelAt: UInt64 = 300 * 1024 * 1024
        do {
            _ = try repo.compareSources(left: .index, right: .workingTree,
                isCancelled: { cancelledMetrics.bytes >= cancelAt }, progress: { cancelledMetrics.receive($0) })
            fatalError("Large scan did not cancel")
        } catch GitError.cancelled { }
        expect(cancelledMetrics.bytes >= cancelAt && cancelledMetrics.bytes < sizes[0], "Cancellation interrupts a large file after actual streamed bytes: \(cancelledMetrics.bytes)")

        let manyRoot = parent.appendingPathComponent("many-streaming-sources")
        try FileManager.default.createDirectory(at: manyRoot, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main", "--template="], at: manyRoot)
        let emptyBlob = value(try git(["hash-object", "-w", "--stdin"], at: manyRoot, input: Data()))
        let count = 70_001, padding = String(repeating: "x", count: 233)
        var treeInput = Data(), indexInput = Data(), nameBytes = 0
        for index in 0..<count {
            let path = String(format: "f%06d-", index) + padding + ".txt"
            nameBytes += path.utf8.count + 1
            treeInput.append(Data(("100644 blob " + emptyBlob + "\t" + path + "\0").utf8))
            indexInput.append(Data(("100644 " + emptyBlob + "\t" + path + "\0").utf8))
        }
        expect(nameBytes > GitProcess.maximumOutput, "Fixture paths alone exceed the previous 16 MiB stdout cap")
        let tree = value(try git(["mktree", "-z"], at: manyRoot, input: treeInput))
        let commit = value(try git(["commit-tree", tree], at: manyRoot, input: Data("Many file fixture\n".utf8)))
        try git(["update-ref", "refs/heads/main", commit], at: manyRoot)
        try git(["update-index", "-z", "--index-info"], at: manyRoot, input: indexInput)
        treeInput = Data(); indexInput = Data()
        let manyRepo = try GitRepository.open(manyRoot), manyStarted = ProcessInfo.processInfo.systemUptime
        let commitTree = try manyRepo.tree(objectID: commit)
        expect(commitTree.count == count, "Commit tree streams more than 50,000 files and 16 MiB of output")
        let indexSnapshot = try manyRepo.compareSources(left: .commit("HEAD"), right: .index)
        expect(indexSnapshot.rightTree.count == count && indexSnapshot.changedFiles.isEmpty, "Stage-0 and intent-to-add catalog commands stream the complete large index")
        let workingSnapshot = try manyRepo.compareSources(left: .index, right: .workingTree, includeUntracked: false)
        expect(workingSnapshot.leftTree.count == count && workingSnapshot.changedFiles.count == count, "Working candidate enumeration has no hidden 50,000-file rejection")
        let emptyTree = value(try git(["mktree"], at: manyRoot, input: Data()))
        let emptyCommit = value(try git(["commit-tree", emptyTree], at: manyRoot, input: Data("Empty fixture\n".utf8)))
        let fullDiff = try manyRepo.compare(left: emptyCommit, right: commit)
        expect(fullDiff.changedFiles.count == count, "Rename/raw-diff enumeration streams a result larger than 16 MiB")
        var streamed = 0
        do {
            try GitProcess.streamRecords(at: manyRoot, arguments: ["ls-tree", "-z", "--name-only", commit], isCancelled: { streamed >= 1234 }) { _ in streamed += 1 }
            fatalError("Catalog stream did not cancel")
        } catch GitError.cancelled { }
        expect(streamed == 1234, "Catalog cancellation stops between records without buffering the remaining tree")
        expectError("Oversized individual catalog records are still rejected") {
            try GitProcess.streamRecords(at: manyRoot, arguments: ["ls-tree", "-z", "--name-only", commit], maximumRecordBytes: 32) { _ in }
        }
        print(String(format: "Large catalog measured %.2f seconds; %d entries; %d raw pathname bytes.", ProcessInfo.processInfo.systemUptime - manyStarted, count, nameBytes))
    }
    static func remoteChecks() throws {
        expect(try GitRemote.parse("https://github.com/owner/repo/").url == "https://github.com/owner/repo.git", "GitHub repository page normalizes to clone URL")
        expect(try GitRemote.parse("https://gitlab.com/team/subgroup/repo").url == "https://gitlab.com/team/subgroup/repo.git", "Nested GitLab repository page normalizes")
        expect(try GitRemote.parse("https://gitee.com/owner/repo").url.hasSuffix("repo.git"), "Gitee repository page normalizes")
        expect(try GitRemote.parse("ssh://git@example.com:2222/team/repo.git").url.contains(":2222/"), "Self-hosted SSH custom port accepted")
        expect(try GitRemote.parse("git@example.com:team/repo.git").url == "git@example.com:team/repo.git", "SCP-style SSH accepted without a shell")
        expect(try GitRemote.parse("https://forge.example.com/a/b").url == "https://forge.example.com/a/b", "Self-hosted HTTPS clone paths preserved")
        for input in ["--upload-pack=evil", "file:///tmp/repo", "ext::sh -c evil", "http://example.com/repo", "https://token@example.com/repo", "https://u:p@example.com/repo", "ssh://git:secret@example.com/repo", "https://github.com/u/r/tree/main", "https://gitlab.com/u/r/-/tree/main", "https://example.com/r?token=secret", "https://example.com/r#fragment", "git@example.com:-option", "git@example.com:../repo", "-oProxyCommand=evil:repo", "https://example.com/%0Aevil"] {
            expectError("Reject unsafe/ambiguous remote: " + input) { _ = try GitRemote.parse(input) }
        }
    }
}
