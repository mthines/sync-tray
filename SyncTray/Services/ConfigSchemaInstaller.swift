import Foundation

/// Copies the committed JSON Schemas bundled with the app
/// (`SyncTray/Resources/Schemas/*.schema.json`) into
/// `~/.config/synctray/schema/`, so editors/agents that hand-edit
/// `{shortId}.profile.json` or `settings.json` can validate against the
/// `$schema` each written file references.
///
/// The bundled copy is the source of truth and is kept in lockstep with
/// `SyncProfile.CodingKeys` by `scripts/check-schema-in-sync.sh` (run locally
/// and in CI). Installing simply copies it out — it is not generated from the
/// model at runtime.
enum ConfigSchemaInstaller {
    static let schemaResourceFilenames = ["profile.schema.json", "settings.schema.json"]

    static var defaultBase: String {
        "\(NSHomeDirectory())/.config/synctray"
    }

    static func schemaDirectory(base: String = defaultBase) -> String {
        "\(base)/schema"
    }

    /// Copy the bundled schema resources into `base/schema/`, overwriting any
    /// existing copy so an app update always ships the current schema.
    /// - Returns: the list of installed file paths (empty on total failure).
    @discardableResult
    static func writeSchemas(base: String = defaultBase) -> [String] {
        let destDir = schemaDirectory(base: base)
        guard (try? FileManager.default.createDirectory(
            atPath: destDir, withIntermediateDirectories: true)) != nil else {
            return []
        }

        var installed: [String] = []
        for filename in schemaResourceFilenames {
            // Bundle.url(forResource:withExtension:) splits on the LAST dot, so
            // "profile.schema.json" -> resource "profile.schema", extension "json".
            let resourceName = (filename as NSString).deletingPathExtension
            guard let sourceURL = Bundle.main.url(forResource: resourceName, withExtension: "json"),
                  let data = try? Data(contentsOf: sourceURL) else { continue }

            let destPath = "\(destDir)/\(filename)"
            if (try? data.write(to: URL(fileURLWithPath: destPath), options: .atomic)) != nil {
                installed.append(destPath)
            }
        }
        return installed
    }
}
