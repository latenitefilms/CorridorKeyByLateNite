//
//  CorridorKeyToolboxPlugIn+RenderRects.swift
//  CorridorKey by LateNite
//
//  Tells FxPlug which parts of the input and output images we touch. The
//  keyer is an identity transform so the output bounds always equal the
//  input bounds. Because the neural matte considers spatial context, we
//  also ask for the full source image rather than a sub-tile.
//

import Foundation
import CoreMedia

extension FxImageTile {
    /// Full-resolution square-pixel dimensions, independent of proxy scaling
    /// and anamorphic storage. Analysis and playback can have different rasters.
    var squarePixelSize: CGSize {
        let bounds = imagePixelBounds
        let rasterSize = CGSize(width: Double(bounds.right) - Double(bounds.left),
                                height: Double(bounds.top) - Double(bounds.bottom))
        guard let inversePixelTransform else { return rasterSize }
        let origin = inversePixelTransform.transform2DPoint(FxPoint2D(x: Double(bounds.left), y: Double(bounds.bottom)))
        let horizontal = inversePixelTransform.transform2DPoint(FxPoint2D(x: Double(bounds.right), y: Double(bounds.bottom)))
        let vertical = inversePixelTransform.transform2DPoint(FxPoint2D(x: Double(bounds.left), y: Double(bounds.top)))
        let width = hypot(horizontal.x - origin.x, horizontal.y - origin.y)
        let height = hypot(vertical.x - origin.x, vertical.y - origin.y)
        guard width.isFinite, height.isFinite,
              (1...Double(Int32.max)).contains(width), (1...Double(Int32.max)).contains(height) else { return rasterSize }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Maps the full source bounds through document space into output pixels.
    /// Copying pixel bounds directly is only valid when both transforms agree.
    func imageBounds(in destination: FxImageTile) -> FxRect {
        guard let inversePixelTransform, let transform = destination.pixelTransform else { return imagePixelBounds }
        let bounds = imagePixelBounds
        let corners = [
            FxPoint2D(x: Double(bounds.left), y: Double(bounds.bottom)),
            FxPoint2D(x: Double(bounds.right), y: Double(bounds.bottom)),
            FxPoint2D(x: Double(bounds.left), y: Double(bounds.top)),
            FxPoint2D(x: Double(bounds.right), y: Double(bounds.top))
        ].map { transform.transform2DPoint(inversePixelTransform.transform2DPoint($0)) }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let left = corners.map(\.x).min(), let right = corners.map(\.x).max(),
              let bottom = corners.map(\.y).min(), let top = corners.map(\.y).max() else { return imagePixelBounds }
        func boundedCoordinate(_ value: Double, rounding rule: FloatingPointRoundingRule) -> Int32 {
            Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded(rule))))
        }
        return FxRect(left: boundedCoordinate(left, rounding: .down), bottom: boundedCoordinate(bottom, rounding: .down),
                      right: boundedCoordinate(right, rounding: .up), top: boundedCoordinate(top, rounding: .up))
    }
}

extension CorridorKeyToolboxPlugIn {

    @objc(destinationImageRect:sourceImages:destinationImage:pluginState:atTime:error:)
    func destinationImageRect(
        _ destinationImageRect: UnsafeMutablePointer<FxRect>,
        sourceImages: [FxImageTile],
        destinationImage: FxImageTile,
        pluginState: Data?,
        atTime renderTime: CMTime
    ) throws {
        if let source = sourceImages.first {
            destinationImageRect.pointee = source.imageBounds(in: destinationImage)
        } else {
            destinationImageRect.pointee = destinationImage.imagePixelBounds
        }
    }

    @objc(sourceTileRect:sourceImageIndex:sourceImages:destinationTileRect:destinationImage:pluginState:atTime:error:)
    func sourceTileRect(
        _ sourceTileRect: UnsafeMutablePointer<FxRect>,
        sourceImageIndex: UInt,
        sourceImages: [FxImageTile],
        destinationTileRect: FxRect,
        destinationImage: FxImageTile,
        pluginState: Data?,
        atTime renderTime: CMTime
    ) throws {
        let index = Int(sourceImageIndex)
        if sourceImages.indices.contains(index) {
            sourceTileRect.pointee = sourceImages[index].imagePixelBounds
        } else {
            sourceTileRect.pointee = destinationTileRect
        }
    }
}
