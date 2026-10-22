//
//  StreamControlState.swift
//  Moonlight Vision
//
//  Created by Linggan-ua on 2025/12/03.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Shared stream control state - for communication between control panel window and main view
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import RealityKit
import Combine

/// Stream control state manager
/// Used to share state between independent control panel window and immersive space
@MainActor
class StreamControlState: ObservableObject {
    static let shared = StreamControlState()
    
    // MARK: - Control Panel State
    @Published var isControlPanelVisible: Bool = false
    
    // MARK: - Screen Control
    nonisolated static let defaultImmersiveScale: Float = 0.8
    nonisolated static let defaultImmersivePosition = SIMD3<Float>(0, 1.0, -1.5)
    nonisolated static let defaultPinnedStageScale: Float = 5.0
    nonisolated static let defaultPinnedStageHeight: Float = 0.75

    @Published var immersiveScale: Float = StreamControlState.defaultImmersiveScale
    @Published var immersivePositionX: Float = StreamControlState.defaultImmersivePosition.x
    @Published var immersivePositionY: Float = StreamControlState.defaultImmersivePosition.y
    @Published var immersivePositionZ: Float = StreamControlState.defaultImmersivePosition.z
    @Published var immersionAmount: Float = 0.0
    @Published var isInteractive: Bool = false
    
    // MARK: - Environment Control
    @Published var selectedEnvironmentState: EnvironmentStateType = .none
    @Published var isSemiImmersionEnabled: Bool = false
    @Published var isUpdatingImmersion: Bool = false
    
    // MARK: - Display Control
    @Published var isKeyboardActive: Bool = false
    @Published var videoMode: VideoMode = .standard2D
    @Published var dimLevel: Int = 0
    @Published var tiltAngle: Float = 0.0
    
    // MARK: - Pin to Stage Control
    @Published var isPinnedToStage: Bool = false
    @Published var isPinningTransitioning: Bool = false
    @Published var canPinToStage: Bool = false
    @Published var pinnedStageScale: Float = StreamControlState.defaultPinnedStageScale // Screen scale when pinned
    @Published var pinnedStageHeight: Float = StreamControlState.defaultPinnedStageHeight // Vertical offset when pinned
    
    // MARK: - Action Callbacks
    /// Home: push main overlay (stream stays). Stop: full teardown.
    var homeAction: (() -> Void)?
    var stopAction: (() -> Void)?
    var closeAction: (() -> Void)?  // Legacy fallback
    var toggleKeyboardAction: (() -> Void)?
    var toggleDimmingPickerAction: (() -> Void)?
    var onEnvironmentChange: ((EnvironmentStateType) -> Void)?
    var onSemiImmersionToggle: ((Bool) -> Void)?
    var onPinToggle: (() -> Void)?
    var saveSettings: (() -> Void)?
    var toggle3DMode: (() -> Void)?
    var onOverlayHint: ((String) -> Void)?
    
    // MARK: - Controller Support
    weak var controllerSupport: ControllerSupport?
    
    // MARK: - HDR State
    var needsHdr: Bool = false
    @Published var isCalibrationModeActive: Bool = false
    @Published var reactiveLighting: Bool = false
    
    // MARK: - Audio State
    @Published var isAudioFallbackModeActive: Bool = false
    
    private init() {
        // Load saved immersive screen settings
        let defaults = UserDefaults.standard
        if let savedScale = defaults.object(forKey: .realitykitImmersiveScale) as? Float {
            immersiveScale = savedScale
        }
        if let savedPosX = defaults.object(forKey: .realitykitImmersivePosX) as? Float,
           let savedPosY = defaults.object(forKey: .realitykitImmersivePosY) as? Float,
           let savedPosZ = defaults.object(forKey: .realitykitImmersivePosZ) as? Float {
            immersivePositionX = savedPosX
            immersivePositionY = savedPosY
            immersivePositionZ = savedPosZ
        }
        if let savedImmersion = defaults.object(forKey: .realitykitImmersionAmount) as? Float {
            immersionAmount = savedImmersion
        }
        // Load pinned screen settings
        if let savedPinnedScale = defaults.object(forKey: .realitykitPinnedStageScale) as? Float {
            pinnedStageScale = savedPinnedScale
        }
        if let savedPinnedHeight = defaults.object(forKey: .realitykitPinnedStageHeight) as? Float {
            pinnedStageHeight = savedPinnedHeight
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AudioFallbackModeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let fallbackMode = notification.userInfo?["fallbackMode"] as? Bool {
                self?.isAudioFallbackModeActive = fallbackMode
            }
        }
    }
    
    /// Clears the saved immersive placement and returns the live state to the defaults.
    func resetImmersiveTransform() {
        let defaults = UserDefaults.standard
        for key in SettingsKey.immersiveTransform {
            defaults.removeObject(forKey: key)
        }
        immersiveScale = Self.defaultImmersiveScale
        immersivePosition = Self.defaultImmersivePosition
        immersionAmount = 0.0
        pinnedStageScale = Self.defaultPinnedStageScale
        pinnedStageHeight = Self.defaultPinnedStageHeight
    }
    
    // MARK: - Computed Properties
    var immersivePosition: SIMD3<Float> {
        get { SIMD3<Float>(immersivePositionX, immersivePositionY, immersivePositionZ) }
        set {
            immersivePositionX = newValue.x
            immersivePositionY = newValue.y
            immersivePositionZ = newValue.z
        }
    }
}

