#if os(iOS)

import Metal
import MetalPetal
import SwiftUI
import UIKit

private enum ThreadSafeImageViewDemoSchedulingMode: String, CaseIterable, Identifiable {
    case immediate = "Immediate"
    case coalesced = "Coalesced"

    var id: String { rawValue }

    var objcValue: MTIThreadSafeImageViewRenderSchedulingMode {
        switch self {
        case .immediate:
            return .immediate
        case .coalesced:
            return .coalesced
        }
    }
}

private enum ThreadSafeImageViewDemoWorkload: String, CaseIterable, Identifiable {
    case preparedFrames = "Batch"
    case cgImageChurn = "Churn"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preparedFrames:
            return "Prewarmed Persistent Frames"
        case .cgImageChurn:
            return "Repeated CGImage Rebuild"
        }
    }

    var note: String {
        switch self {
        case .preparedFrames:
            return "Use this to verify the Metal 4 multi-view path. In coalesced mode on iOS 26 hardware, batch candidate and Metal 4 commit counters should climb."
        case .cgImageChurn:
            return "Use this to stress MTIImage creation and destruction. Source texture cache hits should climb, while batched submission is expected to fall back."
        }
    }
}

private enum ThreadSafeImageViewStressLaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static let prefersMetal4BatchedSubmission = arguments.contains("-mti-enable-metal4-batched-submission")
}

private struct ThreadSafeImageViewMetricRow: Identifiable {
    let id: String
    let title: String
    let value: String
}

private struct ThreadSafeImageTile: Identifiable {
    let id: Int
    let image: MTIImage?
}

private final class ThreadSafeImageViewStressModel: ObservableObject {

    @Published var schedulingMode: ThreadSafeImageViewDemoSchedulingMode = .coalesced
    @Published var prefersMetal4BatchedSubmission = false
    @Published var workload: ThreadSafeImageViewDemoWorkload = .preparedFrames
    @Published var tileCount: Int = 9
    @Published var updatesPerSecond: Double = 6
    @Published var isAnimating: Bool = true
    @Published private(set) var tiles: [ThreadSafeImageTile] = []
    @Published private(set) var metricRows: [ThreadSafeImageViewMetricRow] = []
    @Published private(set) var preparedFramesReady = false

    let context: MTIContext

    private let baseImage = DemoImages.p1040808
    private let baseCGImage = DemoImages.cgImage(named: "P1040808.jpg")!
    private let prepareQueue = DispatchQueue(label: "org.metalpetal.examples.threadsafe.prepare", qos: .userInitiated)

    private var preparedFrames: [MTIImage] = []
    private var frameTimer: Timer?
    private var metricsTimer: Timer?
    private var tick: Int = 0

    init() {
        self.prefersMetal4BatchedSubmission = ThreadSafeImageViewStressLaunchOptions.prefersMetal4BatchedSubmission
        let device = MTLCreateSystemDefaultDevice()!
        let options = MTIContextOptions()
        options.enablesPerformanceStatistics = true
        self.context = try! MTIContext(device: device, options: options)
        rebuildTiles()
        startPreparedFrameWarmup()
        restartTimers()
        refreshMetrics()
    }

    deinit {
        frameTimer?.invalidate()
        metricsTimer?.invalidate()
    }

    func onAppear() {
        restartTimers()
        refreshMetrics()
    }

