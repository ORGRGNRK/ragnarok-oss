import Foundation

actor HarnessRunner {
    var legCeiling = 10
    var stepTries = 3
    var planRounds = 2

    private var receiptsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalAI")
            .appendingPathComponent("receipts.jsonl")
    }

    func runNextLeg(in store: TaskStore, registry: SeatRegistry) async throws -> RunResult {
        let beltId = await store.selectedBeltId
        let belt = await store.selectedBelt
        if let task = await store.tasks(in: .plan, beltId: beltId).first(where: { $0.intent == nil }) {
            return try await runRouterLeg(task: task, belt: belt, store: store, registry: registry)
        }
        if let task = await store.tasks(in: .plan, beltId: beltId).last {
            return try await runPlanLeg(task: task, belt: belt, store: store, registry: registry)
        }
        if let task = await store.tasks(in: .queue, beltId: beltId).last {
            return try await runDriverLeg(task: task, belt: belt, store: store, registry: registry)
        }
        if let task = await store.tasks(in: .verify, beltId: beltId).last {
            return try await runVerifyLeg(task: task, belt: belt, store: store, registry: registry)
        }
        return .noWork
    }

    private func runRouterLeg(task: HarnessTask, belt: HarnessBelt, store: TaskStore, registry: SeatRegistry) async throws -> RunResult {
        var routerSeat: (any HarnessSeat)? = await registry.driver
        if routerSeat == nil { routerSeat = await registry.localSeat }
        if routerSeat == nil { routerSeat = await registry.serverSeats.first }
        guard let routerSeat else { return .needSeat("No router seat") }
        do {
            let result = try await HarnessRouter.route(task: task, using: routerSeat)
            let leg = Leg(index: task.legCount + 1, seat: routerSeat.id, verdict: "intent-\(result.intent.rawValue)", notes: "intent: \(result.intent.rawValue)\nreason: \(result.reason)\n\nraw:\n\(result.rawOutput)")
            await store.appendLeg(task.id, leg: leg)
            await store.setIntent(task.id, intent: result.intent, reason: result.reason)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "intent-\(result.intent.rawValue)", leg: leg.index, seat: routerSeat.id)
            if result.intent == .unknown {
                return .moved(task.id, .human, "Router unknown — needs human: \(result.reason)")
            }
            return .stayed(task.id, .plan, "Intent \(result.intent.rawValue) — \(result.reason)")
        } catch {
            let leg = Leg(index: task.legCount + 1, seat: routerSeat.id, verdict: "router-error", notes: "Router failed: \(error.localizedDescription)")
            await store.appendLeg(task.id, leg: leg)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "router-error", leg: leg.index, seat: routerSeat.id)
            await store.setIntent(task.id, intent: .code, reason: "router error fallback to code")
            return .stayed(task.id, .plan, "Router error — fallback to code")
        }
    }

    private func runPlanLeg(task: HarnessTask, belt: HarnessBelt, store: TaskStore, registry: SeatRegistry) async throws -> RunResult {
        if task.intent == .message {
            await store.move(task, to: .queue)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "message-no-plan-needed", leg: task.legCount + 1, seat: "runner")
            return .moved(task.id, .queue, "Message intent — no checklist needed")
        }
        let plannerOpt = await registry.planner
        let driverOptP = await registry.driver
        let planner = plannerOpt ?? driverOptP
        let criticOpt = await registry.critic
        let verifierOptC = await registry.verifier
        let critic = criticOpt ?? verifierOptC
        guard let planner else { return .needSeat("No planner seat configured") }

        if !task.checklist.isEmpty {
            let errors = task.validateForPlan()
            if errors.isEmpty {
                await store.move(task, to: .queue)
                try await appendReceipt(task: task.id, belt: belt.id, verdict: "plan-valid", leg: task.legCount + 1, seat: "runner")
                return .moved(task.id, .queue, "Plan valid — moved to queue")
            } else {
                let leg = Leg(index: task.legCount + 1, seat: "runner", verdict: "invalid-plan", notes: errors.map(\.localizedDescription).joined(separator: "\n"))
                await store.appendLeg(task.id, leg: leg)
                try await appendReceipt(task: task.id, belt: belt.id, verdict: "invalid-plan", leg: leg.index, seat: "runner")
                return .stayed(task.id, .plan, "Plan invalid: \(errors.map(\.localizedDescription).joined(separator: ", "))")
            }
        }

        let prompt = buildPlannerPrompt(task: task)
        let systemPrompt = "You are the CONVEYOR PLANNER. Your ONLY permitted output is a JSON checklist. Format: [{\"description\": \"create file ...\", \"verify\": \"test -f outputs/file.py && python3 outputs/file.py\", \"expect\": \"hi\"}] Rules: At least 1 step, each must have non-empty verify that is NOT true/: /echo, No HUMAN steps, verify must be a real shell check that proves the file exists and works, Intent is \(task.effectiveIntent.rawValue). Example for code: [{\"description\":\"Create outputs/hello.py that prints hi\",\"verify\":\"test -f outputs/hello.py && python3 outputs/hello.py\",\"expect\":\"hi\"}]"

        do {
            let raw = try await planner.generate(prompt: prompt, systemPrompt: systemPrompt)
            let checklist = try parseChecklistJSON(raw)
            let validation = HarnessTask(title: task.title, checklist: checklist, legs: [], legCount: 0).validateForPlan()
            if !validation.isEmpty && task.effectiveIntent != .message {
                let leg = Leg(index: task.legCount + 1, seat: planner.id, verdict: "planner-invalid", notes: "Planner produced invalid checklist:\n\(validation.map(\.localizedDescription).joined(separator: "\n"))\n\nRaw:\n\(raw)")
                await store.appendLeg(task.id, leg: leg)
                await store.updateChecklist(task.id, checklist: checklist)
                try await appendReceipt(task: task.id, belt: belt.id, verdict: "planner-invalid", leg: leg.index, seat: planner.id)
                return .stayed(task.id, .plan, "Planner output invalid")
            }
            if let critic {
                let criticPrompt = buildCriticPrompt(task: task, checklist: checklist)
                let criticSystem = "You are the CONVEYOR CRITIC. Output APPROVED if checklist has at least one real verify command that is not true/:/echo and will prove the task done. Otherwise PROBLEM: explain."
                let criticRaw = try await critic.generate(prompt: criticPrompt, systemPrompt: criticSystem)
                if criticRaw.uppercased().contains("APPROVED") {
                    await store.updateChecklist(task.id, checklist: checklist)
                    let leg = Leg(index: task.legCount + 1, seat: "\(planner.id)+\(critic.id)", verdict: "plan-approved", notes: "Intent: \(task.effectiveIntent.rawValue)\nPlanner:\n\(raw)\n\nCritic: APPROVED")
                    await store.appendLeg(task.id, leg: leg)
                    await store.move(task, to: .queue)
                    try await appendReceipt(task: task.id, belt: belt.id, verdict: "plan-approved", leg: leg.index, seat: leg.seat)
                    return .moved(task.id, .queue, "Plan approved by critic")
                } else {
                    let leg = Leg(index: task.legCount + 1, seat: critic.id, verdict: "plan-needs-revision", notes: "Intent: \(task.effectiveIntent.rawValue)\nChecklist:\n\(raw)\n\nCritic:\n\(criticRaw)")
                    await store.appendLeg(task.id, leg: leg)
                    await store.updateChecklist(task.id, checklist: checklist)
                    try await appendReceipt(task: task.id, belt: belt.id, verdict: "plan-needs-revision", leg: leg.index, seat: critic.id)
                    return .stayed(task.id, .plan, "Critic found problems — needs revision")
                }
            } else {
                await store.updateChecklist(task.id, checklist: checklist)
                await store.move(task, to: .queue)
                return .moved(task.id, .queue, "Plan written (no critic)")
            }
        } catch {
            let leg = Leg(index: task.legCount + 1, seat: planner.id, verdict: "planner-error", notes: "Planner failed: \(error.localizedDescription)")
            await store.appendLeg(task.id, leg: leg)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "planner-error", leg: leg.index, seat: planner.id)
            return .failed(task.id, "Planner error: \(error.localizedDescription)")
        }
    }

    private func runDriverLeg(task: HarnessTask, belt: HarnessBelt, store: TaskStore, registry: SeatRegistry) async throws -> RunResult {
        let driver = await registry.driver
        guard let driver else { return .needSeat("No driver seat configured") }
        await store.move(task, to: .running)
        let taskFolder = try? TaskFolder.ensure(for: task.id)
        let prompt = buildDriverPrompt(task: task, taskFolder: taskFolder)
        let systemPrompt = buildDriverSystem(task: task, belt: belt, taskFolder: taskFolder)
        var rawOutput = ""
        do {
            rawOutput = try await driver.generate(prompt: prompt, systemPrompt: systemPrompt)
        } catch {
            let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "seat-crash", notes: "Seat crashed: \(error.localizedDescription)\n\nLast output:\n\(rawOutput)")
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .queue)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "seat-crash", leg: leg.index, seat: driver.id)
            return .stayed(task.id, .queue, "Seat crashed — refunded to queue")
        }

        var writtenFiles: [String] = []
        if let folder = taskFolder {
            writtenFiles = performImplicitWrites(from: rawOutput, taskFolder: folder, checklist: task.checklist)
        }

        let resultLine = rawOutput.components(separatedBy: "\n").last { $0.contains("RESULT:") } ?? ""
        if resultLine.contains("RESULT: blocked") {
            let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "blocked", notes: "Wrote: \(writtenFiles.joined(separator: ", "))\n\n\(rawOutput)")
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .failed)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "blocked", leg: leg.index, seat: driver.id)
            return .moved(task.id, .failed, "Blocked: \(resultLine)")
        }
        if task.effectiveIntent == .message {
            let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "message-done", notes: rawOutput)
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .verify)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "message-done", leg: leg.index, seat: driver.id)
            return .moved(task.id, .verify, "Message produced — to verify")
        }
        let hasDone = resultLine.contains("RESULT: done") || resultLine.contains("RESULT:") == false
        if !hasDone && writtenFiles.isEmpty {
            let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "no-result", notes: rawOutput)
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .failed)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "no-result", leg: leg.index, seat: driver.id)
            return .moved(task.id, .failed, "No RESULT line and no files written — filed as failed")
        }

        let checkResults = HarnessCheckExecutor.runAll(checklist: task.checklist, taskFolder: taskFolder)
        var newChecklist = task.checklist
        var failedHumanSteps: [ChecklistStep] = []
        for (i, result) in checkResults.enumerated() {
            if result.passed && !newChecklist[i].isChecked {
                newChecklist[i].isChecked = true
                newChecklist[i].lastOutput = result.stdout
                newChecklist[i].lastExitCode = result.exitCode
            } else if !result.passed {
                if newChecklist[i].isHuman {
                    failedHumanSteps.append(newChecklist[i])
                } else {
                    newChecklist[i].tries += 1
                    newChecklist[i].lastOutput = result.stdout + "\n" + result.stderr
                    newChecklist[i].lastExitCode = result.exitCode
                }
            }
        }
        await store.updateChecklist(task.id, checklist: newChecklist)
        if task.legCount + 1 >= legCeiling {
            let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "dead-end-ceiling", notes: "Wrote: \(writtenFiles)\n\n\(rawOutput)")
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .failed)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "dead-end-ceiling", leg: leg.index, seat: driver.id)
            return .moved(task.id, .failed, "Dead end — leg ceiling \(legCeiling)")
        }
        let untickedNonHuman = newChecklist.filter { !$0.isChecked && !$0.isHuman }
        if !untickedNonHuman.isEmpty {
            let failDetails = untickedNonHuman.map { "\($0.description) -> \($0.verify) last: \($0.lastOutput ?? "")" }.joined(separator: "\n")
            let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "needs-more-work", notes: "Wrote: \(writtenFiles)\n\nOutput:\n\(rawOutput)\n\nFails:\n\(failDetails)")
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .queue)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "needs-more-work", leg: leg.index, seat: driver.id)
            return .moved(task.id, .queue, "\(untickedNonHuman.count) checks still failing — back to queue")
        }
        if !failedHumanSteps.isEmpty {
            let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "needs-human", notes: rawOutput)
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .human)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "needs-human", leg: leg.index, seat: driver.id)
            return .moved(task.id, .human, "Needs human — \(failedHumanSteps.count) HUMAN steps")
        }
        let leg = Leg(index: task.legCount + 1, seat: driver.id, verdict: "driver-pass", notes: "Wrote: \(writtenFiles.joined(separator: ", "))\n\n\(rawOutput)")
        await store.appendLeg(task.id, leg: leg)
        await store.move(task, to: .verify)
        try await appendReceipt(task: task.id, belt: belt.id, verdict: "driver-pass", leg: leg.index, seat: driver.id)
        return .moved(task.id, .verify, "All checks passed — to verify (wrote \(writtenFiles.count) files)")
    }

    private func performImplicitWrites(from output: String, taskFolder: URL, checklist: [ChecklistStep]) -> [String] {
        let candidatePaths = extractFilePaths(fromChecklist: checklist)
        let codeBlocks = extractCodeBlocks(from: output)
        if codeBlocks.isEmpty {
            return writeExplicitFileMarkers(from: output, taskFolder: taskFolder)
        }
        var written: [String] = []
        let explicitWrites = parseWroteLines(from: output)
        for (path, content) in explicitWrites {
            if writeFile(path: path, content: content, taskFolder: taskFolder) {
                written.append(path)
            }
        }
        if !written.isEmpty { return written }
        let blocksSorted = codeBlocks.sorted { $0.count > $1.count }
        if let mainPath = candidatePaths.first, let mainContent = blocksSorted.first {
            if writeFile(path: mainPath, content: mainContent, taskFolder: taskFolder) {
                written.append(mainPath)
            }
            for (i, extraPath) in candidatePaths.dropFirst().enumerated() {
                if i < blocksSorted.count - 1 {
                    if writeFile(path: extraPath, content: blocksSorted[i+1], taskFolder: taskFolder) {
                        written.append(extraPath)
                    }
                }
            }
            return written
        }
        if let firstBlock = blocksSorted.first {
            let inferred = inferPathFromCode(firstBlock)
            if writeFile(path: inferred, content: firstBlock, taskFolder: taskFolder) {
                written.append(inferred)
            }
        }
        written.append(contentsOf: writeExplicitFileMarkers(from: output, taskFolder: taskFolder))
        return Array(Set(written))
    }

    private func extractFilePaths(fromChecklist checklist: [ChecklistStep]) -> [String] {
        var paths: [String] = []
        let pattern = #"([A-Za-z0-9_\-./]+\.(py|csv|json|md|txt|sh|swift|js|ts|html))"#
        for step in checklist {
            let text = step.verify + " " + step.description
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = text as NSString
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    let p = ns.substring(with: m.range(at: 1))
                    if !paths.contains(p) { paths.append(p) }
                }
            }
        }
        return paths.sorted { a, b in
            let aOut = a.hasPrefix("outputs/")
            let bOut = b.hasPrefix("outputs/")
            if aOut != bOut { return aOut }
            return a.count < b.count
        }
    }

    private func extractCodeBlocks(from text: String) -> [String] {
        var blocks: [String] = []
        let pattern = #"```(?:[A-Za-z0-9_\-]*\n)?([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let content = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.count > 10 { blocks.append(content) }
            }
        }
        if blocks.isEmpty {
            let lines = text.components(separatedBy: "\n")
            if let idx = lines.firstIndex(where: { $0.contains("def ") || $0.contains("import ") || $0.contains("print(") }) {
                let code = lines[idx...].joined(separator: "\n")
                if code.count > 20 { blocks.append(code) }
            }
        }
        return blocks
    }

    private func parseWroteLines(from text: String) -> [(String, String)] {
        var results: [(String, String)] = []
        let codeBlocks = extractCodeBlocks(from: text)
        guard let firstBlock = codeBlocks.first else { return [] }
        for line in text.components(separatedBy: "\n") where line.lowercased().contains("wrote ") {
            if let path = extractFilePaths(fromChecklist: [ChecklistStep(description: line, verify: line)]).first {
                results.append((path, firstBlock))
            }
        }
        return results
    }

    private func writeExplicitFileMarkers(from text: String, taskFolder: URL) -> [String] {
        var written: [String] = []
        let pattern = #"FILE:\s*([A-Za-z0-9_\-./]+)\s*\n```(?:[A-Za-z0-9_\-]*\n)?([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let path = ns.substring(with: m.range(at: 1))
            let content = ns.substring(with: m.range(at: 2))
            if writeFile(path: path, content: content, taskFolder: taskFolder) {
                written.append(path)
            }
        }
        return written
    }

    private func writeFile(path: String, content: String, taskFolder: URL) -> Bool {
        var relative = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if relative.hasPrefix("~/") || relative.hasPrefix("/") { return false }
        if relative.hasPrefix("outputs/") == false && !relative.contains("/") {
            relative = "outputs/" + relative
        }
        let dest = taskFolder.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: dest, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func inferPathFromCode(_ code: String) -> String {
        if code.contains("import pandas") || code.contains(".csv") { return "outputs/report.csv" }
        return "outputs/output.py"
    }

    private func runVerifyLeg(task: HarnessTask, belt: HarnessBelt, store: TaskStore, registry: SeatRegistry) async throws -> RunResult {
        let vOpt = await registry.verifier
        let dOpt = await registry.driver
        let verifier = vOpt ?? dOpt
        guard let verifier else { return .needSeat("No verifier seat") }
        let taskFolder = try? TaskFolder.ensure(for: task.id)
        if task.effectiveIntent != .message {
            let preChecks = HarnessCheckExecutor.runAll(checklist: task.checklist, taskFolder: taskFolder)
            if preChecks.contains(where: { !$0.passed }) {
                let leg = Leg(index: task.legCount + 1, seat: "runner", verdict: "verify-precheck-fail", notes: "Pre-check failed: \(preChecks.filter{!$0.passed}.map{"\($0.stepId): \($0.stdout) \($0.stderr)"}.joined(separator: "\n"))")
                await store.appendLeg(task.id, leg: leg)
                await store.move(task, to: .queue)
                try await appendReceipt(task: task.id, belt: belt.id, verdict: "verify-precheck-fail", leg: leg.index, seat: "runner")
                return .moved(task.id, .queue, "Pre-check failed — regression")
            }
        }
        let prompt = buildVerifierPrompt(task: task, taskFolder: taskFolder)
        let systemPrompt = "You are the CONVEYOR VERIFIER on \(belt.displayName). Intent is \(task.effectiveIntent.rawValue). Output CONFIRMED: or REFUTED: per step, then VERDICT: pass or fail."
        var rawOutput = ""
        do {
            rawOutput = try await verifier.generate(prompt: prompt, systemPrompt: systemPrompt)
        } catch {
            let leg = Leg(index: task.legCount + 1, seat: verifier.id, verdict: "verifier-crash", notes: "Verifier crashed: \(error.localizedDescription)")
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .queue)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "verifier-crash", leg: leg.index, seat: verifier.id)
            return .stayed(task.id, .queue, "Verifier crashed — refunded")
        }
        let verdictLine = rawOutput.components(separatedBy: "\n").last { $0.contains("VERDICT:") } ?? ""
        if verdictLine.contains("VERDICT: pass") {
            let leg = Leg(index: task.legCount + 1, seat: verifier.id, verdict: "pass", notes: rawOutput)
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .done)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: "pass", leg: leg.index, seat: verifier.id)
            return .moved(task.id, .done, "Verified — done")
        } else {
            let verdict = verdictLine.isEmpty ? "verify-no-verdict" : "fail"
            let leg = Leg(index: task.legCount + 1, seat: verifier.id, verdict: verdict, notes: rawOutput)
            await store.appendLeg(task.id, leg: leg)
            await store.move(task, to: .queue)
            try await appendReceipt(task: task.id, belt: belt.id, verdict: verdict, leg: leg.index, seat: verifier.id)
            return .moved(task.id, .queue, "Verifier failed — back to queue")
        }
    }

    private func parseChecklistJSON(_ raw: String) throws -> [ChecklistStep] {
        let jsonStr: String
        if let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]") {
            jsonStr = String(raw[start...end])
        } else {
            jsonStr = raw
        }
        struct RawStep: Codable {
            var description: String
            var verify: String
            var expect: String?
            var isHuman: Bool?
        }
        let data = jsonStr.data(using: .utf8) ?? Data()
        let rawSteps = try JSONDecoder().decode([RawStep].self, from: data)
        return rawSteps.map { ChecklistStep(description: $0.description, verify: $0.verify, expect: $0.expect, isHuman: $0.isHuman ?? false) }
    }

    private func buildPlannerPrompt(task: HarnessTask) -> String {
        "Task: \(task.title)\nIntent: \(task.effectiveIntent.rawValue) — \(task.effectiveIntent.blurb)\nReason: \(task.intentReason ?? "")\nCreate checklist JSON: [{\"description\": \"...\", \"verify\": \"command\"}]. Example: [{\"description\":\"Create outputs/hello.py\",\"verify\":\"test -f outputs/hello.py && python3 outputs/hello.py\"}]"
    }

    private func buildCriticPrompt(task: HarnessTask, checklist: [ChecklistStep]) -> String {
        let steps = checklist.enumerated().map { i, s in "\(i+1). \(s.description) :: verify: \(s.verify)" }.joined(separator: "\n")
        return "Task: \(task.title)\nIntent: \(task.effectiveIntent.rawValue)\nProposed:\n\(steps)\nAPPROVED or PROBLEM:"
    }

    private func buildDriverPrompt(task: HarnessTask, taskFolder: URL?) -> String {
        let steps = task.checklist.enumerated().map { i, s in "\(s.isChecked ? "[x]" : "[ ]") \(s.description) :: verify: \(s.verify)" }.joined(separator: "\n")
        let folder = taskFolder?.path ?? "~/LocalAI-Workspace"
        return "Task: \(task.title)\nIntent: \(task.effectiveIntent.rawValue)\nBelt: \(task.beltId)\nFolder: \(folder)/outputs\nLegs: \(task.legCount)/\(legCeiling)\n\nChecklist:\n\(steps)\n\nYou MUST actually create files in \(folder)/outputs/. For each step, write the file then run its verify. Output format:\nFILE: outputs/<name>\n```<content>```\nThen RESULT: done"
    }

    private func buildDriverSystem(task: HarnessTask, belt: HarnessBelt, taskFolder: URL?) -> String {
        let folder = taskFolder?.path ?? "~/Library/Application Support/LocalAI/Tasks/..."
        switch task.effectiveIntent {
        case .message: return "You are CONVEYOR EXECUTOR \(belt.displayName). MESSAGE intent — chat only, no tools, end RESULT: done. Task folder: \(folder)"
        case .script: return "You are CONVEYOR EXECUTOR \(belt.displayName). SCRIPT intent — create files in \(folder)/outputs/ using FILE: outputs/name + code fence. Then run verify commands mentally. End RESULT: done. Task folder: \(folder)"
        case .code: return "You are CONVEYOR EXECUTOR \(belt.displayName). CODE intent — you MUST create files in \(folder)/outputs/. Format: FILE: outputs/<filename> newline ```lang content ```. Example FILE: outputs/hello.py. End RESULT: done. Task folder: \(folder)"
        case .unknown: return "You are CONVEYOR EXECUTOR. UNKNOWN — end RESULT: blocked"
        }
    }

    private func buildVerifierPrompt(task: HarnessTask, taskFolder: URL?) -> String {
        let steps = task.checklist.map { "- \($0.description) :: verify: \($0.verify)" }.joined(separator: "\n")
        return "Task: \(task.title)\nIntent: \(task.effectiveIntent.rawValue)\nFolder: \(taskFolder?.path ?? "~/LocalAI-Workspace")\nChecklist:\n\(steps)\nVerify each by checking file exists and content. Output CONFIRMED: or REFUTED: per step, then VERDICT: pass or fail"
    }

    private func appendReceipt(task: UUID, belt: String, verdict: String, leg: Int, seat: String) async throws {
        let entry: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "task": task.uuidString, "belt": belt, "verdict": verdict, "rc": 0, "log": NSNull(), "leg": leg, "seat": seat]
        guard let data = try? JSONSerialization.data(withJSONObject: entry), let line = String(data: data, encoding: .utf8) else { return }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalAI").appendingPathComponent("receipts.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write((line + "\n").data(using: .utf8)!); try? handle.close() }
    }

    enum RunResult { case noWork; case moved(UUID, Tray, String); case stayed(UUID, Tray, String); case failed(UUID, String); case needSeat(String) }
}
