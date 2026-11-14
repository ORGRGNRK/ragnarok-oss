#!/bin/bash
# Exercise the actual model loader against fake transport responses; no server or model calls.
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/Check.swift" <<'SWIFT'
import Foundation

enum Gate {
    nonisolated(unsafe) static var reply: (Int32, String, String) = (0, "", "")
    static func run(_ path: String, _ args: [String]) -> (Int32, String, String) { reply }
}
enum LocalModels {
    static let lmDisk = "/nonexistent-ragnarok-model-test"
    static func base(_ raw: String) -> String { raw }
}
@main
struct Check {
    @MainActor static func main() async {
        var failures = 0
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "PASS" : "FAIL") \(name)")
            if !pass { failures += 1 }
        }
        func wait(_ loader: LocalModelLoader) async {
            for _ in 0..<200 {
                if !loader.isLoading { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        Gate.reply = (0, #"{"models":[{"name":"z-chat"},{"model":"a-chat"},{"name":"embed-only"}]}"#, "")
        let alexus = LocalModelLoader()
        alexus.refreshAlexus()
        await wait(alexus)
        check("alexus-model-discovery", !alexus.isLoading && alexus.alexusModels.map(\.slug) == ["a-chat", "z-chat"])
        Gate.reply = (7, "", "fixture failure")
        let offline = LocalModelLoader()
        offline.refreshLocalOllama()
        await wait(offline)
        check("ollama-offline-fallback", !offline.isLoading && offline.localOllamaModels == LocalModelLoader.fallbackOllama)
        Gate.reply = (0, "not json", "")
        let malformed = LocalModelLoader()
        malformed.refreshAlexus()
        await wait(malformed)
        check("alexus-malformed-fallback", !malformed.isLoading && malformed.alexusModels == LocalModelLoader.fallbackAlexus)
        Gate.reply = (0, #"{"data":[{"id":"b-chat"},{"id":"a-chat"},{"id":"embed-only"}]}"#, "")
        let studio = LocalModelLoader()
        studio.refreshLMStudio()
        await wait(studio)
        check("lmstudio-model-discovery", !studio.isLoading && studio.lmStudioModels.map(\.slug) == ["a-chat", "b-chat"])
        Gate.reply = (0, #"{"data":[]}"#, "")
        let empty = LocalModelLoader()
        empty.refreshLMStudio()
        await wait(empty)
        check("lmstudio-empty-fallback", !empty.isLoading && empty.lmStudioModels == LocalModelLoader.fallbackLMStudio)
        exit(failures == 0 ? 0 : 1)
    }
}
SWIFT
swiftc -parse-as-library Sources/Heimdall/LocalConfig.swift Sources/Heimdall/LocalModelLoader.swift "$T/Check.swift" -o "$T/check"
"$T/check"
