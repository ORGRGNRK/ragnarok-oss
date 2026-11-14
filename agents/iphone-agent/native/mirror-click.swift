import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    fputs("usage: mirror-click X Y\n", stderr)
    exit(64)
}

let point = CGPoint(x: x, y: y)
guard let mouseDown = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseDown,
    mouseCursorPosition: point,
    mouseButton: .left
), let mouseUp = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseUp,
    mouseCursorPosition: point,
    mouseButton: .left
) else {
    fputs("could not create mouse events\n", stderr)
    exit(1)
}

mouseDown.post(tap: .cghidEventTap)
usleep(40_000)
mouseUp.post(tap: .cghidEventTap)
