// Reads a 6-digit code (e.g. an RSA SecurID OTP) held up to the Mac's built-in
// or USB camera and copies it to the clipboard. Fully on-device: AVFoundation + Vision.
import AVFoundation
import AppKit
import Vision

// Account mode is opt-in; the RSA reader retains its existing behaviour.
struct AccountText {
    let text: String
    let box: CGRect
    var confidence: Float = 1
}

enum AccountCode {
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    static func digits(_ text: String) -> String? {
        let value = text.filter { !$0.isWhitespace }
        return value.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) } ? value : nil
    }

    static func match(_ lines: [AccountText], account: String) -> String? {
        let labels = lines.filter { normalized($0.text) == normalized(account) }
        guard labels.count == 1, let label = labels.first, label.confidence >= 0.8 else { return nil }
        // Vision coordinates run upwards. Only use the code immediately below
        // this label, with a shared horizontal span and no intervening text.
        let below = lines.filter {
            $0.box.midY < label.box.minY &&
            label.box.minY - $0.box.maxY < label.box.height * 5 &&
            $0.box.maxX > label.box.minX && $0.box.minX < label.box.maxX
        }
        guard let nearest = below.max(by: { $0.box.midY < $1.box.midY }) else { return nil }
        let row = below.filter { abs($0.box.midY - nearest.box.midY) < min($0.box.height, nearest.box.height) * 0.4 }
            .sorted { $0.box.minX < $1.box.minX }
        guard row.allSatisfy({ $0.confidence >= 0.8 }) else { return nil }
        if row.count == 1 { return digits(row[0].text) }
        guard row.count == 2,
              row.allSatisfy({ $0.text.count == 3 && $0.text.utf8.allSatisfy { (48...57).contains($0) } }),
              row[1].box.minX - row[0].box.maxX < max(row[0].box.width, row[1].box.width) else { return nil }
        return digits(row.map(\.text).joined())
    }
}

/// The RSA app shows 000000 while it loads, so give that up to 5 seconds to
/// change before treating it as a genuine code.
struct PlaceholderGate {
    private var firstSeen: Date?

    mutating func accepts(_ code: String, at now: Date = Date()) -> Bool {
        guard code == "000000" else { return true }
        let firstSeen = firstSeen ?? now
        self.firstSeen = firstSeen
        return now.timeIntervalSince(firstSeen) >= 5
    }
}

