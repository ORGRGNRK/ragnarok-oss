import Foundation

/// Lines from a file handle, one dispatch source per handle.
///
/// Foundation runs every file-handle byte stream on one process-wide serial
/// queue (`AsyncBytesIOActorQueue`). A long-lived quiet pipe — the Room `ssh`
/// watch — parks on that queue, and a chat curl that has already finished never
/// gets its lines. This reader waits in a per-handle dispatch source instead,
/// so a quiet pipe does not block any other pipe.
///
/// Partial lines stay buffered until a newline. A multi-byte UTF-8 sequence
/// split across reads is decoded only once the line (or EOF) is complete.
/// The readability handler is cleared at EOF and when the stream ends.
enum FileHandleLines {
    /// `opened` runs after the read source is installed, before any line is delivered.
    static func lines(from handle: FileHandle, opened: (@Sendable () -> Void)? = nil) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let buffer = Buffer()
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    if let tail = buffer.finish() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in buffer.append(chunk) { continuation.yield(line) }
            }
            continuation.onTermination = { _ in
                // Clearing from inside the handler can wait on the handler's own
                // queue. Hop off so cancel during a callback cannot deadlock.
                DispatchQueue.global(qos: .utility).async {
                    handle.readabilityHandler = nil
                }
            }
            opened?()
        }
    }

    /// Bytes held across reads. Newline splitting matches `AsyncLineSequence`:
    /// LF, CR LF, and a bare CR. A CR at the end of a chunk is kept until the
    /// next byte shows whether it is part of CR LF.
    struct FileHandleLineBuffer {
        private var raw = Data()

        mutating func append(_ chunk: Data) -> [String] {
            guard !chunk.isEmpty else { return [] }
            raw.append(chunk)
            var lines: [String] = []
            var start = 0
            var i = 0
            while i < raw.count {
                let b = raw[i]
                if b == 0x0A {
                    let end = (i > start && raw[i - 1] == 0x0D) ? i - 1 : i
                    lines.append(Self.decode(raw.subdata(in: start..<end)))
                    i += 1
                    start = i
                } else if b == 0x0D {
                    if i + 1 >= raw.count { break }
                    if raw[i + 1] == 0x0A {
                        lines.append(Self.decode(raw.subdata(in: start..<i)))
                        i += 2
                    } else {
                        lines.append(Self.decode(raw.subdata(in: start..<i)))
                        i += 1
                    }
                    start = i
                } else {
                    i += 1
                }
            }
            if start > 0 { raw.removeSubrange(0..<start) }
            return lines
        }

        /// The unfinished tail at EOF, including a line that never got a newline.
        /// Nil when the handle ended on a newline (no extra empty line).
        mutating func finish() -> String? {
            if raw.isEmpty { return nil }
            if raw.last == 0x0D { raw.removeLast() }
            let line = Self.decode(raw)
            raw.removeAll()
            return line
        }

        private static func decode(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self)
        }
    }

    private final class Buffer: @unchecked Sendable {
        private var buf = FileHandleLineBuffer()
        func append(_ chunk: Data) -> [String] { buf.append(chunk) }
        func finish() -> String? { buf.finish() }
    }
}
