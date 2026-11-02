import Accelerate
import Foundation

/// Turns a block of mono float samples into logarithmically spaced band
/// magnitudes in `0...1`. The FFT plan and scratch buffers live in the struct,
/// so the audio tap can reuse one instance instead of allocating per buffer.
public struct SpectrumAnalyzer {
    public static let bandCount = 24
    public static let fftSize = 1024
    public static let minimumFrequency = 40.0
    public static let maximumFrequency = 16_000.0

    public let bandCount: Int
    private let fftSize: Int
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]

    // Scratch storage, reused on every call.
    private var input: [Float]
    private var inputReal: [Float]
    private var inputImaginary: [Float]
    private var outputReal: [Float]
    private var outputImaginary: [Float]
    private var magnitudes: [Float]

    public init(bandCount: Int = SpectrumAnalyzer.bandCount, fftSize: Int = SpectrumAnalyzer.fftSize) {
        let size = max(fftSize, 2)
        self.bandCount = max(bandCount, 0)
        self.fftSize = size
        let log2n = vDSP_Length(log2(Double(size)).rounded())
        self.fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.window = window

        let half = size / 2
        self.input = [Float](repeating: 0, count: size)
        self.inputReal = [Float](repeating: 0, count: half)
        self.inputImaginary = [Float](repeating: 0, count: half)
        self.outputReal = [Float](repeating: 0, count: half)
        self.outputImaginary = [Float](repeating: 0, count: half)
        self.magnitudes = [Float](repeating: 0, count: half)
    }

    /// Convenience path for tests and one-off analysis.
    public static func computeBands(
        samples: [Float],
        sampleRate: Double,
        bandCount: Int = SpectrumAnalyzer.bandCount
    ) -> [Float] {
        var analyzer = SpectrumAnalyzer(bandCount: bandCount)
        var bands = [Float](repeating: 0, count: max(bandCount, 0))
        samples.withUnsafeBufferPointer { buffer in
            analyzer.process(buffer, sampleRate: sampleRate, into: &bands)
        }
        return bands
    }

    /// Fills `output` with `bandCount` magnitudes. Silence yields exact zeros.
    public mutating func process(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        into output: inout [Float]
    ) {
        if output.count != bandCount {
            output = [Float](repeating: 0, count: bandCount)
        }
        guard bandCount > 0, let fft, sampleRate > 0, let base = samples.baseAddress, samples.count > 0 else {
            for index in output.indices { output[index] = 0 }
            return
        }

        let copied = min(samples.count, fftSize)
        input.withUnsafeMutableBufferPointer { inputPointer in
            vDSP_vmul(base, 1, window, 1, inputPointer.baseAddress!, 1, vDSP_Length(copied))
            if copied < fftSize {
                for index in copied..<fftSize {
                    inputPointer[index] = 0
                }
            }
        }

        let half = fftSize / 2
        inputReal.withUnsafeMutableBufferPointer { realPointer in
            inputImaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                input.withUnsafeBufferPointer { inputPointer in
                    inputPointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: half
                    ) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                outputReal.withUnsafeMutableBufferPointer { outRealPointer in
                    outputImaginary.withUnsafeMutableBufferPointer { outImaginaryPointer in
                        var result = DSPSplitComplex(
                            realp: outRealPointer.baseAddress!,
                            imagp: outImaginaryPointer.baseAddress!
                        )
                        fft.forward(input: split, output: &result)
                        vDSP_zvabs(&result, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
            }
        }

        let binCount = half
        let maximum = min(Self.maximumFrequency, sampleRate / 2)
        guard binCount > 0, maximum > Self.minimumFrequency else {
            for index in output.indices { output[index] = 0 }
            return
        }

        let hertzPerBin = sampleRate / Double(fftSize)
        let frequencyRatio = maximum / Self.minimumFrequency
        for band in 0..<bandCount {
            let low = Self.minimumFrequency * pow(frequencyRatio, Double(band) / Double(bandCount))
            let high = Self.minimumFrequency * pow(frequencyRatio, Double(band + 1) / Double(bandCount))
            let lowBin = min(max(Int(low / hertzPerBin), 0), binCount - 1)
            let highBin = min(max(Int(high / hertzPerBin), lowBin), binCount - 1)

            var peak: Float = 0
            for bin in lowBin...highBin {
                peak = max(peak, magnitudes[bin])
            }
            // vDSP's real FFT is unnormalised; the Hann window makes a
            // full-scale sine peak near fftSize / 4. sqrt keeps quiet passages
            // visible without a per-frame automatic gain control. Silence gives
            // peak 0 and therefore an exact 0 in the output.
            let normalised = peak * 2 / Float(fftSize)
            output[band] = min(1, sqrt(max(0, normalised)))
        }
    }
}
