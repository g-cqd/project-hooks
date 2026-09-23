import Foundation
import Testing

/// Review finding PH-7: every push rebuilt from a cold, per-process build directory, and nothing removed it.
struct BuildReuseTests {
    @Test
    func `a module's build directory survives from one push to the next`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let log = repository.scratch.appendingPathComponent("swift-runs")
        // Records the source and build directories, and whether the build directory kept the previous run's output.
        try repository.installTool(
            "swift",
            script: """
                #!/bin/sh
                [ "$1" = "--version" ] && echo "Swift version 6.4 (fake)" && exit 0
                package=""; scratch=""; previous=""
                for argument in "$@"; do
                  [ "$previous" = "--package-path" ] && package="$argument"
                  [ "$previous" = "--scratch-path" ] && scratch="$argument"
                  previous="$argument"
                done
                if [ -f "$scratch/product" ]; then kept=kept; else kept=cold; fi
                echo "$package|$scratch|$kept" >> '\(log.path)'
                mkdir -p "$scratch" && touch "$scratch/product"
                """)
        try repository.write("Package.swift", "// swift-tools-version: 6.0\n")
        try repository.write("Sources/App.swift", "let value = 1\n")
        let first = try repository.commitAll("Add the app")
        try repository.trust()

        let firstPush = try repository.runPrePush(localSHA: first)
        try repository.write("Sources/App.swift", "let value = 2\n")
        let second = try repository.commitAll("Change the app")
        let secondPush = try repository.runPrePush(localSHA: second, remoteSHA: first)

        let runs = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "|") }
        #expect(firstPush.exitCode == 0 && secondPush.exitCode == 0, "\(secondPush.output)")
        #expect(runs.count == 2)
        #expect(runs.map(\.first) == [runs.first?.first, runs.first?.first], "same source path every push")
        #expect(runs.map { $0.dropFirst().first } == [runs.first?.dropFirst().first, runs.first?.dropFirst().first])
        #expect(runs.first?.dropFirst().first?.hasPrefix(repository.cacheDirectory.path) == true)
        #expect(runs.map(\.last) == ["cold", "kept"])
    }
}
