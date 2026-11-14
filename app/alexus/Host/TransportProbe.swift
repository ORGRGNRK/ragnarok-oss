import Foundation
@main struct TransportProbe {
    static func main() async {
        do {
        let input=FileHandle.standardInput.readDataToEndOfFile()
        struct Fixture:Decodable{let link:PairingLink;let token:String}
        let fixture=try JSONDecoder().decode(Fixture.self,from:input)
        let data=try await PinnedOwnerTransport(link:fixture.link).request("/v1/pairing/challenge",token:fixture.token)
        let payload=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        guard payload?["rp"] as? String=="work.example.com" else{throw OwnerDeviceError.invalidResponse}
        let wrong=PairingLink(schema:fixture.link.schema,endpoint:fixture.link.endpoint,certificate_sha256:String(repeating:"0",count:64),certificate_expires_unix:fixture.link.certificate_expires_unix,pairing_token:"",pairing_expires_unix:0,rp:fixture.link.rp)
        var rejected=false
        do{_=try await PinnedOwnerTransport(link:wrong).request("/v1/pairing/challenge",token:fixture.token)}catch{rejected=true}
        guard rejected else{throw OwnerDeviceError.authorization}
        let expired=PairingLink(schema:fixture.link.schema,endpoint:fixture.link.endpoint,certificate_sha256:fixture.link.certificate_sha256,certificate_expires_unix:0,pairing_token:"",pairing_expires_unix:0,rp:fixture.link.rp)
        rejected=false
        do{_=try await PinnedOwnerTransport(link:expired).request("/v1/pairing/challenge",token:fixture.token)}catch{rejected=true}
        guard rejected else{throw OwnerDeviceError.authorization}
        let owner=await OwnerDevice()
        let enrollment=PairingLink(schema:fixture.link.schema,endpoint:"https://127.0.0.1:8849",certificate_sha256:fixture.link.certificate_sha256,certificate_expires_unix:fixture.link.certificate_expires_unix,pairing_token:fixture.token,pairing_expires_unix:Int(Date().timeIntervalSince1970)+120,rp:fixture.link.rp)
        _=try await owner.pairingLink(from:JSONEncoder().encode(enrollment))
        let stale=PairingLink(schema:enrollment.schema,endpoint:enrollment.endpoint,certificate_sha256:enrollment.certificate_sha256,certificate_expires_unix:enrollment.certificate_expires_unix,pairing_token:enrollment.pairing_token,pairing_expires_unix:0,rp:enrollment.rp)
        rejected=false
        do{try await owner.checkPairingConnection(from:JSONEncoder().encode(stale))}catch OwnerDeviceError.expiredLink{rejected=true}
        guard rejected else{throw OwnerDeviceError.authorization}
        func callback(_ body:[String:Any]) throws->URL {
            let data=try JSONSerialization.data(withJSONObject:body)
            return URL(string:"alexus-owner://auth#"+data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:""))!
        }
        let proof=try await OwnerDevice.decodeBrowserCallback(callback(["state":"fixture-state","ok":true,"proof":["fixture":true]]),state:"fixture-state")
        guard proof["fixture"] as? Bool==true else{throw OwnerDeviceError.invalidResponse}
        rejected=false
        do{_=try await OwnerDevice.decodeBrowserCallback(callback(["state":"wrong","ok":true,"proof":[:]]),state:"fixture-state")}catch OwnerDeviceError.browserCallback("callback-state-mismatch"){rejected=true}
        guard rejected else{throw OwnerDeviceError.authorization}
        rejected=false
        do{_=try await OwnerDevice.decodeBrowserCallback(callback(["state":"fixture-state","ok":false,"error":"NotAllowedError"]),state:"fixture-state")}catch OwnerDeviceError.browserRejected("NotAllowedError"){rejected=true}
        guard rejected else{throw OwnerDeviceError.authorization}
        rejected=false
        do{_=try await OwnerDevice.decodeBrowserCallback(callback(["state":"fixture-state","ok":false,"error":"untrusted private payload"]),state:"fixture-state")}catch OwnerDeviceError.browserRejected("unknown"){rejected=true}
        guard rejected else{throw OwnerDeviceError.authorization}
        print("Nine native assertions passed: five TLS/link checks and four browser callback/state/error checks. No hardware enrollment performed.")
        } catch {let value=error as NSError;print("Native TLS fixture error: "+value.domain+" code "+String(value.code)+" stream "+String(describing:value.userInfo["_kCFStreamErrorCodeKey"]));exit(1)}
    }
}
