import Foundation
import MLXLMCommon
import MLXLLM

protocol HarnessSeat: Sendable {
    var id: String { get }
    var displayName: String { get }
    func generate(prompt: String, systemPrompt: String?) async throws -> String
}

enum SeatError: LocalizedError {
    case notReady(String)
    case generationFailed(String)
    var errorDescription: String? {
        switch self {
        case .notReady(let s): return "Seat not ready: \(s)"
        case .generationFailed(let s): return "Generation failed: \(s)"
        }
    }
}

final class LocalMLXSeat: HarnessSeat, @unchecked Sendable {
    let id = "local"
    let displayName = "On-device (MLX)"
    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        guard let container = await modelManager.container else {
            throw SeatError.notReady("MLX model not loaded — load it in Settings first")
        }
        var chat: [Chat.Message] = []
        if let sys = systemPrompt, !sys.isEmpty {
            chat.append(.system(sys))
        }
        chat.append(.user(prompt))

        var params = GenerateParameters()
        params.temperature = 0.3
        params.maxTokens = 2048
        params.prefill.stepSize = 256

        let userInput = UserInput(chat: chat)

        return try await container.perform(nonSendable: userInput) { (context: ModelContext, input: UserInput) async throws -> String in
            let lmInput = try await context.processor.prepare(input: input)
            let stream = try MLXLMCommon.generate(input: lmInput, parameters: params, context: context)
            var out = ""
            for await event in stream {
                switch event {
                case .chunk(let text): out += text
                case .info: break
                case .toolCall: break
                case .rejectedToolCall: break
                @unknown default: break
                }
            }
            return out
        }
    }
}

final class ServerSeat: HarnessSeat, @unchecked Sendable {
    let id: String
    let displayName: String
    private let base: URL
    private let model: String

    init(id: String = "server", displayName: String, base: URL, model: String) {
        self.id = id
        self.displayName = displayName
        self.base = base
        self.model = model
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        var messages: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": prompt])
        let bodyDict: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "temperature": 0.3,
            "max_tokens": 2048
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        var output = ""
        for try await event in ServerAPI.streamChat(base: base, body: body) {
            switch event {
            case .content(let piece): output += piece
            case .toolCallDelta: break
            case .usage: break
            }
        }
        if output.isEmpty {
            throw SeatError.generationFailed("Server returned empty response for model \(model)")
        }
        return output
    }
}

final class FakeSeat: HarnessSeat, Sendable {
    let id: String
    let displayName: String
    private let response: String

    init(id: String, displayName: String, response: String) {
        self.id = id
        self.displayName = displayName
        self.response = response
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        try await Task.sleep(nanoseconds: 100_000_000)
        return response
    }

    static let passingBuilder = FakeSeat(
        id: "fake-builder",
        displayName: "Fake Builder (passes)",
        response: "I created the report.\nWrote outputs/report.csv with 12 rows.\nRESULT: done\n"
    )
    static let failingVerifier = FakeSeat(
        id: "fake-verifier",
        displayName: "Fake Verifier (fails)",
        response: "CONFIRMED: file exists\nREFUTED: row count is 10 not 12 — wc -l shows 10\nVERDICT: fail\n"
    )
    static let passingVerifier = FakeSeat(
        id: "fake-verifier-pass",
        displayName: "Fake Verifier (passes)",
        response: "CONFIRMED: file exists\nCONFIRMED: row count 12 matches\nVERDICT: pass\n"
    )
}

@MainActor
final class SeatRegistry: ObservableObject {
    @Published var localSeat: LocalMLXSeat?
    @Published var serverSeats: [ServerSeat] = []
    @Published var driverSeatId: String = "local"
    @Published var verifierSeatId: String = "server"
    @Published var plannerSeatId: String = "server"
    @Published var criticSeatId: String = "server"

    private var modelManager: ModelManager?
    private var serverManager: ServerManager?

    func configure(modelManager: ModelManager, serverManager: ServerManager) {
        self.modelManager = modelManager
        self.serverManager = serverManager
        self.localSeat = LocalMLXSeat(modelManager: modelManager)
        if let base = serverManager.base, !serverManager.selectedModel.isEmpty {
            let seat = ServerSeat(
                id: "server",
                displayName: "\(serverManager.selectedModel) @ \(base.host ?? "server")",
                base: base,
                model: serverManager.selectedModel
            )
            serverSeats = [seat]
        }
    }

    func seat(for id: String) -> (any HarnessSeat)? {
        if id == "local" { return localSeat }
        return serverSeats.first { $0.id == id } ?? serverSeats.first
    }

    var driver: (any HarnessSeat)? { seat(for: driverSeatId) }
    var verifier: (any HarnessSeat)? { seat(for: verifierSeatId) }
    var planner: (any HarnessSeat)? { seat(for: plannerSeatId) }
    var critic: (any HarnessSeat)? { seat(for: criticSeatId) }
}
