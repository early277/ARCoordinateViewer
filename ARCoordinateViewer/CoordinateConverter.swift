import Foundation
import simd

enum CoordinateError: LocalizedError {
    case invalidPlaneSystem
    case invalidNumber

    var errorDescription: String? {
        switch self {
        case .invalidPlaneSystem:
            return "平面直角座標系は1〜19を指定してください。"
        case .invalidNumber:
            return "数値を確認してください。"
        }
    }
}

enum CoordinateConverter {
    static let a = 6378137.0
    static let f = 1.0 / 298.257222101
    static var e2: Double { f * (2.0 - f) }

    static func localARPosition(
        from coord: GeoCoordinate,
        origin: GeoCoordinate,
        headingOffsetDegrees: Double,
        verticalOffsetMeters: Double
    ) -> SIMD3<Float> {
        let enu = enuMeters(from: coord, origin: origin)

        // verticalOffsetMeters は、通常は0。標高差表示ON時は基準高度との差分を入れる。
        let east = enu.east
        let north = enu.north

        let angle = headingOffsetDegrees * .pi / 180.0
        let cosA = cos(angle)
        let sinA = sin(angle)

        let rotatedEast = east * cosA - north * sinA
        let rotatedNorth = east * sinA + north * cosA

        return SIMD3<Float>(Float(rotatedEast), Float(verticalOffsetMeters), Float(-rotatedNorth))
    }

    static func enuMeters(from coord: GeoCoordinate, origin: GeoCoordinate) -> (east: Double, north: Double, up: Double) {
        let target = geodeticToECEF(latitude: coord.latitude, longitude: coord.longitude, altitude: coord.altitude ?? 0)
        let base = geodeticToECEF(latitude: origin.latitude, longitude: origin.longitude, altitude: origin.altitude ?? 0)

        let dx = target.x - base.x
        let dy = target.y - base.y
        let dz = target.z - base.z

        let lat = origin.latitude * .pi / 180.0
        let lon = origin.longitude * .pi / 180.0
        let sinLat = sin(lat)
        let cosLat = cos(lat)
        let sinLon = sin(lon)
        let cosLon = cos(lon)

        let east = -sinLon * dx + cosLon * dy
        let north = -sinLat * cosLon * dx - sinLat * sinLon * dy + cosLat * dz
        let up = cosLat * cosLon * dx + cosLat * sinLon * dy + sinLat * dz
        return (east, north, up)
    }

    static func coordinate(fromEast east: Double, north: Double, origin: GeoCoordinate, name: String? = nil) -> GeoCoordinate {
        let lat0 = origin.latitude * .pi / 180.0
        let lon0 = origin.longitude * .pi / 180.0
        let sinLat = sin(lat0)
        let n = a / sqrt(1.0 - e2 * sinLat * sinLat)
        let m = a * (1.0 - e2) / pow(1.0 - e2 * sinLat * sinLat, 1.5)
        let dLat = north / m
        let dLon = east / (n * cos(lat0))
        return GeoCoordinate(
            name: name,
            latitude: (lat0 + dLat) * 180.0 / .pi,
            longitude: (lon0 + dLon) * 180.0 / .pi,
            altitude: nil
        )
    }

    static func geodeticToECEF(latitude: Double, longitude: Double, altitude: Double) -> (x: Double, y: Double, z: Double) {
        let lat = latitude * .pi / 180.0
        let lon = longitude * .pi / 180.0
        let sinLat = sin(lat)
        let cosLat = cos(lat)
        let sinLon = sin(lon)
        let cosLon = cos(lon)
        let n = a / sqrt(1.0 - e2 * sinLat * sinLat)
        let x = (n + altitude) * cosLat * cosLon
        let y = (n + altitude) * cosLat * sinLon
        let z = (n * (1.0 - e2) + altitude) * sinLat
        return (x, y, z)
    }
}

enum JapanesePlaneRectangularSystem {
    static let scaleFactor = 0.9999
    static let a = 6378137.0
    static let f = 1.0 / 298.257222101
    static var e2: Double { f * (2.0 - f) }
    static var ep2: Double { e2 / (1.0 - e2) }

