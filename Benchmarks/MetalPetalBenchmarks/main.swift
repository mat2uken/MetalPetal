import CoreGraphics
import CoreVideo
import Dispatch
import Foundation
import Metal
import MetalPetal

struct BenchmarkResult {
    let iterations: Int
    let wallTime: TimeInterval
    let submitTime: TimeInterval
    let completionWaitTime: TimeInterval
    let snapshot: MTIPerformanceStatisticsSnapshot
}

struct BenchmarkPhases {
    let submitTime: TimeInterval
    let completionWaitTime: TimeInterval
}

struct BenchmarkCase {
    let name: String
    let cold: () throws -> BenchmarkResult
    let steady: () throws -> BenchmarkResult
}

enum BenchmarkError: Error {
    case noMetalDevice
    case cannotCreatePixelBuffer
    case cannotCreateCGContext
    case cannotCreateCGImage
}

enum MetalPetalBenchmarks {
    static func main() throws {
        let deviceDescription = MTLCreateSystemDefaultDevice()?.description ?? "No Metal device"
        print("MetalPetal Benchmarks")
        print("Device: \(deviceDescription)")
        print("")
        
        for benchmark in try makeBenchmarks() {
            let cold = try benchmark.cold()
            let steady = try benchmark.steady()
            printReport(name: benchmark.name, cold: cold, steady: steady)
        }
    }
    
    private static func makeBenchmarks() throws -> [BenchmarkCase] {
        let sourceImage = try makeCheckerboardImage(width: 1024, height: 1024, cellSize: 32)
        let layerImage = try makeCheckerboardImage(width: 320, height: 320, cellSize: 20)
        let maskImage = try makeCheckerboardImage(width: 320, height: 320, cellSize: 10)
        let videoPixelBuffer = try makePixelBuffer(width: 1920, height: 1080)
        
        return [
            makeFilterGraphBenchmark(sourceImage: sourceImage),
            makeParallelFilterGraphBenchmark(sourceImage: sourceImage),
            makeMultilayerBenchmark(backgroundImage: sourceImage, layerImage: layerImage, maskImage: maskImage),
            makeCGImageLoadingBenchmark(sourceImage: sourceImage),
            makeCVPixelBufferBenchmark(pixelBuffer: videoPixelBuffer),
        ]
    }
    
    private static func makeFilterGraphBenchmark(sourceImage: CGImage) -> BenchmarkCase {
        BenchmarkCase(
            name: "Filter Graph",
            cold: {
                let context = try makeContext()
                let output = makeFilterGraphImage(sourceImage: sourceImage)
                return try runMeasured(context: context, iterations: 1) {
                    try timedRenderToNowhere(output, context: context)
                }
            },
            steady: {
                let context = try makeContext()
                let output = makeFilterGraphImage(sourceImage: sourceImage)
                try warmUp(context: context, iterations: 2) {
                    _ = try timedRenderToNowhere(output, context: context)
                }
                return try runMeasured(context: context, iterations: 10) {
                    try timedRenderToNowhere(output, context: context)
                }
            }
        )
    }
    
    private static func makeMultilayerBenchmark(backgroundImage: CGImage, layerImage: CGImage, maskImage: CGImage) -> BenchmarkCase {
        BenchmarkCase(
            name: "Multilayer Composite",
            cold: {
                let context = try makeContext()
                let output = makeMultilayerImage(backgroundImage: backgroundImage, layerImage: layerImage, maskImage: maskImage)
                return try runMeasured(context: context, iterations: 1) {
                    try timedRenderToNowhere(output, context: context)
                }
            },
            steady: {
                let context = try makeContext()
                let output = makeMultilayerImage(backgroundImage: backgroundImage, layerImage: layerImage, maskImage: maskImage)
                try warmUp(context: context, iterations: 2) {
                    _ = try timedRenderToNowhere(output, context: context)
                }
                return try runMeasured(context: context, iterations: 10) {
                    try timedRenderToNowhere(output, context: context)
                }
            }
        )
    }
    
