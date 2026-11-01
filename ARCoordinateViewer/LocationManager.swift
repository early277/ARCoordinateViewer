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
    @Published private(set) var photoLocation:DeviceLocationObservation?
    @Published private(set) var photoHeading:DeviceHeadingObservation?
    private var wantsPhotoLocationUpdates=false
    private var pendingOriginLocationRequest=false

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
            pendingOriginLocationRequest=true
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
            setPhotoLocationUpdatesActive(wantsPhotoLocationUpdates)
        }
    }

    /// Uses an existing grant only. Photo geotag updates must never move the AR
    /// origin; only the explicit "iPhoneの現在位置を使う" request does that.
    func setPhotoLocationUpdatesActive(_ active:Bool) {
        wantsPhotoLocationUpdates=active
        if active && (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways) {
            manager.startUpdatingLocation()
        } else { manager.stopUpdatingLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            lastLocation = location
            photoLocation=DeviceLocationObservation(timestamp:location.timestamp,latitude:location.coordinate.latitude,longitude:location.coordinate.longitude,altitudeMeanSeaLevel:location.verticalAccuracy>=0 && location.altitude.isFinite ? location.altitude : nil,ellipsoidalAltitude:location.verticalAccuracy>=0 && location.ellipsoidalAltitude.isFinite ? location.ellipsoidalAltitude : nil,horizontalAccuracy:location.horizontalAccuracy,verticalAccuracy:location.verticalAccuracy,simulatedBySoftware:location.sourceInformation?.isSimulatedBySoftware ?? false,producedByAccessory:location.sourceInformation?.isProducedByAccessory ?? false)
            locationMessage = location.horizontalAccuracy>=0 ? "水平精度：約\(Int(location.horizontalAccuracy))m" : "位置精度は未取得"
            if pendingOriginLocationRequest { pendingOriginLocationRequest=false;onLocation?(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        Task { @MainActor in
            compassHeadingDegrees = heading
            compassAccuracyDegrees = accuracy
            photoHeading=DeviceHeadingObservation(timestamp:newHeading.timestamp,trueHeading:newHeading.trueHeading>=0 ? newHeading.trueHeading : nil,magneticHeading:newHeading.magneticHeading>=0 ? newHeading.magneticHeading : nil,accuracyDegrees:accuracy,magneticFieldDeviceXYZ:[newHeading.x,newHeading.y,newHeading.z])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            pendingOriginLocationRequest=false
            locationMessage = "位置情報取得エラー：\(error.localizedDescription)"
        }
    }
}
