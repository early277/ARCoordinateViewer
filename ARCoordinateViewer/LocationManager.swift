import Foundation
import CoreLocation
import UIKit

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?
    @Published var locationMessage: String = "位置情報未取得"
    @Published var compassHeadingDegrees: Double?
    @Published var compassAccuracyDegrees: Double = -1

    var onLocation: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 1
        authorizationStatus = manager.authorizationStatus
    }

    func setHeadingUpdatesActive(_ active: Bool) {
        guard CLLocationManager.headingAvailable() else {
            compassHeadingDegrees = nil
            compassAccuracyDegrees = -1
            return
        }

        if active {
            updateHeadingOrientation()
            manager.startUpdatingHeading()
        } else {
            manager.stopUpdatingHeading()
        }
    }

    private func updateHeadingOrientation() {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            manager.headingOrientation = .landscapeRight
        case .landscapeRight:
            manager.headingOrientation = .landscapeLeft
        case .portraitUpsideDown:
            manager.headingOrientation = .portraitUpsideDown
        default:
            manager.headingOrientation = .portrait
        }
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

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        Task { @MainActor in
            compassHeadingDegrees = heading
            compassAccuracyDegrees = accuracy
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationMessage = "位置情報取得エラー：\(error.localizedDescription)"
        }
    }
}
