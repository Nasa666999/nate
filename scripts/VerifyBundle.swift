import CryptoKit
import Foundation

struct ResourceEntry: Decodable {
    var path: String
    var sha256: String
}

struct ResourceManifest: Decodable {
    var product: String
    var format: Int
    var files: [ResourceEntry]
}

let bundle = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist/Nate.app")
let resources = bundle.appendingPathComponent("Contents/Resources")
let manifest = try JSONDecoder().decode(ResourceManifest.self, from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
guard manifest.format == 1 && manifest.product == "Nate" else {
    throw NSError(domain: "Nate.Bundle", code: 1)
}
for file in manifest.files {
    guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
        throw NSError(domain: "Nate.Bundle", code: 2)
    }
    let data = try Data(contentsOf: resources.appendingPathComponent(file.path))
    let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard checksum == file.sha256 else {
        throw NSError(domain: "Nate.Bundle", code: 3, userInfo: [NSLocalizedDescriptionKey: "资源校验失败：" + file.path])
    }
}
for name in ["languages", "udl", "completion", "function-list", "themes", "keymaps", "defaults", "licenses"] {
    guard FileManager.default.fileExists(atPath: resources.appendingPathComponent(name).path) else {
        throw NSError(domain: "Nate.Bundle", code: 4, userInfo: [NSLocalizedDescriptionKey: "资源目录缺失：" + name])
    }
}
guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
    let executable = info["CFBundleExecutable"] as? String,
    info["LSMinimumSystemVersion"] as? String == "13.0",
    FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/" + executable).path),
    FileManager.default.fileExists(atPath: resources.appendingPathComponent("Nate.icns").path)
else {
    throw NSError(domain: "Nate.Bundle", code: 5)
}
print("Nate.app: \(manifest.files.count) resources verified")
