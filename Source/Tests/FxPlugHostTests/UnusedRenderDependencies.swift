import Metal

// These dependencies satisfy the OSC drawing method at compile time. Tests call
// hit-testing and mouse callbacks only. Any accidental GPU call fails immediately.
enum PluginLog {
    static func notice(_ message: String) {}
    static func error(_ message: String) { print(message) }
}
enum MetalDeviceCacheError: Error {
    case unknownDevice(UInt64), queueExhausted, commandBufferCreationFailed, commandEncoderCreationFailed
}
struct MetalDeviceCache: Sendable {
    static let shared = MetalDeviceCache()
    func device(forRegistryID identifier: UInt64) -> (any MTLDevice)? { fatalError("Unexpected drawing") }
    func entry(for device: any MTLDevice) throws -> UnusedMetalEntry { fatalError("Unexpected drawing") }
}
struct UnusedMetalEntry {
    func borrowCommandQueue() -> (any MTLCommandQueue)? { fatalError("Unexpected drawing") }
    func returnCommandQueue(_ queue: any MTLCommandQueue) { fatalError("Unexpected drawing") }
    func renderPipelines(for format: MTLPixelFormat) throws -> UnusedRenderPipelines { fatalError("Unexpected drawing") }
}
struct UnusedRenderPipelines {
    let drawOSC: any MTLRenderPipelineState
}
