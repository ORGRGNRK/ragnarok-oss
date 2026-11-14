import AppKit

/// Where `create_note` and `append_to_note` write. The app uses Notes.app; tests can swap in a fake.
@MainActor
protocol NoteStore {
    /// Creates a note and returns its identifier, which `append(text:to:)` accepts.
    func create(text: String, folder: String?) throws -> String
    /// Appends to a note given its identifier (from `create`) or its name.
    func append(text: String, to note: String) throws
}

/// Writes to Notes.app via AppleScript.
/// The first time this runs, macOS asks permission for CLI Tools to control Notes.
struct NotesWriter: NoteStore {
    func create(text: String, folder: String?) throws -> String {
        let location = folder.map { " at folder \(quoted($0))" } ?? ""
        return try run("""
        tell application "Notes"
            set theNote to make new note\(location) with properties {body:\(quoted(html(text)))}
            return id of theNote
        end tell
        """)
    }

    func append(text: String, to note: String) throws {
        // Notes IDs look like x-coredata://…/ICNote/p123; anything else is treated as a note name.
        let reference = note.hasPrefix("x-coredata://") ? "note id \(quoted(note))" : "first note whose name is \(quoted(note))"
        _ = try run("""
        tell application "Notes"
            set theNote to \(reference)
            set body of theNote to (body of theNote) & \(quoted(html(text)))
        end tell
        """)
    }

    private func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw PipelineError.notesFailed("could not compile the AppleScript.")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            throw PipelineError.notesFailed(message)
        }
        return result.stringValue ?? ""
    }

    /// Notes stores bodies as HTML; the first line becomes the note title.
    /// Lines go in as monospaced divs so man-page excerpts keep their alignment.
    private func html(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let escaped = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: " ", with: "&nbsp;")
            let content = escaped.isEmpty ? "<br>" : escaped
            return index == 0 ? "<div><b>\(content)</b></div>" : "<div><tt>\(content)</tt></div>"
        }.joined()
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
