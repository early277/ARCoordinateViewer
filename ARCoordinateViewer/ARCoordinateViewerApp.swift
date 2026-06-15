import SwiftUI

@main
struct ARCoordinateViewerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(locationManager)
                .onAppear {
                    locationManager.onLocation = { location in
                        model.setOriginFromLocation(location)
                    }
                }
        }
    }
}
