import Foundation

/// What a USB/usbmux read can tell us. Deliberately has NO iCloud/FRP,
/// carrier-lock or original-screen fields: those stay manual checklist items.
public struct DeviceReadout: Equatable, Sendable {
    public enum Platform: String, Sendable { case iOS, android }
    public var platform: Platform
    public var identifier: String = ""
    public var rawModel: String = ""          // ProductType (iPhone10,5) or ro.product.model
    public var marketingModel: String?        // ladder-style name, nil if unknown
    public var manufacturer: String?
    public var storageGb: Int?
    public var osVersion: String?
    public var serial: String?
    public var imei: String?
    public var batteryHealthPercent: Int?     // iOS: device MaximumCapacityPercent, else floor(Nominal/Design) (estimate)
    /// true when computed from capacities (not the device-reported MaximumCapacityPercent)
    public var batteryHealthIsEstimate = false
    public var batteryCycles: Int?
    public var batteryLevel: Int?
    public var batteryHealthText: String?     // Android dumpsys health
    /// true when the device answered but exposed no capacity numbers to compute health from
    public var batteryHealthUnreadable = false
    public var storageUnreadable = false
    public var simCarrierHint: String?        // SIM's carrier bundle — NOT a lock status
    public var connection: String?
    public init(platform: Platform) { self.platform = platform }
}

public enum DeviceProblem: Error, Equatable, Sendable {
    case noDevice
    case needsTrust          // iOS: not paired / pairing dialog pending
    case locked              // iOS: passcode-locked
    case unauthorized        // Android: USB debugging prompt not accepted
    case offline
    case toolMissing(String)
    case other(String)

    public var message: String {
        switch self {
        case .noDevice: return "No phone found. Plug it in with a data cable (for Android, enable USB debugging)."
        case .needsTrust: return "Unlock the iPhone and tap Trust on the \"Trust This Computer?\" prompt, then press Plug in phone again."
        case .locked: return "The iPhone is locked. Unlock it (and tap Trust if asked), then try again."
        case .unauthorized: return "Android: unlock the phone and tap Allow on the \"Allow USB debugging?\" prompt."
        case .offline: return "Android device is offline — replug the cable, check USB debugging is on."
        case .toolMissing(let t): return "\(t) is not installed. See Settings → Device tools."
        case .other(let m): return m
        }
    }
}

public enum DeviceParsing {
    // MARK: iPhone identifiers -> Atlas-ladder model names

    public static let iPhoneModels: [String: String] = [
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone 17 Air", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
    ]

