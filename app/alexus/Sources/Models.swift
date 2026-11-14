import Foundation
import SwiftUI

struct HostRepair: Decodable, Identifiable {
    let id: String
    let status: String
    let created: String
    let note: String
    let changed_files: [String]?
    let candidate_sha256: String?
    let targets:[String]?
}
struct HostReceipt: Decodable, Identifiable {
    var id: String { hash }
    let sequence: Int
    let timestamp: String
    let action: String
    let repair_id: String
    let previous_hash: String
    let hash: String
}
struct AgentSummary: Decodable, Identifiable {
    let id: String
    let who: String
    let status: String
}
struct HostStatus: Decodable {
    struct Heimdall: Decodable {
        let name:String
        let source:String
        let observed_at:String
        let revision:String
        let changed_entries:Int?
        let app_present:Bool
        let error_log_present:Bool
        let error_log_updated_at:String?
        let runtime:String
    }
    let heimdall:Heimdall?
    let schema: String
    let repairs: [HostRepair]
    let receipts: [HostReceipt]
    let agents: [AgentSummary]
    let enclave_enrolled: Bool
    let external_profiles: [String]
    let automation: String
    let receipt_integrity: String
}
@MainActor final class AppModel: ObservableObject {
    @Published var projects: [PublicProject]=[]
    @Published var snapshot="Unverified · no catalog loaded"
    @Published var host: HostStatus?
    @Published var message=""
    @Published var busy=false
    @Published var query=""
    @Published var changeRequest=""
    @Published var repairProvider="codex"
    @Published var repairModel=""
    @Published var diff=""
    @Published var inspectedRepairID=""
    @Published var selectedKey="yubikey-primary"
    @Published var ownerDeviceStatus="Unpaired"
    @Published var ownerDeviceFingerprint="Unverified"
    @Published var pairedDevices:[PairedDeviceSummary]=[]
    @Published var pairingFile:URL?
    @Published var transferredPairingFile:URL?
    @Published var pairingDiagnostic=""
    let ownerDevice=OwnerDevice()
    struct PairedDeviceSummary:Decodable,Identifiable {let id:String;let status:String;let fingerprint:String}
    let foundation: FoundationText? = {
        guard let u=Bundle.main.url(forResource:"Foundation",withExtension:"json"),let d=try? Data(contentsOf:u) else{return nil}
        return try? JSONDecoder().decode(FoundationText.self,from:d)
    }()
    var filtered: [PublicProject] {
        projects.filter { query.isEmpty || ($0.title+" "+$0.category+" "+$0.description).localizedCaseInsensitiveContains(query) }
    }
    func refresh() async {
        if let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {
            let url=documents.appendingPathComponent("ALEXUS-pairing.json")
            transferredPairingFile=FileManager.default.fileExists(atPath:url.path) ? url:nil
        }
        do {
            let request=URLRequest(url:URL(string:"https://work.example.com/api/catalog")!,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:20)
            let (data,response)=try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode==200,data.count<2_000_000 else { throw URLError(.badServerResponse) }
            let catalog=try JSONDecoder().decode(WorkCatalog.self,from:data)
            guard catalog.schema=="ragnarok-work-atlas:v1",catalog.projects.count<=1000 else { throw URLError(.cannotParseResponse) }
            projects=catalog.projects;snapshot="Catalog · "+catalog.captured_at
        } catch {message="Catalog unavailable. Runtime remains Unverified."
            #if os(macOS)
            _ = try? await HostBridge.call(["command":"report_error","code":"catalog-unavailable"])
            #endif
        }
        #if os(macOS)
        do {host=try await HostBridge.decode(command:"status",as:HostStatus.self)}
        catch {message="Local host unavailable. No repair has been authorized."}
        #else
        ownerDeviceStatus=ownerDevice.status;ownerDeviceFingerprint=ownerDevice.connection?.fingerprint ?? "Unverified"
        if ownerDevice.connection != nil {
            do {
                try await ownerDevice.refreshPairing();ownerDeviceStatus=ownerDevice.status;ownerDeviceFingerprint=ownerDevice.connection?.fingerprint ?? "Unverified"
                if ownerDeviceStatus=="approved" {let data=try await ownerDevice.request("/v1/status");host=try JSONDecoder().decode(HostStatus.self,from:data)}
            } catch {message="Private Mac connection unavailable or not yet approved. Editing remains closed."}
        }
        #endif
    }
    func pairPhone(file:URL) async {
        let access=file.startAccessingSecurityScopedResource();defer{if access{file.stopAccessingSecurityScopedResource()}}
        guard !busy else{return};busy=true;defer{busy=false}
        ownerDevice.beginPairingFileRead()
        do {let data=try Data(contentsOf:file);try await ownerDevice.pair(from:data);ownerDeviceStatus=ownerDevice.status;ownerDeviceFingerprint=ownerDevice.connection?.fingerprint ?? "Unverified";pairingDiagnostic="Device proofs submitted. Compare the fingerprint and approve this device on the enrolled Mac.";message=pairingDiagnostic}
        catch {pairingDiagnostic=ownerDevice.pairingFailure(error);message=pairingDiagnostic}
    }
    func checkPairingConnection(file:URL) async {
        guard !busy else{return};busy=true;defer{busy=false}
        ownerDevice.beginPairingFileRead()
        do {try await ownerDevice.checkPairingConnection(from:Data(contentsOf:file));pairingDiagnostic="Mac connection and pairing challenge verified. No keys enrolled and no authority granted. You can now start enrollment."}
        catch {pairingDiagnostic=ownerDevice.pairingFailure(error)}
    }
    func refreshDevices() async {
        #if os(macOS)
        do {let result=try await HostBridge.call(["command":"pairing_list"]);let data=try JSONSerialization.data(withJSONObject:result["devices"] ?? []);pairedDevices=try JSONDecoder().decode([PairedDeviceSummary].self,from:data)}catch{message="Device list unavailable."}
        #else
        await refresh()
        #endif
    }
    func perform(_ command: String, id: String="") async {
        guard !busy || command=="stop" else{return}
        if command != "stop" {busy=true}
        defer{if command != "stop" {busy=false}}
        #if os(macOS)
        do {
            let result=try await HostBridge.call(["command":command,"id":id,"instruction":changeRequest,"profile":selectedKey,"provider":repairProvider,"model":repairModel])
            message=result["message"] as? String ?? "Operation completed."
            if let text=result["diff"] as? String {diff=text;inspectedRepairID=id}
            if let path=result["pairing_file"] as? String {pairingFile=URL(fileURLWithPath:path)}
            await refresh();await refreshDevices()
        } catch {message="Operation did not complete. No authorization was inferred from this error.";await refresh()}
        #else
        do {
            switch command {
            case "queue": _=try await ownerDevice.request("/v1/queue",method:"POST",body:["instruction":changeRequest,"provider":repairProvider,"model":repairModel]);message="Repair queued privately on your paired Mac."
            case "stop": ownerDevice.cancelPending();_=try await ownerDevice.request("/v1/stop",method:"POST",body:[:]);message="Pending work stopped and authorization epoch revoked."
            case "diff": let data=try await ownerDevice.request("/v1/repairs/"+id+"/diff");let response=try JSONSerialization.jsonObject(with:data) as? [String:Any];diff=response?["diff"] as? String ?? "";inspectedRepairID=id
            case "apply": guard let repair=host?.repairs.first(where:{$0.id==id}),let hash=repair.candidate_sha256 else{throw OwnerDeviceError.invalidResponse};try await ownerDevice.approveRepair(id:id,candidateSHA256:hash);message="The paired Mac accepted both fresh owner proofs. Refresh its observed repair state."
            default:throw OwnerDeviceError.notPaired
            }
            await refresh()
        }catch{message="Private operation held. Pairing, fresh proofs and the exact tested candidate are required."}
        #endif
    }
}
#if os(macOS)
enum HostBridge {
    static func decode<T: Decodable>(command: String,as type:T.Type) async throws -> T {
        let data=try await run(["command":command]);return try JSONDecoder().decode(type,from:data)
    }
    static func call(_ request:[String:String]) async throws -> [String:Any] {
        let data=try await run(request)
        guard let response=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw URLError(.cannotParseResponse)}
        return response
    }
    static func run(_ request:[String:String]) async throws -> Data {
        let input=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys])
        guard let script=Bundle.main.url(forResource:"alexus_host",withExtension:"py") else {throw URLError(.fileDoesNotExist)}
        return try await Task.detached(priority:.userInitiated) {
            let process=Process();let stdout=Pipe(),stdin=Pipe()
            let candidates=["/opt/homebrew/bin/python3","/usr/local/bin/python3","/usr/bin/python3"]
            guard let python=candidates.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else {throw URLError(.fileDoesNotExist)}
            process.executableURL=URL(fileURLWithPath:python);process.arguments=["-I","-B",script.path]
            process.standardInput=stdin;process.standardOutput=stdout;process.standardError=FileHandle.nullDevice
            var env=ProcessInfo.processInfo.environment
            env["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["ALEXUS_BUNDLE"]=Bundle.main.bundleURL.path
            env["ALEXUS_SOURCE_ROOT"]=Bundle.main.object(forInfoDictionaryKey:"ALEXUSSourceRoot") as? String
            process.environment=env
            try process.run();try stdin.fileHandleForWriting.write(contentsOf:input);try stdin.fileHandleForWriting.close()
            let data=stdout.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            guard process.terminationStatus==0,data.count<3_000_000 else {throw URLError(.badServerResponse)}
            return data
        }.value
    }
}
#endif
