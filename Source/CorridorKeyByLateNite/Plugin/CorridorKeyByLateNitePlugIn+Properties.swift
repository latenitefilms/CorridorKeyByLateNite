//
//  CorridorKeyToolboxPlugIn+Properties.swift
//  CorridorKey by LateNite
//
//  Declares the static capabilities of the plug-in. Properties are fetched
//  once per instance and cached by the host, so this method is the right place
//  to advertise things like colour-space preferences and tiling support.
//

import Foundation

extension CorridorKeyToolboxPlugIn {

    @objc(properties:error:)
    func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
        // Both hosts use video-gamma pixels. The v2 bridge converts these to
        // scene-linear/asinh internally and returns foreground in the host's
        // encoding, preserving the shared compositing contract. Take the whole
        // image each render because the matte depends on spatial context
        // outside any individual tile.
        let swiftProperties: [String: Any] = [
            kFxPropertyKey_MayRemapTime: NSNumber(value: false),
            // Inference uses an axis-aligned image. Let the host resolve rotation,
            // translation and perspective; retain non-uniform/proxy scaling.
            kFxPropertyKey_PixelTransformSupport: NSNumber(value: kFxPixelTransform_Scale),
            kFxPropertyKey_VariesWhenParamsAreStatic: NSNumber(value: false),
            kFxPropertyKey_ChangesOutputSize: NSNumber(value: false),
            kFxPropertyKey_DesiredProcessingColorInfo: NSNumber(value: kFxImageColorInfo_RGB_GAMMA_VIDEO),
            kFxPropertyKey_NeedsFullBuffer: NSNumber(value: true)
        ]
        properties?.pointee = swiftProperties as NSDictionary
    }
}
