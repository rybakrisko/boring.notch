//
//  LiquidGlass.swift
//  boringNotch
//
//  Apple's Liquid Glass (macOS 26+) for controls inside the notch, with a flat
//  fallback on older systems. The notch shell itself stays black so it blends
//  with the physical notch.
//

import SwiftUI

extension View {
    /// Draws this view's background as Liquid Glass in `shape`.
    /// - Parameters:
    ///   - tint: optional color mixed into the glass (e.g. for a primary button).
    ///   - interactive: glass reacts to hover/press (macOS 26+).
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(shape.fill(tint ?? Color.white.opacity(0.12)))
        }
    }

    @available(macOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}
