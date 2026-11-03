// Photographs a phone held up to the Mac's built-in camera, crops and
// straightens its screen into a "screenshot", and copies it to the clipboard.
// Fully on-device: AVFoundation + Vision + Core Image.
import AVFoundation
import AppKit
import CoreImage
import Vision

final class ScreenGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onQuad: ((VNRectangleObservation?) -> Void)?
    var onImage: ((CGImage) -> Void)?

    private let queue = DispatchQueue(label: "camera-screenshot.frames", qos: .userInteractive)
    private let handler = VNSequenceRequestHandler()
    private let detect: VNDetectRectanglesRequest = {
        let r = VNDetectRectanglesRequest()
        // Phone screens are roughly 9:19.5 to 3:4 (short side / long side), either orientation.
        r.minimumAspectRatio = 0.35
        r.maximumAspectRatio = 0.8
        r.minimumSize = 0.25
        r.quadratureTolerance = 20
        r.minimumConfidence = 0.6
        r.maximumObservations = 1
        return r
    }()
    private let context = CIContext()
    private var lastQuad: VNRectangleObservation?
    private var frames: [CIImage] = []
    private var done = false
    /// 8 frames is about a quarter of a second at 30fps.
    static let frameCount = 8

    func configure() throws {
        // Prefer the built-in FaceTime camera over a Continuity Camera iPhone.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "camera-screenshot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }
        session.beginConfiguration()
        session.addInput(try AVCaptureDeviceInput(device: device))
        // Use the format with the most pixels (e.g. 1760x1328 beats 1080p for a portrait phone).
        let pixels = { (f: AVCaptureDevice.Format) -> Int32 in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        if let best = device.formats.max(by: { pixels($0) < pixels($1) }) {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !done, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        try? handler.perform([detect], on: pixels, orientation: .up)
        let quad = detect.results?.first
        DispatchQueue.main.async { self.onQuad?(quad) }

        // Collect frames while the phone is held still (so they're not blurred),
        // starting over if it moves.
        if let quad, let last = lastQuad, Self.distance(quad, last) < 0.01,
           let frame = straighten(pixels, to: quad) {
            frames.append(frame)
        } else {
            frames.removeAll()
        }
        lastQuad = quad
        guard frames.count == Self.frameCount, let image = combine(frames) else { return }
        done = true
        DispatchQueue.main.async { self.onImage?(image) }
    }

    /// Averages the frames to cancel out camera noise, then cleans up the result.
    func combine(_ frames: [CIImage]) -> CGImage? {
        // Each frame was straightened with its own quad, so sizes can differ by a pixel or two.
        let extent = frames[0].extent
        let sum = frames.dropFirst().reduce(frames[0]) { sum, frame in
            frame.transformed(by: CGAffineTransform(scaleX: extent.width / frame.extent.width,
                                                    y: extent.height / frame.extent.height))
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum])
        }
        let n = CGFloat(frames.count)
        let average = sum.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / n, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / n, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / n, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: extent)  // the alpha bias would otherwise make it infinite
        return context.createCGImage(enhance(average), from: extent)
    }

    /// The quad's contents, straightened into a rectangle.
    func straighten(_ pixels: CVPixelBuffer, to quad: VNRectangleObservation) -> CIImage? {
        let frame = CIImage(cvPixelBuffer: pixels)
        // Vision and Core Image both use normalised, bottom-left-origin coordinates.
        let size = frame.extent.size
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * size.width, y: p.y * size.height) }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(frame, forKey: kCIInputImageKey)
        filter.setValue(point(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(quad.topRight), forKey: "inputTopRight")
        filter.setValue(point(quad.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(quad.bottomRight), forKey: "inputBottomRight")
        // Render now, rather than holding on to the camera's buffer (it has only a few).
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent) else { return nil }
        return CIImage(cgImage: image)
    }

    /// Undoes the camera's washed-out look: stretches levels so the darkest and
    /// brightest parts of the screen become black and white (which also fixes the
    /// colour cast), darkens midtones, then boosts saturation and sharpens.
    func enhance(_ image: CIImage) -> CIImage {
        // Sample a small copy to find each channel's levels.
        let scale = 128 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &rgba, rowBytes: w * 4,
                       bounds: small.extent, format: .RGBA8, colorSpace: nil)
        func percentile(_ channel: Int, _ p: Double) -> CGFloat {
            let values = stride(from: channel, to: rgba.count, by: 4).map { rgba[$0] }.sorted()
            return CGFloat(values[Int(Double(values.count - 1) * p)]) / 255
        }
        // White point per channel (white balance); one shared black point, so dark
        // but colourful areas (e.g. a blue wallpaper) keep their colour.
        let black = (0..<3).map { percentile($0, 0.01) }.min()!
        let whites = (0..<3).map { max(percentile($0, 0.99), black + 0.1) }
        func vector(_ i: Int) -> CIVector {
            var v = [CGFloat](repeating: 0, count: 4)
            v[i] = 1 / (whites[i] - black)
            return CIVector(x: v[0], y: v[1], z: v[2], w: v[3])
        }
        return image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": vector(0), "inputGVector": vector(1), "inputBVector": vector(2),
                "inputBiasVector": CIVector(x: -black / (whites[0] - black),
                                            y: -black / (whites[1] - black),
                                            z: -black / (whites[2] - black), w: 0),
            ])
            // The camera exposes for the room, so the bright screen's midtones are lifted.
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.5])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6])
    }

    /// Largest corner movement between two quads, in normalised frame units.
    static func distance(_ a: VNRectangleObservation, _ b: VNRectangleObservation) -> CGFloat {
        zip([a.topLeft, a.topRight, a.bottomLeft, a.bottomRight],
            [b.topLeft, b.topRight, b.bottomLeft, b.bottomRight])
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? .infinity
    }
}

