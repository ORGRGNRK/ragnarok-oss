import SwiftUI
struct AgentDeployment:Decodable,Identifiable {
    struct Spec:Decodable {let project:String;let provider:String;let model:String}
    struct Step:Decodable {let title:String;let status:String;let observations:Int?;let evidence_sha256:String?}
    let id:String
    let kind:String
    let spec:Spec
    let status:String
    let phase:String
    let steps:[Step]
    let repair_id:String?
    let chat_id:String?
}
@MainActor final class DeploymentModel:ObservableObject {
    @Published var provider="alexus"
    @Published var selectedModel=""
    @Published var project="heimdall"
    @Published var kind="inspect"
    @Published var steps=""
    @Published var models:[String]=[]
    @Published var deployments:[AgentDeployment]=[]
    @Published var message=""
    @Published var busy=false
    func call(_ request:[String:String],owner:AppModel) async throws -> Data {
        #if os(macOS)
        return try await HostBridge.run(request)
        #else
        guard owner.ownerDeviceStatus=="approved" else{throw OwnerDeviceError.notPaired}
        return try await owner.ownerDevice.request("/v1/deployments",method:"POST",body:request)
        #endif
    }
    func refresh(owner:AppModel) async {
        struct List:Decodable{let deployments:[AgentDeployment]}
        do {deployments=try JSONDecoder().decode(List.self,from:await call(["command":"deployments_list"],owner:owner)).deployments}
        catch{message="Deployment connection unavailable. An approved iPad enrollment and reachable Mac are required."}
    }
    func discover(owner:AppModel) async {
        struct Models:Decodable{let models:[String]}
        let query=["command":"chat_models","provider":provider]
        do {
            let data:Data
            #if os(macOS)
            data=try await HostBridge.run(query)
            #else
            guard owner.ownerDeviceStatus=="approved" else{throw OwnerDeviceError.notPaired}
            data=try await owner.ownerDevice.request("/v1/chat",method:"POST",body:query)
            #endif
            models=try JSONDecoder().decode(Models.self,from:data).models
            if !models.contains(selectedModel){selectedModel=models.first(where:{$0.hasPrefix("qwen2.5-coder:3b")}) ?? models.first ?? ""}
            message=models.isEmpty ? "No local models discovered; no cloud fallback." : "Discovered \(models.count) local models."
        }catch{message="Model discovery unavailable. Editing authority was not inferred."}
    }
    func deploy(owner:AppModel) async {
        guard !busy else{return};busy=true;defer{busy=false}
        do {
            _ = try JSONDecoder().decode(AgentDeployment.self,from:await call(["command":"deployment_start","kind":kind,"project":project,"provider":provider,"model":selectedModel,"steps":steps],owner:owner))
            message="Deployment recorded. Each step needs new host evidence; model conclusions remain Unverified."
            await refresh(owner:owner)
        }catch{message="Deployment held. Check enrollment, model availability, active work and allowed project. No source deployment was authorized."}
    }
    func stop(_ deployment:AgentDeployment,owner:AppModel) async {
        do {_ = try await call(["command":"deployment_stop","id":deployment.id],owner:owner);message="Revocation recorded. No later stage is authorized. Repair-chain stop also revokes all repair work.";await refresh(owner:owner)}
        catch{message="Stop could not be confirmed. Use global force stop on the Mac if reachable."}
    }
    func resume(_ deployment:AgentDeployment,owner:AppModel) async {
        do {_ = try await call(["command":"deployment_resume","id":deployment.id],owner:owner);message="Resume requested from frozen host checkpoints. Completed steps are preserved; retry limits still apply.";await refresh(owner:owner)}
        catch{message="Resume held. Revocation, changed evidence or exhausted attempts require a new deployment."}
    }
}
struct DeploymentsView:View {
    @EnvironmentObject var owner:AppModel
    @StateObject private var model=DeploymentModel()
    var approved:Bool {
        #if os(macOS)
        return true
        #else
        return owner.ownerDeviceStatus=="approved"
        #endif
    }
    var body:some View {
        Page(title:"Deploy agents") {
            Panel {
                Text("Run from your iPad. Execute on your Mac.").font(.headline)
                Text("Deploy a local inspection agent with durable steps, or an isolated ALEXUS implement → verify → review chain. Applied repairs still need your fresh Enclave and external-key proofs.").foregroundStyle(.secondary)
                if !approved {Text("Pair and approve this iPad in Authority before deploying private agents.").foregroundStyle(.orange)}
                Picker("Deployment",selection:$model.kind){Text("Inspect · multiple steps").tag("inspect");Text("ALEXUS · staged repair chain").tag("repair")}
                    .onChange(of:model.kind){_,value in if value=="repair"{model.project="alexus"}else if model.provider=="codex"{model.provider="alexus"}}
                Picker("Project",selection:$model.project){Text("Heimdall").tag("heimdall");Text("ALEXUS").tag("alexus")}.disabled(model.kind=="repair")
                Picker("Provider",selection:$model.provider){Text("Alexus · Ollama").tag("alexus");Text("Mac · Ollama").tag("mac");if model.kind=="repair"{Text("Codex default").tag("codex")}}
                if model.provider != "codex" {
                    Picker("Model",selection:$model.selectedModel){Text("Select discovered model").tag("");ForEach(model.models,id:\.self){Text($0).tag($0)}}
                    Button("Discover models"){Task{await model.discover(owner:owner)}}.disabled(!approved || model.busy)
                }
                Text("One step or requirement per line · up to eight").font(.caption)
                TextEditor(text:$model.steps).frame(minHeight:110).accessibilityLabel("Agent deployment steps")
                Button("Deploy agent"){Task{await model.deploy(owner:owner)}}.disabled(!approved || model.busy || model.steps.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (model.provider != "codex" && model.selectedModel.isEmpty))
                Text("Inspection never changes source. Staged repairs may change only the two ALEXUS files allowed by your existing policy. Heimdall editing is not authorized through this lane.").font(.caption).foregroundStyle(.secondary)
                if model.busy{ProgressView()}
                Text(model.message).font(.caption)
            }
            HStack{Button("Refresh deployments"){Task{await model.refresh(owner:owner)}};Button("Global force stop & revoke",role:.destructive){Task{await owner.perform("stop")}}}
            ForEach(model.deployments){deployment in
                Panel {
                    HStack{Text(deployment.id.prefix(12)).font(.caption.monospaced());Spacer();Stamp(text:deployment.status)}
                    Text("\(deployment.spec.project) · \(deployment.spec.provider) · \(deployment.spec.model)").font(.caption.monospaced())
                    Text(deployment.phase)
                    ForEach(Array(deployment.steps.enumerated()),id:\.offset){index,step in
                        VStack(alignment:.leading,spacing:4){Text("\(index+1). \(step.title)");Text(step.status).font(.caption).foregroundStyle(Brand.gold);if let hash=step.evidence_sha256{Text(hash).font(.system(size:10,design:.monospaced)).textSelection(.enabled)}}
                    }
                    if let repair=deployment.repair_id{Text("Repair \(repair) · inspect and approve in Repairs").font(.caption).textSelection(.enabled)}
                    if let chat=deployment.chat_id{Text("Private transcript in Chat · \(chat.prefix(12))").font(.caption)}
                    Text("Observed steps do not independently verify every model conclusion.").font(.caption).foregroundStyle(.secondary)
                    if deployment.kind=="inspect" && deployment.status=="held"{Button("Resume from evidence checkpoint"){Task{await model.resume(deployment,owner:owner)}}}
                    Button(deployment.kind=="repair" ? "Force stop repair work & revoke" : "Stop inspection",role:.destructive){Task{await model.stop(deployment,owner:owner)}}
                }
            }
        }
        .task{await model.refresh(owner:owner);await model.discover(owner:owner)}
        .task{while !Task.isCancelled{do{try await Task.sleep(for:.seconds(3))}catch{return};await model.refresh(owner:owner)}}
    }
}