    // 平成14年国土交通省告示第9号の原点。緯度・経度は度単位。
    static let origins: [Int: (lat: Double, lon: Double)] = [
        1: (33.0, 129.5),
        2: (33.0, 131.0),
        3: (36.0, 132.16666666666666),
        4: (33.0, 133.5),
        5: (36.0, 134.33333333333334),
        6: (36.0, 136.0),
        7: (36.0, 137.16666666666666),
        8: (36.0, 138.5),
        9: (36.0, 139.83333333333334),
        10: (40.0, 140.83333333333334),
        11: (44.0, 140.25),
        12: (44.0, 142.25),
        13: (44.0, 144.25),
        14: (26.0, 142.0),
        15: (26.0, 127.5),
        16: (26.0, 124.0),
        17: (26.0, 131.0),
        18: (20.0, 136.0),
        19: (26.0, 154.0)
    ]

    static func toGeodetic(system: Int, x: Double, y: Double) throws -> GeoCoordinate {
        guard let origin = origins[system] else { throw CoordinateError.invalidPlaneSystem }
        let lat0 = origin.lat * .pi / 180.0
        let lon0 = origin.lon * .pi / 180.0
        let m0 = meridionalArc(lat0)

        let m1 = m0 + x / scaleFactor
        let mu = m1 / (a * (1.0 - e2 / 4.0 - 3.0 * pow(e2, 2) / 64.0 - 5.0 * pow(e2, 3) / 256.0))
        let e1 = (1.0 - sqrt(1.0 - e2)) / (1.0 + sqrt(1.0 - e2))

        let fp = mu
            + (3.0 * e1 / 2.0 - 27.0 * pow(e1, 3) / 32.0) * sin(2.0 * mu)
            + (21.0 * pow(e1, 2) / 16.0 - 55.0 * pow(e1, 4) / 32.0) * sin(4.0 * mu)
            + (151.0 * pow(e1, 3) / 96.0) * sin(6.0 * mu)
            + (1097.0 * pow(e1, 4) / 512.0) * sin(8.0 * mu)

        let sinFp = sin(fp)
        let cosFp = cos(fp)
        let tanFp = tan(fp)
        let c1 = ep2 * cosFp * cosFp
        let t1 = tanFp * tanFp
        let n1 = a / sqrt(1.0 - e2 * sinFp * sinFp)
        let r1 = a * (1.0 - e2) / pow(1.0 - e2 * sinFp * sinFp, 1.5)
        let d = y / (n1 * scaleFactor)

        let lat = fp - (n1 * tanFp / r1) * (
            pow(d, 2) / 2.0
            - (5.0 + 3.0 * t1 + 10.0 * c1 - 4.0 * pow(c1, 2) - 9.0 * ep2) * pow(d, 4) / 24.0
            + (61.0 + 90.0 * t1 + 298.0 * c1 + 45.0 * pow(t1, 2) - 252.0 * ep2 - 3.0 * pow(c1, 2)) * pow(d, 6) / 720.0
        )

        let lon = lon0 + (
            d
            - (1.0 + 2.0 * t1 + c1) * pow(d, 3) / 6.0
            + (5.0 - 2.0 * c1 + 28.0 * t1 - 3.0 * pow(c1, 2) + 8.0 * ep2 + 24.0 * pow(t1, 2)) * pow(d, 5) / 120.0
        ) / cosFp

        return GeoCoordinate(name: nil, latitude: lat * 180.0 / .pi, longitude: lon * 180.0 / .pi, altitude: nil)
    }

    static func meridionalArc(_ lat: Double) -> Double {
        let e4 = e2 * e2
        let e6 = e4 * e2
        return a * (
            (1.0 - e2 / 4.0 - 3.0 * e4 / 64.0 - 5.0 * e6 / 256.0) * lat
            - (3.0 * e2 / 8.0 + 3.0 * e4 / 32.0 + 45.0 * e6 / 1024.0) * sin(2.0 * lat)
            + (15.0 * e4 / 256.0 + 45.0 * e6 / 1024.0) * sin(4.0 * lat)
            - (35.0 * e6 / 3072.0) * sin(6.0 * lat)
        )
    }
}
