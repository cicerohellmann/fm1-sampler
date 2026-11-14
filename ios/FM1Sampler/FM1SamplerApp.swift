import SwiftUI

@main
struct FM1SamplerApp: App {
    @StateObject private var model = SamplerModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
