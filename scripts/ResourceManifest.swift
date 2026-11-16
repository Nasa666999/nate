import CryptoKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "resources")
var files: [[String: String]] = []
if let enumerator = FileManager.default.enumerator(
    at: directory,
    includingPropertiesForKeys: [.isRegularFileKey]
) {
    for case let url as URL in enumerator where url.lastPathComponent != "manifest.json" {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let data = try Data(contentsOf: url)
            files.append([
                "path": String(url.path.dropFirst(directory.path.count + 1)),
                "sha256": SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined(),
            ])
        }
    }
}
let manifest: [String: Any] = [
    "product": "Nate", "format": 1,
    "files": files.sorted {
        ($0["path"] ?? "") < ($1["path"] ?? "")
    },
]
let output = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try output.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
