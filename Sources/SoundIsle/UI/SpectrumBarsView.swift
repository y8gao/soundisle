import AppKit
import Combine
import SoundIsleCore
import SwiftUI

/// Draws the 24 engine bands in an `NSView`. The view subscribes to
/// `PlayerEngine.$spectrum` itself, so SwiftUI is never re-rendered at the
/// ~24 fps publish rate; only this small rect is redrawn.
struct SpectrumBarsView: NSViewRepresentable {
    let engine: PlayerEngine
    let bottomColor: Color
    let topColor: Color
    var gap: CGFloat = 2
    var minBarHeight: CGFloat = 1
    var cornerRadius: CGFloat = 1.2

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SpectrumBarsNSView {
        let view = SpectrumBarsNSView()
        configure(view)
        context.coordinator.attach(engine: engine, view: view)
        return view
    }

    func updateNSView(_ nsView: SpectrumBarsNSView, context: Context) {
        configure(nsView)
        context.coordinator.attach(engine: engine, view: nsView)
    }

    private func configure(_ view: SpectrumBarsNSView) {
        view.bottomColor = NSColor(bottomColor)
        view.topColor = NSColor(topColor)
        view.gap = gap
        view.minBarHeight = minBarHeight
        view.cornerRadius = cornerRadius
    }

    final class Coordinator {
        private var cancellable: AnyCancellable?
        private weak var observedEngine: PlayerEngine?

        func attach(engine: PlayerEngine, view: SpectrumBarsNSView) {
            guard observedEngine !== engine else { return }
            observedEngine = engine
            cancellable = engine.$spectrum.sink { [weak view] bands in
                view?.setBands(bands)
            }
        }
    }
}

final class SpectrumBarsNSView: NSView {
    var bottomColor = NSColor.white { didSet { needsDisplay = true } }
    var topColor = NSColor.white { didSet { needsDisplay = true } }
    var gap: CGFloat = 2 { didSet { needsDisplay = true } }
    var minBarHeight: CGFloat = 1 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 1.2 { didSet { needsDisplay = true } }

    private var bands: [Float] = [] {
        didSet {
            if bands != oldValue {
                needsDisplay = true
            }
        }
    }

    override var isOpaque: Bool { false }

    func setBands(_ newBands: [Float]) {
        bands = newBands
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !bands.isEmpty, bounds.width > 0, bounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(
                  colorsSpace: CGColorSpaceCreateDeviceRGB(),
                  colors: [bottomColor.cgColor, topColor.cgColor] as CFArray,
                  locations: [0, 1]
              ) else { return }

        let count = CGFloat(bands.count)
        let width = max(1, (bounds.width - gap * (count - 1)) / count)
        let path = CGMutablePath()
        for (index, band) in bands.enumerated() {
            let value = CGFloat(min(max(band, 0), 1))
            let height = max(minBarHeight, value * bounds.height)
            let rect = CGRect(
                x: CGFloat(index) * (width + gap),
                y: 0,
                width: width,
                height: height
            )
            path.addRoundedRect(
                in: rect,
                cornerWidth: min(cornerRadius, width / 2),
                cornerHeight: min(cornerRadius, height / 2)
            )
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: bounds.height),
            options: []
        )
        context.restoreGState()
    }
}
