//
//  TemporarySettings.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import Observation
import AppIntents
import SwiftUI

/// UserDefaults keys used from Swift. Raw values are what's on disk, so don't rename them.
/// Objective-C still reads some of these by literal (spatialAudioMode, preferUninterruptedAudio).
enum SettingsKey: String {
    // TemporarySettings
    case appLanguagePreference
    case hasMigratedToNewDefaults_v1
    case hasSavedNewDefaults_v1
    case fpsMouseCapture
    case realitykitRendererTilt
    case realitykitScreenCornerRadius
    case realitykitImmersiveMode
    case reactiveLightingEnabled
    case macVirtualDisplayExperimental
    case autoResumeStreamOnReopen
    case rememberStreamSettings
    case uikitWindowCornerRadius
    case spatialAudioMode
    case preferUninterruptedAudio

    // Immersive screen transform
    case realitykitImmersiveScale
    case realitykitImmersivePosX
    case realitykitImmersivePosY
    case realitykitImmersivePosZ
    case realitykitImmersionAmount
    case realitykitPinnedStageScale
    case realitykitPinnedStageHeight
    case immersiveLocked = "immersive.locked"
    case legacyImmersivePosition = "immersive.pos"
    case legacyImmersiveScale = "immersive.scale"

    // Per-mode display settings, restored over the global ones when rememberStreamSettings is on
    case realitykitImmersiveCurvature
    case realitykitImmersiveGamma
    case realitykitImmersiveSaturation
    case realitykitImmersiveBrightness
    case realitykitImmersivePqExposure
    case realitykitHeight
    case realitykitDepthOffset
    case realitykitVolumeCurvature
    case realitykitVolumeGamma
    case realitykitVolumeSaturation
    case realitykitVolumeBrightness
    case realitykitVolumePqExposure
    case realitykitVolumeDimPassthrough
    case realitykitPqExposure
    case legacyTiltAngle = "realitykitTiltAngle"

    static let immersiveTransform: [SettingsKey] = [
        .realitykitImmersiveScale, .realitykitImmersivePosX, .realitykitImmersivePosY, .realitykitImmersivePosZ,
        .realitykitImmersionAmount, .realitykitPinnedStageScale, .realitykitPinnedStageHeight,
        .legacyImmersivePosition, .legacyImmersiveScale,
    ]

    static let perModeDisplay: [SettingsKey] = [
        .realitykitImmersiveCurvature, .realitykitImmersiveGamma, .realitykitImmersiveSaturation,
        .realitykitImmersiveBrightness, .realitykitImmersivePqExposure,
        .realitykitHeight, .realitykitDepthOffset,
        .realitykitVolumeCurvature, .realitykitVolumeGamma, .realitykitVolumeSaturation,
        .realitykitVolumeBrightness, .realitykitVolumePqExposure, .realitykitVolumeDimPassthrough,
        .realitykitPqExposure,
    ]
}

extension UserDefaults {
    func object(forKey key: SettingsKey) -> Any? { object(forKey: key.rawValue) }
    func bool(forKey key: SettingsKey) -> Bool { bool(forKey: key.rawValue) }
    func float(forKey key: SettingsKey) -> Float { float(forKey: key.rawValue) }
    func array(forKey key: SettingsKey) -> [Any]? { array(forKey: key.rawValue) }
    func set(_ value: Any?, forKey key: SettingsKey) { set(value, forKey: key.rawValue) }
    func removeObject(forKey key: SettingsKey) { removeObject(forKey: key.rawValue) }
}

@objc public enum AppLanguage: Int, CaseIterable, Sendable, Hashable {
    case english = 0
    case chinese

    public var displayName: LocalizedStringKey {
        switch self {
        case .english:
            return "English"
        case .chinese:
            return "简体中文"
        }
    }
}

@objc public enum SpatialAudioMode: Int, CaseIterable, Sendable, Hashable {
    case stereo = 0
    case window = 1
    case surround = 2
}

#if os(visionOS)
@Observable
#endif
@objc
@MainActor
public class TemporarySettings: NSObject {
    @objc public var bitrate: Int32
    @objc public var framerate: Int32
    @objc public var height: Int32
    @objc public var width: Int32
    @objc public var audioConfig: Int32
    @objc public var onscreenControls: OnScreenControlsLevel
    @objc public var uniqueId: String
    @objc public var preferredCodec = PreferredCodec.auto
    @objc public var renderer: Renderer = .classic

    @objc public var realitykitRendererAnimateOpening: Bool = false
    @objc public var realitykitRendererCurvature: Float = 0.0
    @objc public var realitykitRendererTilt: Float = 0.0
    @objc public var realitykitScreenCornerRadius: Float = 0.018
    @objc public var realitykitImmersiveMode: Bool = false
    @objc public var reactiveLightingEnabled: Bool = false

