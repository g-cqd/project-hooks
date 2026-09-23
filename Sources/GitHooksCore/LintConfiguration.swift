import Foundation
import Yams

/// The files that decide what a linter reports, besides the files it lints.
public enum LintConfiguration {
    /// Names of the files that configure a linter, wherever they are in the repository. `.swift-version` counts
    /// because SwiftFormat reads it to choose its Swift version.
    public static let fileNames: Set<String> = Set(
        (LinterDiscovery.configCandidates + [".swift-version"]).map { URL(fileURLWithPath: $0).lastPathComponent },
    )

    /// The parent and child configurations that SwiftLint reads, as written.
    ///
    /// A reference can be relative to the configuration's directory, absolute, or a remote URL.
    /// - Returns: The referenced paths, or none when `yaml` does not parse as a SwiftLint configuration.
    public static func swiftLintReferences(in yaml: String) -> [String] {
        guard let references = try? YAMLDecoder().decode(SwiftLintReferences.self, from: yaml) else { return [] }
        return [references.parentConfig, references.childConfig]
            .compactMap(\.self)
    }

    private struct SwiftLintReferences: Decodable {
        let parentConfig: String?
        let childConfig: String?

        enum CodingKeys: String, CodingKey {
            case parentConfig = "parent_config"
            case childConfig = "child_config"
        }
    }
}