    func onDisappear() {
        frameTimer?.invalidate()
        frameTimer = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    func step() {
        advanceTick()
    }

    func resetCounters() {
        context.resetPerformanceStatistics()
        refreshMetrics()
    }

    func configurationDidChange() {
        tick = 0
        rebuildTiles()
        resetCounters()
        advanceTick()
    }

    func updateAnimationState() {
        restartTimers()
    }

    func updateTileCount() {
        rebuildTiles()
        advanceTick()
    }

    private func rebuildTiles() {
        let currentImage = tiles.first?.image
        tiles = (0..<tileCount).map { ThreadSafeImageTile(id: $0, image: currentImage) }
    }

    private func restartTimers() {
        frameTimer?.invalidate()
        frameTimer = nil
        metricsTimer?.invalidate()
        metricsTimer = nil

        metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshMetrics()
        }

        guard isAnimating else {
            return
        }

        let interval = 1.0 / max(updatesPerSecond, 1)
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceTick()
        }
    }

    private func startPreparedFrameWarmup() {
        preparedFramesReady = false
        let baseImage = self.baseImage
        let context = self.context
        prepareQueue.async { [weak self] in
            let frames = Self.makePreparedFrames(baseImage: baseImage, context: context)
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.preparedFrames = frames
                self.preparedFramesReady = !frames.isEmpty
                self.context.resetPerformanceStatistics()
                self.advanceTick()
                self.refreshMetrics()
            }
        }
    }

    private static func makePreparedFrames(baseImage: MTIImage, context: MTIContext) -> [MTIImage] {
        let values: [Float] = [0.2, 0.45, 0.7, 1.0, 1.35, 1.7, 1.35, 0.8]
        return values.map { saturation in
            let image = baseImage
                .adjusting(saturation: saturation)
                .adjusting(contrast: 0.9 + saturation * 0.08)
                .withCachePolicy(.persistent)
            if let task = try? context.startTask(toRender: image, completion: nil) {
                task.waitUntilCompleted()
            }
            return image
        }
    }

    private func advanceTick() {
        tick += 1
        switch workload {
        case .preparedFrames:
            let image = preparedFrames.isEmpty ? baseImage.withCachePolicy(.persistent) : preparedFrames[tick % preparedFrames.count]
            tiles = (0..<tileCount).map { ThreadSafeImageTile(id: $0, image: image) }
        case .cgImageChurn:
            let nextTiles = (0..<tileCount).map { index -> ThreadSafeImageTile in
                let phase = Double(tick) * 0.3 + Double(index) * 0.35
                let saturation = Float(1.0 + sin(phase) * 0.7)
                let contrast = Float(1.0 + cos(phase * 0.7) * 0.12)
                let image = MTIImage(cgImage: baseCGImage, isOpaque: true)
                    .adjusting(saturation: saturation)
                    .adjusting(contrast: contrast)
                return ThreadSafeImageTile(id: index, image: image)
            }
            tiles = nextTiles
        }
    }

    private func refreshMetrics() {
        let snapshot = context.performanceStatisticsSnapshot()
        metricRows = [
            ThreadSafeImageViewMetricRow(id: "prepared", title: "Prepared Frames", value: preparedFramesReady ? "Ready" : "Preparing"),
            ThreadSafeImageViewMetricRow(id: "candidate", title: "Batch Candidates", value: Self.string(for: snapshot.counters["threadSafeImageView.batch.candidate"])),
            ThreadSafeImageViewMetricRow(id: "metal4items", title: "Metal 4 Items", value: Self.string(for: snapshot.counters["threadSafeImageView.batch.metal4.items"])),
            ThreadSafeImageViewMetricRow(id: "metal4commit", title: "Metal 4 Commits", value: Self.string(for: snapshot.counters["threadSafeImageView.batch.metal4.commit"])),
            ThreadSafeImageViewMetricRow(id: "classicfallback", title: "Classic Fallbacks", value: Self.string(for: snapshot.counters["threadSafeImageView.batch.classicFallback"])),
            ThreadSafeImageViewMetricRow(id: "metal4fallback", title: "Metal 4 Fallbacks", value: Self.string(for: snapshot.counters["threadSafeImageView.batch.metal4.fallback"])),
            ThreadSafeImageViewMetricRow(id: "cgimagehit", title: "CGImage Cache Hits", value: Self.string(for: snapshot.counters["promise.cgImage.sourceTextureCache.hit"])),
            ThreadSafeImageViewMetricRow(id: "cgimagemiss", title: "CGImage Cache Misses", value: Self.string(for: snapshot.counters["promise.cgImage.sourceTextureCache.miss"]))
        ]
    }

    private static func string(for number: NSNumber?) -> String {
        "\(number?.intValue ?? 0)"
    }
}

private struct ThreadSafeImageViewTileView: UIViewRepresentable {
    let image: MTIImage?
    let renderContext: MTIContext
    let schedulingMode: MTIThreadSafeImageViewRenderSchedulingMode
    let prefersMetal4BatchedSubmission: Bool

