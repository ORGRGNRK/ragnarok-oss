import XCTest
@testable import PhoneGraderCore

final class DeviceParsingTests: XCTestCase {
    typealias P = DeviceParsing

    func testEveryMappedModelIsLadderNamedOrKnownOffLadder() {
        let ladder = Set(TestData.ladder.canonicalModels)
        let offLadder: Set<String> = ["iphone 6s", "iphone 6s plus", "iphone se", "iphone se (2nd gen)"]
        for name in Set(P.iPhoneModels.values) {
            XCTAssertTrue(ladder.contains(pyNorm(name)) || offLadder.contains(pyNorm(name)), name)
        }
        // and the price engine resolves them exactly
        XCTAssertEqual(TestData.engine.canonicalizeModel(P.iPhoneModelName("iPhone10,5")!, interpreter: nil).1, "exact")
        XCTAssertEqual(P.iPhoneModelName("iPhone15,3"), "iPhone 14 Pro Max")
        XCTAssertEqual(P.iPhoneModelName("iPhone14,6"), "iPhone SE (3rd gen)")
        XCTAssertEqual(P.iPhoneModelName("iPhone18,4"), "iPhone 17 Air")
        XCTAssertNil(P.iPhoneModelName("iPad13,1"))
    }

    func testStorageTiers() {
        XCTAssertEqual(P.storageTier(bytes: 256_000_000_000), 256)
        XCTAssertEqual(P.storageTier(bytes: 127_999_000_000), 128)
        XCTAssertEqual(P.storageTier(bytes: 1_000_000_000_000), 1024)
        XCTAssertEqual(P.storageTier(bytes: 110_000_000_000), 128)   // Android /data partition
        XCTAssertNil(P.storageTier(bytes: 0))
    }

    // Shape captured from a real iPhone 8 Plus via pymobiledevice3 (serial/IMEI replaced).
    let lockdownJSON = #"{"ProductType":"iPhone10,5","ProductVersion":"16.7.14","SerialNumber":"F2LXXXXXXXXX","InternationalMobileEquipmentIdentity":"490154203237518","UniqueDeviceID":"2b86d1e1","ActivationState":"Activated","CarrierBundleInfoArray":[{"CFBundleIdentifier":"com.apple.ATT_US","MCC":"310"}]}"#
    let diskJSON = #"{"TotalDataCapacity":250784157696,"TotalDiskCapacity":256000000000}"#
    let batteryJSON = #"{"AppleRawMaxCapacity":1922,"CurrentCapacity":100,"CycleCount":702,"DesignCapacity":2675,"MaxCapacity":100,"NominalChargeCapacity":1869}"#

    func testIOSReadout() {
        let r = P.iOSReadout(lockdown: P.parseLockdown(json: Data(lockdownJSON.utf8)),
                             diskUsage: P.parseLockdown(json: Data(diskJSON.utf8)),
                             battery: P.parseLockdown(json: Data(batteryJSON.utf8)))
        XCTAssertEqual(r.marketingModel, "iPhone 8 Plus")
        XCTAssertEqual(r.storageGb, 256)
        XCTAssertEqual(r.osVersion, "16.7.14")
        XCTAssertEqual(r.imei, "490154203237518")
        XCTAssertEqual(r.batteryHealthPercent, 69)   // floored estimate
        XCTAssertEqual(r.batteryCycles, 702)
        XCTAssertEqual(r.simCarrierHint, "ATT US")
    }

    func testIdeviceinfoText() {
        let text = "ActivationState: Activated\nProductType: iPhone14,2\nProductVersion: 17.5\nTotalDiskCapacity: 128000000000\nSomeArray:\n 0: x\n"
        let r = P.iOSReadout(lockdown: P.parseIdeviceinfo(text))
        XCTAssertEqual(r.marketingModel, "iPhone 13 Pro"); XCTAssertEqual(r.storageGb, 128); XCTAssertNil(r.imei)
    }

