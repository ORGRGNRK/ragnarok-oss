import Foundation
import FoundationModels

/// The `use_model` action, backed by Apple's on-device foundation model.
enum OnDeviceModel {
    static func respond(to prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw PipelineError.modelUnavailable(describe(reason))
        }
        // A fresh session per run, like the Shortcuts action: no memory between lookups.
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: prompt)
        return response.content
    }

    static var availabilityNote: String? {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            return describe(reason)
        }
        return nil
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "this Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled: "turn on Apple Intelligence in System Settings."
        case .modelNotReady: "the model is still downloading. Try again shortly."
        @unknown default: String(describing: reason)
        }
    }
}
