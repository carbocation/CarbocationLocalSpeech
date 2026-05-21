import Foundation

#if canImport(Darwin)
import Dispatch
#endif

public enum FluidAudioModelMemoryPressurePolicy: String, Codable, Hashable, Sendable {
    case disabled
    case evictWhenIdle
}

internal enum FluidAudioMemoryPressureEvent: Sendable {
    case warning
}

internal final class FluidAudioMemoryPressureMonitor: @unchecked Sendable {
#if canImport(Darwin)
    private let source: DispatchSourceMemoryPressure

    init(handler: @escaping @Sendable (FluidAudioMemoryPressureEvent) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue(label: "CarbocationDiarizationRuntime.MemoryPressure")
        )
        self.source = source
        source.setEventHandler {
            handler(.warning)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
#else
    init(handler: @escaping @Sendable (FluidAudioMemoryPressureEvent) -> Void) {
        _ = handler
    }
#endif
}