    @objc public var gazeTouchMode = false
    @objc public var gazeCursorOffsetX: Int = 0
    @objc public var gazeCursorOffsetY: Int = 0
    @objc public var hideHandsIn360Environment = false

    @objc public var useFramePacing = false
    @objc public var multiController = false
    @objc public var swapABXYButtons = false
    @objc public var playAudioOnPC = false
    @objc public var optimizeGames = false
    @objc public var enableHdr = false
    @objc public var btMouseSupport = false
    @objc public var fpsMouseCapture = false
    @objc public var absoluteTouchMode = false
    @objc public var statsOverlay = false
    @objc public var dimPassthrough = true
    @objc public var macVirtualDisplayExperimental = false
    
    // UIKit window corner radius (default: 0, may affect clarity)
    @objc public var uikitWindowCornerRadius: Float = 0.0
    
    // --- HDR / Color Settings ---
    // HDR correct neutral: boost=1.0, contrast=1.0, saturation=1.0 (passed directly to shader)
    @objc public var brightness: Float = 1.0
    @objc public var gamma: Float = 1.0       // Default: 1.0 (Neutral)
    @objc public var saturation: Float = 1.0  // Default: 1.0 (Neutral)
    /// PQ (HDR10) / ST.2084 exposure trim for RealityKit; 1.0 = neutral. Not stored in Core Data.
    @objc public var pqExposure: Float = 1.0
    
    @objc public var appLanguageRaw: Int = AppLanguage.english.rawValue
    @objc public var autoResumeStreamOnReopen = false
    @objc public var rememberStreamSettings = true
    
    @objc public var spatialAudioMode: Int = SpatialAudioMode.window.rawValue
    @objc public var preferUninterruptedAudio: Bool = true

    @objc public var parent: MoonlightSettings?

    // This init is used for SwiftUI Previews only
    override public init() {
        self.bitrate = 30000
        self.framerate = 60
        self.height = 1440
        self.width = 2560
        self.audioConfig = 0
        self.uniqueId = ""
        self.onscreenControls = OnScreenControlsLevel.off
        self.renderer = .classic
        self.realitykitRendererAnimateOpening = false
        self.realitykitRendererCurvature = 0.0
        self.realitykitRendererTilt = 0.0
        self.dimPassthrough = false
        self.macVirtualDisplayExperimental = false
        self.reactiveLightingEnabled = false
        
        // HDR defaults: 1.0 = neutral (correct for shader)
        self.brightness = 1.0
        self.gamma = 1.0
        self.saturation = 1.0
        self.pqExposure = 1.0
        
        if let storedLang = UserDefaults.standard.object(forKey: .appLanguagePreference) as? Int {
            self.appLanguageRaw = storedLang
        } else {
            self.appLanguageRaw = AppLanguage.english.rawValue
        }
        
        self.spatialAudioMode = SpatialAudioMode.window.rawValue
        self.preferUninterruptedAudio = true
        super.init()
    }

