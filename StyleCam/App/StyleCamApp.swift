import SwiftUI

@main
struct StyleCamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.camera)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
