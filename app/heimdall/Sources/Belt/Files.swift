import Foundation

// Files in and out of a task (2026-10-26). Same layout as the belt's
// `conveyor add --attach`: inputs are copied to attachments/<task-id>/ and
// listed under "## Attachments" by full path; every task gets an empty
// outputs/<task-id>/ named on an "outputs:" line under "## Outputs", which
// the belt's conveyor-check hands to checklist commands as $CONVEYOR_OUTPUTS.
// The app writes these sections itself only where the belt cannot: a remote
// belt (its scripts may predate --attach) or an older local one.
enum TaskFiles {
    /// Per file. Matches the belt's CONVEYOR_ATTACH_MAX_MB default.
    static let maxMB = 100

    /// nil when every file can be attached, else a sentence for the person.
    static func problem(with files: [URL]) -> String? {
        for f in files {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: f.path, isDirectory: &dir) else {
                return "\(f.lastPathComponent) is no longer there."
            }
            if dir.boolValue { return "\(f.lastPathComponent) is a folder. Attach files, or zip the folder first." }
            let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
            if size > maxMB * 1024 * 1024 {
                return "\(f.lastPathComponent) is \(size / 1_048_576) MB. The limit is \(maxMB) MB per file."
            }
        }
        return nil
    }

    /// Names kept as they are; a repeat becomes "name (2).ext", as the belt does.
    static func uniqueNames(_ files: [URL]) -> [String] {
        var used = Set<String>()
        return files.map { f in
            let name = f.lastPathComponent
            var candidate = name
            var n = 2
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            while used.contains(candidate) {
                candidate = ext.isEmpty || stem.isEmpty ? "\(name) (\(n))" : "\(stem) (\(n)).\(ext)"
                n += 1
            }
            used.insert(candidate)
            return candidate
        }
    }

    static func newID(title: String) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let slug = title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(stamp.string(from: Date()))-\(String(slug.prefix(30)))-\(UUID().uuidString.prefix(4).lowercased())"
    }

    /// The text the belt's conveyor-add writes, so both read the same.
    static func sections(attachments: [String], outputs: String) -> String {
        var s = ""
        if !attachments.isEmpty {
            s += "## Attachments\n\nInput files for this task (copies; the originals are untouched). Read them as needed. Do not modify, move or delete them.\n\n"
            s += attachments.map { "- `\($0)`" }.joined(separator: "\n") + "\n\n"
        }
        s += "## Outputs\n\noutputs: \(outputs)\n\nSave every file this task produces in that folder (it already exists). Checklist commands can refer to it as \"$CONVEYOR_OUTPUTS\"."
        return s
    }

    /// What a task file lists: attachment paths (the "## Attachments" list,
    /// plus the older "Images (...)" list) and its outputs folder.
    static func parse(_ text: String) -> (attachments: [String], outputs: String?) {
        var atts: [String] = []
        var outputs: String?
        var inList = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if outputs == nil, line.hasPrefix("outputs: /") {
                outputs = String(line.dropFirst("outputs: ".count))
            }
            if line.hasPrefix("## ") { inList = line == "## Attachments"; continue }
            if line.hasPrefix("Images (") { inList = true; continue }
            if inList, line.hasPrefix("- /") || line.hasPrefix("- `/") {
                var p = String(line.dropFirst(2))
                if p.hasPrefix("`") && p.hasSuffix("`") && p.count > 1 { p = String(p.dropFirst().dropLast()) }
                if !atts.contains(p) { atts.append(p) }
            }
        }
        return (atts, outputs)
    }

    /// Every file under a local folder, relative paths, sorted. Hidden files skipped.
    static func list(_ dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        let base = dir.standardizedFileURL.path
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let p = u.standardizedFileURL.path
            out.append(p.hasPrefix(base + "/") ? String(p.dropFirst(base.count + 1)) : u.lastPathComponent)
        }
        return out.sorted()
    }
}
