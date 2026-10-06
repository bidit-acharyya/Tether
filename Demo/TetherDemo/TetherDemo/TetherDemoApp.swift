// Tether demo: one shared task list that syncs between iPhone and Mac with no server.

import SwiftUI

@main
struct TetherDemoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
