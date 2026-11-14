import AppKit
import Foundation
import SwiftUI

@MainActor
public final class AppState: ObservableObject {
    @Published public var selectedProvider: String = "ollama" {
        didSet { if selectedProvider != oldValue { selectedModel = "" } }
    }
    @Published public var projectDirectory: String = NSHomeDirectory()
    @Published public var acceptanceFile: String = ""
    @Published public var repairGoal: String = ""
    @Published public var ollamaURL: String = UserDefaults.standard.string(forKey: "ollamaEndpoint") ?? "" {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: "ollamaEndpoint") }
    }
    @Published public var cloudProvider: String = ""
    @Published public var cloudModel: String = ""
    private var runGeneration = UUID()
    @Published public var selectedModel: String = ""
    @Published public var localModels: [String] = []
    @Published public var modelDiscoveryStatus: String = ""
    @Published public var isDiscoveringModels = false
    private var discoveryGeneration = UUID()
    @Published public var commandInput: String = "pytest -v"

    @Published public var commands: [ShellCommand] = []
    @Published public var selectedCommand: ShellCommand? = nil {
        didSet {
            if let cmd = selectedCommand {
                commandInput = cmd.cmd
                projectDirectory = cmd.cwd
            }
        }
    }

    @Published public var terminalOutput: String = ""
    @Published public var isRunning: Bool = false
    @Published public var isAnalyzing: Bool = false
    @Published public var isAgentRunning: Bool = false

    @Published public var report: DiagnosticReport? = nil
    @Published public var agentRun: AgentRun? = nil
    @Published public var attachments: [MultimodalAttachment] = []
    @Published public var logTail: String = ""

    private var activeProcess: Process?
    private var timer: Timer?

    public init() {
        refreshCommands()
        refreshLogTail()
        startWatcher()
        refreshLocalModels()
    }

    public func refreshLocalModels() {
        let endpoint = ollamaURL
        let generation = UUID()
        discoveryGeneration = generation
        isDiscoveringModels = true
        modelDiscoveryStatus = "Checking Ollama…"
        Task { [weak self] in
            let discovered = await Task.detached { DebuggerBridge.shared.discoverLocalModels(endpoint: endpoint) }.value
            guard let self = self, self.discoveryGeneration == generation else { return }
            self.isDiscoveringModels = false
            guard self.ollamaURL == endpoint else {
                self.modelDiscoveryStatus = "Endpoint changed; refresh local models"
                return
            }
            self.localModels = discovered.models
            self.modelDiscoveryStatus = discovered.endpoint + (discovered.error.isEmpty
                ? " — \(discovered.models.count) models available" : " — " + discovered.error)
            if self.selectedProvider == "ollama" && self.selectedModel.isEmpty {
                self.selectedModel = discovered.models.first ?? ""
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    public func startWatcher() {
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCommands()
                self?.refreshLogTail()
            }
        }
    }

    public func refreshCommands() {
        let list = DebuggerBridge.shared.fetchRecentCommands()
        let currentIDs = self.commands.map(\.id)
        let newIDs = list.map(\.id)

        if currentIDs != newIDs {
            self.commands = list
            if let currentSelected = self.selectedCommand {
                // Preserve active selection if still in history
                if let matched = list.first(where: { $0.id == currentSelected.id }) {
                    self.selectedCommand = matched
                }
            } else if let firstFail = list.first(where: { $0.isFailed }) {
                self.selectCommand(firstFail)
            } else if let firstCmd = list.first {
                self.selectCommand(firstCmd)
            }
        }
    }

    public func selectCommand(_ cmd: ShellCommand) {
        self.selectedCommand = cmd
        self.commandInput = cmd.cmd
        self.terminalOutput = ">>> Inspected Shell Command from History:\nCommand:   \(cmd.cmd)\nDirectory: \(cmd.cwd)\nExit Code: \(cmd.exitCode) (\(cmd.isFailed ? "FAILED" : "SUCCESS"))\nTimestamp: \(cmd.formattedTime) [\(cmd.ts)]\nSource:    \(cmd.src)\n----------------------------------------\n"
    }

    public func refreshLogTail() {
        self.logTail = DebuggerBridge.shared.fetchRecentOutput(maxLines: 60)
    }

    // MARK: - Multimodal Actions

    public func captureInteractiveScreenshot() {
        ScreenCaptureHelper.shared.captureInteractive { [weak self] url in
            guard let self = self, let url = url else { return }
            self.attachments.append(MultimodalAttachment(url: url))
        }
    }

    public func pasteImageFromClipboard() {
        if let url = ScreenCaptureHelper.shared.captureFromClipboard() {
            attachments.append(MultimodalAttachment(url: url))
        }
    }

    public func selectImageFiles() {
        ScreenCaptureHelper.shared.openFilePicker { [weak self] urls in
            guard let self = self else { return }
            for url in urls {
                self.attachments.append(MultimodalAttachment(url: url))
            }
        }
    }

    public func removeAttachment(_ attachment: MultimodalAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    public func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    self?.attachments.append(MultimodalAttachment(url: url))
                }
            }
        }
    }

    // MARK: - Pipeline & Agent Runners

    public func runPipeline(cmd: String) {
        guard !isRunning && !isAnalyzing && !isAgentRunning else { return }
        runGeneration = UUID()
        let generation = runGeneration
        isRunning = true
        terminalOutput = DebuggerBridge.shared.scrub(">>> Executing Pipeline: \(cmd)\n----------------------------------------\n")
        report = nil

        let imgURLs = attachments.map(\.url)
        activeProcess = DebuggerBridge.shared.runPipeline(
            command: cmd,
            cwd: projectDirectory,
            ollamaURL: ollamaURL,
            images: imgURLs,
            provider: selectedProvider,
            model: selectedModel,
            onOutput: { [weak self] chunk in
                guard let self = self, self.runGeneration == generation else { return }
                self.terminalOutput += chunk
            },
            onFinished: { [weak self] code, full in
                guard let self = self, self.runGeneration == generation else { return }
                self.isRunning = false
                self.activeProcess = nil
                self.refreshCommands()

                if code != 0 {
                    self.report = DiagnosticReport.fromEvents(full)
                }
            }
        )
    }

    public func debugLast() {
        guard !isRunning && !isAnalyzing && !isAgentRunning else { return }
        runGeneration = UUID()
        let generation = runGeneration
        isAnalyzing = true
        terminalOutput += "\n>>> Invoking AI Pipeline & Error Debugger on Last Failure...\n"

        let imgURLs = attachments.map(\.url)
        activeProcess = DebuggerBridge.shared.debugLast(
            selectedFailure: selectedCommand,
            cwd: projectDirectory,
            ollamaURL: ollamaURL,
            images: imgURLs,
            provider: selectedProvider,
            model: selectedModel,
            onOutput: { [weak self] chunk in
                guard let self = self, self.runGeneration == generation else { return }
                self.terminalOutput += chunk
            },
            onFinished: { [weak self] full in
                guard let self = self, self.runGeneration == generation else { return }
                self.isAnalyzing = false
                self.activeProcess = nil
                self.report = DiagnosticReport.fromEvents(full)
            }
        )
    }

    public func launchAutonomousAgent(task: String = "") {
        guard !isAgentRunning && !isRunning && !isAnalyzing else { return }
        runGeneration = UUID()
        let generation = runGeneration
        let taskDesc = task.isEmpty ? (repairGoal.isEmpty ? "Fix the failure: " + (selectedCommand?.cmd ?? commandInput) : repairGoal) : task
        guard !acceptanceFile.isEmpty, selectedProvider == "ollama", !selectedModel.isEmpty else {
            let reason = "Isolated repair needs an outside acceptance JSON file, Ollama, and an explicit local model."
            var blocked = AgentRun(task: taskDesc, status: "blocked", verdict: "blocked", rounds: 0)
            blocked.reason = reason
            agentRun = blocked
            terminalOutput += "\n" + reason + " Set these in the Agent tab.\n"
            return
        }
        isAgentRunning = true
        terminalOutput += "\n>>> Launching Heimdall Autonomous Repair Agent...\nTask: \(taskDesc)\n"
        agentRun = AgentRun(task: taskDesc, status: "planning")

        // Parse only this child's output. The visible console may contain older runs.
        var runOutput = ""
        let imgURLs = attachments.map(\.url)
        activeProcess = DebuggerBridge.shared.runAgent(
            task: taskDesc,
            cwd: projectDirectory,
            ollamaURL: ollamaURL,
            images: imgURLs,
            provider: selectedProvider,
            model: selectedModel,
            rounds: 3,
            acceptance: acceptanceFile,
            cloudProvider: cloudProvider,
            cloudModel: cloudModel,
            onOutput: { [weak self] chunk in
                guard let self = self, self.runGeneration == generation else { return }
                self.terminalOutput += chunk
                runOutput += chunk
                self.agentRun = AgentRun.parse(from: runOutput, task: taskDesc)
            },
            onFinished: { [weak self] code, full in
                guard let self = self, self.runGeneration == generation else { return }
                self.isAgentRunning = false
                self.activeProcess = nil
                var finalRun = AgentRun.parse(from: full, task: taskDesc)
                if finalRun.verdict == "in_progress" {
                    finalRun.status = code == 0 ? "unverified" : "failed"
                    finalRun.verdict = code == 0 ? "unverified" : "failed"
                    finalRun.reason = code == 0 ? "Engine exited without a final repair result" :
                        "Engine exited before a final repair result (exit \(code)).\n" + String(full.suffix(3000))
                }
                self.agentRun = finalRun
                self.refreshCommands()
            }
        )
    }

    public func applyFix() {
        guard let fix = report?.fixCommand, !fix.isEmpty else { return }
        runPipeline(cmd: fix)
    }

    public func runVerification() {
        guard let verify = report?.verifyCommand, !verify.isEmpty else { return }
        runPipeline(cmd: verify)
    }

    public func exportEvidence() {
        guard let evidence = agentRun?.evidence, !evidence.isEmpty else { return }
        let source = URL(fileURLWithPath: evidence)
        let panel = NSSavePanel()
        panel.title = "Export run evidence and proposed patch"
        panel.nameFieldStringValue = source.lastPathComponent + "-evidence"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            terminalOutput += "\nEvidence exported.\n"
        } catch {
            terminalOutput += DebuggerBridge.shared.scrub("\nExport failed: \(error.localizedDescription)\n")
        }
    }

    public func stop() {
        runGeneration = UUID()
        activeProcess?.terminate()
        activeProcess = nil
        isRunning = false
        isAnalyzing = false
        isAgentRunning = false
        agentRun?.status = "cancelled"
        agentRun?.verdict = "cancelled"
        terminalOutput += "\n[Process terminated by user]\n"
    }
}
