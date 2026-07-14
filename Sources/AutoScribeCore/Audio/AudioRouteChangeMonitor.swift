import CoreAudio
import Foundation

public protocol AudioRouteChangeMonitoring: AnyObject, Sendable {
    func start(handler: @escaping AudioRouteChangeMonitor.Handler)
    func stop()
}

/// Watches the macOS default audio route and coalesces the burst of Core Audio
/// notifications produced while Bluetooth and wired devices reconnect.
public final class AudioRouteChangeMonitor: AudioRouteChangeMonitoring, @unchecked Sendable {
    public typealias Handler = @Sendable (
        _ previous: AudioRouteInspector.Route,
        _ current: AudioRouteInspector.Route
    ) -> Void

    private let queue = DispatchQueue(label: "com.autoscribe.audio-route-monitor")
    private let debounceInterval: TimeInterval
    private var registrations: [Registration] = []
    private var pendingNotification: DispatchWorkItem?
    private var currentRoute: AudioRouteInspector.Route?
    private var handler: Handler?

    private struct Registration {
        var address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }

    public init(debounceInterval: TimeInterval = 0.6) {
        self.debounceInterval = debounceInterval
    }

    public func start(handler: @escaping Handler) {
        queue.sync {
            stopLocked()
            self.handler = handler
            currentRoute = AudioRouteInspector.currentRoute()

            let selectors: [AudioObjectPropertySelector] = [
                kAudioHardwarePropertyDefaultInputDevice,
                kAudioHardwarePropertyDefaultSystemOutputDevice,
                kAudioHardwarePropertyDevices
            ]

            for selector in selectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.scheduleRouteEvaluation()
                }
                let status = AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    queue,
                    listener
                )
                if status == noErr {
                    registrations.append(Registration(address: address, listener: listener))
                }
            }
        }
    }

    public func stop() {
        queue.sync {
            stopLocked()
        }
    }

    private func scheduleRouteEvaluation() {
        pendingNotification?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateRoute()
        }
        pendingNotification = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func evaluateRoute() {
        let newRoute = AudioRouteInspector.currentRoute()
        guard let oldRoute = currentRoute, oldRoute != newRoute else {
            currentRoute = newRoute
            return
        }
        currentRoute = newRoute
        handler?(oldRoute, newRoute)
    }

    private func stopLocked() {
        pendingNotification?.cancel()
        pendingNotification = nil

        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &registration.address,
                queue,
                registration.listener
            )
        }
        registrations.removeAll()
        handler = nil
        currentRoute = nil
    }

    deinit {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &registration.address,
                queue,
                registration.listener
            )
        }
    }
}
