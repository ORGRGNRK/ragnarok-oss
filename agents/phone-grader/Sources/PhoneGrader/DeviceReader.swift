import Foundation
import PhoneGraderCore

#if os(macOS)

/// Reads a plugged-in phone with local tools. Read-only: never pairs silently,
/// never changes device state. iOS: pymobiledevice3 (no-sudo pip install) or
/// libimobiledevice if present; Android: adb (Google platform-tools).
enum DeviceReader {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func find(_ names: [String]) -> String? {
        let dirs = ["\(home)/.local/bin", "\(home)/.local/platform-tools", "\(home)/.local/pymobiledevice3/bin",
                    "/opt/homebrew/bin", "/usr/local/bin"]
        for n in names { for d in dirs where FileManager.default.isExecutableFile(atPath: "\(d)/\(n)") { return "\(d)/\(n)" } }
        return nil
    }
    static var pmd3: String? { find(["pymobiledevice3"]) }
    static var ideviceinfo: String? { find(["ideviceinfo"]) }
    static var ideviceId: String? { find(["idevice_id"]) }
    static var adb: String? { find(["adb"]) }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 45) async -> (Int32, String, String) {
        (try? await AIClient.run(exe, args, timeout: timeout)) ?? (-1, "", "failed to launch \(exe)")
    }

    struct Connected: Equatable { var platform: DeviceReadout.Platform; var id: String; var state: String }

    /// Cheap presence check used by auto-detect.
    static func listConnected() async -> [Connected] {
        var out: [Connected] = []
        if let p = pmd3 {
            let (_, so, _) = await run(p, ["usbmux", "list"], timeout: 10)
            out += DeviceParsing.parseUsbmuxList(Data(so.utf8)).map { Connected(platform: .iOS, id: $0.udid, state: $0.connection) }
        } else if let i = ideviceId {
            let (_, so, _) = await run(i, ["-l"], timeout: 10)
            out += so.split(separator: "\n").map { Connected(platform: .iOS, id: String($0).trimmingCharacters(in: .whitespaces), state: "USB") }
        }
        if let a = adb {
            let (_, so, _) = await run(a, ["devices"], timeout: 10)
            out += DeviceParsing.parseAdbDevices(so).map { Connected(platform: .android, id: $0.serial, state: $0.state) }
        }
        return out
    }

    static func readFirst() async -> Result<DeviceReadout, DeviceProblem> {
        if pmd3 == nil && ideviceinfo == nil && adb == nil { return .failure(.toolMissing("pymobiledevice3 / adb")) }
        let devices = await listConnected()
        // Prefer a USB iPhone, then any iPhone, then a ready Android device.
        let ios = devices.filter { $0.platform == .iOS }
        if let d = ios.first(where: { $0.state.uppercased() == "USB" }) ?? ios.first { return await readIOS(udid: d.id, connection: d.state) }
        if let d = devices.first(where: { $0.platform == .android }) {
            switch d.state {
            case "device": return await readAndroid(serial: d.id)
            case "unauthorized": return .failure(.unauthorized)
            default: return .failure(.offline)
            }
        }
        return .failure(.noDevice)
    }

    static func readIOS(udid: String, connection: String) async -> Result<DeviceReadout, DeviceProblem> {
        var lockdown: [String: Any] = [:], disk: [String: Any]?, battery: [String: Any]?
        if let p = pmd3 {
            let (code, so, se) = await run(p, ["lockdown", "info", "--udid", udid])
            guard code == 0 else { return .failure(DeviceParsing.classifyIOSError(se + so)) }
            lockdown = DeviceParsing.parseLockdown(json: Data(so.utf8))
            // Retry once: right after Trust, or while the phone is busy, the first query can stall.
            for _ in 0..<2 where disk.map({ DeviceParsing.storageGb(lockdown: [:], diskUsage: $0) == nil }) ?? true {
                let (c2, d2, _) = await run(p, ["lockdown", "get", "com.apple.disk_usage", "--udid", udid])
                if c2 == 0 { disk = DeviceParsing.parseLockdown(json: Data(d2.utf8)) }
            }
            let (c3, b3, _) = await run(p, ["diagnostics", "battery", "single", "--udid", udid])
            if c3 == 0 { battery = DeviceParsing.parseLockdown(json: Data(b3.utf8)) }
        } else if let i = ideviceinfo {
            let (code, so, se) = await run(i, ["-u", udid])
            guard code == 0 else { return .failure(DeviceParsing.classifyIOSError(se + so)) }
            lockdown = DeviceParsing.parseIdeviceinfo(so)
            let (c2, d2, _) = await run(i, ["-u", udid, "-q", "com.apple.disk_usage"])
            if c2 == 0 { disk = DeviceParsing.parseIdeviceinfo(d2) }
            if let diag = find(["idevicediagnostics"]) {
                let (c3, b3, _) = await run(diag, ["-u", udid, "ioregentry", "AppleSmartBattery"])
                if c3 == 0, let d = b3.data(using: .utf8),
                   let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                    battery = ((pl["IORegistry"] as? [String: Any]) ?? pl)
                }
            }
        }
        guard !lockdown.isEmpty else { return .failure(.other("Device answered but returned no info.")) }
        var r = DeviceParsing.iOSReadout(lockdown: lockdown, diskUsage: disk, battery: battery)
        if r.identifier.isEmpty { r.identifier = udid }
        r.connection = connection.isEmpty ? "usbmux" : connection
        return .success(r)
    }

    static func readAndroid(serial: String) async -> Result<DeviceReadout, DeviceProblem> {
        guard let a = adb else { return .failure(.toolMissing("adb")) }
        let (code, props, se) = await run(a, ["-s", serial, "shell", "getprop"])
        guard code == 0 else {
            return .failure(se.contains("unauthorized") ? .unauthorized : .other(String(se.prefix(300))))
        }
        let (_, df, _) = await run(a, ["-s", serial, "shell", "df", "-k", "/data"])
        let (_, bat, _) = await run(a, ["-s", serial, "shell", "dumpsys", "battery"])
        // IMEI: only works on old/rooted builds; anything else is ignored, never guessed.
        let (_, imei, _) = await run(a, ["-s", serial, "shell", "service", "call", "iphonesubinfo", "1"], timeout: 8)
        return .success(DeviceParsing.androidReadout(serial: serial, props: DeviceParsing.parseGetprop(props),
                                                     df: df, battery: bat, imeiCall: imei))
    }
}
#else
/// iPhone / iPad: no USB reading (no Process, no libimobiledevice / adb on iOS). The Grade tab hides
/// the "Plug in phone" panel; model, storage, battery and IMEI are entered by hand.
enum DeviceReader {
    struct Connected: Equatable { var platform: DeviceReadout.Platform; var id: String; var state: String }
    static func listConnected() async -> [Connected] { [] }
    static func readFirst() async -> Result<DeviceReadout, DeviceProblem> {
        .failure(.other("Reading a plugged-in phone over USB needs the Mac app. Enter the details by hand."))
    }
}
#endif
