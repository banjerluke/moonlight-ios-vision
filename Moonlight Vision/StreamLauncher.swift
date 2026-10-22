//
//  StreamLauncher.swift
//  Moonlight Vision
//
//  The one launch path for streaming an app, shared by the app list and the App Intent.
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

/// Starts streaming an app: replaces whatever is streaming, begins the session and opens the
/// window or immersive space for the chosen renderer.
@MainActor
struct StreamLauncher {
    let viewModel: MainViewModel
    let openWindow: OpenWindowAction
    let dismissWindow: DismissWindowAction
    let openImmersiveSpace: OpenImmersiveSpaceAction
    let dismissImmersiveSpace: DismissImmersiveSpaceAction

    /// Returns once the stream's window or space has been asked to open, or the launch was skipped.
    func launch(_ app: TemporaryApp) async {
        // A launch replaces the current stream, if any: stop it and detach it. There's no need to
        // wait here, because the new session's first connection waits for the old one to stop.
        if viewModel.streamState != .idle {
            viewModel.forceResetStreamLifecycleIfNeeded()
        }

        guard let config = viewModel.stream(app: app) else {
            return
        }

        // Dismiss existing stream windows before opening new one
        dismissWindow(id: "realitykitStreamingWindow")
        dismissWindow(id: "classicStreamingWindow")

        switch viewModel.getStreamDestination() {
        case .immersiveSpace(let id):
            dismissWindow(id: "mainView")
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await openImmersiveSpace(id: id, value: config)
        case .window(let id):
            await dismissImmersiveSpace()
            try? await Task.sleep(nanoseconds: 150_000_000)
            openWindow(id: id, value: config)
            try? await Task.sleep(nanoseconds: 150_000_000)
            dismissWindow(id: "mainView")
        }
    }
}