    // This init is used by the App when loading from the Database
        @objc public init(fromSettings settings: MoonlightSettings) {
            #if TARGET_OS_TV
            self.bitrate = 0
            self.framerate = 0
            self.height = 0
            self.width = 0
            self.audioConfig = 0
            self.uniqueId = ""
            self.onscreenControls = .off
            #else

            // 1. Load raw values from the Database
            let loadedBitrate = settings.bitrate?.int32Value ?? 0
            let loadedHeight = settings.height?.int32Value ?? 0
            let loadedWidth = settings.width?.int32Value ?? 0
            let loadedFps = settings.framerate?.int32Value ?? 0
            let loadedOsc = settings.onscreenControls?.intValue ?? 0
            
            // Initialize self with loaded values first
            self.bitrate = loadedBitrate
            self.framerate = loadedFps
            self.height = loadedHeight
            self.width = loadedWidth
            self.onscreenControls = OnScreenControlsLevel(rawValue: loadedOsc) ?? OnScreenControlsLevel.off

            // 2. ONE-TIME MIGRATION CHECK (Resolution/Bitrate Defaults)
            let hasMigrated = UserDefaults.standard.bool(forKey: .hasMigratedToNewDefaults_v1)

            if !hasMigrated {
                let isOldDefaultBitrate = (loadedBitrate == 10000)
                let isOldDefaultRes = (loadedHeight == 720 || loadedHeight == 1080)
                let isOldDefaultOsc = (loadedOsc == 1) // 1 = Auto
                let isOldDefaultFps = (loadedFps == 60)

                if isOldDefaultBitrate && isOldDefaultRes && isOldDefaultOsc && isOldDefaultFps {
                    print("Detected fresh install or default settings. Applying new Vision defaults.")
                    
                    self.bitrate = 30000
                    self.height = 1440
                    self.width = 2560
                    self.onscreenControls = .off
                }
                
                UserDefaults.standard.set(true, forKey: .hasMigratedToNewDefaults_v1)
            }

            // Load remaining settings normally
            self.audioConfig = settings.audioConfig?.int32Value ?? 0
            self.preferredCodec = PreferredCodec(rawValue: Int(settings.preferredCodec)) ?? PreferredCodec.auto
            self.renderer = if let ren = settings.renderer?.uint8Value { Renderer(rawValue: UInt8(ren)) ?? .classic } else { .classic }
            self.uniqueId = settings.uniqueId ?? ""

            self.useFramePacing = settings.useFramePacing
            self.multiController = settings.multiController
            self.swapABXYButtons = settings.swapABXYButtons
            self.playAudioOnPC = settings.playAudioOnPC
            self.optimizeGames = settings.optimizeGames
            self.enableHdr = settings.enableHdr
            self.btMouseSupport = settings.btMouseSupport
            self.fpsMouseCapture = UserDefaults.standard.bool(forKey: .fpsMouseCapture)
            self.absoluteTouchMode = settings.absoluteTouchMode
            self.statsOverlay = settings.statsOverlay

            self.realitykitRendererAnimateOpening = settings.realitykitRendererAnimateOpening == 1
            self.realitykitRendererCurvature = settings.realitykitRendererCurvature?.floatValue ?? 0
            self.realitykitRendererTilt = UserDefaults.standard.object(forKey: .realitykitRendererTilt) as? Float ?? 0.0
            self.realitykitScreenCornerRadius = UserDefaults.standard.object(forKey: .realitykitScreenCornerRadius) as? Float ?? 0.018
            self.dimPassthrough = settings.dimPassthrough?.boolValue ?? false
            
            self.realitykitImmersiveMode = UserDefaults.standard.bool(forKey: .realitykitImmersiveMode)
            self.reactiveLightingEnabled = UserDefaults.standard.bool(forKey: .reactiveLightingEnabled)
            self.macVirtualDisplayExperimental = UserDefaults.standard.bool(forKey: .macVirtualDisplayExperimental)
            
            // --- HDR / COLOR LOADING ---
            self.brightness = settings.brightness?.floatValue ?? 1.0
            self.gamma = settings.gamma?.floatValue ?? 1.0
            self.saturation = settings.saturation?.floatValue ?? 1.0
            self.pqExposure = 1.0
            
            if let storedLang = UserDefaults.standard.object(forKey: .appLanguagePreference) as? Int {
                self.appLanguageRaw = storedLang
            } else {
                self.appLanguageRaw = AppLanguage.english.rawValue
            }
            self.autoResumeStreamOnReopen = UserDefaults.standard.bool(forKey: .autoResumeStreamOnReopen)
            self.rememberStreamSettings = UserDefaults.standard.object(forKey: .rememberStreamSettings) as? Bool ?? true
            self.uikitWindowCornerRadius = UserDefaults.standard.object(forKey: .uikitWindowCornerRadius) as? Float ?? 0.0
            self.spatialAudioMode = UserDefaults.standard.object(forKey: .spatialAudioMode) as? Int ?? SpatialAudioMode.window.rawValue
            self.preferUninterruptedAudio = UserDefaults.standard.object(forKey: .preferUninterruptedAudio) as? Bool ?? true
            #endif

            super.init()
            
            if !UserDefaults.standard.bool(forKey: .hasSavedNewDefaults_v1) {
                if self.bitrate != loadedBitrate || self.height != loadedHeight {
                    self.save()
                    UserDefaults.standard.set(true, forKey: .hasSavedNewDefaults_v1)
                }
            }
        }
    
