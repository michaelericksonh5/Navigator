import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = (try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
var failures = 0
for f in files {
    let t = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
    let r = GDDSymbolSetRules.parseWithProblems(t)
    print("──── \(f.deletingPathExtension().lastPathComponent)")
    if r.symbols.isEmpty { print("   ✗ NO SYMBOLS PARSED"); failures += 1 }
    else {
        print("   \(r.symbols.count) symbols")
        for s in r.symbols {
            let n = s.note.isEmpty ? "" : "   “\(s.note.prefix(70))”"
            print("     \(s.code.padding(toLength: 5, withPad: " ", startingAt: 0)) \(s.role.label.padding(toLength: 14, withPad: " ", startingAt: 0))\(n)")
        }
    }
    if !r.problems.isEmpty { print("   problems: \(r.problems.count)") }
}
print("\n\(files.count - failures)/\(files.count) parsed")
