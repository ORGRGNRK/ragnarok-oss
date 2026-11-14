import SwiftUI

public struct AgentView: View {
    @EnvironmentObject var state: AppState

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Heimdall Autonomous Agent", systemImage: "figure.run.square.stack.fill")
                            .font(.title3.bold())
                            .foregroundStyle(.purple)

                        Spacer()

                        if let run = state.agentRun {
                            verdictBadge(run.verdict)
                        } else {
                            Text("Agent Standby")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    if let run = state.agentRun {
                        Text(run.task)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Text("ID: \(run.id)")
                                .font(.caption.monospaced())
                            Text("Rounds: \(run.rounds)")
                                .font(.caption.monospaced())
                            Spacer()
                            Text(run.status.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(run.status == "completed" ? .green : .blue)
                        }
                    } else {
                        Text("Local repair runs against frozen outside checks; optional cloud continuation uses the best checkpoint.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Ollama endpoint (blank uses environment/local.conf)", text: $state.ollamaURL)
                    HStack {
                        Button("Refresh local models") { state.refreshLocalModels() }
                            .disabled(state.isDiscoveringModels)
                        Text(state.modelDiscoveryStatus).font(.caption).textSelection(.enabled)
                    }
                    TextField("Repair goal", text: $state.repairGoal)
                    TextField("Outside acceptance JSON file", text: $state.acceptanceFile)
                    HStack {
                        Picker("Cloud continuation", selection: $state.cloudProvider) {
                            Text("Save packet only").tag("")
                            Text("Claude (text only, no tools)").tag("claude-text")
                            Text("OpenAI API").tag("openai")
                            Text("Anthropic API").tag("anthropic")
                            Text("Gemini API").tag("gemini")
                        }
                        TextField("Explicit cloud model", text: $state.cloudModel)
                    }
                    Text("Source is copied. Frozen checks run in Docker without network access. Repairs remain in the evidence folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let run = state.agentRun {
                    Text("Stage: \(run.stage) · Round: \(run.rounds) · \(run.status)")
                    Text("Best checkpoint: \(run.bestCheckpoint)").font(.caption)
                    Text("Provider / model: \(run.providerModel)").font(.caption)
                    Text("Baseline passed: \(run.baselineChecks) · Best passed: \(run.bestChecks)").font(.caption)
                    Text("Current: \(run.checkSummary)").font(.caption.monospaced())
                    if !run.controllerDecision.isEmpty {
                        Text("Controller: \(run.controllerDecision)").font(.caption.monospaced())
                        Text(run.gateSummary).font(.caption)
                    }
                    Text("Source hash: \(run.sourceHash)").font(.caption2.monospaced()).textSelection(.enabled)
                    Text("Proposed files: \(run.changes.joined(separator: ", "))").font(.caption)
                    Text(run.reason).font(.caption)
                    if !run.evidence.isEmpty {
                        Button("Inspect evidence and proposed patch") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: run.evidence))
                        }
                        Button("Export evidence and patch") { state.exportEvidence() }
                    }
                }

                // Launch Agent Trigger Box (if not active or to trigger new run)
                HStack(spacing: 10) {
                    Button {
                        state.launchAutonomousAgent()
                    } label: {
                        Label(state.isAgentRunning ? "Agent Working..." : "Launch Autonomous Repair Agent", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(state.isAgentRunning || state.isRunning)

                    if state.isAgentRunning {
                        Button("Stop Agent") {
                            state.stop()
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Text("Model: \(state.selectedModel)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                // Autonomous Plan Card
                if let run = state.agentRun, !run.plan.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Autonomous Plan & Checklist", systemImage: "checklist")
                            .font(.headline)

                        ForEach(run.plan) { step in
                            HStack(alignment: .top, spacing: 10) {
                                if step.isCompleted {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else if step.isInProgress {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }

                                Text(step.step)
                                    .font(.system(.body, design: .monospaced))
                                    .strikethrough(step.isCompleted)
                                    .foregroundStyle(step.isCompleted ? .secondary : .primary)

                                Spacer()
                            }
                            .padding(8)
                            .background(step.isInProgress ? Color.blue.opacity(0.08) : Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }

                // Action Timeline
                if let run = state.agentRun, !run.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Executed Tool Actions", systemImage: "wrench.and.screwdriver")
                            .font(.headline)

                        ForEach(run.actions) { act in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Round \(act.round): \(act.tool)")
                                        .font(.caption.bold())
                                    Spacer()
                                    Text("Exit \(act.exitCode)")
                                        .font(.caption.bold())
                                        .foregroundStyle(act.exitCode == 0 ? .green : .red)
                                }

                                Text(act.cmd)
                                    .font(.caption.monospaced())
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.black.opacity(0.8))
                                    .foregroundStyle(.green)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                if !act.output.isEmpty {
                                    Text(act.output)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                }
                            }
                            .padding(10)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: String) -> some View {
        switch verdict.lowercased() {
        case "passed_checks":
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                Text("PASSED CHECKS")
            }
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.2))
            .foregroundStyle(.green)
            .clipShape(Capsule())

        case "needs_you":
            HStack(spacing: 4) {
                Image(systemName: "person.fill.questionmark")
                Text("NEEDS YOU")
            }
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.2))
            .foregroundStyle(.orange)
            .clipShape(Capsule())

        case "failed":
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill")
                Text("FAILED")
            }
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.2))
            .foregroundStyle(.red)
            .clipShape(Capsule())

        case "blocked", "unverified", "cancelled", "timed_out":
            Text(verdict.uppercased()).font(.caption.bold()).foregroundStyle(.orange)

        default:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("IN PROGRESS")
            }
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.2))
            .foregroundStyle(.blue)
            .clipShape(Capsule())
        }
    }
}
