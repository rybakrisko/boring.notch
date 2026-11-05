//
//  Button+Bouncing.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import SwiftUI
import Defaults

struct BouncingButtonStyle: ButtonStyle {
    let vm: BoringViewModel
    @State private var isPressed = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: Defaults[.cornerRadiusScaling] ? 10 : MusicPlayerImageSizes.cornerRadiusInset.closed),
                interactive: true
            )
            .scaleEffect(isPressed ? 0.9 : 1.0)
            .onChange(of: configuration.isPressed) { _, _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.3, blendDuration: 0.3)) {
                    isPressed.toggle()
                }
            }
    }
}

extension Button {
    func bouncingStyle(vm: BoringViewModel) -> some View {
        self.buttonStyle(BouncingButtonStyle(vm: vm))
    }
}
