import AppKit
import Foundation
@main struct NativeChecks {
 @MainActor static func main() async {
  var failures = 0
  func check(_ name: String, _ pass: Bool) {
   print("\(pass ? "PASS" : "FAIL") \(name)"); if !pass { failures += 1 }
  }
  let bridge = DebuggerBridge.shared
  let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: scratch) }
  var complete = false, output = "", code = -1
  _ = bridge.runPipeline(command: "pwd", cwd: scratch.path, onOutput: {_ in}, onFinished: { c,o in code=c;output=o;complete=true })
  while !complete { try? await Task.sleep(nanoseconds: 10_000_000) }
  check("actual project working folder", code == 0 && output.contains(scratch.path))
  complete=false
  let selected=ShellCommand(ts:"fixture",cmd:"SELECTED_FIXTURE_FAILURE",cwd:scratch.path,exitCode:7,src:"fixture")
  _ = bridge.debugLast(selectedFailure:selected,cwd:scratch.path,provider:"mock",onOutput:{_ in},onFinished:{o in output=o;complete=true})
  while !complete { try? await Task.sleep(nanoseconds:10_000_000) }
  check("selected diagnosis structured result",DiagnosticReport.fromEvents(output) != nil)
  check("provider error never diagnosis",DiagnosticReport.fromEvents("Permission denied") == nil)
  let event="PIPELINE_EVENT " + "{\"type\":\"agent_state\",\"state\":{\"id\":\"fixture\",\"rounds\":2,\"status\":\"completed\",\"verdict\":\"unverified\",\"actions\":[{\"round\":2,\"tool\":\"Bash\",\"cmd\":\"false\",\"exit\":1,\"out\":\"fixture\"}]}}"
  let parsed=AgentRun.parse(from:event,task:"fixture")
  check("structured round and action",parsed.rounds == 2 && parsed.actions.count == 1 && parsed.actions[0].exitCode == 1)
  check("decorative success ignored",AgentRun.parse(from:"VERDICT: PROVED",task:"fixture").verdict != "proved")
  let retained = """
  PIPELINE_EVENT {"type":"checkpoint","stage":"baseline","round":0,"checkpoint":"baseline-0","source_hash":"good-hash","passed":["a"],"best":"baseline-0","best_hash":"good-hash","best_passed":["a"]}
  PIPELINE_EVENT {"type":"checkpoint","stage":"local","round":1,"checkpoint":"local-1","source_hash":"regressed-hash","passed":[],"best":"baseline-0","best_hash":"good-hash","best_passed":["a"]}
  """
  let best = AgentRun.parse(from: retained, task: "fixture")
  check("retained best hash matches best checkpoint", best.bestCheckpoint == "baseline-0" && best.sourceHash == "good-hash" && best.bestChecks == "a")
  let controllerEvents = """
  PIPELINE_EVENT {"type":"decision","decision":{"outcome":"reject","code":"regression","gates":{"proposal":true,"acceptance":false,"non_regression":false}}}
  """
  let rejected = AgentRun.parse(from: controllerEvents, task: "fixture")
  check("UI uses controller gate evidence", rejected.controllerDecision == "reject · regression" && rejected.gateSummary.contains("non regression: fail") && rejected.verdict != "passed_checks")
  let invalid = AgentRun.parse(from: "PIPELINE_EVENT {\"type\":\"proposal_rejected\",\"decision\":{\"outcome\":\"reject\",\"code\":\"invalid_patch\",\"gates\":{\"proposal\":false,\"acceptance\":null,\"non_regression\":null}}}", task: "fixture")
  check("unrun gates stay not checked", invalid.gateSummary.contains("acceptance: not checked") && invalid.gateSummary.contains("proposal: fail"))
  let discovery = await Task.detached { bridge.discoverLocalModels(endpoint:"http://127.0.0.1:1") }.value
  check("discovery exposes connection failure", discovery.models.isEmpty && discovery.error.contains("Ollama discovery failed") && discovery.endpoint == "http://127.0.0.1:1")
  let state=AppState();state.selectedProvider="ollama";state.selectedModel="fixture-model";state.selectedProvider="agy"
  check("provider change clears stale model",state.selectedModel.isEmpty)
  state.agentRun = AgentRun(task: "previous", status: "passed_checks", verdict: "passed_checks")
  state.launchAutonomousAgent(task: "missing setup")
  check("invalid setup replaces prior success", state.agentRun?.verdict == "blocked" && !(state.agentRun?.reason.isEmpty ?? true))
  let previousEndpoint = UserDefaults.standard.object(forKey: "ollamaEndpoint")
  state.ollamaURL = "http://127.0.0.1:1"
  let restored = AppState()
  check("endpoint retained across app state creation", restored.ollamaURL == state.ollamaURL)
  if let previousEndpoint { UserDefaults.standard.set(previousEndpoint, forKey: "ollamaEndpoint") }
  else { UserDefaults.standard.removeObject(forKey: "ollamaEndpoint") }
  state.projectDirectory = scratch.path
  state.selectedProvider = "ollama"; state.selectedModel = "fixture"; state.acceptanceFile = scratch.appendingPathComponent("missing-acceptance.json").path
  state.launchAutonomousAgent(task: "invalid acceptance")
  while state.isAgentRunning { try? await Task.sleep(nanoseconds:10_000_000) }
  check("startup failure retains actual error", state.agentRun?.verdict == "failed" && (state.agentRun?.reason.contains("missing-acceptance.json") ?? false))
  state.selectCommand(selected)
  check("selected folder retained",state.projectDirectory == scratch.path)
  state.runPipeline(cmd:"sleep 1; printf late")
  state.stop()
  try? await Task.sleep(nanoseconds:1_300_000_000)
  check("cancelled callbacks cannot restore results",!state.isRunning && state.report == nil && !state.terminalOutput.contains("late\nPIPELINE"))
  let fake="sk-proj-"+String(repeating:"Abc123Def456",count:4)
  check("bridge scrubs synthetic value",!bridge.scrub(fake).contains(fake))
  exit(failures == 0 ? 0 : 1)
 }
}
