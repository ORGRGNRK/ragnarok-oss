import Foundation
import Observation

/// A variable's value. Most actions produce text; `split_text` produces a list.
enum Value: Sendable {
    case text(String)
    case list([String])

    var text: String {
        switch self {
        case .text(let s): s
        case .list(let items): items.joined(separator: "\n")
        }
    }

    var items: [String] {
        switch self {
        case .text(let s): [s]
        case .list(let items): items
        }
    }
}

enum StepStatus: Equatable {
    case pending, running, waiting, done, skipped, failed, stopped
}

struct StepDetail {
    var input: String?
    var output: String?
    var note: String?
    var error: String?
    var duration: Duration?
}

/// Something the pipeline is waiting on the user for (Ask for Text, Choose from Menu, Show Alert).
struct Interaction: Identifiable {
    enum Kind {
        case text(prompt: String, defaultValue: String, placeholder: String)
        case menu(prompt: String?, items: [String])
        case alert(title: String, message: String)
    }

    let id = UUID()
    let stepID: String
    let kind: Kind
    fileprivate let resume: (String?) -> Void
}

/// One row of the step list: an action, or the label of a branch under an `if` or menu.
struct StepRow: Identifiable {
    let id: String
    let action: Action?
    let branchLabel: String?
    let depth: Int
}

/// Interprets the pipeline JSON: runs each action in `flow` order, resolving `{{action.Output}}`
/// references against earlier outputs and descending into `if` / menu branches.
@MainActor
@Observable
final class PipelineEngine {
    private(set) var pipeline: Pipeline?
    private(set) var pipelineSource: String = "Bundled cli-tools.json"
    private(set) var loadError: String?
    private(set) var rows: [StepRow] = []
    private(set) var statuses: [String: StepStatus] = [:]
    private(set) var details: [String: StepDetail] = [:]
    private(set) var interaction: Interaction?
    private(set) var isRunning = false
    private(set) var runSummary: String?
    var selectedStepID: String?

    private var outputs: [String: [String: Value]] = [:]
    private var runTask: Task<Void, Never>?
    private let runDate = Date.FormatStyle(date: .long, time: .shortened)
    private let notes: NoteStore
    private let records: RecordStore

    private struct StopSignal: Error {}

    init(records: RecordStore, notes: NoteStore = NotesWriter()) {
        self.records = records
        self.notes = notes
        do { load(try Pipeline.bundled(), source: "Bundled cli-tools.json") }
        catch { loadError = error.localizedDescription }
    }

    // MARK: Loading

