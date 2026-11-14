import SwiftUI

struct LocalChat:Decodable {
    struct Message:Decodable {let role:String;let content:String}
    struct Action:Decodable {let tool:String;let result:String;let output_sha256:String}
    let id:String
    let provider:String
    let model:String
    let project:String
    let status:String
    let messages:[Message]
    let actions:[Action]
    let note:String?
}
struct LocalChatSummary:Decodable,Identifiable {
    let id:String
    let provider:String
    let model:String
    let project:String
    let status:String
}
@MainActor final class ChatModel:ObservableObject {
    @Published var provider="alexus"
    @Published var model=""
    @Published var project="heimdall"
    @Published var models:[String]=[]
    @Published var sessions:[LocalChatSummary]=[]
    @Published var current:LocalChat?
    @Published var text=""
    @Published var message=""
    @Published var busy=false
    @Published var discovering=false
    private var discoveryID=UUID()
    func call(_ request:[String:String],owner:AppModel) async throws -> Data {
        #if os(macOS)
        return try await HostBridge.run(request)
        #else
        guard owner.ownerDeviceStatus=="approved" else{throw OwnerDeviceError.notPaired}
        return try await owner.ownerDevice.request("/v1/chat",method:"POST",body:request)
        #endif
    }
    func discover(owner:AppModel) async {
        guard !busy,current == nil else{return}
        let requestID=UUID();discoveryID=requestID
        let requestedProvider=provider
        discovering=true;models=[];model=""
        message="Discovering models on \(requestedProvider == "mac" ? "this Mac" : "Alexus")…"
        defer{if discoveryID==requestID{discovering=false}}
        struct Models:Decodable{let models:[String];let observation:String?}
        do {
            let result=try JSONDecoder().decode(Models.self,from:await call(["command":"chat_models","provider":requestedProvider],owner:owner))
            guard discoveryID==requestID,provider==requestedProvider,!Task.isCancelled,current == nil else{return}
            models=result.models
            if !models.contains(model){model=models.first(where:{$0.hasPrefix("qwen2.5-coder:3b")}) ?? models.first ?? ""}
            message=models.isEmpty ? "No models discovered on \(requestedProvider == "mac" ? "this Mac" : "Alexus"). \(result.observation ?? "Unverified"). Check Ollama, connectivity and ALEXUS Local Network permission." : "Discovered \(models.count) models on \(requestedProvider == "mac" ? "this Mac" : "Alexus"). No cloud fallback."
            await refreshSessions(owner:owner)
        }catch{
            guard discoveryID==requestID,provider==requestedProvider,!Task.isCancelled,current == nil else{return}
            message="Model discovery unavailable on \(requestedProvider == "mac" ? "this Mac" : "Alexus"). No cloud fallback."
        }
    }
    func refreshSessions(owner:AppModel) async {
        struct Sessions:Decodable{let chats:[LocalChatSummary]}
        if let data=try? await call(["command":"chat_list"],owner:owner),let list=try? JSONDecoder().decode(Sessions.self,from:data){sessions=list.chats}
    }
    func load(_ id:String,owner:AppModel) async {
        do {
            current=try JSONDecoder().decode(LocalChat.self,from:await call(["command":"chat_get","id":id],owner:owner))
            if let current{provider=current.provider;model=current.model;project=current.project;if !models.contains(current.model){models.append(current.model)};if current.status != "working"{await refreshSessions(owner:owner)}}
        }catch{message="Chat state unavailable; no outcome inferred."}
    }
    func send(owner:AppModel) async {
        guard !busy,!discovering,current?.status != "working" else{return};busy=true;defer{busy=false}
        do {
            let request=["command":"chat_send","id":current?.id ?? "","provider":provider,"model":model,"project":project,"text":text]
            current=try JSONDecoder().decode(LocalChat.self,from:await call(request,owner:owner));text="";message="Running inside the structured harness."
            await refreshSessions(owner:owner)
        }catch{message="Chat held. Check model availability, active runs, force-stop state and enrollment. No cloud fallback."}
    }
    func stop(owner:AppModel) async {
        guard let current else{return}
        do {_ = try await call(["command":"chat_stop","id":current.id],owner:owner);message="Stop requested. Active model calls are bounded to 30 seconds; no subsequent tools are authorized."}
        catch{message="Stop request could not be confirmed. Use global Force stop if the Mac is reachable."}
    }
}
struct ChatView:View {
    @EnvironmentObject var owner:AppModel
    @StateObject private var chat=ChatModel()
    var body:some View {
        Page(title:"Local chat") {
            Panel {
                Text("Your model. Your structured harness.").font(.headline)
                Text("Plan → inspect → report evidence. Shell inspection is read-only. Model answers stay Unverified; host tool results are recorded separately. Changes use the existing repair pipeline and fresh hardware approval.").foregroundStyle(.secondary)
                Text("Mac runs commands; inference runs on the selected Mac or Alexus endpoint. No cloud fallback.").font(.caption)
                Picker("Provider",selection:$chat.provider){Text("Mac · Ollama").tag("mac");Text("Alexus · Ollama").tag("alexus")}.disabled(chat.current != nil)
                Picker("Project",selection:$chat.project){Text("Heimdall").tag("heimdall");Text("ALEXUS").tag("alexus")}.disabled(chat.current != nil)
                Picker("Model",selection:$chat.model){Text("Select discovered model").tag("");ForEach(chat.models,id:\.self){Text($0).tag($0)}}.disabled(chat.current != nil)
                HStack {
                    Button("Discover models"){Task{await chat.discover(owner:owner)}}.disabled(chat.busy || chat.discovering)
                    Button("New chat"){chat.current=nil;chat.message="";Task{await chat.discover(owner:owner)}}.disabled(chat.current?.status=="working")
                    Button("Refresh chats"){Task{await chat.refreshSessions(owner:owner)}}
                }
                ForEach(chat.sessions){session in Button("\(session.provider == "mac" ? "Mac" : "Alexus") · \(session.project) · \(session.model) · \(session.status) · \(session.id.prefix(8))"){Task{await chat.load(session.id,owner:owner)}}.disabled(chat.busy || chat.discovering || chat.current?.status=="working")}
            }
            if let current=chat.current {
                HStack{Stamp(text:current.status);Text(current.model).font(.caption.monospaced());Spacer();Button("Stop chat",role:.destructive){Task{await chat.stop(owner:owner)}}}
                ForEach(Array(current.messages.enumerated()),id:\.offset){_,message in
                    Panel {
                        Text(message.role=="assistant" ? "MODEL · UNVERIFIED" : message.role=="tool" ? "HOST TOOL RESULT" : "YOU").font(.caption.monospaced()).foregroundStyle(Brand.gold)
                        Text(message.content).font(message.role=="tool" ? .system(.caption,design:.monospaced):.body).textSelection(.enabled)
                        if message.role=="assistant" {
                            if current.project=="alexus" {
                                Button("Copy proposal and local model to Repairs") {owner.changeRequest=String(message.content.prefix(5000));owner.repairProvider=current.provider;owner.repairModel=current.model;owner.message="Proposal and local model copied to Repairs. Review before queueing; chat did not authorize a change."}
                            } else {
                                Text("Heimdall changes require its separately authorized edit workflow. This chat can inspect it.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let note=current.note{Text(note).foregroundStyle(.orange)}
                Text("\(current.actions.count) host tool observations · receipt hashes in Activity").font(.caption)
            }
            Panel {
                TextEditor(text:$chat.text).frame(minHeight:90).accessibilityLabel("Local chat message")
                HStack {
                    Button("Send"){Task{await chat.send(owner:owner)}}.disabled(chat.busy || chat.discovering || chat.model.isEmpty || chat.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || chat.current?.status=="working")
                    if chat.busy || chat.discovering || chat.current?.status=="working"{ProgressView()}
                    Button("Global force stop & revoke",role:.destructive){Task{await owner.perform("stop")}}
                }
                Text(chat.message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id:chat.provider){await chat.discover(owner:owner);await chat.refreshSessions(owner:owner)}
        .task(id:chat.current?.id){
            while !Task.isCancelled {
                do{try await Task.sleep(for:.seconds(2))}catch{return}
                if let current=chat.current,current.status=="working"{await chat.load(current.id,owner:owner)}
            }
        }
    }
}