    @objc public func save() {
        UserDefaults.standard.set(self.realitykitImmersiveMode, forKey: .realitykitImmersiveMode)
        UserDefaults.standard.set(self.reactiveLightingEnabled, forKey: .reactiveLightingEnabled)
        UserDefaults.standard.set(self.macVirtualDisplayExperimental, forKey: .macVirtualDisplayExperimental)
        UserDefaults.standard.set(self.autoResumeStreamOnReopen, forKey: .autoResumeStreamOnReopen)
        UserDefaults.standard.set(self.fpsMouseCapture, forKey: .fpsMouseCapture)
        UserDefaults.standard.set(self.rememberStreamSettings, forKey: .rememberStreamSettings)
        UserDefaults.standard.set(self.uikitWindowCornerRadius, forKey: .uikitWindowCornerRadius)
        UserDefaults.standard.set(self.realitykitScreenCornerRadius, forKey: .realitykitScreenCornerRadius)
        UserDefaults.standard.set(self.realitykitRendererTilt, forKey: .realitykitRendererTilt)
        UserDefaults.standard.set(self.spatialAudioMode, forKey: .spatialAudioMode)
        UserDefaults.standard.set(self.preferUninterruptedAudio, forKey: .preferUninterruptedAudio)

        // save settings to parent via DataManager
        let dataManager = DataManager()
        dataManager.saveSettings(
                withBitrate: Int(bitrate),
                framerate: Int(framerate),
                height: Int(height),
                width: Int(width),
                audioConfig: Int(audioConfig),
                onscreenControls: Int(onscreenControls.rawValue),
                optimizeGames: optimizeGames,
                multiController: multiController,
                swapABXYButtons: swapABXYButtons,
                audioOnPC: playAudioOnPC,
                preferredCodec: UInt32(preferredCodec.rawValue),
                renderer: renderer.rawValue,
                useFramePacing: useFramePacing,
                enableHdr: enableHdr,
                btMouseSupport: btMouseSupport,
                absoluteTouchMode: absoluteTouchMode,
                statsOverlay: statsOverlay,
                realitykitRendererAnimateOpening: realitykitRendererAnimateOpening,
                realitykitRendererCurvature: NSNumber(value: realitykitRendererCurvature),
                dimPassthrough: dimPassthrough,
                brightness: brightness,
                gamma: gamma,            // <--- Pass Gamma
                saturation: saturation   // <--- Pass Saturation
        )
        UserDefaults.standard.set(appLanguageRaw, forKey: .appLanguagePreference)
    }
    
    // Resets the display sliders and every saved screen placement and per-mode override.
    // With includingSystemSettings, also resets video, input, audio and app settings (language is kept).
    @objc public func resetToDefaults(includingSystemSettings: Bool) {
        if includingSystemSettings {
            // Video settings
            self.bitrate = 30000
            self.framerate = 60
            self.height = 1440
            self.width = 2560
            self.audioConfig = 0
            self.onscreenControls = OnScreenControlsLevel.off
            self.renderer = .classic

            // RealityKit settings
            self.realitykitRendererAnimateOpening = false
            self.realitykitImmersiveMode = false
            self.reactiveLightingEnabled = false
            self.macVirtualDisplayExperimental = false

            // Stream settings
            self.useFramePacing = false
            self.multiController = false
            self.swapABXYButtons = false
            self.playAudioOnPC = false
            self.optimizeGames = false
            self.enableHdr = false
            self.btMouseSupport = false
            self.fpsMouseCapture = false
            self.absoluteTouchMode = false
            self.statsOverlay = false
            self.dimPassthrough = true
            self.preferredCodec = PreferredCodec.auto
            self.uikitWindowCornerRadius = 0.0
            self.spatialAudioMode = SpatialAudioMode.window.rawValue
            self.preferUninterruptedAudio = true

            // App settings (keep language, reset others)
            self.autoResumeStreamOnReopen = false
            self.rememberStreamSettings = true
        }

        // HDR / Color settings - correct neutral values for HDR shader
        self.brightness = 1.0
        self.gamma = 1.0
        self.saturation = 1.0
        self.pqExposure = 1.0

        // RealityKit display settings
        self.realitykitRendererCurvature = 0.0
        self.realitykitRendererTilt = 0.0
        self.realitykitScreenCornerRadius = 0.018

        // Saved placement and per-mode overrides fall back to their defaults once removed
        let defaults = UserDefaults.standard
        for key in SettingsKey.immersiveTransform + SettingsKey.perModeDisplay {
            defaults.removeObject(forKey: key)
        }

        self.save()
    }
}

extension TemporarySettings {
    var appLanguage: AppLanguage {
        get {
            AppLanguage(rawValue: appLanguageRaw) ?? .english
        }
        set {
            appLanguageRaw = newValue.rawValue
        }
    }
}

@objc public enum PreferredCodec: Int {
    case auto
    case h264
    case hevc
    case av1
}

@objc public enum Renderer: UInt8, Codable, Sendable, AppEnum {
    
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
            TypeDisplayRepresentation(
                stringLiteral: "Renderer"
            )
        }
    
    public static var caseDisplayRepresentations: [Renderer : DisplayRepresentation] = [
        .classic: .init(stringLiteral: "UIKit (Classic)"),
        .realitykit: .init(stringLiteral: "RealityKit (Experimental)"),
    ]
    
    case classic
    case realitykit

    // Swift-only computed property for mapping cases to strings
    var windowId: String {
        switch self {
        case .classic: return "classicStreamingWindow"
        case .realitykit: return "realitykitStreamingWindow"
        }
    }
}