    func open(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { load(try Pipeline.load(from: url), source: url.lastPathComponent) }
        catch { loadError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    func reloadBundled() {
        do { load(try Pipeline.bundled(), source: "Bundled cli-tools.json") }
        catch { loadError = error.localizedDescription }
    }

    private func load(_ pipeline: Pipeline, source: String) {
        cancel()
        self.pipeline = pipeline
        pipelineSource = source
        loadError = nil
        rows = Self.flatten(pipeline.orderedActions, depth: 0)
        resetState()
    }

    private static func flatten(_ actions: [Action], depth: Int) -> [StepRow] {
        actions.flatMap { action -> [StepRow] in
            var result = [StepRow(id: action.id, action: action, branchLabel: nil, depth: depth)]
            for key in action.orderedBranchKeys {
                result.append(StepRow(id: "\(action.id)#\(key)", action: nil, branchLabel: key, depth: depth + 1))
                result += flatten(action.branches?[key] ?? [], depth: depth + 2)
            }
            return result
        }
    }

    private func resetState() {
        outputs = [:]
        details = [:]
        runSummary = nil
        statuses = Dictionary(uniqueKeysWithValues: rows.compactMap { $0.action.map { ($0.id, StepStatus.pending) } })
    }

    // MARK: Running

    /// Starts a run. `shortcutInput` is what `receive_input` hands on, e.g. text sent from the Services menu.
    func run(shortcutInput: String? = nil) {
        guard let pipeline else { return }
        // Let a run in progress unwind before the new one resets the shared state.
        let previous = runTask
        cancel()
        isRunning = true
        runTask = Task {
            await previous?.value
            resetState()
            isRunning = true
            let started = ContinuousClock.now
            do {
                try await execute(pipeline.orderedActions, shortcutInput: shortcutInput)
                runSummary = "Finished in \(format(ContinuousClock.now - started))."
            } catch is StopSignal {
                runSummary = "Stopped."
            } catch is CancellationError {
                runSummary = "Cancelled."
            } catch {
                runSummary = "Failed: \(error.localizedDescription)"
            }
            for (id, status) in statuses where status == .pending { statuses[id] = .skipped }
            isRunning = false
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if let pending = interaction {
            interaction = nil
            pending.resume(nil)
        }
    }

    /// Answers the current interaction. `nil` means Cancel, which stops the run (as in Shortcuts).
    func respond(to interaction: Interaction, with answer: String?) {
        guard self.interaction?.id == interaction.id else { return }
        self.interaction = nil
        interaction.resume(answer)
    }

    private func execute(_ actions: [Action], shortcutInput: String?) async throws {
        for action in actions {
            try Task.checkCancellation()
            try await execute(action, shortcutInput: shortcutInput)
        }
    }

    private func execute(_ action: Action, shortcutInput: String?) async throws {
        statuses[action.id] = .running
        selectedStepID = action.id
        let started = ContinuousClock.now
        do {
            let value = try await perform(action, shortcutInput: shortcutInput)
            if let value, let name = action.outputs?.first {
                outputs[action.id, default: [:]][name] = value
            }
            if let value { details[action.id, default: StepDetail()].output = value.text }
            details[action.id, default: StepDetail()].duration = ContinuousClock.now - started
            if statuses[action.id] == .running { statuses[action.id] = .done }
        } catch let stop as StopSignal {
            // Only the step that stopped the run is marked; an `if` whose branch stopped stays done.
            if statuses[action.id] == .running || statuses[action.id] == .waiting {
                statuses[action.id] = .stopped
            }
            throw stop
        } catch {
            statuses[action.id] = error is CancellationError ? .stopped : .failed
            details[action.id, default: StepDetail()].error = error.localizedDescription
            throw error
        }
    }

    private func perform(_ action: Action, shortcutInput: String?) async throws -> Value? {
        switch action.type {
        case "receive_input":
            if let shortcutInput, !shortcutInput.isEmpty { return .text(shortcutInput) }
            if action.string("if_no_input")?.lowercased() == "stop" { throw StopSignal() }
            note(action, "No input (the app was opened directly). Continuing.")
            return .text("")

        case "ask_for_input":
            let prompt = resolve(action.string("prompt") ?? "")
            let defaultValue = action.string("default_answer").map(resolve) ?? (shortcutInput ?? "")
            let placeholder = action.string("placeholder") ?? ""
            guard let answer = await ask(.text(prompt: prompt, defaultValue: defaultValue, placeholder: placeholder), step: action.id) else {
                throw StopSignal()
            }
            return .text(answer)

        case "use_model":
            let model = action.string("model") ?? "On-Device"
            guard model.lowercased().replacingOccurrences(of: "-", with: "") == "ondevice" else {
                throw PipelineError.unsupportedModel(model)
            }
            let prompt = resolve(try required(action, "prompt_template"))
            details[action.id, default: StepDetail()].input = prompt
            return .text(try await OnDeviceModel.respond(to: prompt))

        case "split_text":
            let input = resolveValue(try required(action, "input")).text
            details[action.id, default: StepDetail()].input = input
            return .list(split(input, by: action.string("separator") ?? "New Lines", custom: action.string("custom_separator")))

        case "get_item_from_list":
            let items = resolveValue(try required(action, "input")).items
            details[action.id, default: StepDetail()].input = items.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
            return .text(pick(from: items, position: action.string("position") ?? "First Item", index: action.string("index")))

        case "list":
            let items = (action.params["items"]?.arrayValue ?? []).compactMap(\.stringValue).map(resolve)
            return .list(items)

        case "run_shell_script":
            let input = resolveValue(action.string("input") ?? "").items
            details[action.id, default: StepDetail()].input = input.count == 1
                ? input[0]
                : input.enumerated().map { "$\($0 + 1):\n\($1)" }.joined(separator: "\n\n")
            return .text(try await ShellRunner.run(
                shell: action.string("shell") ?? "/bin/zsh",
                script: try required(action, "script"),
                input: input,
                passInput: action.string("pass_input") ?? "as arguments"
            ))

        case "if":
            let input = resolveValue(try required(action, "input")).text
            let condition = action.string("condition") ?? "has any value"
            let expected = resolve(action.string("value") ?? "")
            let matched = evaluate(input, condition, expected)
            details[action.id, default: StepDetail()].input = input
            note(action, "Input \(condition) “\(expected)” → \(matched ? "then" : "otherwise")")
            statuses[action.id] = .done
            try await runBranch(matched ? "then" : "otherwise", of: action, shortcutInput: shortcutInput)
            return nil

        case "choose_from_menu":
            let items = action.params["items"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let prompt = action.string("prompt").map(resolve)
            guard let choice = await ask(.menu(prompt: prompt, items: items), step: action.id) else {
                throw StopSignal()
            }
            note(action, "Chose “\(choice)”")
            statuses[action.id] = .done
            try await runBranch(choice, of: action, shortcutInput: shortcutInput)
            return .text(choice)

        case "save_record":
            let type = try required(action, "record")
            let parent = action.string("parent").map(resolve)
            var fields: [String: String] = [:]
            if case .object(let templates) = action.params["fields"] {
                for (name, template) in templates {
                    fields[name] = template.stringValue.map(resolve) ?? ""
                }
            }
            details[action.id, default: StepDetail()].input = fields.keys.sorted()
                .map { "\($0): \(fields[$0]!.split(separator: "\n").first ?? "")" }
                .joined(separator: "\n")
            let id = try records.save(record: type, parent: parent, fields: fields)
            note(action, "Saved \(type.replacingOccurrences(of: "_", with: " ")) to History.")
            return .text(id)

        case "create_note":
            let body = resolve(try required(action, "body_template"))
            details[action.id, default: StepDetail()].input = body
            let id = try notes.create(text: body, folder: action.string("folder"))
            note(action, "Saved to Notes.")
            return .text(id)

        case "append_to_note":
            let text = resolve(try required(action, "text_template"))
            let target = resolve(try required(action, "note"))
            details[action.id, default: StepDetail()].input = text
            try notes.append(text: text, to: target)
            note(action, "Appended to Notes.")
            return nil

        case "show_alert":
            let title = resolve(action.string("title") ?? "Alert")
            let message = resolve(action.string("message") ?? "")
            _ = await ask(.alert(title: title, message: message), step: action.id)
            return nil

        case "stop_shortcut":
            statuses[action.id] = .done
            throw StopSignal()

        default:
            throw PipelineError.unsupportedAction(action.type)
        }
    }

    /// Runs one branch and marks the steps in the branches not taken as skipped.
    private func runBranch(_ key: String, of action: Action, shortcutInput: String?) async throws {
        for (other, steps) in action.branches ?? [:] where other != key {
            markSkipped(steps)
        }
        try await execute(action.branches?[key] ?? [], shortcutInput: shortcutInput)
    }

    private func markSkipped(_ actions: [Action]) {
        for action in actions {
            statuses[action.id] = .skipped
            action.branches?.values.forEach(markSkipped)
        }
    }

    private func ask(_ kind: Interaction.Kind, step: String) async -> String? {
        statuses[step] = .waiting
        selectedStepID = step
        let answer = await withCheckedContinuation { continuation in
            interaction = Interaction(stepID: step, kind: kind) { continuation.resume(returning: $0) }
        }
        if statuses[step] == .waiting { statuses[step] = .running }
        return answer
    }

    // MARK: Variables

    private static let reference = /\{\{\s*([^}]+?)\s*\}\}/

    /// Replaces every `{{…}}` in a template with the text of the variable it names.
    func resolve(_ template: String) -> String {
        template.replacing(Self.reference) { match in lookup(String(match.output.1))?.text ?? "" }
    }

    /// A parameter that is exactly one `{{…}}` keeps the variable's type, so lists stay lists.
    private func resolveValue(_ template: String) -> Value {
        if let match = template.wholeMatch(of: Self.reference), let value = lookup(String(match.output.1)) {
            return value
        }
        return .text(resolve(template))
    }

    /// `a2.Provided Input` names an action's output; a bare name like `Shortcut Input` or
    /// `Current Date` is looked up as a magic variable.
    private func lookup(_ name: String) -> Value? {
        if name == "Current Date" { return .text(Date.now.formatted(runDate)) }
        if let dot = name.firstIndex(of: "."), let byName = outputs[String(name[..<dot])] {
            return byName[String(name[name.index(after: dot)...])]
        }
        return outputs.values.compactMap { $0[name] }.first
    }

    // MARK: Helpers

    private func required(_ action: Action, _ key: String) throws -> String {
        guard let value = action.string(key) else { throw PipelineError.missingParameter(action: action.id, name: key) }
        return value
    }

    private func note(_ action: Action, _ text: String) {
        details[action.id, default: StepDetail()].note = text
    }

    private func split(_ text: String, by separator: String, custom: String?) -> [String] {
        let parts: [String]
        switch separator.lowercased() {
        case "new lines": parts = text.components(separatedBy: .newlines)
        case "spaces": parts = text.components(separatedBy: .whitespaces)
        case "every character": parts = text.map(String.init)
        default: parts = text.components(separatedBy: custom ?? separator)
        }
        // Drop blank pieces: the model sometimes opens with an empty line, which would
        // otherwise become "First Item" and fail validation.
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func pick(from items: [String], position: String, index: String?) -> String {
        switch position.lowercased() {
        case "last item": return items.last ?? ""
        case "random item": return items.randomElement() ?? ""
        case "item at index":
            let i = (index.flatMap(Int.init) ?? 1) - 1
            return items.indices.contains(i) ? items[i] : ""
        default: return items.first ?? ""
        }
    }

    private func evaluate(_ input: String, _ condition: String, _ value: String) -> Bool {
        switch condition.lowercased() {
        case "begins with": input.hasPrefix(value)
        case "ends with": input.hasSuffix(value)
        case "contains": input.localizedCaseInsensitiveContains(value)
        case "does not contain": !input.localizedCaseInsensitiveContains(value)
        case "is": input == value
        case "is not": input != value
        case "does not have any value": input.isEmpty
        default: !input.isEmpty
        }
    }

    func format(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1))
    }
}