    private static func makeParallelFilterGraphBenchmark(sourceImage: CGImage) -> BenchmarkCase {
        BenchmarkCase(
            name: "Parallel Filter Graph",
            cold: {
                let context = try makeContext()
                let output = makeFilterGraphImage(sourceImage: sourceImage)
                return try runParallelMeasured(context: context, workers: 4, iterationsPerWorker: 1) {
                    try timedRenderToNowhere(output, context: context)
                }
            },
            steady: {
                let context = try makeContext()
                let output = makeFilterGraphImage(sourceImage: sourceImage)
                try warmUp(context: context, iterations: 2) {
                    _ = try timedRenderToNowhere(output, context: context)
                }
                return try runParallelMeasured(context: context, workers: 4, iterationsPerWorker: 5) {
                    try timedRenderToNowhere(output, context: context)
                }
            }
        )
    }
    
    private static func makeCGImageLoadingBenchmark(sourceImage: CGImage) -> BenchmarkCase {
        BenchmarkCase(
            name: "CGImage Source Resolve",
            cold: {
                let context = try makeContext()
                return try runMeasured(context: context, iterations: 1) {
                    let image = MTIImage(cgImage: sourceImage, isOpaque: true)
                    return try timedRenderToNowhere(image, context: context)
                }
            },
            steady: {
                let context = try makeContext()
                try warmUp(context: context, iterations: 2) {
                    let image = MTIImage(cgImage: sourceImage, isOpaque: true)
                    _ = try timedRenderToNowhere(image, context: context)
                }
                return try runMeasured(context: context, iterations: 10) {
                    let image = MTIImage(cgImage: sourceImage, isOpaque: true)
                    return try timedRenderToNowhere(image, context: context)
                }
            }
        )
    }
    
    private static func makeCVPixelBufferBenchmark(pixelBuffer: CVPixelBuffer) -> BenchmarkCase {
        BenchmarkCase(
            name: "CVPixelBuffer Source Resolve",
            cold: {
                let context = try makeContext()
                return try runMeasured(context: context, iterations: 1) {
                    let image = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
                    return try timedRenderToNowhere(image, context: context)
                }
            },
            steady: {
                let context = try makeContext()
                try warmUp(context: context, iterations: 2) {
                    let image = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
                    _ = try timedRenderToNowhere(image, context: context)
                }
                return try runMeasured(context: context, iterations: 10) {
                    let image = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
                    return try timedRenderToNowhere(image, context: context)
                }
            }
        )
    }
    
