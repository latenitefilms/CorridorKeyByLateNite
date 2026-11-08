import CoreMedia
import Foundation

/// Minimal owner for the production rectangle callbacks; no app or host is opened.
final class CorridorKeyToolboxPlugIn: NSObject {}

/// Real SDK matrices with controlled raster bounds, including shifted origins.
private final class GeometryTile: FxImageTile {
    private let bounds: FxRect
    private let forward = FxMatrix44()
    private let inverse = FxMatrix44()

    override var imagePixelBounds: FxRect { bounds }
    override var pixelTransform: FxMatrix44! { forward }
    override var inversePixelTransform: FxMatrix44! { inverse }

    init(width: Int32, height: Int32, displaySize: CGSize, left: Int32 = 0, bottom: Int32 = 0) {
        bounds = FxRect(left: left, bottom: bottom, right: left + width, top: bottom + height)
        super.init()
        forward.matrix().withMemoryRebound(to: Double.self, capacity: 16) { values in
            values[0] = Double(width) / displaySize.width
            values[5] = Double(height) / displaySize.height
            values[3] = Double(left)
            values[7] = Double(bottom)
        }
        forward.matrix().withMemoryRebound(to: (Double, Double, Double, Double).self, capacity: 4) {
            inverse.setMatrix($0)
        }
        precondition(inverse.invert())
    }

    required init?(coder: NSCoder) { fatalError("The fixture is never archived.") }
}

/// Exercises FxPlug geometry with Apple's actual matrix implementation.
@main
struct ImageGeometryHostTests {
    static func main() throws {
        let displaySize = CGSize(width: 872, height: 480)
        let analysis = GeometryTile(width: 872, height: 480, displaySize: displaySize)
        let plugin = CorridorKeyToolboxPlugIn()
        for (width, height) in [(706, 480), (720, 480), (436, 240), (353, 240), (872, 480)] {
            let playback = GeometryTile(width: Int32(width), height: Int32(height), displaySize: displaySize,
                                        left: -17, bottom: 23)
            precondition(playback.squarePixelSize == displaySize)
            precondition(analysis.squarePixelSize == playback.squarePixelSize)
            var output = FxRect()
            try plugin.destinationImageRect(&output, sourceImages: [analysis], destinationImage: playback,
                                            pluginState: nil, atTime: .zero)
            // Outward rounding can add one boundary pixel after floating-point
            // transforms; it must never substitute the source's raster width.
            precondition(abs(output.left - playback.imagePixelBounds.left) <= 1)
            precondition(abs(output.bottom - playback.imagePixelBounds.bottom) <= 1)
            precondition(abs(output.right - playback.imagePixelBounds.right) <= 1)
            precondition(abs(output.top - playback.imagePixelBounds.top) <= 1)
        }
        let portrait = GeometryTile(width: 240, height: 353, displaySize: CGSize(width: 480, height: 872))
        precondition(portrait.squarePixelSize == CGSize(width: 480, height: 872))
        print("PASS: anamorphic and proxy geometry, square-pixel analysis identity, shifted origins, output bounds and portrait geometry.")
    }
}
