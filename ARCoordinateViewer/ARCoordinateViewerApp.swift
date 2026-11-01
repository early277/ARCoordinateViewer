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
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    if DrawingUIFixture.active { await DrawingUIFixture.prepare(model); return }
                    #endif
                    #if DEBUG
                    if let root = ProcessInfo.processInfo.environment["AR_SURVEY_VALIDATION_ROOT"] {
                        let url = URL(fileURLWithPath: root)
                        model.importDXF(url: url.appendingPathComponent("Samples/Generated/survey_100mb.dxf"), options: DXFImportOptions())
                        while model.isImporting { try? await Task.sleep(for: .milliseconds(100)) }
                        if let point = try? JapanesePlaneRectangularSystem.toGeodetic(system: 9, x: -34500, y: -8500) { model.setOriginFromPoint(point) }
                        if let data = try? Data(contentsOf: url.appendingPathComponent("Samples/Generated/survey_image_108mb.tif"), options: .mappedIfSafe) {
                            model.importGeoTIFF(data: data, fileName: "検証用GeoTIFF", coordinateMode: .planeRectangular(system: 9))
                        }
                    }
                    #endif
                }
                .onAppear {
                    locationManager.onLocation = { location in
                        model.setOriginFromLocation(location)
                    }
                }
        }
    }
}
