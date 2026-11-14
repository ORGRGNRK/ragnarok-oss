import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Brand {
    static let gold=Color(red:201/255,green:168/255,blue:76/255)
    static let background=Color(red:13/255,green:13/255,blue:13/255)
    static let panel=Color(red:17/255,green:17/255,blue:17/255)
    static let line=Color.white.opacity(0.13)
}
struct BrandMark:View {
    var body:some View {
        if let url=Bundle.main.url(forResource:"Ragnarok",withExtension:"png") {
            #if os(macOS)
            if let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit().accessibilityLabel("Ragnarok icon")}
            #else
            if let image=UIImage(contentsOfFile:url.path){Image(uiImage:image).resizable().scaledToFit().accessibilityLabel("Ragnarok icon")}
            #endif
        }
    }
}
struct RootView: View {
    @EnvironmentObject var model:AppModel
    var body: some View {
        TabView {
            OriginView().tabItem{Label("ALEXUS",systemImage:"circle.hexagongrid")}
            ProjectsView().tabItem{Label("Work",systemImage:"square.grid.2x2")}
            ChatView().tabItem{Label("Chat",systemImage:"bubble.left.and.bubble.right")}
            DeploymentsView().tabItem{Label("Agents",systemImage:"person.3.sequence")}
            ActivityView().tabItem{Label("Activity",systemImage:"list.bullet.rectangle")}
            RepairsView().tabItem{Label("Repairs",systemImage:"wrench.and.screwdriver")}
            SecurityView().tabItem{Label("Authority",systemImage:"key")}
        }.tint(Brand.gold).background(Brand.background)
        .task{await model.refresh()}
        .overlay(alignment:.bottom){if !model.message.isEmpty {Text(model.message).font(.caption).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding().onTapGesture{model.message=""}}}
    }
}
struct Page<Content:View>: View {
    let title:String
    @ViewBuilder let content:Content
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24){
                    HStack(spacing:12){BrandMark().frame(width:44,height:44);Text("RAGNAROK / ALEXUS").font(.system(size:11,design:.monospaced)).tracking(2).foregroundStyle(Brand.gold);Spacer()}
                    Text(title.uppercased()).font(.system(size:28,weight:.light,design:.monospaced)).tracking(3).foregroundStyle(Brand.gold)
                    content
                }.padding(24).frame(maxWidth:1100,alignment:.leading).frame(maxWidth:.infinity)
            }.background(Brand.background).navigationTitle(title)
        }
    }
}
struct Panel<Content:View>:View {
    @ViewBuilder let content:Content
    var body:some View{VStack(alignment:.leading,spacing:12){content}.frame(maxWidth:.infinity,alignment:.leading).padding(20).background(Brand.panel,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(Brand.line))}
}
struct Stamp:View {
    let text:String
    var body:some View{Text(text).font(.system(size:10,design:.monospaced)).foregroundStyle(text=="Unverified" ? .orange:Brand.gold).padding(.horizontal,10).padding(.vertical,5).overlay(Capsule().stroke(Brand.line))}
}
struct OriginView:View {
    @EnvironmentObject var model:AppModel
    var body:some View{Page(title:"ALEXUS"){
        Text(model.foundation?.quote ?? "Foundation quote unavailable.").font(.system(size:24,weight:.light,design:.monospaced)).foregroundStyle(Brand.gold).textSelection(.enabled)
        Text("CLR — Rgnrk · Origin and Branch Theory").font(.caption.monospaced()).foregroundStyle(.secondary)
        Text("Your work. Its evidence. Your authority.").font(.title2)
        Panel{Text("A working surface for the Ragnarok system.").font(.headline);Text("Browse the catalog, inspect observed agent states and receipts, and prepare a tested repair. Every applied repair needs fresh Enclave and external-key approval.");Stamp(text:"Runtime Unverified")}
        Panel{Text(model.foundation?.foundation_title ?? "Ragnarok Foundation").font(.caption.monospaced()).foregroundStyle(Brand.gold);Text(model.foundation?.origin_quote ?? "");ForEach(model.foundation?.theory ?? [],id:\.self){Text($0).foregroundStyle(.secondary)}}
        Text("Source: selected Foundation passages. Philosophy is not a runtime verification claim.").font(.caption).foregroundStyle(.secondary)
    }}
}
struct ProjectsView:View {
    @EnvironmentObject var model:AppModel
    var body:some View{Page(title:"Work"){
        HStack{Text(model.snapshot).font(.caption.monospaced()).foregroundStyle(.secondary);Spacer();Button("Refresh"){Task{await model.refresh()}}}
        TextField("Search projects and processes",text:$model.query).textFieldStyle(.roundedBorder)
        Text("\(model.filtered.count) catalog entries · source inventories can overlap.").font(.caption).foregroundStyle(.secondary)
        LazyVStack(spacing:12){ForEach(model.filtered){project in NavigationLink{ProjectView(project:project)} label:{Panel{HStack{Text(project.category.uppercased()).font(.caption.monospaced()).foregroundStyle(Brand.gold);Spacer();Stamp(text:project.runtime)};Text(project.title).font(.title3).foregroundStyle(.primary);Text(project.description).font(.callout).foregroundStyle(.secondary);Text(project.status).font(.caption.monospaced())}}.buttonStyle(.plain)}}
    }}
}
struct ProjectView:View {
    let project:PublicProject
    var body:some View{Page(title:project.title){Text(project.description);Stamp(text:project.runtime);Text(project.path).font(.caption.monospaced()).textSelection(.enabled);ForEach(project.checks){check in Panel{Text(check.name).font(.headline);Text("\(check.result) · \(check.cases) cases").foregroundStyle(Brand.gold);Text(check.checked_at).font(.caption.monospaced());Text(check.scope).foregroundStyle(.secondary)}};ForEach(project.limits,id:\.self){Text($0).font(.callout).foregroundStyle(.secondary)};Text("A selected check does not verify the whole product.").font(.caption)}}
}
struct ActivityView:View {
    @EnvironmentObject var model:AppModel
    var body:some View{Page(title:"Activity"){
        Button("Refresh observations"){Task{await model.refresh()}}
        Panel {
            Text("Current Heimdall project").font(.headline)
            if let project=model.host?.heimdall {
                Text(project.name).foregroundStyle(Brand.gold)
                Text(project.source).font(.caption.monospaced()).textSelection(.enabled)
                Text("Observed: "+project.observed_at).font(.caption.monospaced())
                Text("Revision: "+project.revision).font(.caption.monospaced()).textSelection(.enabled)
                Text(project.changed_entries.map{"\($0) changed entries in Heimdall"} ?? "Git state Unverified")
                Text(project.app_present ? "Ragnarok app found on the Mac" : "Ragnarok app not found at its expected location")
                Text(project.error_log_present ? "App error log present · last modified "+(project.error_log_updated_at ?? "Unverified") : "No app error log observed")
                Text("Log presence does not establish errors or their cause. Agent states below come from the same Ragnarok run store.").font(.caption).foregroundStyle(.secondary)
                Stamp(text:"Runtime "+project.runtime)
                #if os(macOS)
                Link("Open Ragnarok",destination:URL(string:"ragnarok://open")!)
                #endif
            } else {
                Text("Connect to your enrolled Mac to observe its Heimdall project.").foregroundStyle(.secondary)
            }
            Text("This connection observes Heimdall. The ALEXUS repair lane still targets ALEXUS only; it does not authorize Heimdall edits.").font(.caption).foregroundStyle(.secondary)
        }
        Panel{Text("Agents").font(.headline);if let agents=model.host?.agents,!agents.isEmpty{ForEach(agents){agent in HStack{Text(agent.who);Spacer();Text(agent.status).font(.caption.monospaced());Text(agent.id.prefix(12)).font(.caption.monospaced()).foregroundStyle(.secondary)}}}else{Text("No local agent observation is available on this device.").foregroundStyle(.secondary)}}
        Panel{Text("Repair receipts").font(.headline);Text("Chain integrity: "+(model.host?.receipt_integrity ?? "Unverified")).font(.caption.monospaced());if let receipts=model.host?.receipts,!receipts.isEmpty{ForEach(receipts.reversed()){receipt in VStack(alignment:.leading,spacing:6){Text("\(receipt.sequence) · \(receipt.action)");Text(receipt.timestamp).font(.caption.monospaced()).foregroundStyle(.secondary);Text(receipt.hash).font(.system(size:10,design:.monospaced)).textSelection(.enabled)}.padding(.vertical,6)}}else{Text("No local repair receipts observed. No fixture is presented as a real event.").foregroundStyle(.secondary)}}
    }}
}
struct RepairsView:View {
    @EnvironmentObject var model:AppModel
    @State private var confirming:HostRepair?
    var controlsAvailable:Bool {
        #if os(macOS)
        return true
        #else
        return model.ownerDeviceStatus=="approved"
        #endif
    }
    var body:some View {
        Page(title:"Repair control") {
            Panel {
                Text("Implement → verify → review → your approval").font(.headline)
                Text("A candidate is staged and checked on the Mac. Applying it requires fresh device-Enclave and external-key proofs bound to the exact candidate. Force stop revokes pending approvals.").foregroundStyle(.secondary)
            }
            if controlsAvailable {
                Panel {
                    Text("Request a change").font(.headline)
                    Text("ALEXUS source only · provider: \(model.repairProvider) · model: \(model.repairModel.isEmpty ? "Codex default" : model.repairModel)").font(.caption.monospaced())
                    Text("Copy an ALEXUS proposal from Chat to select its local model for both implementation and independent review.").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text:$model.changeRequest).frame(minHeight:90).accessibilityLabel("Change request")
                    HStack {
                        Button("Queue staged repair"){Task{await model.perform("queue")}}
                            .disabled(model.busy||model.changeRequest.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        if model.busy{ProgressView()}
                    }
                    Text("Requests stay on your private Mac connection. Do not include secrets.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh"){Task{await model.refresh()}}
                    Button("Force stop & revoke",role:.destructive){Task{await model.perform("stop")}}
                }
                ForEach(model.host?.repairs ?? []) { repair in
                    Panel {
                        HStack{Text(repair.id.prefix(12)).font(.caption.monospaced());Spacer();Stamp(text:repair.status)}
                        Text(repair.note)
                        if let targets=repair.targets {Text("Targets: "+targets.joined(separator:", ")).font(.caption.monospaced())}
                        if let files=repair.changed_files {Text(files.joined(separator:"\n")).font(.caption.monospaced())}
                        if let hash=repair.candidate_sha256 {Text(hash).font(.system(size:10,design:.monospaced)).textSelection(.enabled)}
                        HStack {
                            #if os(macOS)
                            if repair.status=="queued" {Button("Stage, verify, review"){Task{await model.perform("stage",id:repair.id)}}.disabled(model.busy)}
                            #endif
                            if repair.status=="awaiting_owner" {
                                Button("Inspect diff"){Task{await model.perform("diff",id:repair.id)}}
                                Button("Approve this repair"){confirming=repair}.disabled(model.busy||model.inspectedRepairID != repair.id)
                            }
                        }
                    }
                }
                if !model.diff.isEmpty {
                    Panel{Text("Candidate diff").font(.headline);Text(model.diff).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}
                }
            } else {
                Panel{Text("Pair this device first").font(.headline);Text("Import a pairing file in Authority, provide phone-Enclave and external-key proofs, then approve the device on your enrolled Mac. Unpaired devices have no editing authority.").foregroundStyle(.secondary)}
            }
        }
        .confirmationDialog("Approve exactly this tested repair?",isPresented:Binding(get:{confirming != nil},set:{if !$0{confirming=nil}}),titleVisibility:.visible) {
            if let repair=confirming {Button("Biometric approval, then security key"){confirming=nil;Task{await model.perform("apply",id:repair.id)}}}
        } message:{Text("Both fresh proofs are required. The selected Mac and iOS builds will be installed; the iOS app may relaunch. Rejection, cancellation, changed artifacts or a revoked epoch prevents application.")}
    }
}
struct SecurityView:View {
    @EnvironmentObject var model:AppModel
    @State private var importing=false
    var body:some View {
        Page(title:"Your authority") {
            Panel {
                Text("Fresh authorization. Every repair.").font(.headline)
                Text("Secure Enclave AND an enrolled external security key. No password fallback. No reusable repair session.").foregroundStyle(Brand.gold)
                Stamp(text:"Physical flow Unverified")
            }
            #if os(macOS)
            Panel {
                Text("Mac owner enrollment").font(.headline)
                Text(model.host?.enclave_enrolled == true ? "Enclave profile files present. Fresh signature still required." : "No Enclave enrollment observed.")
                Picker("External key",selection:$model.selectedKey){ForEach(model.host?.external_profiles ?? ["yubikey-primary","utrust-spare"],id:\.self){Text($0).tag($0)}}
                Text("Profile presence does not prove a key is connected.").font(.caption).foregroundStyle(.secondary)
            }
            Panel {
                Text("Pair your iPhone or iPad").font(.headline)
                Text("Share a five-minute pairing file directly with your phone. It contains a private capability; keep it off public sites and chats.").font(.callout).foregroundStyle(.secondary)
                Button("Create private pairing file"){Task{await model.perform("pairing_start")}}.disabled(model.busy)
                if let url=model.pairingFile{ShareLink("Share pairing file",item:url)}
                Button("Refresh device requests"){Task{await model.refreshDevices()}}
                ForEach(model.pairedDevices){device in
                    VStack(alignment:.leading,spacing:8){
                        HStack{Text(device.id.prefix(12));Spacer();Stamp(text:device.status)}
                        Text(device.fingerprint).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
                        if device.status=="pending"{Button("Approve this device with both keys"){Task{await model.perform("pairing_approve",id:device.id)}}.disabled(model.busy)}
                        if device.status=="approved"{Button("Revoke device",role:.destructive){Task{await model.perform("pairing_revoke",id:device.id)}}}
                    }.padding(.vertical,8)
                }
            }
            #else
            Panel {
                Text("Private Mac pairing").font(.headline)
                Stamp(text:model.ownerDeviceStatus)
                Text(model.ownerDeviceFingerprint).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
                Text("Compare this fingerprint with the pending request on your Mac before approving.").font(.caption).foregroundStyle(.secondary)
                Text("Create the pairing file on your Mac. Import it here, authorize with this device's Enclave and your physical security key, then approve this device on the Mac.").foregroundStyle(.secondary)
                Button("Import pairing file"){importing=true}.disabled(model.busy)
                if let url=model.transferredPairingFile,model.ownerDeviceStatus != "approved" {
                    Button("Check Mac connection with transferred file"){Task{await model.checkPairingConnection(file:url)}}.disabled(model.busy)
                    Button("Enroll this iPad with transferred file"){Task{await model.pairPhone(file:url)}}.disabled(model.busy)
                }
                if !model.pairingDiagnostic.isEmpty{Text(model.pairingDiagnostic).font(.callout).foregroundStyle(Brand.gold).textSelection(.enabled)}
                Button("Refresh pairing and host state"){Task{await model.refresh()}}
                if model.busy{ProgressView()}
                Text("An iOS simulator cannot stand in for a physical Secure Enclave or external-key touch.").font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Panel {
                Text("Self-healing status").font(.headline)
                Text(model.host?.automation ?? "Unverified on this device")
                Text("The automatic lane cannot change its host, authorization policy or frozen harness. Those require a separate owner-reviewed update.").foregroundStyle(.secondary)
            }
            Panel {
                Text("Security boundary").font(.headline)
                Text("These gates control this app's repair and release workflow. They do not isolate it from malicious software running as your OS account, or stop that account from editing source directly. Remote hardware attestation remains Unverified.").foregroundStyle(.secondary)
            }
            Link("Open inspectable Proof Lab",destination:URL(string:"https://demo.rgnrk.co/")!)
        }
        .task{await model.refreshDevices()}
        .fileImporter(isPresented:$importing,allowedContentTypes:[.json]){result in
            if case .success(let url)=result{Task{await model.pairPhone(file:url)}}
        }
    }
}