    func makeUIView(context: Context) -> MTIThreadSafeImageView {
        let view = MTIThreadSafeImageView(frame: .zero)
        view.automaticallyCreatesContext = false
        view.clearColor = MTLClearColorMake(0.05, 0.06, 0.08, 1.0)
        view.colorPixelFormat = .bgra8Unorm
        view.resizingMode = .aspect
        view.clipsToBounds = true
        view.layer.cornerRadius = 14
        return view
    }

    func updateUIView(_ uiView: MTIThreadSafeImageView, context: Context) {
        if uiView.context !== renderContext {
            uiView.context = renderContext
        }
        if uiView.renderSchedulingMode != schedulingMode {
            uiView.renderSchedulingMode = schedulingMode
        }
        if uiView.prefersMetal4BatchedSubmission != prefersMetal4BatchedSubmission {
            uiView.prefersMetal4BatchedSubmission = prefersMetal4BatchedSubmission
        }
        if uiView.image !== image {
            uiView.setImage(image, renderCompletion: nil)
        }
    }
}

struct ThreadSafeImageViewStressView: View {

    @StateObject private var model = ThreadSafeImageViewStressModel()

    private var columns: [GridItem] {
        let count = max(1, Int(ceil(sqrt(Double(model.tileCount)))))
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlPanel
                metricsPanel
                workloadNote
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.tiles) { tile in
                        ZStack(alignment: .topLeading) {
                            ThreadSafeImageViewTileView(
                                image: tile.image,
                                renderContext: model.context,
                                schedulingMode: model.schedulingMode.objcValue,
                                prefersMetal4BatchedSubmission: model.prefersMetal4BatchedSubmission
                            )
                            .aspectRatio(1, contentMode: .fit)

                            Text("#\(tile.id + 1)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.18))
                                )
                                .padding(8)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            model.onAppear()
        }
        .onDisappear {
            model.onDisappear()
        }
        .onChange(of: model.schedulingMode) { _ in
            model.configurationDidChange()
        }
        .onChange(of: model.workload) { _ in
            model.configurationDidChange()
        }
        .onChange(of: model.tileCount) { _ in
            model.updateTileCount()
        }
        .onChange(of: model.updatesPerSecond) { _ in
            model.updateAnimationState()
        }
        .onChange(of: model.isAnimating) { _ in
            model.updateAnimationState()
        }
        .inlineNavigationBarTitle("Thread-Safe Views")
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verification Controls")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scheduling")
                    .font(.subheadline.weight(.medium))
                Picker("Scheduling", selection: $model.schedulingMode) {
                    ForEach(ThreadSafeImageViewDemoSchedulingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Enable Metal 4 Batched Submission", isOn: $model.prefersMetal4BatchedSubmission)

            VStack(alignment: .leading, spacing: 8) {
                Text("Workload")
                    .font(.subheadline.weight(.medium))
                Picker("Workload", selection: $model.workload) {
                    ForEach(ThreadSafeImageViewDemoWorkload.allCases) { workload in
                        Text(workload.rawValue).tag(workload)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Views")
                    .font(.subheadline.weight(.medium))
                Picker("Views", selection: $model.tileCount) {
                    Text("4").tag(4)
                    Text("9").tag(9)
                    Text("16").tag(16)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Animate Updates", isOn: $model.isAnimating)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Updates / sec")
                    Spacer()
                    Text("\(Int(model.updatesPerSecond))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $model.updatesPerSecond, in: 1...12, step: 1)
            }

            HStack(spacing: 12) {
                Button("Step Once") {
                    model.step()
                }
                .disabled(model.isAnimating)

                Button("Reset Counters") {
                    model.resetCounters()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondarySystemBackground)
        )
    }

    private var metricsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Counters")
                .font(.headline)
            ForEach(model.metricRows) { row in
                HStack {
                    Text(row.title)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(row.value)
                        .font(.system(.body, design: .monospaced))
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondarySystemBackground)
        )
    }

    private var workloadNote: some View {
        Text(model.workload.note)
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondarySystemBackground)
            )
    }
}

#endif
