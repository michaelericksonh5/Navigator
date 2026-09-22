import Foundation
import AppKit

// The app's own extraction, so the harness sees exactly what the parser sees.
func localText(_ url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "docx", "rtf":
        let type: NSAttributedString.DocumentType =
            url.pathExtension.lowercased() == "rtf" ? .rtf : .officeOpenXML
        return (try? NSAttributedString(url: url, options: [.documentType: type],
                                        documentAttributes: nil))?.string
    default: return try? String(contentsOf: url, encoding: .utf8)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for path in CommandLine.arguments.dropFirst(2) {
    let u = URL(fileURLWithPath: path)
    guard let t = localText(u) else { FileHandle.standardError.write("FAIL \(path)\n".data(using: .utf8)!); continue }
    let name = u.deletingPathExtension().lastPathComponent + ".txt"
    try? t.write(to: out.appendingPathComponent(name), atomically: true, encoding: .utf8)
    print("\(t.count)\t\(name)")
}
