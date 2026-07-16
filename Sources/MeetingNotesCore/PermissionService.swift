import AppKit
import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionState: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case restartRequired

    public var isAuthorized: Bool {
        self == .authorized
    }
}

public struct PermissionSnapshot: Equatable, Sendable {
    public let microphone: PermissionState
    public let screenCapture: PermissionState

    public init(microphone: PermissionState, screenCapture: PermissionState) {
        self.microphone = microphone
        self.screenCapture = screenCapture
    }

    public var isReady: Bool {
        microphone.isAuthorized && screenCapture.isAuthorized
    }
}

public protocol PermissionServicing: AnyObject {
    func microphoneState() -> PermissionState
    func screenCaptureState(
        hasRequestedAccess: Bool,
        isAwaitingRelaunch: Bool
    ) -> PermissionState
    func requestMicrophoneAccess() async -> Bool
    func requestScreenCaptureAccess() -> Bool
    func openMicrophoneSettings()
    func openScreenCaptureSettings()
}

public final class SystemPermissionService: PermissionServicing {
    public init() {}

    public func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .restricted, .denied:
            .denied
        case .authorized:
            .authorized
        @unknown default:
            .denied
        }
    }

    public func screenCaptureState(
        hasRequestedAccess: Bool,
        isAwaitingRelaunch: Bool
    ) -> PermissionState {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        if isAwaitingRelaunch {
            return .restartRequired
        }
        return hasRequestedAccess ? .denied : .notDetermined
    }

    public func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    @discardableResult
    public func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    public func openScreenCaptureSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
