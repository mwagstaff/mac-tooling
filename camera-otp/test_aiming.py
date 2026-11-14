"""Check physical aiming directions and mirrored masks without a camera.

Pass an optional PNG path to render synthetic RSA/Authenticator guide fixtures.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(__file__).with_name("camera_otp.swift").read_text()
preview = source.split("struct PhoneOutline {", 1)[1].split("final class MirrorControl", 1)[0]
tests = r'''
func box(_ x: Double, _ y: Double) -> CGRect {
    CGRect(x: x - 0.02, y: y - 0.02, width: 0.04, height: 0.04)
}
precondition(Aiming.direction(for: box(0.2, 0.5)).contains("← towards your left"))
precondition(Aiming.direction(for: box(0.8, 0.5)).contains("→ towards your right"))
precondition(Aiming.direction(for: box(0.5, 0.2)).contains("↑ raise"))
precondition(Aiming.direction(for: box(0.5, 0.8)).contains("↓ lower"))
precondition(Aiming.direction(for: box(0.5, 0.5)).contains("Hold still"))
precondition(Aiming.direction(for: nil).contains("whole phone"))
let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
let size = CGSize(width: 1280, height: 720)
let point = CGPoint(x: 0.25, y: 0.75)
precondition(Aiming.previewPoint(point, size: size, bounds: bounds, mirrored: false) == CGPoint(x: 160, y: 270))
precondition(Aiming.previewPoint(point, size: size, bounds: bounds, mirrored: true) == CGPoint(x: 480, y: 270))
let square = CGRect(x: 0, y: 0, width: 640, height: 640)
precondition(Aiming.previewPoint(point, size: size, bounds: square, mirrored: false) == CGPoint(x: 160, y: 410))
let phone = PhoneOutline(points: [CGPoint(x: 0.18, y: 0.88), CGPoint(x: 0.41, y: 0.85),
                                 CGPoint(x: 0.43, y: 0.12), CGPoint(x: 0.2, y: 0.1)])
precondition(abs(phone.box.midX - 0.305) < 0.001)
let longestHint = Aiming.direction(for: box(0.8, 0.8)) as NSString
precondition(longestHint.size(withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium)]).width < 600)

func outline(_ box: CGRect) -> PhoneOutline {
    PhoneOutline(points: [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
                          CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.minY)])
}
let screen = outline(CGRect(x: 0.1, y: 0.1, width: 0.25, height: 0.75))
let face = CGRect(x: 0.55, y: 0.3, width: 0.2, height: 0.4)
let faceOutline = outline(face)
let codeBox = CGRect(x: 0.15, y: 0.45, width: 0.1, height: 0.04)
var tracker = PhoneTracker()
for i in 0..<5 {
    precondition(tracker.update([faceOutline], faces: [face], text: face.insetBy(dx: 0.05, dy: 0.1), now: Double(i)) == nil,
                 "Face must be rejected even if OCR reports text there")
    precondition(tracker.update([screen], faces: [], text: nil, now: Double(i)) == nil,
                 "Isolated detections separated by long gaps cannot acquire")
}
precondition(tracker.update([screen, faceOutline], faces: [face], text: codeBox, now: 10) == nil)
precondition(tracker.update([faceOutline, screen], faces: [face], text: codeBox, now: 10.1) == nil)
precondition(tracker.update([screen, faceOutline], faces: [face], text: codeBox, now: 10.2)?.box == screen.box,
             "Three stable detections acquire the phone, ignoring a central face")
precondition(tracker.update([], faces: [], text: nil, now: 10.4)?.box == screen.box,
             "Brief detector dropout does not flash grey")
precondition(tracker.update([], faces: [], text: nil, now: 10.9) == nil,
             "Lost phone opening expires")
for i in 0..<3 { _ = tracker.update([screen], faces: [], text: codeBox, now: 11 + Double(i) * 0.1) }
precondition(tracker.update([screen], faces: [screen.box], text: nil, now: 11.21) == nil,
             "Face entering a retained opening hides it immediately")
var jitter = PhoneTracker()
for i in 0..<3 { _ = jitter.update([screen], faces: [], text: codeBox, now: Double(i) * 0.1) }
let shifted = outline(screen.box.offsetBy(dx: 0.02, dy: 0))
let smoothed = jitter.update([shifted, faceOutline], faces: [], text: nil, now: 0.3)!
precondition(smoothed.box.minX > screen.box.minX && smoothed.box.minX < shifted.box.minX,
             "Smooth the existing phone, do not jump to a different rectangle")
precondition(jitter.update([faceOutline], faces: [], text: nil, now: 1.1) == nil,
             "Unrelated rectangle cannot take over a lost lock")
var unreadable = PhoneTracker()
precondition(unreadable.update([screen], faces: [], text: nil, now: 0) == nil)
precondition(unreadable.update([screen], faces: [], text: nil, now: 0.25) == nil)
precondition(unreadable.update([screen], faces: [], text: nil, now: 0.5)?.box == screen.box,
             "Stable phone becomes visible before OCR succeeds")
var schedule = AnalysisSchedule()
precondition(schedule.begin(at: 0))
schedule.finish(at: 0.05)
precondition(!schedule.begin(at: 0.2))
precondition(schedule.begin(at: 0.25))
schedule.finish(at: 1)
precondition(!schedule.begin(at: 1.05), "Slow analysis must leave CPU breathing room")
precondition(schedule.begin(at: 1.1))
print("Aiming, phone tracking and analysis-rate regression checks passed")

if CommandLine.arguments.count > 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Synthetic blur fixtures — no camera"
    let container = NSView(frame: window.contentView!.bounds)
    for index in 0..<4 {
        let panel = NSView(frame: CGRect(x: CGFloat(index % 2) * 640, y: CGFloat(index / 2) * 360,
                                        width: 640, height: 360))
        panel.wantsLayer = true
        for y in 0..<18 {
            for x in 0..<32 {
                let tile = CALayer()
                tile.frame = CGRect(x: x * 20, y: y * 20, width: 20, height: 20)
                tile.backgroundColor = ((x + y) % 2 == 0 ? NSColor.systemTeal : NSColor.white).cgColor
                panel.layer!.addSublayer(tile)
            }
        }
        let silhouette = CALayer()
        silhouette.frame = CGRect(x: index % 2 == 0 ? 115 : 365, y: 36, width: 160, height: 280)
        silhouette.backgroundColor = NSColor.darkGray.cgColor
        silhouette.cornerRadius = 16
        panel.layer!.addSublayer(silhouette)
        let screenText = CATextLayer()
        screenText.frame = CGRect(x: 10, y: 125, width: 140, height: 35)
        screenText.string = "SCREEN"
        screenText.fontSize = 20
        screenText.alignmentMode = .center
        silhouette.addSublayer(screenText)
        let guide = AimingGuide(frame: bounds)
        guide.accountMode = index >= 2
        guide.detected = index == 3
        guide.mirrored = index % 2 == 1
        guide.phone = index == 2 ? nil : phone
        panel.addSubview(guide.backgroundBlur)
        panel.addSubview(guide)
        container.addSubview(panel)
    }
    window.contentView = container
    window.center()
    window.orderFrontRegardless()
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), CommandLine.arguments[1]]
        try! capture.run()
        capture.waitUntilExit()
        precondition(capture.terminationStatus == 0)
        app.terminate(nil)
    }
    app.run()
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "main.swift").write_text("import AppKit\nimport QuartzCore\nstruct PhoneOutline {" + preview + tests)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test"), *sys.argv[1:]], check=True)
