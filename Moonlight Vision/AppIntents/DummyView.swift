//
//  DummyView.swift
//  Moonlight Vision
//
//  Created by tht7 on 06/02/2025.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  DumyView.swift
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct DummyView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismiss) private var dismiss
    
    @EnvironmentObject private var viewModel: MainViewModel
    
    var body: some View {
        ProgressView()
            .onContinueUserActivity("dummy") { _ in
                guard let app = viewModel.pendingIntentApp else {
                    print("DummyView - no pending App Intent launch")
                    dismiss()
                    return
                }
                viewModel.pendingIntentApp = nil
                print("DUMMY GOT EVENT \(app.name)")
                
                let launcher = StreamLauncher(
                    viewModel: viewModel,
                    openWindow: openWindow,
                    dismissWindow: dismissWindow,
                    openImmersiveSpace: openImmersiveSpace,
                    dismissImmersiveSpace: dismissImmersiveSpace
                )
                Task {
                    await launcher.launch(app)
                    dismiss()
                }
            }
    }
}
