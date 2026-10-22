//
//  ObservableConnectionManager.swift
//  Moonlight Vision
//
//  Created by tht7 on 29/12/2024.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import Combine
@MainActor
@objc class ObservableConnectionManager: NSObject, ObservableObject, StreamSessionEvents {
    
    // Published properties for SwiftUI to observe
    @Published var connectionStatus: Int32 = 0
    @Published var currentStage: String = ""
    @Published var errorMessage: String?
    @Published var isHDRModeEnabled: Bool = false
    @Published var videoShown: Bool = false
    @Published var showAlert = false

    nonisolated func connectionStarted() {
        print("Connection started")
    }
    
    nonisolated func stageStarting(_ stageName: UnsafePointer<CChar>!) {
        let stage = stageName.map { String(cString: $0) } ?? ""
        print("Stage starting: \(stage)")
        Task { @MainActor in self.currentStage = stage }
    }
    
    nonisolated func stageComplete(_ stageName: UnsafePointer<CChar>!) {
        let stage = stageName.map { String(cString: $0) } ?? ""
        print("Stage complete: \(stage)")
        Task { @MainActor in self.currentStage = stage }
    }
    
    nonisolated func connectionStatusUpdate(_ status: Int32) {
        print("Connection status updated to: \(status)")
        Task { @MainActor in self.connectionStatus = status }
    }
    
    nonisolated func setHdrMode(_ enabled: Bool) {
        print("HDR Mode set to: \(enabled)")
        Task { @MainActor in self.isHDRModeEnabled = enabled }
    }
    
    nonisolated func setMotionEventState(_ controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        print("Set motion event state: Controller \(controllerNumber), Motion type \(motionType), Report rate \(reportRateHz) Hz")
    }
    
    nonisolated func setControllerLed(_ controllerNumber: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        print("Set LED for controller \(controllerNumber): R \(r), G \(g), B \(b)")
    }
    
    nonisolated func videoContentShown() {
        print("Video content shown")
        Task { @MainActor in
            // DrawableVideoDecoder may call this on every IDR frame in error-recovery
            // paths; only publish the first one per connection.
            guard !self.videoShown else { return }
            self.videoShown = true
            self.showAlert = false
        }
    }
}
