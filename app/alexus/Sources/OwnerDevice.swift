import Foundation
import CryptoKit
import LocalAuthentication
import Security
import AuthenticationServices
#if os(iOS)
import UIKit
#endif

enum OwnerDeviceError: Error { case unavailable, invalidLink, expiredLink, notPaired, invalidResponse, httpStatus(Int), keychain, authorization, browserSession(Int), browserCallback(String), browserRejected(String) }
struct PairingLink: Codable {
    let schema:String
    let endpoint:String
    let certificate_sha256:String
    let certificate_expires_unix:Int
    var pairing_token:String
    let pairing_expires_unix:Int
    let rp:String
}
struct OwnerConnection: Codable {
    var link:PairingLink
    let device_token:String
    let device_id:String
    let fingerprint:String
    var status:String
}
private enum OwnerVault {
    static let service="co.rgnrk.alexus.owner-device"
    static func read(_ account:String)->Data? {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?;guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess else{return nil};return result as? Data
    }
    static func save(_ data:Data,account:String) throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let update:[String:Any]=[kSecValueData as String:data]
        let status=SecItemUpdate(query as CFDictionary,update as CFDictionary)
        if status==errSecItemNotFound {
            var item=query;item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else{throw OwnerDeviceError.keychain}
        } else if status != errSecSuccess {throw OwnerDeviceError.keychain}
    }
}
final class PinnedOwnerTransport:NSObject,URLSessionDelegate,URLSessionTaskDelegate,@unchecked Sendable {
    let link:PairingLink
    init(link:PairingLink){self.link=link}
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void){
        #if ALEXUS_TRANSPORT_FIXTURE
        print("TLS fixture trust challenge received")
        #endif
        guard challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust,
              Date().timeIntervalSince1970<Double(link.certificate_expires_unix),let trust=challenge.protectionSpace.serverTrust,
              let certificates=SecTrustCopyCertificateChain(trust) as? [SecCertificate],let certificate=certificates.first else{completionHandler(.cancelAuthenticationChallenge,nil);return}
        let data=SecCertificateCopyData(certificate) as Data
        let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        guard hash==link.certificate_sha256 else{completionHandler(.cancelAuthenticationChallenge,nil);return}
        // Exact owner-imported leaf pin is the trust anchor for this private endpoint only.
        SecTrustSetAnchorCertificates(trust,[certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust,true)
        SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,nil))
        #if ALEXUS_TRANSPORT_FIXTURE
        var fixtureError:CFError?
        let fixtureTrust=SecTrustEvaluateWithError(trust,&fixtureError)
        print("TLS fixture pin matched; trust="+String(fixtureTrust)+" error="+String(describing:fixtureError.map{CFErrorGetCode($0)}))
        #endif
        guard SecTrustEvaluateWithError(trust,nil) else{completionHandler(.cancelAuthenticationChallenge,nil);return}
        completionHandler(.useCredential,URLCredential(trust:trust))
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
    func request(_ path:String,method:String="GET",token:String,body:[String:Any]?=nil) async throws -> Data {
        guard path.hasPrefix("/v1/"),let base=URL(string:link.endpoint),base.scheme=="https",base.user==nil,base.password==nil,let url=URL(string:path,relativeTo:base) else{throw OwnerDeviceError.invalidLink}
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:25);request.httpMethod=method
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let body=body{request.httpBody=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys])}
        let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=25
        let session=URLSession(configuration:configuration,delegate:self,delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        let(data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse else{throw OwnerDeviceError.invalidResponse}
        guard http.statusCode==200 else{throw OwnerDeviceError.httpStatus(http.statusCode)}
        guard data.count<2_000_000 else{throw OwnerDeviceError.invalidResponse}
        return data
    }
}
@MainActor final class OwnerDevice:NSObject,ASWebAuthenticationPresentationContextProviding {
    private(set) var pairingStage="Read pairing file"
    func beginPairingFileRead(){pairingStage="Read pairing file"}
    private var browserSession:ASWebAuthenticationSession?
    private var context:LAContext?
    var connection:OwnerConnection? {
        guard let data=OwnerVault.read("connection") else{return nil}
        return try? JSONDecoder().decode(OwnerConnection.self,from:data)
    }
    var status:String{connection?.status ?? "Unpaired"}
    private func save(_ value:OwnerConnection) throws{try OwnerVault.save(JSONEncoder().encode(value),account:"connection")}
    private func key(allowCreate:Bool=false) async throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else{throw OwnerDeviceError.unavailable}
        let context=LAContext();context.localizedFallbackTitle="";context.touchIDAuthenticationAllowableReuseDuration=0;self.context=context
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,localizedReason:"Authorize this exact ALEXUS owner action") else{throw OwnerDeviceError.authorization}
        if let reference=OwnerVault.read("enclave-reference") {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation:reference,authenticationContext:context)
        }
        guard allowCreate else{throw OwnerDeviceError.unavailable}
        var error:Unmanaged<CFError>?
        guard let access=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenUnlockedThisDeviceOnly,[.privateKeyUsage,.biometryCurrentSet],&error) else{throw OwnerDeviceError.authorization}
        let key=try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable:false,accessControl:access,authenticationContext:context)
        try OwnerVault.save(key.dataRepresentation,account:"enclave-reference");return key
    }
    func presentationAnchor(for session:ASWebAuthenticationSession)->ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap{$0.windows}.first(where:{$0.isKeyWindow}) ?? UIWindow()
        #else
        return ASPresentationAnchor()
        #endif
    }
    private func browserProof(operation:String,challenge:Data,credentialID:Data?=nil,userID:Data?=nil) async throws->[String:Any] {
        guard browserSession==nil else{throw OwnerDeviceError.browserCallback("session-already-active")}
        let state=UUID().uuidString+UUID().uuidString
        var request:[String:Any]=["v":1,"state":state,"operation":operation,"challenge":challenge.base64EncodedString()]
        if let credentialID=credentialID{request["credential_id"]=credentialID.base64EncodedString()}
        if let userID=userID{request["user_id"]=userID.base64EncodedString()}
        let data=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys])
        let fragment=data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        guard let url=URL(string:"https://work.example.com/owner-auth#"+fragment) else{throw OwnerDeviceError.invalidResponse}
        return try await withCheckedThrowingContinuation { continuation in
            var finished=false
            let completion:ASWebAuthenticationSession.CompletionHandler={callback,error in
                Task{@MainActor in
                    guard !finished else{return};finished=true
                    self.browserSession=nil
                    if let error=error{continuation.resume(throwing:OwnerDeviceError.browserSession((error as NSError).code));return}
                    do {continuation.resume(returning:try Self.decodeBrowserCallback(callback,state:state))}
                    catch{continuation.resume(throwing:error)}
                }
            }
            let session:ASWebAuthenticationSession
            if #available(iOS 17.4,macOS 14.4,*){session=ASWebAuthenticationSession(url:url,callback:.customScheme("alexus-owner"),completionHandler:completion)}
            else{session=ASWebAuthenticationSession(url:url,callbackURLScheme:"alexus-owner",completionHandler:completion)}
            self.browserSession=session;session.presentationContextProvider=self;session.prefersEphemeralWebBrowserSession=true
            if !session.start(){finished=true;self.browserSession=nil;continuation.resume(throwing:OwnerDeviceError.browserCallback("session-did-not-start"))}
        }
    }
    static func decodeBrowserCallback(_ callback:URL?,state:String) throws->[String:Any] {
        guard let callback=callback,callback.scheme=="alexus-owner",callback.host=="auth",let fragment=callback.fragment else{throw OwnerDeviceError.browserCallback("missing-or-invalid-callback")}
        guard fragment.count<100000 else{throw OwnerDeviceError.browserCallback("callback-too-large")}
        var text=fragment.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        text += String(repeating:"=",count:(4-text.count%4)%4)
        guard let raw=Data(base64Encoded:text),let result=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any] else{throw OwnerDeviceError.browserCallback("invalid-callback-data")}
        guard result["state"] as? String==state else{throw OwnerDeviceError.browserCallback("callback-state-mismatch")}
        guard result["ok"] as? Bool==true else{
            let known=["cancelled","NotAllowedError","NotSupportedError","SecurityError","InvalidStateError","AbortError","ConstraintError","TypeError","unavailable","external-required"]
            let code=result["error"] as? String ?? "unknown"
            throw OwnerDeviceError.browserRejected(known.contains(code) ? code:"unknown")
        }
        guard let proof=result["proof"] as? [String:Any] else{throw OwnerDeviceError.browserCallback("missing-proof")}
        return proof
    }
    private func externalAssertion(challenge:Data,credentialID:Data) async throws->[String:Any]{
        try await browserProof(operation:"get",challenge:challenge,credentialID:credentialID)
    }
    func pairingLink(from data:Data) throws -> PairingLink {
        pairingStage="Validate pairing file"
        guard data.count<12000 else{throw OwnerDeviceError.invalidLink}
        let link=try JSONDecoder().decode(PairingLink.self,from:data)
        guard Date().timeIntervalSince1970<Double(link.pairing_expires_unix) else{throw OwnerDeviceError.expiredLink}
        guard link.schema=="alexus-bridge:v1",link.rp=="work.example.com",link.certificate_sha256.count==64,link.pairing_token.count>=32,
              let endpoint=URL(string:link.endpoint),endpoint.scheme=="https",endpoint.port==8849,endpoint.user==nil,endpoint.password==nil,endpoint.path.isEmpty else{throw OwnerDeviceError.invalidLink}
        return link
    }
    func pairingFailure(_ error:Error)->String {
        let detail:String
        if let own=error as? OwnerDeviceError {
            switch own {
            case .expiredLink:detail="Pairing file expired. Create and transfer a fresh file from the Mac."
            case .invalidLink:detail="Pairing file is invalid. Use the file generated by your Mac."
            case .unavailable:detail="Required enrolled device key or Secure Enclave is unavailable."
            case .keychain:detail="The device could not save its private enrollment reference."
            case .httpStatus(let status):detail="The Mac rejected this private request (HTTP \(status)). No server response body was displayed."
            case .browserSession(let code):detail="Apple browser session failed (code \(code))."
            case .browserCallback(let code):detail="Browser callback failed: \(code)."
            case .browserRejected(let code):detail="Security-key browser reported: \(code). This code alone does not establish the cause."
            case .authorization:detail="The biometric or security-key action was cancelled, refused, or returned an invalid proof."
            default:detail="The expected private response did not validate."
            }
        } else {
            let value=error as NSError
            let domains=[NSURLErrorDomain,"com.apple.LocalAuthentication","com.apple.AuthenticationServices.WebAuthenticationSession","NSOSStatusErrorDomain","NSCocoaErrorDomain"]
            let domain=domains.contains(value.domain) ? value.domain : "Device operation"
            detail="\(domain) code \(value.code). No error payload or credentials were logged."
        }
        return "Stopped at: \(pairingStage). \(detail) No authority was granted."
    }
    func checkPairingConnection(from data:Data) async throws {
        let link=try pairingLink(from:data);pairingStage="Connect to Mac (pinned TLS and pairing challenge)"
        let response=try await PinnedOwnerTransport(link:link).request("/v1/pairing/challenge",token:link.pairing_token)
        guard let info=try JSONSerialization.jsonObject(with:response) as? [String:Any],info["rp"] as? String==link.rp,let challenge=info["challenge_b64"] as? String,Data(base64Encoded:challenge)?.count==32 else{throw OwnerDeviceError.invalidResponse}
        pairingStage="Mac connection verified"
    }
    func pair(from data:Data) async throws {
        let link=try pairingLink(from:data)
        let transport=PinnedOwnerTransport(link:link)
        pairingStage="Connect to Mac (pinned TLS and pairing challenge)"
        let response=try await transport.request("/v1/pairing/challenge",token:link.pairing_token)
        guard let info=try JSONSerialization.jsonObject(with:response) as? [String:Any],let bootstrapText=info["challenge_b64"] as? String,let bootstrapChallenge=Data(base64Encoded:bootstrapText) else{throw OwnerDeviceError.invalidResponse}
        pairingStage="Device biometric approval and Secure Enclave key"
        let deviceKey=try await key(allowCreate:true);let publicDER=deviceKey.publicKey.derRepresentation
        pairingStage="Register physical security key in browser"
        let registration=try await browserProof(operation:"create",challenge:bootstrapChallenge,userID:Data(SHA256.hash(data:publicDER)))
        guard let attestation=registration["attestation"] as? String,let clientData=registration["client_data"] as? String,
              let credentialText=registration["credential_id"] as? String,let credentialID=Data(base64Encoded:credentialText) else{throw OwnerDeviceError.invalidResponse}
        var tokenBytes=Data(count:48)
        guard tokenBytes.withUnsafeMutableBytes({SecRandomCopyBytes(kSecRandomDefault,48,$0.baseAddress!)})==errSecSuccess else{throw OwnerDeviceError.authorization}
        let token=tokenBytes.base64EncodedString()
        let tokenHash=SHA256.hash(data:Data(token.utf8)).map{String(format:"%02x",$0)}.joined()
        pairingStage="Validate security-key registration on Mac"
        let prepared=try await transport.request("/v1/pairing/prepare",method:"POST",token:link.pairing_token,body:["device_public_der":publicDER.base64EncodedString(),"device_token_sha256":tokenHash,"attestation":attestation,"client_data":clientData])
        guard let proposal=try JSONSerialization.jsonObject(with:prepared) as? [String:Any],let id=proposal["id"] as? String,let messageText=proposal["message_b64"] as? String,let message=Data(base64Encoded:messageText),let challengeText=proposal["challenge_b64"] as? String,let challenge=Data(base64Encoded:challengeText) else{throw OwnerDeviceError.invalidResponse}
        guard Data(SHA256.hash(data:message))==challenge,
              let manifest=try JSONSerialization.jsonObject(with:message) as? [String:Any],manifest["id"] as? String==id,
              manifest["device_public_sha256"] as? String==SHA256.hash(data:publicDER).map({String(format:"%02x",$0)}).joined(),
              manifest["device_token_sha256"] as? String==tokenHash,
              manifest["server_certificate_sha256"] as? String==link.certificate_sha256 else{throw OwnerDeviceError.invalidResponse}
        pairingStage="Fresh device biometric signature"
        let signingKey=try await key();guard signingKey.publicKey.derRepresentation==publicDER else{throw OwnerDeviceError.authorization}
        let signature=try signingKey.signature(for:message).derRepresentation
        pairingStage="Fresh physical security-key assertion in browser"
        let external=try await externalAssertion(challenge:challenge,credentialID:credentialID)
        pairingStage="Submit both enrollment proofs to Mac"
        _=try await transport.request("/v1/pairing/submit",method:"POST",token:link.pairing_token,body:["id":id,"enclave_signature":signature.base64EncodedString(),"external":external])
        pairingStage="Save private device connection"
        try save(OwnerConnection(link:link,device_token:token,device_id:id,fingerprint:SHA256.hash(data:publicDER).map{String(format:"%02x",$0)}.joined(),status:"pending"))
        pairingStage="Pending Mac owner approval"
    }
    func refreshPairing() async throws {
        guard var connection=connection else{throw OwnerDeviceError.notPaired}
        let data=try await PinnedOwnerTransport(link:connection.link).request("/v1/pairing/status",token:connection.device_token)
        guard let result=try JSONSerialization.jsonObject(with:data) as? [String:Any],let status=result["status"] as? String,result["id"] as? String==connection.device_id else{throw OwnerDeviceError.invalidResponse}
        connection.status=status
        if status=="approved"{connection.link.pairing_token=""}
        try save(connection)
    }
    func request(_ path:String,method:String="GET",body:[String:Any]?=nil) async throws -> Data {
        guard let connection=connection,connection.status=="approved" else{throw OwnerDeviceError.notPaired}
        return try await PinnedOwnerTransport(link:connection.link).request(path,method:method,token:connection.device_token,body:body)
    }
    func approveRepair(id:String,candidateSHA256:String) async throws {
        let data=try await request("/v1/repairs/"+id+"/challenge",method:"POST",body:[:])
        guard let proposal=try JSONSerialization.jsonObject(with:data) as? [String:Any],proposal["id"] as? String==id,let messageText=proposal["message_b64"] as? String,let message=Data(base64Encoded:messageText),let challengeText=proposal["challenge_b64"] as? String,let challenge=Data(base64Encoded:challengeText),let credentialText=proposal["credential_id"] as? String,let credential=Data(base64Encoded:credentialText) else{throw OwnerDeviceError.invalidResponse}
        guard Data(SHA256.hash(data:message))==challenge,
              let manifest=try JSONSerialization.jsonObject(with:message) as? [String:Any],manifest["repair_id"] as? String==id,
              manifest["candidate_sha256"] as? String==candidateSHA256,
              manifest["action"] as? String=="apply-source-and-install-selected-targets",
              let expiry=manifest["expires_unix"] as? Int,Double(expiry)>Date().timeIntervalSince1970,Double(expiry)-Date().timeIntervalSince1970<=180 else{throw OwnerDeviceError.invalidResponse}
        let deviceKey=try await key();let signature=try deviceKey.signature(for:message).derRepresentation
        let external=try await externalAssertion(challenge:challenge,credentialID:credential)
        _=try await request("/v1/repairs/"+id+"/apply",method:"POST",body:["enclave_signature":signature.base64EncodedString(),"external":external])
    }
    func cancelPending(){context?.invalidate();context=nil;browserSession?.cancel();browserSession=nil}
}
