//
//  BluetoothAudioManager.swift
//  boringNotch
//
//  Shows AirPods / headphones with their battery the moment they connect.
//  Event driven: IOBluetooth calls us on connect/disconnect, nothing polls.
//

import AppKit
import Defaults
import Foundation
import IOBluetooth

struct BluetoothAudioDevice: Equatable {
    let name: String
    let symbol: String
    /// 0–100, nil when the device doesn't report it.
    let left: Int?
    let right: Int?
    let caseLevel: Int?
    let single: Int?

    /// The level to show in the closed notch: the lowest earbud, or the single value.
    var displayLevel: Int? {
        if let single { return single }
        let buds = [left, right].compactMap { $0 }
        return buds.min()
    }
}

@MainActor
final class BluetoothAudioManager: NSObject, ObservableObject {
    static let shared = BluetoothAudioManager()

    @Published private(set) var device: BluetoothAudioDevice?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [IOBluetoothUserNotification] = []
    private var startedAt = Date.distantPast

    private override init() {}

    func start() {
        guard connectNotification == nil else { return }
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    // IOBluetooth also reports devices that were already connected when we register.
    // Those aren't "the moment they connect", so skip them.
    private var isLaunchReplay: Bool { Date().timeIntervalSince(startedAt) < 3 }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.isAudioDevice(device) else { return }
        if let disconnect = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
            disconnectNotifications.append(disconnect)
        }
        guard !isLaunchReplay, Defaults[.showBluetoothAudioNotifications] else { return }

        Task { @MainActor in
            // Battery levels arrive a moment after the link comes up.
            try? await Task.sleep(for: .seconds(2))
            guard device.isConnected() else { return }
            self.device = Self.snapshot(of: device)
            BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .bluetooth)
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        disconnectNotifications.removeAll { $0 === notification }
        if self.device?.name == device.name {
            self.device = nil
        }
    }

    // MARK: - Helpers

    private static func isAudioDevice(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
    }

    private static func snapshot(of device: IOBluetoothDevice) -> BluetoothAudioDevice {
        let name = device.name ?? "Headphones"
        return BluetoothAudioDevice(
            name: name,
            symbol: symbol(for: name),
            left: batteryLevel(device, "batteryPercentLeft"),
            right: batteryLevel(device, "batteryPercentRight"),
            caseLevel: batteryLevel(device, "batteryPercentCase"),
            single: batteryLevel(device, "batteryPercentSingle")
        )
    }

    /// Reads Apple's undocumented battery properties. Returns nil when missing or 0 (unknown).
    private static func batteryLevel(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? Int,
              (1...100).contains(value) else { return nil }
        return value
    }

    private static func symbol(for name: String) -> String {
        let lowered = name.lowercased()
        let candidates: [String]
        if lowered.contains("airpods max") {
            candidates = ["airpods.max", "airpodsmax"]
        } else if lowered.contains("airpods pro") {
            candidates = ["airpods.pro", "airpodspro"]
        } else if lowered.contains("airpods") {
            candidates = ["airpods"]
        } else if lowered.contains("beats") {
            candidates = ["beats.headphones"]
        } else {
            candidates = []
        }
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "headphones"
    }
}