final class CodeReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onCode: ((String) -> Void)?
    var onGuidance: ((String, Bool) -> Void)?

    private let queue = DispatchQueue(label: "camera-otp.frames", qos: .userInteractive)
    private let handler = VNSequenceRequestHandler()
    // Fast OCR scans the whole frame to find the code; accurate OCR then reads
    // just that region. Fast alone can misread consistently (e.g. 8 as 6).
    private let locate = textRequest(.fast)
    private let read = textRequest(.accurate)
    private var lastCode: String?
    private var placeholderGate = PlaceholderGate()
    private var done = false
    var account: String?
    private var stableSince: Date?

    func configure() throws {
        // Prefer the built-in FaceTime camera, then a USB webcam (e.g. on a Mac
        // mini), over a Continuity Camera iPhone, which also reports as external.
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices
        let preferred = devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first { $0.deviceType == .external && !$0.isContinuityCamera }
        guard let device = preferred ?? AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "camera-otp", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }
        session.beginConfiguration()
        session.addInput(try AVCaptureDeviceInput(device: device))
        // Not 1080p: on the real camera, fast OCR then failed to find the code at all.
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true  // always OCR the freshest frame
        // Camera-native format, so no colour conversion before Vision.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// Loads the OCR models on a blank frame while the camera is still starting,
    /// so the first real frame doesn't pay the model-load cost.
    func warmUp() {
        queue.async { [self] in
            var blank: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &blank)
            if let blank { try? handler.perform([locate, read], on: blank) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !done, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let code = code(in: pixels)
        var message = code == nil ? "Centre the text in the guide and hold still" : "Code detected — hold still"
        if account != nil && code != nil && Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30) >= 25 {
            message = "Waiting for the next code — hold still"
        } else if account == nil && code == "000000" {
            message = "Waiting for the RSA token to finish loading"
        }
        DispatchQueue.main.async { self.onGuidance?(message, code != nil) }
        if account != nil {
            // Leave time to fill and submit near the usual 30-second TOTP rollover.
            // This is a local-clock guard, not proof of the phone's remaining time.
            guard Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30) < 25 else {
                lastCode = nil
                stableSince = nil
                return
            }
            if code != lastCode { stableSince = Date() }
            defer { lastCode = code }
            guard let code, code == lastCode, let since = stableSince,
                  Date().timeIntervalSince(since) >= 0.6 else { return }
            done = true
            DispatchQueue.main.async { self.onCode?(code) }
            return
        }
        // Require two consecutive frames to agree, guarding against a one-off misread.
        if let code, code == lastCode, placeholderGate.accepts(code) {
            done = true
            DispatchQueue.main.async { self.onCode?(code) }
        }
        lastCode = code
    }

    /// The code in one frame, only if fast and accurate OCR agree on it.
    func code(in pixels: CVPixelBuffer) -> String? {
        if let account {
            read.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            do { try handler.perform([read], on: pixels, orientation: .up) } catch { return nil }
            let lines = (read.results ?? []).compactMap { observation -> AccountText? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return AccountText(text: candidate.string, box: observation.boundingBox, confidence: candidate.confidence)
            }
            return AccountCode.match(lines, account: account)
        }
        try? handler.perform([locate], on: pixels, orientation: .up)
        guard let found = Self.match(in: locate.results ?? [], candidates: 3) else { return nil }
        read.regionOfInterest = found.box
            .insetBy(dx: -found.box.width * 0.2, dy: -found.box.height * 0.5)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        try? handler.perform([read], on: pixels, orientation: .up)
        guard let code = Self.match(in: read.results ?? [], candidates: 1)?.codes.first,
              found.codes.contains(code) else { return nil }
        return code
    }

    /// 6-digit codes among each observation's top candidates, and where they are.
    static func match(in observations: [VNRecognizedTextObservation],
                      candidates: Int) -> (codes: [String], box: CGRect)? {
        var halves: [(text: String, box: CGRect)] = []
        for observation in observations {
            let texts = observation.topCandidates(candidates).map(\.string)
            let codes = texts.compactMap {
                $0.firstMatch(of: #/\b\d{3} ?\d{3}\b/#).map { String($0.output.filter(\.isNumber)) }
            }
            if !codes.isEmpty { return (codes, observation.boundingBox) }
            // Vision sometimes splits "709 945" into two observations.
            if let text = texts.first, text.wholeMatch(of: #/\d{3}/#) != nil {
                halves.append((text, observation.boundingBox))
            }
        }
        halves.sort { $0.box.minX < $1.box.minX }
        for (i, left) in halves.enumerated() {
            for right in halves[(i + 1)...]
            where abs(left.box.midY - right.box.midY) < left.box.height / 2 {
                return ([left.text + right.text], left.box.union(right.box))
            }
        }
        return nil
    }
}

private func textRequest(_ level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
    let r = VNRecognizeTextRequest()
    r.recognitionLevel = level
    r.usesLanguageCorrection = false
    return r
}

// MARK: - Main

let reader = CodeReader()

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2 && arguments[0] == "--account" && !arguments[1].isEmpty {
    reader.account = arguments[1]
} else if !arguments.isEmpty {
    fail("Usage: camera-otp [--account 'Service: account']")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func start() {
    do { try reader.configure() } catch { fail("camera-otp: \(error.localizedDescription)") }
    reader.warmUp()
    DispatchQueue.global(qos: .userInteractive).async { reader.session.startRunning() }
    DispatchQueue.main.async(execute: showPreview)
}

/// Never takes the keyboard, so typing stays in the terminal. A non-activating
/// panel would otherwise become key while the terminal still looks frontmost.
final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AimingGuide: NSView {
    var accountMode = false
    var detected = false { didSet { if oldValue != detected { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let target = NSRect(x: 80, y: accountMode ? 96 : 118,
                            width: bounds.width - 160, height: accountMode ? 168 : 124)
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(roundedRect: target, xRadius: 14, yRadius: 14))
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        mask.fill()

        let border = NSBezierPath(roundedRect: target, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.7).setStroke()
        border.lineWidth = 6
        border.stroke()
        (detected ? NSColor.systemGreen : NSColor.white).setStroke()
        border.lineWidth = 3
        border.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let title = accountMode ? "Account name + six-digit code" : "Six-digit RSA code"
        (title as NSString).draw(in: NSRect(x: 20, y: bounds.height - 52, width: bounds.width - 40, height: 26),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                                                 .foregroundColor: NSColor.white, .paragraphStyle: style])
        let hint = "Aim the text here — you don’t need the whole phone in view"
        (hint as NSString).draw(in: NSRect(x: 20, y: 28, width: bounds.width - 40, height: 22),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                                .foregroundColor: NSColor.white, .paragraphStyle: style])
    }
}

