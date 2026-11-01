// Reads a 6-digit code (e.g. an RSA SecurID OTP) held up to the Mac's built-in
// camera and copies it to the clipboard. Fully on-device: AVFoundation + Vision.
import AVFoundation
import AppKit
import Vision

final class CodeReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onCode: ((String) -> Void)?

    private let queue = DispatchQueue(label: "camera-otp.frames", qos: .userInteractive)
    private let handler = VNSequenceRequestHandler()
    private let request: VNRecognizeTextRequest = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .fast  // ~10x quicker than .accurate; big OTP digits read fine
        r.usesLanguageCorrection = false
        return r
    }()
    private var lastCode: String?
    private var done = false

    func configure() throws {
        // Prefer the built-in FaceTime camera over a Continuity Camera iPhone.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "camera-otp", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        session.addInput(try AVCaptureDeviceInput(device: device))
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

    /// Loads the OCR model on a blank frame while the camera is still starting,
    /// so the first real frame doesn't pay the model-load cost.
    func warmUp() {
        queue.async { [self] in
            var blank: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &blank)
            if let blank { try? handler.perform([request], on: blank) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !done, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        try? handler.perform([request], on: pixels, orientation: .up)
        let code = Self.code(in: request.results ?? [])
        // Require two consecutive frames to agree, guarding against a fast-mode misread.
        if let code, code == lastCode {
            done = true
            DispatchQueue.main.async { self.onCode?(code) }
        }
        lastCode = code
    }

    static func code(in observations: [VNRecognizedTextObservation]) -> String? {
        var halves: [(text: String, box: CGRect)] = []
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            if let match = text.firstMatch(of: #/\b\d{3} ?\d{3}\b/#) {
                return match.output.filter(\.isNumber)
            }
            // Vision sometimes splits "709 945" into two observations.
            if text.wholeMatch(of: #/\d{3}/#) != nil {
                halves.append((text, observation.boundingBox))
            }
        }
        halves.sort { $0.box.minX < $1.box.minX }
        for (i, left) in halves.enumerated() {
            for right in halves[(i + 1)...]
            where abs(left.box.midY - right.box.midY) < left.box.height / 2 {
                return left.text + right.text
            }
        }
        return nil
    }
}

// MARK: - Main

let reader = CodeReader()

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

func showPreview() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Hold your phone up to the camera"
    window.level = .floating
    let view = NSView()
    view.wantsLayer = true
    let preview = AVCaptureVideoPreviewLayer(session: reader.session)
    preview.videoGravity = .resizeAspectFill
    view.layer = preview
    window.contentView = view
    window.center()
    // Show without taking focus, so typing still goes to the terminal.
    window.orderFrontRegardless()
    NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in exit(1) }
}

reader.onCode = { code in
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    print(code)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

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
