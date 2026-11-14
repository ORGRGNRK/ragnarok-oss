import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    fputs("usage: vision-ocr IMAGE\n", stderr)
    exit(64)
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .fast
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]

do {
    let handler = VNImageRequestHandler(url: imageURL)
    try handler.perform([request])
    let observations = (request.results ?? []).sorted {
        if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        return $0.boundingBox.minX < $1.boundingBox.minX
    }
    let recognized: [[String: Any]] = observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let bounds = observation.boundingBox
        return [
            "text": candidate.string.replacingOccurrences(of: "\n", with: " "),
            "confidence": candidate.confidence,
            "x": bounds.origin.x,
            "y": bounds.origin.y,
            "width": bounds.size.width,
            "height": bounds.size.height
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: recognized)
    FileHandle.standardOutput.write(data)
} catch {
    fputs("Vision OCR failed: \(error)\n", stderr)
    exit(1)
}
