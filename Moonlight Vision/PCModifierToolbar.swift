//
//  PCModifierToolbar.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Esc/Tab keys and sticky Win/Ctrl/Alt/Shift toggles shown around the virtual keyboard field.
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct PCModifierToolbar<Content: View>: View {
    @State private var ctrlActive = false
    @State private var altActive = false
    @State private var shiftActive = false
    @State private var winActive = false

    @ViewBuilder let textField: Content

    var body: some View {
        HStack(spacing: 12) {
            Button("Esc") { sendInstantKey(0x1B) }
                .buttonStyle(.bordered)
            Button("Tab") { sendInstantKey(0x09) }
                .buttonStyle(.bordered)

            Divider().frame(height: 24)

            textField

            Divider().frame(height: 24)

            Toggle("Win", isOn: Binding(get: { winActive }, set: { val in
                winActive = val; sendToggleKey(0x5B, down: val)
            })).toggleStyle(.button)

            Toggle("Ctrl", isOn: Binding(get: { ctrlActive }, set: { val in
                ctrlActive = val; sendToggleKey(0xA2, down: val)
            })).toggleStyle(.button)

            Toggle("Alt", isOn: Binding(get: { altActive }, set: { val in
                altActive = val; sendToggleKey(0xA4, down: val)
            })).toggleStyle(.button)

            Toggle("Shift", isOn: Binding(get: { shiftActive }, set: { val in
                shiftActive = val; sendToggleKey(0xA0, down: val)
            })).toggleStyle(.button)
        }
        .padding(12)
        .glassBackgroundEffect()
    }

    private func sendInstantKey(_ keyCode: Int16) {
        let hidCode = Int16(bitPattern: 0x8000 | UInt16(keyCode))
        LiSendKeyboardEvent(hidCode, 0x03, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            LiSendKeyboardEvent(hidCode, 0x04, 0)
        }
    }

    private func sendToggleKey(_ keyCode: Int16, down: Bool) {
        let hidCode = Int16(bitPattern: 0x8000 | UInt16(keyCode))
        LiSendKeyboardEvent(hidCode, down ? 0x03 : 0x04, 0)
    }
}