// MARK: - Main

let grabber = ScreenGrabber()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func start() {
    do { try grabber.configure() } catch { fail("camera-screenshot: \(error.localizedDescription)") }
    DispatchQueue.global(qos: .userInteractive).async { grabber.session.startRunning() }
    DispatchQueue.main.async(execute: showPreview)
}

func showPreview() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Hold your phone screen up to the camera"
    window.level = .floating
    let view = NSView()
    view.wantsLayer = true
    let preview = AVCaptureVideoPreviewLayer(session: grabber.session)
    preview.videoGravity = .resizeAspectFill
    view.layer = preview
    // Outline the detected screen, so it's clear what will be captured.
    let outline = CAShapeLayer()
    outline.fillColor = nil
    outline.strokeColor = NSColor.systemGreen.cgColor
    outline.lineWidth = 3
    preview.addSublayer(outline)
    window.contentView = view
    window.center()
    window.orderFrontRegardless()

    grabber.onQuad = { quad in
        guard let quad else { outline.path = nil; return }
        // Device points are top-left origin; Vision's are bottom-left.
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map {
            preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: $0.x, y: 1 - $0.y))
        }
        let path = CGMutablePath()
        path.addLines(between: corners)
        path.closeSubpath()
        outline.frame = preview.bounds
        outline.path = path
    }
    NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in exit(1) }
}

grabber.onImage = { image in
    let rep = NSBitmapImageRep(cgImage: image)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(rep.representation(using: .png, properties: [:]), forType: .png)
    NSSound(named: "Tink")?.play()
    print("Copied \(image.width)x\(image.height) screenshot to the clipboard")
    // Let the sound play before exiting.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    start()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else { fail("camera-screenshot: camera access denied") }
        DispatchQueue.main.async(execute: start)
    }
default:
    fail("camera-screenshot: camera access denied; allow your terminal app in System Settings > Privacy & Security > Camera")
}

app.run()
