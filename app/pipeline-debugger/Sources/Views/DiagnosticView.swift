import SwiftUI

public struct DiagnosticView: View {
    @EnvironmentObject var state: AppState
    let report: DiagnosticReport

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header Banner
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.classification.isEmpty ? "Pipeline Failure Diagnosed" : report.classification)
                            .font(.title3.bold())
                        if !report.stageOrCommand.isEmpty {
                            Text(report.stageOrCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if !report.exitCode.isEmpty {
                        Text("Exit \(report.exitCode)")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Location info
                if !report.location.isEmpty && report.location != "N/A" {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Culprit Location", systemImage: "mappin.and.ellipse")
                            .font(.headline)
                        Text(report.location)
                            .font(.subheadline.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Root Cause Analysis
                if !report.rootCause.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Root Cause Analysis", systemImage: "magnifyingglass.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text(report.rootCause)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Remediation Patch
                if !report.patch.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Remediation & Patch", systemImage: "wrench.and.screwdriver.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(report.patch)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Executable Fix Command
                if !report.fixCommand.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Executable Fix Command", systemImage: "bolt.fill")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report.fixCommand, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)

                            Button {
                                state.applyFix()
                            } label: {
                                Label("Apply Fix Now", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(state.isRunning)
                        }

                        Text(report.fixCommand)
                            .font(.system(.callout, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.85))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Pipeline Verification Command
                if !report.verifyCommand.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Verification Command", systemImage: "checkmark.seal.fill")
                                .font(.headline)
                                .foregroundStyle(.cyan)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report.verifyCommand, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)

                            Button {
                                state.runVerification()
                            } label: {
                                Label("Run Verification", systemImage: "play.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(state.isRunning)
                        }

                        Text(report.verifyCommand)
                            .font(.system(.callout, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.85))
                            .foregroundStyle(.cyan)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Preventative Guard
                if !report.preventativeGuard.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Preventative Guard", systemImage: "shield.lefthalf.filled")
                            .font(.headline)
                            .foregroundStyle(.purple)
                        Text(report.preventativeGuard)
                            .font(.callout)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.purple.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding()
        }
    }
}
