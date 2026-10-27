import CoreMedia
import Foundation
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("FxPlug custom parameter archives")
struct CustomParameterArchiveTests {
    @Test("Every custom inspector row has a decodable Motion default", arguments: [50, 9012, 9013, 9014, 9015])
    func templateDefaults(parameterID: Int) throws {
        let document = try motionTemplate()
        let nodes = try document.nodes(forXPath: "//filter[@id='10010']//parameter[@id='\(parameterID)']")
        #expect(nodes.count == 1)
        let parameter = try #require(nodes.first as? XMLElement)
        for key in ["defaultVal", "dataValue"] {
            let encoded = try #require(parameter.elements(forName: key).first?.stringValue)
            let outer = try NSKeyedUnarchiver(forReadingFrom: motionData(encoded))
            outer.requiresSecureCoding = true
            let customArchive = try #require(outer.decodeObject(of: NSData.self, forKey: "BlindDataObject") as Data?)
            let legacy = try #require(outer.decodeObject(of: NSNumber.self, forKey: "DataIsLegacy"))
            #expect(!legacy.boolValue)
            outer.finishDecoding()
            let value = try decodeCustomValue(customArchive)
            #expect(value == CustomParameterValue.empty)
        }
    }

    @Test("The published storage channel exists and retired storage is absent")
    func templateStorageChannel() throws {
        let document = try motionTemplate()
        #expect(try document.nodes(forXPath: "//publishSettings/target[@object='10010'][@channel='./50']").count == 1)
        #expect(try document.nodes(forXPath: "//filter[@id='10010']/parameter[@id='7003' or @id='7004']").isEmpty)
    }

    @Test("Secure host archives preserve tools, frame hints, assets and analysis together")
    func populatedArchive() throws {
        let frame = try #require(HintFrame(time: .zero, duration: CMTime(value: 1, timescale: 25)))
        let hints = HintPointSet(points: [
            HintPoint(x: 0.2, y: 0.7, kind: .foreground, frame: frame),
            HintPoint(x: 0.8, y: 0.3, kind: .ignore, frame: frame)
        ])
        let analysis = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 25), firstFrameTime: .zero,
            frameCount: 1, analyzedCount: 1, screenColorRaw: 0, qualityModeRaw: 0,
            inferenceResolution: 512, matteWidth: 512, matteHeight: 512,
            mattes: [0: Data([1, 2, 3])]
        )
        let asset: NSDictionary = ["asset": Data([4, 5, 6])]
        let value: NSDictionary = [
            "schemaVersion": 1,
            "subjectTool": OnScreenControlTool.backgroundHint.parameterDictionary,
            "subjectPoints": hints.asParameterDictionary(),
            "alphaHintAsset": asset,
            "analysisData": analysis.asParameterDictionary()
        ]
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(value, forKey: "Custom Data")
        archiver.finishEncoding()
        let decoded = try decodeCustomValue(archiver.encodedData)
        #expect(OnScreenControlTool(parameterDictionary: decoded["subjectTool"] as? NSDictionary) == .backgroundHint)
        #expect(HintPointSet.fromParameterDictionary(decoded["subjectPoints"] as? NSDictionary) == hints)
        #expect(decoded["alphaHintAsset"] as? NSDictionary == asset)
        let restoredAnalysis = try #require(AnalysisData.fromParameterDictionary(decoded["analysisData"] as? NSDictionary))
        #expect(restoredAnalysis.frameDuration == analysis.frameDuration)
        #expect(restoredAnalysis.mattes == analysis.mattes)
    }

    private func decodeCustomValue(_ data: Data) throws -> NSDictionary {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        let value = try #require(unarchiver.decodeObject(
            of: CustomParameterValue.allowedClasses, forKey: "Custom Data"
        ) as? NSDictionary)
        unarchiver.finishDecoding()
        return value
    }

    private func motionTemplate() throws -> XMLDocument {
        let source = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try XMLDocument(contentsOf: source.appending(path:
            "CorridorKeyByLateNite/WrapperApp/Resources/Motion Template/CorridorKey by LateNite/CorridorKey by LateNite.moef"
        ))
    }

    /// Motion uses a different Base64 alphabet and a nine-byte length/type prefix.
    /// Decode the shipped value itself so a missing or damaged template cannot pass.
    private func motionData(_ encoded: String) throws -> Data {
        let motionAlphabet = Array("*-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let standardAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var standard = try String(encoded.map { character in
            let index = try #require(motionAlphabet.firstIndex(of: character))
            return standardAlphabet[index]
        })
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        let bytes = try #require(Data(base64Encoded: standard))
        try #require(bytes.count >= 9)
        let length = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        #expect(bytes[8] == 42)
        #expect(length == bytes.count - 9)
        return Data(bytes.dropFirst(9))
    }
}
