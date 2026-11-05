//
//  BluetoothAudioLiveActivity.swift
//  boringNotch
//
//  Closed-notch view shown when AirPods/headphones connect:
//  icon + name on the left of the notch, battery ring on the right.
//

import SwiftUI

struct BluetoothAudioLiveActivity: View {
    let device: BluetoothAudioDevice
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: device.symbol)
                    .font(.system(size: 14, weight: .medium))
                Text(device.name)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 150, alignment: .leading)
            .fixedSize()

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 10)

            HStack(spacing: 6) {
                if let level = device.displayLevel {
                    Text("\(level)%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white)
                    BatteryRing(level: level)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .frame(height: height, alignment: .center)
    }
}

private struct BatteryRing: View {
    let level: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(level) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }

    private var color: Color {
        level <= 20 ? .red : .green
    }
}
