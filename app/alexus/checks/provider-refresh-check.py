#!/usr/bin/env python3
"""Compile the real ChatModel with a controlled host; no model/network/private state."""
from pathlib import Path
import subprocess,tempfile
source=(Path(__file__).resolve().parents[1]/'Sources/Chat.swift').read_text().split('struct ChatView:View {')[0]
harness=r'''
@MainActor final class AppModel {}
@MainActor enum HostBridge {
 static var handler: ([String:String]) async throws -> Data = {_ in Data()}
 static func run(_ request:[String:String]) async throws -> Data {try await handler(request)}
}
@main struct Checks {
 @MainActor static func main() async throws {
  let owner=AppModel(), model=ChatModel()
  var old:CheckedContinuation<Data,Error>?
  HostBridge.handler={request in
   if request["command"]=="chat_list" {return Data(#"{"chats":[]}"#.utf8)}
   if request["provider"]=="alexus" {return try await withCheckedThrowingContinuation{old=$0}}
   return Data(#"{"models":["mac-only"]}"#.utf8)
  }
  model.models=["stale"];model.model="stale"
  let previous=Task {await model.discover(owner:owner)}
  while old == nil {await Task.yield()}
  precondition(model.models.isEmpty && model.model.isEmpty && model.discovering)
  model.provider="mac"
  await model.discover(owner:owner)
  precondition(model.models==["mac-only"] && model.model=="mac-only" && !model.discovering)
  old!.resume(returning:Data(#"{"models":["alexus-stale"]}"#.utf8))
  await previous.value
  precondition(model.models==["mac-only"] && model.message.contains("this Mac"))
  HostBridge.handler={_ in throw URLError(.cannotConnectToHost)}
  await model.discover(owner:owner)
  precondition(model.models.isEmpty && model.model.isEmpty && !model.discovering && model.message.contains("this Mac"))
  print("Passed provider refresh, stale-response rejection, and failure-clearing checks")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'check.swift';p.write_text(source+harness)
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',str(Path(tmp)/'check')],check=True)
 subprocess.run([str(Path(tmp)/'check')],check=True)
