import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 5,
      let startX = Double(CommandLine.arguments[1]),
      let startY = Double(CommandLine.arguments[2]),
      let endX = Double(CommandLine.arguments[3]),
      let endY = Double(CommandLine.arguments[4]) else {
    fputs("usage: mirror-swipe START_X START_Y END_X END_Y\n", stderr)
    exit(64)
}

let start = CGPoint(x: startX, y: startY)
let end = CGPoint(x: endX, y: endY)
let source = CGEventSource(stateID: .combinedSessionState)
guard let move = CGEvent(
    mouseEventSource: source,
    mouseType: .mouseMoved,
    mouseCursorPosition: start,
    mouseButton: .left
) else {
    fputs("could not create pointer event\n", stderr)
    exit(1)
}
move.post(tap: .cghidEventTap)
usleep(40_000)

let frames = 24
let verticalDelta = Int32(((end.y - start.y) / Double(frames)).rounded())
let horizontalDelta = Int32(((end.x - start.x) / Double(frames)).rounded())
for _ in 1...frames {
    guard let scroll = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 2,
        wheel1: verticalDelta,
        wheel2: horizontalDelta,
        wheel3: 0
    ) else {
        fputs("could not create scroll event\n", stderr)
        exit(1)
    }
    scroll.location = start
    scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    scroll.post(tap: .cghidEventTap)
    usleep(12_000)
}
