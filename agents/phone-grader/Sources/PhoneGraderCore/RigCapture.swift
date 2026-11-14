import Foundation

/// Two-spin rig capture, pure logic (no AppKit) so it is testable on fixtures.
///
/// The rig (crew recmwttGtEvTpJszA): subject phone on a turntable, fixed cameras.
/// It can't be one pass — the About page needs the screen ON. The owner's open fix was
/// a frame-paced Shortcut; the cheaper one adopted here: TWO spins, screen flipped
/// between them (Auto-Lock = Never holds the About page), and frames SELF-LABEL by
/// the perceptual-hash/brightness jump the gate already measures.
public struct GrayImage: Equatable, Sendable {
    public let width: Int, height: Int
    public var pixels: [UInt8]       // row-major luma
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }
    public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// Rotate clockwise by 0/90/180/270.
    public func rotated(_ degrees: Int) -> GrayImage {
        let d = ((degrees % 360) + 360) % 360
        guard d != 0 else { return self }
        var out = [UInt8](repeating: 0, count: pixels.count)
        let (nw, nh) = d == 180 ? (width, height) : (height, width)
        for y in 0..<height { for x in 0..<width {
            let (nx, ny): (Int, Int)
            switch d {
            case 90: (nx, ny) = (height - 1 - y, x)
            case 180: (nx, ny) = (width - 1 - x, height - 1 - y)
            default: (nx, ny) = (y, width - 1 - x)          // 270
            }
            out[ny * nw + nx] = self[x, y]
        } }
        return GrayImage(width: nw, height: nh, pixels: out)
    }

    /// Box-average resample (enough for hashing / metrics).
    public func resized(_ w: Int, _ h: Int) -> GrayImage {
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let x0 = x * width / w, x1 = max(x0 + 1, (x + 1) * width / w)
            let y0 = y * height / h, y1 = max(y0 + 1, (y + 1) * height / h)
            var s = 0, n = 0
            for yy in y0..<min(y1, height) { for xx in x0..<min(x1, width) { s += Int(self[xx, yy]); n += 1 } }
            out[y * w + x] = UInt8(n == 0 ? 0 : s / n)
        } }
        return GrayImage(width: w, height: h, pixels: out)
    }

    public var meanLuma: Double { pixels.isEmpty ? 0 : Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) }

    /// Mean luma of the central half — where the screen sits when the phone is framed.
    public var centerLuma: Double {
        var s = 0, n = 0
        for y in (height / 4)..<(height * 3 / 4) { for x in (width / 4)..<(width * 3 / 4) { s += Int(self[x, y]); n += 1 } }
        return n == 0 ? 0 : Double(s) / Double(n)
    }

    /// Variance of a 4-neighbour Laplacian: higher = sharper (blur rejection).
    public var sharpness: Double {
        guard width > 2, height > 2 else { return 0 }
        var vals: [Double] = []; vals.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            let l = 4 * Int(self[x, y]) - Int(self[x - 1, y]) - Int(self[x + 1, y]) - Int(self[x, y - 1]) - Int(self[x, y + 1])
            vals.append(Double(l))
        } }
        let m = vals.reduce(0, +) / Double(vals.count)
        return vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count)
    }

    /// 64-bit difference hash (9x8 resample, compare horizontal neighbours).
    public var dHash: UInt64 {
        let s = resized(9, 8)
        var h: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { h <<= 1; if s[x, y] > s[x + 1, y] { h |= 1 } } }
        return h
    }
}

public enum PHash {
    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}

public enum Upright {
    /// Rotation that makes a phone frame portrait. The phone is taller than wide;
    /// probe-002 finding 2: sideways frames cost the 7B object identity, so normalise
    /// before it sees them. A per-camera rotation set by the operator wins (mount-dependent).
    public static func rotation(width: Int, height: Int, cameraRotation: Int?) -> Int {
        if let r = cameraRotation { return r }
        return width > height ? 90 : 0
    }
}

