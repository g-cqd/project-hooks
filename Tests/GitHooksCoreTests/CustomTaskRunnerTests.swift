import GitHooksCore
import Testing

struct FileGlobMatcherTests {
    @Test
    func `matches extension glob`() {
        #expect(FileGlobMatcher.matches("Resources/en.lproj/Localizable.strings", patterns: ["*.strings"]))
        #expect(FileGlobMatcher.matches("Plurals.stringsdict", patterns: ["*.stringsdict"]))
    }

    @Test
    func `matches prefix glob`() {
        #expect(FileGlobMatcher.matches("Generated/Strings.swift", patterns: ["Generated/*"]))
        #expect(FileGlobMatcher.matches("Generated/deep/File.swift", patterns: ["Generated/*"]))
    }

    @Test
    func `matches exact`() {
        #expect(FileGlobMatcher.matches("Package.swift", patterns: ["Package.swift"]))
    }

    @Test
    func `does not match unrelated file`() {
        #expect(!FileGlobMatcher.matches("Sources/App.swift", patterns: ["*.strings"]))
        #expect(!FileGlobMatcher.matches("README.md", patterns: ["Generated/*"]))
    }

    @Test
    func `matches lproj wildcard`() {
        #expect(FileGlobMatcher.matches("fr.lproj/Main.storyboard", patterns: ["*.lproj/*"]))
    }

    @Test
    func `filter returns matching files`() {
        let files = [
            "Sources/App.swift",
            "Resources/en.lproj/Localizable.strings",
            "README.md",
            "Plurals.stringsdict",
        ]
        let result = FileGlobMatcher.filter(files, matching: ["*.strings", "*.stringsdict"])
        #expect(
            result == [
                "Resources/en.lproj/Localizable.strings",
                "Plurals.stringsdict",
            ])
    }

    @Test
    func `filter returns empty for no matches`() {
        let files = ["Sources/App.swift", "README.md"]
        #expect(FileGlobMatcher.filter(files, matching: ["*.strings"]).isEmpty)
    }
}

struct TaskDependencyResolverTests {
    @Test
    func `resolves tasks with no dependencies`() {
        let tasks = [
            HooksConfig.CustomTask(name: "A", run: "echo A"),
            HooksConfig.CustomTask(name: "B", run: "echo B"),
        ]
        let resolved = TaskDependencyResolver.resolve(tasks)
        #expect(resolved?.count == 2)
    }

    @Test
    func `resolves linear dependency chain`() {
        let tasks = [
            HooksConfig.CustomTask(name: "B", run: "echo B", after: "A"),
            HooksConfig.CustomTask(name: "A", run: "echo A"),
        ]
        let resolved = TaskDependencyResolver.resolve(tasks)
        #expect(resolved?.map(\.name) == ["A", "B"])
    }

    @Test
    func `detects circular dependency`() {
        let tasks = [
            HooksConfig.CustomTask(name: "A", run: "echo A", after: "B"),
            HooksConfig.CustomTask(name: "B", run: "echo B", after: "A"),
        ]
        #expect(TaskDependencyResolver.resolve(tasks) == nil)
    }

    @Test
    func `resolves empty list`() {
        #expect(TaskDependencyResolver.resolve([])?.isEmpty == true)
    }

    @Test
    func `resolves multiple dependencies`() {
        let tasks = [
            HooksConfig.CustomTask(name: "C", run: "echo C", after: "B"),
            HooksConfig.CustomTask(name: "A", run: "echo A"),
            HooksConfig.CustomTask(name: "B", run: "echo B", after: "A"),
        ]
        let resolved = TaskDependencyResolver.resolve(tasks)
        #expect(resolved?.map(\.name) == ["A", "B", "C"])
    }

    @Test
    func `returns nil for dependency on non existent task`() {
        let tasks = [
            HooksConfig.CustomTask(name: "B", run: "echo B", after: "NonExistent")
        ]
        // Missing dependency should return nil (same as unresolvable)
        #expect(TaskDependencyResolver.resolve(tasks) == nil)
    }
}
