import SwiftUI

public struct MainSplitView: View {
    @EnvironmentObject var state: AppState
    @State private var filterFailuresOnly: Bool = false
    @State private var searchText: String = ""
    @State private var activeTab: DetailTab = .split

    enum DetailTab: String, CaseIterable {
        case split = "Split View"
        case terminal = "Terminal"
        case diagnosis = "AI Diagnosis"
        case agent = "AI Agent"
        case logs = "Scrubbed Logs"
    }

    var filteredCommands: [ShellCommand] {
        var list = state.commands
        if filterFailuresOnly {
            list = list.filter { $0.isFailed }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.cmd.localizedCaseInsensitiveContains(q) ||
                $0.cwd.localizedCaseInsensitiveContains(q) ||
                $0.ts.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    public var body: some View {
        NavigationSplitView {
            // Sidebar: Shell Command History
            VStack(spacing: 0) {
                // Header with Controls
                VStack(spacing: 8) {
                    HStack {
                        Text("Command History")
                            .font(.headline)
                        Spacer()
                        Text("\(filteredCommands.count) logged")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())

                        Button {
                            state.refreshCommands()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh History")
                    }

                    // Search Field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("Search commands or directories...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Failures Only Filter
                    HStack {
                        Toggle("Failures Only", isOn: $filterFailuresOnly)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                // Commands List
                if filteredCommands.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "terminal")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No commands match")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    List(filteredCommands, selection: $state.selectedCommand) { cmd in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: cmd.isFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(cmd.isFailed ? .red : .green)
                                .font(.caption)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(cmd.cmd)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(2)
                                    .foregroundStyle(cmd.isFailed ? .primary : .primary)

                                HStack(spacing: 4) {
                                    Text(cmd.cwd)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if cmd.isFailed {
                                        Text("exit \(cmd.exitCode)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.red)
                                    }
                                }

                                if !cmd.formattedTime.isEmpty {
                                    Text(cmd.formattedTime)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectCommand(cmd)
                        }
                        .tag(cmd)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: state.selectedCommand) { newCmd in
                        if let cmd = newCmd {
                            state.selectCommand(cmd)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            // Detail Area
            VStack(spacing: 0) {
                // Multimodal Visual Attachment Bar
                MultimodalBar()

                Divider()

                // Runner Bar
                PipelineRunnerView()

                Divider()

                // Inspector Card for the selected command
                if let selected = state.selectedCommand {
                    CommandInspectorCard(cmd: selected)
                    Divider()
                }

                // Tab Switcher
                HStack {
                    Picker("", selection: $activeTab) {
                        ForEach(DetailTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 480)

                    Spacer()

                    if state.isAgentRunning {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Agent Active")
                                .font(.caption.bold())
                                .foregroundStyle(.purple)
                        }
                    } else if state.report != nil {
                        Text("AI Diagnosis Ready")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // Content View based on Tab
                Group {
                    switch activeTab {
                    case .split:
                        HSplitView {
                            TerminalView()
                                .frame(minWidth: 320)
                            if let report = state.report {
                                DiagnosticView(report: report)
                                    .frame(minWidth: 360)
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 36))
                                        .foregroundStyle(.secondary)
                                    Text("No Active Diagnosis")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                    Text("Click 'Debug Error', 'AI Agent', or run a pipeline command.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 32)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(NSColor.textBackgroundColor))
                                .frame(minWidth: 360)
                            }
                        }
                    case .terminal:
                        TerminalView()
                    case .diagnosis:
                        if let report = state.report {
                            DiagnosticView(report: report)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("No Active Diagnosis")
                                    .font(.title3.bold())
                                    .foregroundStyle(.secondary)
                                Button("Debug Last Failed Command") {
                                    state.debugLast()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .agent:
                        AgentView()
                    case .logs:
                        ScrollView {
                            Text(state.logTail.isEmpty ? "(No logs found in ~/.ragnarok)" : state.logTail)
                                .font(.system(.body, design: .monospaced))
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color(NSColor.textBackgroundColor))
                    }
                }
            }
        }
    }
}