    func testIOSErrorClassification() {
        XCTAssertEqual(P.classifyIOSError("pymobiledevice3.exceptions.PairingDialogResponsePendingError"), .needsTrust)
        XCTAssertEqual(P.classifyIOSError("ERROR: Could not connect to lockdownd: Password protected"), .locked)
        XCTAssertEqual(P.classifyIOSError("PasswordProtectedError"), .locked)
        XCTAssertEqual(P.classifyIOSError("NotPairedError"), .needsTrust)
        XCTAssertEqual(P.classifyIOSError("NoDeviceConnectedError"), .noDevice)
        if case .other = P.classifyIOSError("weird") {} else { XCTFail() }
    }

    func testUsbmuxList() {
        let j = #"[{"ConnectionType":"USB","ProductType":"iPhone13,2","UniqueDeviceID":"abc"},{"ConnectionType":"Network","Identifier":"def"}]"#
        let l = P.parseUsbmuxList(Data(j.utf8))
        XCTAssertEqual(l.map(\.udid), ["abc", "def"]); XCTAssertEqual(l[0].connection, "USB")
    }

    func testAdbDevicesStates() {
        let t = "* daemon started successfully\nList of devices attached\nR5CT1234\tdevice\nZY22\tunauthorized\nemu\toffline\n\n"
        let d = P.parseAdbDevices(t)
        XCTAssertEqual(d.map(\.state), ["device", "unauthorized", "offline"])
        XCTAssertTrue(P.parseAdbDevices("List of devices attached\n\n").isEmpty)
    }

    func testAndroidReadout() {
        let props = "[ro.product.model]: [SM-S911U]\n[ro.product.manufacturer]: [samsung]\n[ro.build.version.release]: [14]\n"
        let df = "Filesystem     1K-blocks     Used Available Use% Mounted on\n/dev/block/dm-48 110404400 30000000 80404400  28% /data\n"
        let bat = "Current Battery Service state:\n  AC powered: false\n  level: 84\n  health: 2\n  Cycle Count: 311\n"
        let r = P.androidReadout(serial: "R5CT", props: P.parseGetprop(props), df: df, battery: bat,
                                 imeiCall: "Result: Parcel(ffffffff 0000 'Requires READ_PRIVILEGED_PHONE_STATE')")
        XCTAssertEqual(r.marketingModel, "Samsung SM-S911U")
        XCTAssertEqual(r.osVersion, "Android 14")
        XCTAssertEqual(r.storageGb, 128)
        XCTAssertEqual(r.batteryLevel, 84); XCTAssertEqual(r.batteryHealthText, "good"); XCTAssertEqual(r.batteryCycles, 311)
        XCTAssertNil(r.imei, "no IMEI without privileges — never guessed")
        XCTAssertNil(r.batteryHealthPercent)
    }

    func testServiceCallIMEIParcel() {
        let parcel = """
        Result: Parcel(
          0x00000000: 00000000 0000000f 00390034 00310030 '........4.9.0.1.'
          0x00000010: 00340035 00300032 00320033 00370033 '5.4.2.0.3.2.3.7.'
          0x00000020: 00310035 00000038                   '5.1.8...        ')
        """
        XCTAssertEqual(P.parseServiceCallIMEI(parcel), "490154203237518")
        XCTAssertFalse(P.isValidIMEI("490154203237519"))
        XCTAssertFalse(P.isValidIMEI("12345"))
    }

