import Foundation
import QuartzCore

@MainActor
final class SamplerModel: ObservableObject {
    @Published private(set) var operations: [DrawOp] = []
    @Published private(set) var texts: [String] = []
    @Published private(set) var linkStatus = "等待连接 FM-1"
    @Published private(set) var backgroundARGB: UInt32 = 0xff14141a

    var openFilePicker: (() -> Bool)?
    private var filePickerPending = false
    private var touchingSurface = false
    @Published var showingImportError = false
    @Published private(set) var importErrorMessage = ""
    private var importingFile = false

    private var displayLink: CADisplayLink?
    private var engineTimer: Timer?
    private var bridge: EngineBridge?
    private var startTime = CACurrentMediaTime()
    private var surfaceWidth: CGFloat = 0
    private var surfaceHeight: CGFloat = 0
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0

    func start() {
        guard displayLink == nil else { return }
        bridge = EngineBridge()
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link

        let timer = Timer(timeInterval: 0.016, target: self, selector: #selector(tickEngine), userInfo: nil, repeats: true)
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        engineTimer = timer
    }

    func stop() {
        engineTimer?.invalidate()
        engineTimer = nil
        displayLink?.invalidate()
        displayLink = nil
        bridge?.stop()
        bridge = nil
        filePickerPending = false
        touchingSurface = false
    }

    private var elapsedMilliseconds: UInt32 {
        let milliseconds = UInt64(max(0, (CACurrentMediaTime() - startTime) * 1000))
        return UInt32(truncatingIfNeeded: milliseconds)
    }

    @objc private func tickEngine() {
        guard let bridge else { return }
        bridge.tick(elapsedMilliseconds)
        if bridge.takeFileRequest() { filePickerPending = true }
        if filePickerPending, !touchingSurface, !importingFile, openFilePicker?() == true {
            filePickerPending = false
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard surfaceHeight > 0 else { return }
        updateFrame(width: surfaceWidth, height: surfaceHeight, top: topInset, bottom: bottomInset)
    }

    func updateFrame(width: CGFloat, height: CGFloat, top: CGFloat, bottom: CGFloat) {
        surfaceWidth = width; surfaceHeight = height; topInset = top; bottomInset = bottom
        guard let bridge else { return }
        let elapsed = elapsedMilliseconds
        // Match SamplerSurface's drawing scale: the short screen dimension is
        // always 400 logical units in both orientations.
        let d = min(width, height) / 400
        let result = bridge.frame(withWidth: Float(width / d), height: Float(height / d), top: Float(top), bottom: Float(bottom), now: elapsed)
        let rows = result["ops"] as? [[NSNumber]] ?? []
        texts = result["texts"] as? [String] ?? []
        if let first = rows.first, first.count > 7 {
            let background = first[7].uint32Value
            if backgroundARGB != background { backgroundARGB = background }
        }
        operations = rows.enumerated().map { index, row in
            DrawOp(id: index, type: row[0].intValue, values: (1...6).map { CGFloat(truncating: row[$0]) }, argb: row[7].uint32Value, textIndex: row[8].intValue >= 0 ? row[8].intValue : nil)
        }
    }

    func touch(action: Int, x: CGFloat, y: CGFloat) {
        let elapsed = elapsedMilliseconds
        touchingSurface = action != 2
        bridge?.touch(Int32(action), x: Float(x), y: Float(y), now: elapsed)
    }

    func importSample(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
            showingImportError = true
        case .success(let url):
            importingFile = true
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    EngineBridge.prepareSample(from: url)
                }.value
                importingFile = false
                if let path = outcome["path"] {
                    bridge?.loadImportedSample(path)
                } else {
                    importErrorMessage = outcome["error"] ?? "没有可读的音频数据。"
                    showingImportError = true
                }
            }
        }
    }
}