final class MirrorControl: NSObject {
    let preview: AVCaptureVideoPreviewLayer
    let preferences = UserDefaults(suiteName: "dev.mac-tooling.camera-otp")!

    init(preview: AVCaptureVideoPreviewLayer) { self.preview = preview }

    @objc func change(_ sender: NSButton) {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = sender.state == .on
        preferences.set(sender.state == .on, forKey: "mirrorPreview")
    }
}

// NSControl targets are weak; retain the preview controller for the capture's lifetime.
var mirrorControl: MirrorControl?

func showPreview() {
    // Stay visible whichever app is in front, as this app never goes active.
    let window = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled, .closable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
    window.hidesOnDeactivate = false
    window.title = reader.account.map { "Looking for \($0)" } ?? "Hold your phone up to the camera"
    window.level = .floating
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 440))
    let cameraView = NSView(frame: NSRect(x: 0, y: 80, width: 640, height: 360))
    cameraView.wantsLayer = true
    let preview = AVCaptureVideoPreviewLayer(session: reader.session)
    preview.videoGravity = .resizeAspect
    cameraView.layer = preview
    view.addSubview(cameraView)
    let guide = AimingGuide(frame: cameraView.bounds)
    guide.accountMode = reader.account != nil
    guide.setAccessibilityElement(true)
    guide.setAccessibilityLabel(guide.accountMode ? "Camera guide: align the account name and code" : "Camera guide: align the RSA code")
    cameraView.addSubview(guide)

    let status = NSTextField(labelWithString: "Centre the text in the guide and hold still")
    status.frame = NSRect(x: 20, y: 45, width: 600, height: 24)
    status.font = .systemFont(ofSize: 16, weight: .medium)
    status.alignment = .center
    view.addSubview(status)
    reader.onGuidance = { message, detected in
        if status.stringValue != message { status.stringValue = message }
        guide.detected = detected
    }

    let control = MirrorControl(preview: preview)
    mirrorControl = control
    let mirror = NSButton(checkboxWithTitle: "Mirror preview", target: control, action: #selector(MirrorControl.change(_:)))
    mirror.frame = NSRect(x: 20, y: 12, width: 150, height: 22)
    mirror.state = control.preferences.bool(forKey: "mirrorPreview") ? .on : .off
    mirror.isEnabled = preview.connection?.isVideoMirroringSupported == true
    mirror.toolTip = "Flip only the preview if aiming feels backwards. Your choice is remembered for both logins."
    control.change(mirror)
    view.addSubview(mirror)
    let help = NSTextField(labelWithString: "Aiming feels backwards? Try Mirror preview.")
    help.frame = NSRect(x: 185, y: 13, width: 435, height: 20)
    help.textColor = .secondaryLabelColor
    help.alignment = .right
    view.addSubview(help)
    window.contentView = view
    window.center()
    window.orderFrontRegardless()
    NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in exit(1) }
}

reader.onCode = { code in
    if reader.account == nil {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
    print(code)
    exit(0)
}

let app = NSApplication.shared
if reader.account != nil {
    Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
        fail("No unambiguous account code found. Search for the account on your phone and try again.")
    }
}
// Not .accessory: launched from a terminal, that made this app frontmost,
// taking typing away from the token prompt.
app.setActivationPolicy(.prohibited)

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    start()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else { fail("camera-otp: camera access denied") }
        DispatchQueue.main.async(execute: start)
    }
default:
    fail("camera-otp: camera access denied; allow your terminal app in System Settings > Privacy & Security > Camera")
}

app.run()
