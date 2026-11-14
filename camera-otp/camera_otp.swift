// Reads a 6-digit code (e.g. an RSA SecurID OTP) held up to the Mac's built-in
// or USB camera and copies it to the clipboard. Fully on-device: AVFoundation + Vision.
import AVFoundation
import AppKit
import CoreImage
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
    var onGuidance: ((String, Bool, PhoneOutline?, CGSize) -> Void)?

    private let queue = DispatchQueue(label: "camera-otp.frames", qos: .userInitiated)
    private var analysisSchedule = AnalysisSchedule()
    private let handler = VNSequenceRequestHandler()
    // Fast OCR scans the whole frame to find the code; accurate OCR then reads
    // just that region. Fast alone can misread consistently (e.g. 8 as 6).
    private let locate = textRequest(.fast)
    private let read = textRequest(.accurate)
    private let rectangles: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 0.75
        request.minimumSize = 0.12
        request.minimumConfidence = 0.7
        request.maximumObservations = 8
        return request
    }()
    private let faces = VNDetectFaceRectanglesRequest()
    private var phoneTracker = PhoneTracker()
    private var textBox: CGRect?
    private var lastCode: String?
    private var placeholderGate = PlaceholderGate()
    private var done = false
    var account: String?
    var previewOnly = false
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
        // Physical movement hints assume the raw camera image, never mirrored OCR.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
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
        guard analysisSchedule.begin(at: ProcessInfo.processInfo.systemUptime) else { return }
        defer { analysisSchedule.finish(at: ProcessInfo.processInfo.systemUptime) }
        let code = code(in: pixels)
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let phone = phone(in: pixels)
        var message = code == nil ? Aiming.direction(for: textBox ?? phone?.box) : "Code detected — hold still"
        if previewOnly && code != nil {
            message = "Code detected — test only; nothing copied or submitted"
        } else if account != nil && code != nil && Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30) >= 25 {
            message = "Waiting for the next code — hold still"
        } else if account == nil && code == "000000" {
            message = "Waiting for the RSA token to finish loading"
        }
        DispatchQueue.main.async { self.onGuidance?(message, code != nil, phone, size) }
        guard !previewOnly else { return }
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

    private func phone(in pixels: CVPixelBuffer) -> PhoneOutline? {
        // Full resolution is useful for OCR, but unnecessary for outlines/faces.
        let scale = min(1, 640 / CGFloat(CVPixelBufferGetWidth(pixels)))
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        do { try VNImageRequestHandler(ciImage: image, orientation: .up).perform([rectangles, faces]) }
        catch {
            phoneTracker = PhoneTracker()
            return nil
        }
        let outlines = (rectangles.results ?? []).map {
            PhoneOutline(points: [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft])
        }
        return phoneTracker.update(outlines, faces: (faces.results ?? []).map(\.boundingBox),
                                   text: textBox, now: ProcessInfo.processInfo.systemUptime)
    }

    /// The code in one frame, only if fast and accurate OCR agree on it.
    func code(in pixels: CVPixelBuffer) -> String? {
        textBox = nil
        if let account {
            read.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            do { try handler.perform([read], on: pixels, orientation: .up) } catch { return nil }
            let lines = (read.results ?? []).compactMap { observation -> AccountText? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return AccountText(text: candidate.string, box: observation.boundingBox, confidence: candidate.confidence)
            }
            let labels = lines.filter { AccountCode.normalized($0.text) == AccountCode.normalized(account) }
            if labels.count == 1 { textBox = labels[0].box }
            return AccountCode.match(lines, account: account)
        }
        try? handler.perform([locate], on: pixels, orientation: .up)
        guard let found = Self.match(in: locate.results ?? [], candidates: 3) else { return nil }
        textBox = found.box
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

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--preview" {
    reader.previewOnly = true
    arguments.removeFirst()
}
if arguments.count == 2 && arguments[0] == "--account" && !arguments[1].isEmpty {
    reader.account = arguments[1]
} else if !arguments.isEmpty {
    fail("Usage: camera-otp [--preview] [--account 'Service: account']")
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

struct PhoneOutline {
    let points: [CGPoint]
    var box: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

// Limit expensive Vision work while AVFoundation keeps the preview smooth.
struct AnalysisSchedule {
    private var next: TimeInterval = 0
    mutating func begin(at now: TimeInterval) -> Bool {
        guard now >= next else { return false }
        next = now + 0.25
        return true
    }
    mutating func finish(at now: TimeInterval) {
        // Leave breathing room even when analysis itself takes longer than 250ms.
        next = max(next, now + 0.1)
    }
}

// Acquire a stable non-face outline even before its text is readable. Once acquired,
// follow that outline rather than switching to whichever rectangle is central.
struct PhoneTracker {
    private var locked: PhoneOutline?
    private var pending: PhoneOutline?
    private var confirmations = 0
    private var lastSeen: TimeInterval = 0
    private var pendingSeen: TimeInterval = 0

    private static func area(_ box: CGRect) -> CGFloat {
        box.isNull ? 0 : box.width * box.height
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = area(a.intersection(b))
        return intersection / max(area(a) + area(b) - intersection, 0.000001)
    }

    private static func overlapsFace(_ box: CGRect, faces: [CGRect]) -> Bool {
        faces.contains { face in
            area(box.intersection(face)) / max(min(area(box), area(face)), 0.000001) > 0.2
        }
    }

    mutating func update(_ outlines: [PhoneOutline], faces: [CGRect], text: CGRect?,
                         now: TimeInterval) -> PhoneOutline? {
        // Never retain a stale opening over a face, even during the grace period.
        if let locked, Self.overlapsFace(locked.box, faces: faces) {
            self.locked = nil
        }
        let candidates = outlines.filter {
            $0.box.height > $0.box.width && !Self.overlapsFace($0.box, faces: faces)
        }
        if let locked {
            let matches = candidates.filter { Self.overlap($0.box, locked.box) > 0.5 }
            if let next = matches.max(by: { Self.overlap($0.box, locked.box) < Self.overlap($1.box, locked.box) }) {
                // Reduce corner jitter without letting the mask lag far behind a hand.
                let smoothed = PhoneOutline(points: zip(locked.points, next.points).map {
                    CGPoint(x: $0.x * 0.25 + $1.x * 0.75, y: $0.y * 0.25 + $1.y * 0.75)
                })
                self.locked = smoothed
                lastSeen = now
                return smoothed
            }
            if now - lastSeen <= 0.65 { return locked }
            self.locked = nil
        }
        // Text helps choose between outlines, but must not gate visual feedback.
        let containingText = text.map { text in candidates.filter { $0.box.contains(text) } } ?? []
        let choices = containingText.isEmpty ? candidates : containingText
        guard let next = choices.max(by: { Self.area($0.box) < Self.area($1.box) }) else {
            pending = nil
            confirmations = 0
            return nil
        }
        if let pending, now - pendingSeen < 0.75, Self.overlap(pending.box, next.box) > 0.5 {
            confirmations += 1
        } else {
            confirmations = 1
        }
        pending = next
        pendingSeen = now
        guard confirmations >= 3 else { return nil }
        locked = next
        pending = nil
        confirmations = 0
        lastSeen = now
        return next
    }
}

enum Aiming {
    // Raw camera x is opposite the user's physical left/right when facing the
    // camera. These arrows describe hand movement, not movement of the image.
    static func direction(for box: CGRect?) -> String {
        guard let box else { return "Show the whole phone screen with the code visible" }
        var hints: [String] = []
        if box.midX < 0.42 { hints.append("← towards your left") }
        if box.midX > 0.58 { hints.append("→ towards your right") }
        if box.midY < 0.40 { hints.append("↑ raise the phone") }
        if box.midY > 0.60 { hints.append("↓ lower the phone") }
        return hints.isEmpty ? "Hold still — keep the screen facing the camera" : hints.joined(separator: "   ")
    }

    static func previewPoint(_ point: CGPoint, size: CGSize, bounds: CGRect, mirrored: Bool) -> CGPoint {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGPoint(x: bounds.midX + ((mirrored ? 1 - point.x : point.x) - 0.5) * width,
                       y: bounds.midY + (point.y - 0.5) * height)
    }
}

final class AimingGuide: NSView {
    var accountMode = false
    let backgroundBlur = NSVisualEffectView()
    private let blurMask = CAShapeLayer()
    var phone: PhoneOutline? { didSet { updateBlurMask(); needsDisplay = true } }
    var imageSize = CGSize(width: 1280, height: 720)
    var mirrored = false { didSet { updateBlurMask(); needsDisplay = true } }
    var detected = false { didSet { if oldValue != detected { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundBlur.frame = bounds
        backgroundBlur.blendingMode = .withinWindow
        backgroundBlur.material = .hudWindow
        backgroundBlur.state = .active
        backgroundBlur.wantsLayer = true
        blurMask.fillRule = .evenOdd
        backgroundBlur.layer?.mask = blurMask
        updateBlurMask()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateBlurMask() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let phone {
            let points = phone.points.map {
                Aiming.previewPoint($0, size: imageSize, bounds: bounds, mirrored: mirrored)
            }
            path.addLines(between: points)
            path.closeSubpath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurMask.frame = bounds
        blurMask.path = path
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let target = NSRect(x: 80, y: accountMode ? 96 : 118,
                            width: bounds.width - 160, height: accountMode ? 168 : 124)
        let border = NSBezierPath(roundedRect: target, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.7).setStroke()
        border.lineWidth = 6
        border.stroke()
        (detected ? NSColor.systemGreen : NSColor.white).setStroke()
        border.lineWidth = 3
        border.stroke()

        // Keep instructions readable even when the phone overlaps the text.
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: 16, y: bounds.height - 56, width: bounds.width - 32, height: 34),
                     xRadius: 8, yRadius: 8).fill()
        NSBezierPath(roundedRect: NSRect(x: 16, y: 24, width: bounds.width - 32, height: 30),
                     xRadius: 8, yRadius: 8).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let title = accountMode ? "Account name + six-digit code" : "Six-digit RSA code"
        (title as NSString).draw(in: NSRect(x: 20, y: bounds.height - 52, width: bounds.width - 40, height: 26),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                                                 .foregroundColor: NSColor.white, .paragraphStyle: style])
        let hint = "Arrows mean your physical movement, even with Mirror preview"
        (hint as NSString).draw(in: NSRect(x: 20, y: 28, width: bounds.width - 40, height: 22),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                                .foregroundColor: NSColor.white, .paragraphStyle: style])
    }
}

final class MirrorControl: NSObject {
    let preview: AVCaptureVideoPreviewLayer
    let guide: AimingGuide
    let preferences = UserDefaults(suiteName: "dev.mac-tooling.camera-otp")!

    init(preview: AVCaptureVideoPreviewLayer, guide: AimingGuide) {
        self.preview = preview
        self.guide = guide
    }

    @objc func change(_ sender: NSButton) {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = sender.state == .on
        guide.mirrored = connection.isVideoMirrored
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
    if reader.previewOnly { window.title = "Camera test — no login or clipboard changes" }
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
    // Sibling overlay blurs the live preview; guide text stays sharp above it.
    cameraView.addSubview(guide.backgroundBlur)
    cameraView.addSubview(guide)

    let status = NSTextField(labelWithString: "Show the whole phone screen with the code visible")
    status.frame = NSRect(x: 20, y: 45, width: 600, height: 24)
    status.font = .systemFont(ofSize: 16, weight: .medium)
    status.alignment = .center
    view.addSubview(status)
    reader.onGuidance = { message, detected, phone, size in
        if status.stringValue != message { status.stringValue = message }
        guide.detected = detected
        guide.imageSize = size
        guide.phone = phone
        guide.setAccessibilityValue(message)
    }

    let control = MirrorControl(preview: preview, guide: guide)
    mirrorControl = control
    let mirror = NSButton(checkboxWithTitle: "Mirror preview", target: control, action: #selector(MirrorControl.change(_:)))
    mirror.frame = NSRect(x: 20, y: 12, width: 150, height: 22)
    mirror.state = control.preferences.bool(forKey: "mirrorPreview") ? .on : .off
    mirror.isEnabled = preview.connection?.isVideoMirroringSupported == true
    mirror.toolTip = "Flip only the preview if aiming feels backwards. Your choice is remembered for both logins."
    control.change(mirror)
    view.addSubview(mirror)
    let help = NSTextField(labelWithString: "Hold the phone steady to bring it into focus.")
    help.frame = NSRect(x: 185, y: 13, width: 435, height: 20)
    help.textColor = .secondaryLabelColor
    help.alignment = .right
    view.addSubview(help)
    window.contentView = view
    window.center()
    window.orderFrontRegardless()
    NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in exit(reader.previewOnly ? 0 : 1) }
}

reader.onCode = { code in
    guard !reader.previewOnly else { return }
    if reader.account == nil {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
    print(code)
    exit(0)
}

let app = NSApplication.shared
if reader.account != nil && !reader.previewOnly {
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