    private static func makeContext() throws -> MTIContext {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BenchmarkError.noMetalDevice
        }
        let options = MTIContextOptions()
        options.enablesPerformanceStatistics = true
        return try MTIContext(device: device, options: options)
    }
    
    private static func warmUp(context: MTIContext, iterations: Int, body: () throws -> Void) throws {
        for _ in 0..<iterations {
            try autoreleasepool {
                try body()
            }
        }
        context.resetPerformanceStatistics()
    }
    
    private static func runMeasured(context: MTIContext, iterations: Int, body: () throws -> BenchmarkPhases) throws -> BenchmarkResult {
        context.resetPerformanceStatistics()
        let start = CFAbsoluteTimeGetCurrent()
        var submitTime: TimeInterval = 0
        var completionWaitTime: TimeInterval = 0
        for _ in 0..<iterations {
            try autoreleasepool {
                let phases = try body()
                submitTime += phases.submitTime
                completionWaitTime += phases.completionWaitTime
            }
        }
        let wallTime = CFAbsoluteTimeGetCurrent() - start
        return BenchmarkResult(
            iterations: iterations,
            wallTime: wallTime,
            submitTime: submitTime,
            completionWaitTime: completionWaitTime,
            snapshot: context.performanceStatisticsSnapshot()
        )
    }
    
    private static func runParallelMeasured(context: MTIContext, workers: Int, iterationsPerWorker: Int, body: @escaping () throws -> BenchmarkPhases) throws -> BenchmarkResult {
        context.resetPerformanceStatistics()
        let totalIterations = workers * iterationsPerWorker
        let errorLock = NSLock()
        var benchmarkError: Error?
        var submitTime: TimeInterval = 0
        var completionWaitTime: TimeInterval = 0
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            for _ in 0..<iterationsPerWorker {
                errorLock.lock()
                let shouldAbort = benchmarkError != nil
                errorLock.unlock()
                if shouldAbort {
                    break
                }
                do {
                    try autoreleasepool {
                        let phases = try body()
                        errorLock.lock()
                        submitTime += phases.submitTime
                        completionWaitTime += phases.completionWaitTime
                        errorLock.unlock()
                    }
                } catch {
                    errorLock.lock()
                    if benchmarkError == nil {
                        benchmarkError = error
                    }
                    errorLock.unlock()
                    break
                }
            }
        }
        if let benchmarkError {
            throw benchmarkError
        }
        let wallTime = CFAbsoluteTimeGetCurrent() - start
        return BenchmarkResult(
            iterations: totalIterations,
            wallTime: wallTime,
            submitTime: submitTime,
            completionWaitTime: completionWaitTime,
            snapshot: context.performanceStatisticsSnapshot()
        )
    }
    
    private static func timedRenderToNowhere(_ image: MTIImage, context: MTIContext) throws -> BenchmarkPhases {
        let submitStart = CFAbsoluteTimeGetCurrent()
        let task = try context.startTask(toRender: image)
        let submitTime = CFAbsoluteTimeGetCurrent() - submitStart
        let completionWaitStart = CFAbsoluteTimeGetCurrent()
        task.waitUntilCompleted()
        let completionWaitTime = CFAbsoluteTimeGetCurrent() - completionWaitStart
        return BenchmarkPhases(submitTime: submitTime, completionWaitTime: completionWaitTime)
    }
    
    private static func makeFilterGraphImage(sourceImage: CGImage) -> MTIImage {
        let input = MTIImage(cgImage: sourceImage, isOpaque: true)
        
        let saturation = MTISaturationFilter()
        saturation.saturation = 1.35
        saturation.inputImage = input
        
        let pixellate = MTIPixellateFilter()
        pixellate.scale = CGSize(width: 8, height: 8)
        pixellate.inputImage = saturation.outputImage
        
        let invert = MTIColorInvertFilter()
        invert.inputImage = input
        
        let vibrance = MTIVibranceFilter()
        vibrance.amount = 0.6
        vibrance.inputImage = invert.outputImage
        
        let contrast = MTIContrastFilter()
        contrast.contrast = 1.15
        contrast.inputImage = vibrance.outputImage
        
        let blend = MTIBlendFilter(blendMode: .overlay)
        blend.inputBackgroundImage = pixellate.outputImage
        blend.inputImage = contrast.outputImage
        return blend.outputImage!
    }
    
    private static func makeMultilayerImage(backgroundImage: CGImage, layerImage: CGImage, maskImage: CGImage) -> MTIImage {
        let background = MTIImage(cgImage: backgroundImage, isOpaque: true)
        let content = MTIImage(cgImage: layerImage, isOpaque: true)
        let maskContent = MTIImage(cgImage: maskImage, isOpaque: true)
        let mask = MTIMask(content: maskContent, component: .red, mode: .normal)
        
        let filter = MultilayerCompositingFilter()
        filter.inputBackgroundImage = background
        filter.outputAlphaType = .premultiplied
        filter.rasterSampleCount = 1
        filter.layers = (0..<24).map { index in
            let row = index / 6
            let column = index % 6
            let position = CGPoint(x: 160 + CGFloat(column) * 140, y: 120 + CGFloat(row) * 140)
            let size = CGSize(width: 220, height: 220)
            var layer = MultilayerCompositingFilter.Layer(content: content)
                .frame(center: position, size: size, layoutUnit: .pixel)
                .rotation(Float(index) * 0.08)
                .opacity(0.75)
                .cornerRadius(18)
            if index.isMultiple(of: 2) {
                layer = layer.blendMode(.screen)
            } else {
                layer = layer.blendMode(.multiply)
            }
            if index.isMultiple(of: 3) {
                layer = layer.mask(mask)
            }
            if index.isMultiple(of: 4) {
                layer = layer.tintColor(MTIColor(red: 0.2, green: 0.7, blue: 1.0, alpha: 0.35))
            }
            return layer
        }
        return filter.outputImage!
    }
    
    private static func makeCheckerboardImage(width: Int, height: Int, cellSize: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw BenchmarkError.cannotCreateCGContext
        }
        
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1))
        for y in stride(from: 0, to: height, by: cellSize) {
            let row = y / cellSize
            let offset = row.isMultiple(of: 2) ? 0 : cellSize
            for x in stride(from: offset, to: width, by: cellSize * 2) {
                context.fill(CGRect(x: x, y: y, width: cellSize, height: cellSize))
            }
        }
        guard let image = context.makeImage() else {
            throw BenchmarkError.cannotCreateCGImage
        }
        return image
    }
    
    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw BenchmarkError.cannotCreatePixelBuffer
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let offset = x * 4
                    row[offset + 0] = UInt8((x * 255) / max(width - 1, 1))
                    row[offset + 1] = UInt8((y * 255) / max(height - 1, 1))
                    row[offset + 2] = 180
                    row[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
    
    private static func printReport(name: String, cold: BenchmarkResult, steady: BenchmarkResult) {
        print("== \(name) ==")
        print("cold wall: \(formatMilliseconds(cold.wallTime))")
        print("cold submit avg: \(formatMilliseconds(cold.submitTime / Double(max(cold.iterations, 1))))")
        print("cold wait avg: \(formatMilliseconds(cold.completionWaitTime / Double(max(cold.iterations, 1))))")
        printMetrics(title: "cold metrics", result: cold, durationLimit: 4, counterLimit: 8)
        print("steady avg wall: \(formatMilliseconds(steady.wallTime / Double(steady.iterations))) over \(steady.iterations) iterations")
        print("steady submit avg: \(formatMilliseconds(steady.submitTime / Double(max(steady.iterations, 1))))")
        print("steady wait avg: \(formatMilliseconds(steady.completionWaitTime / Double(max(steady.iterations, 1))))")
        printMetrics(title: "steady metrics", result: steady, durationLimit: 6, counterLimit: 10)
        print("")
    }
    
    private static func printMetrics(title: String, result: BenchmarkResult, durationLimit: Int, counterLimit: Int) {
        let durations = result.snapshot.durations.sorted { $0.value.doubleValue > $1.value.doubleValue }
        let counters = result.snapshot.counters.sorted { lhs, rhs in
            if lhs.value.intValue == rhs.value.intValue {
                return lhs.key < rhs.key
            }
            return lhs.value.intValue > rhs.value.intValue
        }
        if durations.isEmpty, counters.isEmpty {
            return
        }
        print(title + ":")
        if !durations.isEmpty {
            print("  top durations:")
            for (key, value) in durations.prefix(durationLimit) {
                let average = value.doubleValue / Double(max(result.iterations, 1))
                print("    \(key): total \(formatMilliseconds(value.doubleValue)), avg/iter \(formatMilliseconds(average))")
            }
            printFocusedDurations(result: result)
        }
        if !counters.isEmpty {
            print("  top counters:")
            for (key, value) in counters.prefix(counterLimit) {
                print("    \(key): \(value)")
            }
        }
    }

    private static func printFocusedDurations(result: BenchmarkResult) {
        let focusedDurationNames = [
            "rendergraph.promiseResolve.pipelineLookup.duration",
            "rendergraph.promiseResolve.textureBinding.duration",
            "rendergraph.promiseResolve.parameterEncoding.duration",
            "rendergraph.promiseResolve.drawEncoding.duration",
        ]
        let focusedDurations = focusedDurationNames.compactMap { name in
            result.snapshot.durationNamed(name).map { (name, $0.doubleValue) }
        }
        guard !focusedDurations.isEmpty else {
            return
        }
        print("  focused durations:")
        for (name, duration) in focusedDurations {
            let average = duration / Double(max(result.iterations, 1))
            print("    \(name): total \(formatMilliseconds(duration)), avg/iter \(formatMilliseconds(average))")
        }
    }
    
    private static func formatMilliseconds(_ duration: TimeInterval) -> String {
        String(format: "%.3f ms", duration * 1000)
    }
}

try MetalPetalBenchmarks.main()