public struct RigFrame: Identifiable, Equatable, Sendable, Codable {
    public var id: String { "\(slot)#\(index)" }
    public var index: Int                 // arrival order within the session
    public var slot: String               // camera slot / folder name
    public var time: Double               // seconds since session start
    public var hash: UInt64
    public var sharpness: Double
    public var centerLuma: Double
    public var file: String               // stored JPEG name
    public var markedPass: CapturePass?   // operator's explicit "now on pass N" at capture time
    public var pass: CapturePass?         // final tag
    public var hashRef: String { String(format: "%016llx", hash) }
    public init(index: Int, slot: String, time: Double, hash: UInt64, sharpness: Double, centerLuma: Double,
                file: String, markedPass: CapturePass? = nil) {
        self.index = index; self.slot = slot; self.time = time; self.hash = hash; self.sharpness = sharpness
        self.centerLuma = centerLuma; self.file = file; self.markedPass = markedPass; self.pass = markedPass
    }
}

public enum PassTagger {
    /// Tag frames exterior/screen. Explicit operator marks win. For unmarked frames,
    /// per camera slot find the split between the two spins: the consecutive pair with
    /// the largest combined jump (hash distance + centre brightness rise, since the
    /// screen turning on lights the centre). Below `minJump` there is no split and all
    /// frames are exterior. Frames after the split are `screen`.
    public static func tag(_ frames: [RigFrame], minJump: Double = 12) -> [RigFrame] {
        var out = frames
        let slots = Set(frames.map(\.slot))
        for slot in slots {
            let idx = out.indices.filter { out[$0].slot == slot }.sorted { out[$0].index < out[$1].index }
            if idx.allSatisfy({ out[$0].markedPass != nil }) {
                for i in idx { out[i].pass = out[i].markedPass }; continue
            }
            var best: (at: Int, score: Double)? = nil
            for k in 1..<max(1, idx.count) {
                let a = out[idx[k - 1]], b = out[idx[k]]
                let score = Double(PHash.hamming(a.hash, b.hash)) + max(0, b.centerLuma - a.centerLuma) / 4
                if score >= minJump, score > (best?.score ?? -1) { best = (k, score) }
            }
            for (k, i) in idx.enumerated() {
                if let m = out[i].markedPass { out[i].pass = m; continue }
                out[i].pass = (best.map { k >= $0.at } ?? false) ? .screen : .exterior
            }
        }
        return out
    }

    /// Best (sharpest) frame per angle. A spin is one revolution, so the angle bucket is
    /// the frame's position within its pass's time span, cut into `angles` equal sectors.
    /// Near-duplicates (hash distance ≤ dupDistance) of an already-picked frame are skipped.
    public static func bestPerAngle(_ frames: [RigFrame], pass: CapturePass, angles: Int = 8,
                                    dupDistance: Int = 3) -> [RigFrame] {
        var picked: [RigFrame] = []
        for slot in Set(frames.map(\.slot)).sorted() {
            let fs = frames.filter { $0.slot == slot && $0.pass == pass }.sorted { $0.time < $1.time }
            guard let t0 = fs.first?.time, let t1 = fs.last?.time else { continue }
            let span = max(t1 - t0, 1e-9)
            var buckets: [Int: RigFrame] = [:]
            for f in fs {
                let b = min(angles - 1, Int(Double(angles) * (f.time - t0) / span))
                if f.sharpness > (buckets[b]?.sharpness ?? -1) { buckets[b] = f }
            }
            for b in buckets.keys.sorted() {
                let f = buckets[b]!
                if picked.contains(where: { $0.slot == f.slot && PHash.hamming($0.hash, f.hash) <= dupDistance }) { continue }
                picked.append(f)
            }
        }
        return picked
    }

    /// Pick frames for one AI call, capped (Grader.maxPhotos): sharpest across angles first.
    public static func selection(_ frames: [RigFrame], pass: CapturePass, cap: Int) -> [RigFrame] {
        let best = bestPerAngle(frames, pass: pass)
        if best.count <= cap { return best }
        // spread evenly across the picked angles
        return (0..<cap).map { best[$0 * best.count / cap] }
    }
}
