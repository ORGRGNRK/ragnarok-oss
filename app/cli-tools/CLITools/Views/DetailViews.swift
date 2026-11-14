import AppKit
import SwiftUI

/// Inline UI for Ask for Text and Choose from Menu. Alerts use a real alert instead.
struct InteractionCard: View {
    let interaction: Interaction
    let respond: (String?) -> Void
    @State private var text: String

    init(interaction: Interaction, respond: @escaping (String?) -> Void) {
        self.interaction = interaction
        self.respond = respond
        if case .text(_, let defaultValue, _) = interaction.kind {
            _text = State(initialValue: defaultValue)
        } else {
            _text = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch interaction.kind {
            case .text(let prompt, _, let placeholder):
                Text(prompt).font(.headline)
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(submit)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { respond(nil) }
                        .keyboardShortcut(.cancelAction)
                    Button("Continue", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .menu(let prompt, let items):
                Text(prompt ?? "Choose an option").font(.headline)
                HStack {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index == 0 {
                            Button(item) { respond(item) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button(item) { respond(item) }
                        }
                    }
                }
            case .alert:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.blue.opacity(0.35)))
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        respond(trimmed)
    }
}

struct StepDetailView: View {
    let engine: PipelineEngine
    let action: Action

    var body: some View {
        let detail = engine.details[action.id] ?? StepDetail()
        let status = engine.statuses[action.id] ?? .pending
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusIcon(status: status)
                Text(action.title).font(.title2.weight(.semibold))
                Text("\(action.id) · \(action.type)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if let duration = detail.duration {
                    Text(engine.format(duration)).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let description = action.description {
                Text(description).foregroundStyle(.secondary)
            }
            if let note = detail.note {
                Label(note, systemImage: "info.circle")
            }
            if let error = detail.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let input = detail.input {
                TextBlock(title: "Input", text: input)
            }
            if let output = detail.output {
                TextBlock(title: "Output", text: output)
            }
            if detail.input == nil, detail.output == nil, status == .pending {
                Text("This step hasn't run yet.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct TextBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Copy \(title.lowercased())")
            }
            Text(text.isEmpty ? " " : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct PipelineOverview: View {
    let engine: PipelineEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pipeline = engine.pipeline {
                Text(pipeline.shortcut.name).font(.title2.weight(.semibold))
                if let description = pipeline.shortcut.description {
                    Text(description).foregroundStyle(.secondary)
                }
                Text("Press Run (⌘R) to start. You can also select text in any app and choose Services › Find CLI Tool.")
                Text("Every lookup and command run is saved to History (⌘Y).")
                if let notes = pipeline.notes, !notes.isEmpty {
                    Text("Notes").font(.headline).padding(.top, 8)
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "text.alignleft")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
