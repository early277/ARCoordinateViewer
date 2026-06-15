import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?
    @Published var locationMessage: String = "位置情報未取得"

    var onLocation: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = manager.authorizationStatus
    }

    func requestAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    func requestCurrentLocationOnce() {
        requestAuthorizationIfNeeded()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationMessage = "現在地取得中…"
            manager.requestLocation()
        case .notDetermined:
            locationMessage = "位置情報の許可待ち"
        case .denied, .restricted:
            locationMessage = "位置情報が許可されていません。設定を確認してください。"
        @unknown default:
            locationMessage = "位置情報の状態を確認できません。"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            lastLocation = location
            locationMessage = "水平精度：約\(Int(location.horizontalAccuracy))m"
            onLocation?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationMessage = "位置情報取得エラー：\(error.localizedDescription)"
        }
    }
}
