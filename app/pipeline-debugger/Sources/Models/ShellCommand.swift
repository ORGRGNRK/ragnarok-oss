import Foundation

public struct ShellCommand: Identifiable, Hashable, Equatable {
    public let id: String
    public let ts: String
    public let cmd: String
    public let cwd: String
    public let exitCode: Int
    public let src: String

    public var isFailed: Bool { exitCode != 0 }

    public var formattedTime: String {
        guard !ts.isEmpty else { return "" }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = isoFormatter.date(from: ts)
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: ts)
        }
        guard let d = date else { return ts }
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: d)
    }

    public init(ts: String, cmd: String, cwd: String, exitCode: Int, src: String) {
        self.ts = ts
        self.cmd = cmd
        self.cwd = cwd
        self.exitCode = exitCode
        self.src = src
        self.id = "\(ts)_\(exitCode)_\(cmd.hashValue)_\(cwd)"
    }

    public static func == (lhs: ShellCommand, rhs: ShellCommand) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func fromJSONLine(_ line: String) -> ShellCommand? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else {
            return nil
        }

        let ts = json["ts"] as? String ?? ""
        let cwd = json["cwd"] as? String ?? "~"
        let exitCode = json["exit"] as? Int ?? 0
        let src = json["src"] as? String ?? "shell"

        return ShellCommand(ts: ts, cmd: cmd, cwd: cwd, exitCode: exitCode, src: src)
    }
}