    public static func iPhoneModelName(_ productType: String) -> String? {
        iPhoneModels[productType.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Bytes (decimal, as iOS/Android report) -> marketed GB tier.
    public static func storageTier(bytes: Double) -> Int? {
        guard bytes > 0 else { return nil }
        let gb = bytes / 1_000_000_000
        let tiers = [16, 32, 64, 128, 256, 512, 1024, 2048]
        // smallest marketed tier the reported size fits in (reported is never above marketed)
        return tiers.first { Double($0) * 1.0 >= gb * 0.98 } ?? Int(gb.rounded())
    }

    // MARK: iOS (pymobiledevice3 JSON, or libimobiledevice `ideviceinfo` text)

    public static func parseLockdown(json: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:]
    }

    /// `ideviceinfo` prints "Key: value" lines.
    public static func parseIdeviceinfo(_ text: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix(" ") {
            guard let r = line.range(of: ": ") else { continue }
            out[String(line[..<r.lowerBound])] = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    public static func iOSReadout(lockdown: [String: Any], diskUsage: [String: Any]? = nil,
                                  battery: [String: Any]? = nil) -> DeviceReadout {
        var r = DeviceReadout(platform: .iOS)
        func s(_ k: String, _ d: [String: Any]? = nil) -> String? {
            let v = (d ?? lockdown)[k]
            if let v = v as? String, !v.isEmpty { return v }
            if let v = v as? NSNumber { return v.stringValue }
            return nil
        }
        r.identifier = s("UniqueDeviceID") ?? ""
        r.rawModel = s("ProductType") ?? ""
        r.marketingModel = iPhoneModelName(r.rawModel)
        r.manufacturer = "Apple"
        r.osVersion = s("ProductVersion")
        r.serial = s("SerialNumber")
        r.imei = s("InternationalMobileEquipmentIdentity").flatMap { isValidIMEI($0) ? $0 : nil }
        r.storageGb = storageGb(lockdown: lockdown, diskUsage: diskUsage)
        r.storageUnreadable = r.storageGb == nil
        if let bundles = lockdown["CarrierBundleInfoArray"] as? [[String: Any]],
           let id = bundles.first?["CFBundleIdentifier"] as? String {
            r.simCarrierHint = id.replacingOccurrences(of: "com.apple.", with: "").replacingOccurrences(of: "_", with: " ")
        }
        if let b = battery {
            let bat = parseBattery(b)
            r.batteryCycles = bat.cycles
            r.batteryLevel = bat.level
            r.batteryHealthPercent = bat.healthPercent
            r.batteryHealthIsEstimate = bat.healthPercent != nil && bat.estimated
            r.batteryHealthUnreadable = bat.healthPercent == nil
        } else {
            r.batteryHealthUnreadable = true
        }
        return r
    }

    static func number(_ d: [String: Any]?, _ k: String) -> Double? {
        guard let v = d?[k] else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// com.apple.disk_usage TotalDiskCapacity (marketed bytes), falling back to
    /// data+system partitions, then the root lockdown domain.
    public static func storageGb(lockdown: [String: Any], diskUsage: [String: Any]?) -> Int? {
        if let t = number(diskUsage, "TotalDiskCapacity") ?? number(lockdown, "TotalDiskCapacity") { return storageTier(bytes: t) }
        if let data = number(diskUsage, "TotalDataCapacity") {
            return storageTier(bytes: data + (number(diskUsage, "TotalSystemCapacity") ?? 0))
        }
        return nil
    }

    /// AppleSmartBattery snapshot (pymobiledevice3 `diagnostics battery single` or the
    /// idevicediagnostics ioreg entry). On newer iOS (seen on iOS 27, iPhone 16 Pro) the
    /// capacities moved from the top level into a nested `BatteryData` dict and the
    /// top-level MaxCapacity is just the 100% charge scale — so it is NOT health.
    /// Health: device-reported MaximumCapacityPercent when present (exact, what Settings shows);
    /// otherwise floor(NominalChargeCapacity / DesignCapacity × 100) — iOS truncates, so rounding
    /// read 93% on a phone whose Settings said 92% (3282/3544 = 92.6).
    public static func parseBattery(_ b: [String: Any]) -> (healthPercent: Int?, cycles: Int?, level: Int?, estimated: Bool) {
        let nested = b["BatteryData"] as? [String: Any]
        func n(_ k: String) -> Double? { number(nested, k) ?? number(b, k) }
        let cycles = (number(b, "CycleCount") ?? number(nested, "CycleCount")).map { Int($0) }
        let level = (number(b, "CurrentCapacity") ?? number(nested, "CurrentCapacity")).map { Int($0) }
        var health: Int?
        var estimated = false
        if let pct = n("MaximumCapacityPercent") ?? n("BatteryHealthMetric"), pct > 0, pct <= 100 {
            health = Int(pct.rounded())
        } else if let design = n("DesignCapacity"), design > 0,
                  let full = n("NominalChargeCapacity") ?? n("AppleRawMaxCapacity"), full > 0 {
            // NominalChargeCapacity is the closest raw analogue of Settings > Battery "Maximum Capacity"
            health = batteryHealthEstimate(full: full, design: design)
            estimated = true
        }
        return (health, cycles, level, estimated)
    }

    /// floor, with a tiny epsilon so exact ratios (e.g. 2900/3625 = 80.0) don't drop to 79.
    public static func batteryHealthEstimate(full: Double, design: Double) -> Int? {
        guard design > 0, full > 0 else { return nil }
        return min(100, Int((full / design * 100 + 1e-9).rounded(.down)))
    }

    /// A manual battery entry always beats the device read. Empty/invalid manual = no override.
    public static func resolveBattery(auto: Int?, manual: String?) -> (value: Int?, isManual: Bool) {
        let t = (manual ?? "").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let m = Int(t), (0...100).contains(m) { return (m, true) }
        return (auto, false)
    }

    /// Map pymobiledevice3 / libimobiledevice error text to a user-facing problem.
    public static func classifyIOSError(_ text: String) -> DeviceProblem {
        let t = text.lowercased()
        if t.contains("passwordprotected") || t.contains("password protected") || t.contains("passcode") { return .locked }
        if t.contains("pairingdialogresponsepending") || t.contains("notpaired") || t.contains("not paired")
            || t.contains("userdeniedpairing") || t.contains("invalidhostid") || t.contains("pairing")
            || t.contains("trust") { return .needsTrust }
        if t.contains("nodeviceconnected") || t.contains("no device") || t.contains("device not found")
            || t.contains("connectionfailed") { return .noDevice }
        return .other(String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)))
    }

    /// pymobiledevice3 `usbmux list` JSON -> [(udid, connectionType)]
    public static func parseUsbmuxList(_ json: Data) -> [(udid: String, connection: String, productType: String)] {
        guard let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return arr.compactMap {
            guard let id = ($0["UniqueDeviceID"] ?? $0["Identifier"]) as? String else { return nil }
            return (id, ($0["ConnectionType"] as? String) ?? "", ($0["ProductType"] as? String) ?? "")
        }
    }

    // MARK: Android (adb)

    public static func parseAdbDevices(_ text: String) -> [(serial: String, state: String)] {
        text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("List of devices") || l.hasPrefix("*") { return nil }
            let parts = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// `adb shell df -k /data` -> marketed GB tier.
    public static func parseAndroidDf(_ text: String) -> Int? {
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if cols.count >= 2, let kb = Double(cols[1]) { return storageTier(bytes: kb * 1024) }
        }
        return nil
    }

    public static func parseDumpsysBattery(_ text: String) -> (level: Int?, health: String?, cycles: Int?) {
        var level: Int?, health: String?, cycles: Int?
        let names = ["1": "unknown", "2": "good", "3": "overheat", "4": "dead", "5": "over voltage", "6": "failure", "7": "cold"]
        for raw in text.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard let r = l.range(of: ":") else { continue }
            let k = l[..<r.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            let v = l[r.upperBound...].trimmingCharacters(in: .whitespaces)
            switch k {
            case "level": level = Int(v)
            case "health": health = names[v] ?? v
            case "cycle count", "cycle_count", "charge cycle count": cycles = Int(v)
            default: break
            }
        }
        return (level, health, cycles)
    }

    /// `service call iphonesubinfo 1` parcel -> IMEI, only if it decodes to a valid 15-digit IMEI.
    public static func parseServiceCallIMEI(_ text: String) -> String? {
        guard !text.contains("Exception"), !text.lowercased().contains("permission") else { return nil }
        var digits = ""
        let re = try! NSRegularExpression(pattern: #"'([^']*)'"#)
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            digits += ns.substring(with: m.range(at: 1)).filter { $0.isNumber }
        }
        return isValidIMEI(digits) ? digits : nil
    }

    public static func isValidIMEI(_ s: String) -> Bool {
        let d = s.compactMap { $0.wholeNumberValue }
        guard d.count == 15, s.allSatisfy({ $0.isNumber }) else { return false }
        var sum = 0
        for (i, v) in d.enumerated() {
            if i % 2 == 1 { let x = v * 2; sum += x > 9 ? x - 9 : x } else { sum += v }
        }
        return sum % 10 == 0
    }

    public static func androidReadout(serial: String, props: [String: String], df: String?, battery: String?, imeiCall: String?) -> DeviceReadout {
        var r = DeviceReadout(platform: .android)
        r.identifier = serial
        r.rawModel = props["ro.product.model"] ?? ""
        r.manufacturer = props["ro.product.manufacturer"]
        let maker = (r.manufacturer ?? "").capitalized
        if !r.rawModel.isEmpty { r.marketingModel = r.rawModel.lowercased().hasPrefix(maker.lowercased()) || maker.isEmpty ? r.rawModel : "\(maker) \(r.rawModel)" }
        r.osVersion = props["ro.build.version.release"].map { "Android \($0)" }
        r.storageGb = df.flatMap(parseAndroidDf)
        if let b = battery.map(parseDumpsysBattery) { r.batteryLevel = b.level; r.batteryHealthText = b.health; r.batteryCycles = b.cycles }
        r.imei = imeiCall.flatMap(parseServiceCallIMEI)
        r.connection = "USB (adb)"
        return r
    }

    /// `adb shell getprop` full dump "[key]: [value]" lines.
    public static func parseGetprop(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: #"^\[([^\]]+)\]: \[(.*)\]$"#, options: .anchorsMatchLines)
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }
}
