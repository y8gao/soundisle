import XCTest
@testable import SoundIsleCore

final class SpectrumAnalyzerTests: XCTestCase {
    private func sine(frequency: Double, sampleRate: Double = 44100, count: Int = 1024) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    func testSilenceGivesZeroBands() {
        let bands = SpectrumAnalyzer.computeBands(
            samples: [Float](repeating: 0, count: 1024),
            sampleRate: 44100
        )
        XCTAssertEqual(bands.count, 24)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 })
    }

    func testOneKilohertzSineIsNonZero() {
        let bands = SpectrumAnalyzer.computeBands(
            samples: sine(frequency: 1000),
            sampleRate: 44100
        )
        XCTAssertEqual(bands.count, 24)
        XCTAssertGreaterThan(bands.max()!, 0.1)
    }

    func testSinePeaksNearItsFrequencyBand() {
        let bands = SpectrumAnalyzer.computeBands(
            samples: sine(frequency: 1000),
            sampleRate: 44100
        )
        let loudest = bands.enumerated().max { $0.element < $1.element }?.offset
        XCTAssertNotNil(loudest)
        // 24 logarithmic bands over 40 Hz - 16 kHz put 1 kHz around band 12-13.
        XCTAssertTrue((11...14).contains(loudest!), "unexpected peak band \(loudest!)")
    }

    func testDefaultBandCountIs24() {
        XCTAssertEqual(
            SpectrumAnalyzer.computeBands(samples: sine(frequency: 440), sampleRate: 44100).count,
            24
        )
        XCTAssertEqual(
            SpectrumAnalyzer.computeBands(samples: sine(frequency: 440), sampleRate: 48000, bandCount: 12).count,
            12
        )
    }

    func testEmptySamplesGiveZeroBands() {
        XCTAssertEqual(SpectrumAnalyzer.computeBands(samples: [], sampleRate: 44100), [Float](repeating: 0, count: 24))
        XCTAssertEqual(SpectrumAnalyzer.computeBands(samples: sine(frequency: 1000), sampleRate: 0), [Float](repeating: 0, count: 24))
    }

    func testBandsStayInUnitRange() {
        let bands = SpectrumAnalyzer.computeBands(samples: sine(frequency: 1000), sampleRate: 44100)
        XCTAssertTrue(bands.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    func testReusedOutputIsClearedBySilence() {
        var analyzer = SpectrumAnalyzer()
        var output = [Float](repeating: 1, count: 24)

        sine(frequency: 1000).withUnsafeBufferPointer { samples in
            analyzer.process(samples, sampleRate: 44100, into: &output)
        }
        XCTAssertGreaterThan(output.max()!, 0.1)

        let silence = [Float](repeating: 0, count: 1024)
        silence.withUnsafeBufferPointer { samples in
            analyzer.process(samples, sampleRate: 44100, into: &output)
        }
        XCTAssertEqual(output, [Float](repeating: 0, count: 24))
    }

    func testLowSampleRateClearsReusedOutput() {
        var analyzer = SpectrumAnalyzer()
        var output = [Float](repeating: 1, count: 24)

        sine(frequency: 440).withUnsafeBufferPointer { samples in
            analyzer.process(samples, sampleRate: 44100, into: &output)
        }
        XCTAssertGreaterThan(output.max()!, 0)

        // Nyquist below the 40 Hz lowest band: nothing can be mapped.
        sine(frequency: 20).withUnsafeBufferPointer { samples in
            analyzer.process(samples, sampleRate: 60, into: &output)
        }
        XCTAssertEqual(output, [Float](repeating: 0, count: 24))
    }
}
