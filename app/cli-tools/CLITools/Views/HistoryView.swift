import AppKit
import SwiftData
import SwiftUI

/// Browses the history database: every lookup, newest first, with the commands run against it.
struct HistoryView: View {
    @Query(sort: \Lookup.date, order: .reverse) private var lookups: [Lookup]
    @Environment(\.modelContext) private var context
    @State private var selection: UUID?
    @State private var search = ""

    private var filtered: [Lookup] {
        guard !search.isEmpty else { return lookups }
        return lookups.filter {
            $0.query.localizedCaseInsensitiveContains(search)
                || ($0.tool ?? "").localizedCaseInsensitiveContains(search)
                || $0.runs.contains { $0.command.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { lookup in
                HistoryRow(lookup: lookup).tag(lookup.id)
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search queries, tools, commands")
            .overlay {
                if lookups.isEmpty {
                    ContentUnavailableView("No Lookups Yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Every lookup you run is saved here."))
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if let lookup = lookups.first(where: { $0.id == selection }) {
                LookupDetail(lookup: lookup) {
                    selection = nil
                    context.delete(lookup)
                    try? context.save()
                }
            } else {
                ContentUnavailableView("Select a Lookup", systemImage: "terminal")
            }
        }
        .navigationTitle("History")
        .navigationSubtitle("\(lookups.count) lookup\(lookups.count == 1 ? "" : "s")")
        .onAppear { if selection == nil { selection = lookups.first?.id } }
    }
}

struct HistoryRow: View {
    let lookup: Lookup

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(status: lookup.status)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(lookup.query).lineLimit(1)
                HStack(spacing: 6) {
                    Text(lookup.tool ?? lookup.status).font(.caption.monospaced())
                    if !lookup.runs.isEmpty {
                        Label("\(lookup.runs.count)", systemImage: "terminal").font(.caption)
                    }
                    Spacer()
                    Text(lookup.date, format: .relative(presentation: .named)).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        switch status {
        case "OK", "SAFE": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "NOT_FOUND": Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case "BLOCKED": Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
        default: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct LookupDetail: View {
    let lookup: Lookup
    let delete: () -> Void
    @State private var exportMessage: String?
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lookup.query).font(.title2.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 8) {
                        StatusBadge(status: lookup.status)
                        Text(lookup.status).font(.callout.monospaced())
                        Text("·").foregroundStyle(.tertiary)
                        Text(lookup.date, format: .dateTime.month().day().year().hour().minute())
                    }
                    .foregroundStyle(.secondary)
                }

                if let tool = lookup.tool {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text("Tool").foregroundStyle(.secondary); Text(tool).font(.body.monospaced()) }
                        if let path = lookup.path {
                            GridRow { Text("Path").foregroundStyle(.secondary); Text(path).font(.body.monospaced()) }
                        }
                        if let summary = lookup.summary {
                            GridRow { Text("Summary").foregroundStyle(.secondary); Text(summary).lineLimit(3) }
                        }
                    }
                    .textSelection(.enabled)
                }

                Section {
                    if lookup.runs.isEmpty {
                        Text("No commands were run with this lookup.").foregroundStyle(.secondary)
                    }
                    ForEach(lookup.sortedRuns) { run in
                        RunCard(run: run)
                    }
                } header: {
                    Text("Commands").font(.headline)
                }

                DisclosureGroup("Model response") { MonoBlock(text: lookup.modelResponse) }
                DisclosureGroup("Verification output") { MonoBlock(text: lookup.verification) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Copy as Text", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lookup.exportText, forType: .string)
                }
                Button("Export to Notes", systemImage: "note.text.badge.plus") { exportToNotes() }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .confirmationDialog("Delete this lookup and its \(lookup.runs.count) command run(s) from History?",
                            isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: delete)
        }
        .alert(exportMessage ?? "", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK") { exportMessage = nil }
        }
    }

    private func exportToNotes() {
        do {
            _ = try NotesWriter().create(text: lookup.exportText, folder: nil)
            exportMessage = "Exported to Notes."
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}

private struct RunCard: View {
    let run: CommandRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusBadge(status: run.verdict == "SAFE" ? (run.succeeded ? "OK" : "FAILED") : run.verdict)
                Text("$ \(run.command)").font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Text(run.verdict == "BLOCKED" ? "Blocked" : "Exit \(run.exit ?? "?")")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                if let duration = run.duration {
                    Text(duration).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let reason = run.reason {
                Text(reason).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let output = run.output {
                MonoBlock(text: output)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MonoBlock: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Lookup {
    /// Plain-text version for Notes export and the clipboard.
    var exportText: String {
        var parts = ["\(date.formatted(date: .long, time: .shortened)) - \(tool ?? modelFirstLine)", "Query: \(query)", "", verification]
        for run in sortedRuns {
            parts += ["", "$ \(run.command)"]
            parts.append(run.verdict == "BLOCKED" ? "Not run. \(run.reason ?? "")" : (run.result ?? ""))
        }
        return parts.joined(separator: "\n")
    }
}