    // Shapes captured from a real iPhone 16 Pro (iPhone17,1) on iOS 27.0.1.
    func testIOS27NestedBatteryAndDiskUsage() {
        let lockdown = P.parseLockdown(json: Data(#"{"ProductType":"iPhone17,1","ProductVersion":"27.0.1"}"#.utf8))
        let disk = P.parseLockdown(json: Data(#"{"AmountDataAvailable":64802467840,"CalculateDiskUsage":"OkilyDokily","NANDInfo":{"$hex":"0100"},"TotalDataCapacity":118459056128,"TotalDiskCapacity":128000000000,"TotalSystemCapacity":8930627584}"#.utf8))
        let bat = P.parseLockdown(json: Data(#"{"CurrentCapacity":39,"CycleCount":408,"MaxCapacity":100,"BatteryData":{"AbsoluteCapacity":1382,"CurrentCapacity":39,"DesignCapacity":3544,"FullChargeCapacity":3381,"MaxCapacity":100,"NominalChargeCapacity":3281}}"#.utf8))
        let r = P.iOSReadout(lockdown: lockdown, diskUsage: disk, battery: bat)
        XCTAssertEqual(r.marketingModel, "iPhone 16 Pro")
        XCTAssertEqual(r.storageGb, 128)
        XCTAssertEqual(r.batteryHealthPercent, 92)     // floor(3281 / 3544 = 92.58); Settings shows 92
        XCTAssertTrue(r.batteryHealthIsEstimate)
        XCTAssertEqual(r.batteryCycles, 408)
        XCTAssertEqual(r.batteryLevel, 39)
        XCTAssertFalse(r.batteryHealthUnreadable)
        XCTAssertFalse(r.storageUnreadable)
    }

    func testTopLevelMaxCapacityIsNotHealth() {
        let r = P.parseBattery(["CurrentCapacity": 36, "CycleCount": 408, "MaxCapacity": 100])
        XCTAssertNil(r.healthPercent, "MaxCapacity=100 is the charge scale, never report it as 100% health")
        XCTAssertEqual(r.cycles, 408)
        let ro = P.iOSReadout(lockdown: ["ProductType": "iPhone17,1"], diskUsage: nil, battery: ["CycleCount": 408, "MaxCapacity": 100])
        XCTAssertTrue(ro.batteryHealthUnreadable)
        XCTAssertTrue(ro.storageUnreadable)
    }

    // Raw values read from the user's iPhone 16 Pro (iOS 27.0.1) on 2026-10-16; Settings showed 92%.
    func testFloorNotRoundMatchesSettings() {
        let r = P.parseBattery(["CycleCount": 409, "MaxCapacity": 100, "BatteryData": ["DesignCapacity": 3544, "NominalChargeCapacity": 3282, "FullChargeCapacity": 3389]])
        XCTAssertEqual(r.healthPercent, 92); XCTAssertTrue(r.estimated)
        XCTAssertEqual(P.batteryHealthEstimate(full: 2900, design: 3625), 80)   // exact ratio stays 80
        XCTAssertEqual(P.batteryHealthEstimate(full: 3999, design: 4000), 99)
        XCTAssertEqual(P.batteryHealthEstimate(full: 4100, design: 4000), 100)  // capped
        XCTAssertNil(P.batteryHealthEstimate(full: 0, design: 4000))
    }

    func testDeviceReportedPercentIsNotEstimate() {
        let r = P.parseBattery(["BatteryData": ["MaximumCapacityPercent": 92, "DesignCapacity": 3544, "NominalChargeCapacity": 3330]])
        XCTAssertEqual(r.healthPercent, 92); XCTAssertFalse(r.estimated)
        let ro = P.iOSReadout(lockdown: [:], battery: ["MaximumCapacityPercent": 91])
        XCTAssertEqual(ro.batteryHealthPercent, 91); XCTAssertFalse(ro.batteryHealthIsEstimate)
    }

    func testManualBatteryOverridesAuto() {
        XCTAssertEqual(P.resolveBattery(auto: 93, manual: "92").value, 92)
        XCTAssertTrue(P.resolveBattery(auto: 93, manual: "92%").isManual)
        XCTAssertEqual(P.resolveBattery(auto: 93, manual: nil).value, 93)
        XCTAssertFalse(P.resolveBattery(auto: 93, manual: "").isManual)
        XCTAssertEqual(P.resolveBattery(auto: 93, manual: "abc").value, 93)
        XCTAssertEqual(P.resolveBattery(auto: nil, manual: "101").value, nil)
    }

    func testMaximumCapacityPercentPreferred() {
        XCTAssertEqual(P.parseBattery(["MaximumCapacityPercent": 88, "DesignCapacity": 3000, "NominalChargeCapacity": 2900]).healthPercent, 88)
    }

    func testStorageFallbacks() {
        XCTAssertEqual(P.storageGb(lockdown: [:], diskUsage: ["TotalDataCapacity": 500_000_000_000, "TotalSystemCapacity": 11_000_000_000]), 512)
        XCTAssertEqual(P.storageGb(lockdown: ["TotalDiskCapacity": "1000000000000"], diskUsage: nil), 1024)
        XCTAssertNil(P.storageGb(lockdown: [:], diskUsage: [:]))
    }
}
