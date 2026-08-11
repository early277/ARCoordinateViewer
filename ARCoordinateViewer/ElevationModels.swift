import Foundation

enum GeoTIFFImportPurpose: Hashable {
    case backgroundImage
    case elevationDEM

    var description: String {
        switch self {
        case .backgroundImage:
            return "背景画像"
        case .elevationDEM:
            return "標高DEM"
        }
    }
}

enum ElevationCoordinateReference: Hashable {
    case geographic
    case planeRectangular(system: Int)

    var description: String {
        switch self {
        case .geographic:
            return "緯度経度"
        case .planeRectangular(let system):
            return "平面直角\(system)系"
        }
    }
}

/// DEM配列の列・行番号を、標高値を持つ画素中心のモデル座標へ変換する。
///
/// modelX = originX + columnX * column + rowX * row
/// modelY = originY + columnY * column + rowY * row
struct ElevationGridTransform: Hashable {
    var originX: Double
    var originY: Double
    var columnX: Double
    var columnY: Double
    var rowX: Double
    var rowY: Double

    func modelCoordinate(column: Double, row: Double) -> (x: Double, y: Double) {
        (
            x: originX + columnX * column + rowX * row,
            y: originY + columnY * column + rowY * row
        )
    }

    func gridCoordinate(modelX: Double, modelY: Double) -> (column: Double, row: Double)? {
        let determinant = columnX * rowY - rowX * columnY
        guard determinant.isFinite, abs(determinant) > 1.0e-18 else { return nil }
        let dx = modelX - originX
        let dy = modelY - originY
        return (
            column: (dx * rowY - rowX * dy) / determinant,
            row: (columnX * dy - dx * columnY) / determinant
        )
    }
}

struct ElevationGrid: Identifiable {
    let id = UUID()
    var name: String
    var width: Int
    var height: Int
    /// 行優先。欠測値は `Float.nan`。
    var elevations: [Float]
    var transform: ElevationGridTransform
    var coordinateReference: ElevationCoordinateReference
    var minimumLatitude: Double
    var maximumLatitude: Double
    var minimumLongitude: Double
    var maximumLongitude: Double
    var estimatedCellSizeMeters: Double
    var sourceDescription: String

    var validValueCount: Int {
        elevations.reduce(into: 0) { count, value in
            if value.isFinite { count += 1 }
        }
    }

    var elevationRange: ClosedRange<Double>? {
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for value in elevations where value.isFinite {
            minimum = min(minimum, Double(value))
            maximum = max(maximum, Double(value))
        }
        guard minimum.isFinite, maximum.isFinite else { return nil }
        return minimum...maximum
    }

    func contains(_ coordinate: GeoCoordinate) -> Bool {
        switch coordinateReference {
        case .geographic:
            let latitudeMargin = max(1.0e-10, (maximumLatitude - minimumLatitude) * 1.0e-8)
            let longitudeMargin = max(1.0e-10, (maximumLongitude - minimumLongitude) * 1.0e-8)
            return coordinate.latitude >= minimumLatitude - latitudeMargin
                && coordinate.latitude <= maximumLatitude + latitudeMargin
                && coordinate.longitude >= minimumLongitude - longitudeMargin
                && coordinate.longitude <= maximumLongitude + longitudeMargin
        case .planeRectangular(let system):
            guard let plane = try? JapanesePlaneRectangularSystem.fromGeodetic(
                system: system,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ), let grid = transform.gridCoordinate(
                modelX: plane.y,
                modelY: plane.x
            ) else {
                return false
            }
            return grid.column >= -0.5
                && grid.row >= -0.5
                && grid.column <= Double(width) - 0.5
                && grid.row <= Double(height) - 0.5
        }
    }

    /// 4近傍の有効値を距離重み付きで補間する。
    /// 欠測が重なる場合だけ、周囲2セルまでの最近傍値へフォールバックする。
    func elevation(at coordinate: GeoCoordinate) -> Double? {
        guard width > 0,
              height > 0,
              elevations.count == width * height else { return nil }

        let modelCoordinate: (x: Double, y: Double)
        switch coordinateReference {
        case .geographic:
            guard contains(coordinate) else { return nil }
            modelCoordinate = (coordinate.longitude, coordinate.latitude)
        case .planeRectangular(let system):
            guard let plane = try? JapanesePlaneRectangularSystem.fromGeodetic(
                system: system,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ) else { return nil }
            modelCoordinate = (plane.y, plane.x)
        }

        guard let grid = transform.gridCoordinate(
            modelX: modelCoordinate.x,
            modelY: modelCoordinate.y
        ) else { return nil }

        // 画素中心から半セル外側までをDEMの有効範囲として扱う。
        guard grid.column >= -0.5,
              grid.row >= -0.5,
              grid.column <= Double(width) - 0.5,
              grid.row <= Double(height) - 0.5 else { return nil }

        let column = min(Double(width - 1), max(0, grid.column))
        let row = min(Double(height - 1), max(0, grid.row))
        let column0 = Int(floor(column))
        let row0 = Int(floor(row))
        let column1 = min(width - 1, column0 + 1)
        let row1 = min(height - 1, row0 + 1)
        let fractionX = column - Double(column0)
        let fractionY = row - Double(row0)

        let candidates: [(column: Int, row: Int, weight: Double)] = [
            (column0, row0, (1 - fractionX) * (1 - fractionY)),
            (column1, row0, fractionX * (1 - fractionY)),
            (column0, row1, (1 - fractionX) * fractionY),
            (column1, row1, fractionX * fractionY)
        ]

        var weightedValue = 0.0
        var weightTotal = 0.0
        for candidate in candidates {
            guard candidate.weight > 0,
                  let value = validElevation(column: candidate.column, row: candidate.row) else { continue }
            weightedValue += value * candidate.weight
            weightTotal += candidate.weight
        }
        if weightTotal > 0 {
            return weightedValue / weightTotal
        }

        let centerColumn = Int(column.rounded())
        let centerRow = Int(row.rounded())
        for radius in 1...2 {
            var nearest: (distance: Int, value: Double)?
            for y in max(0, centerRow - radius)...min(height - 1, centerRow + radius) {
                for x in max(0, centerColumn - radius)...min(width - 1, centerColumn + radius) {
                    guard let value = validElevation(column: x, row: y) else { continue }
                    let distance = abs(x - centerColumn) + abs(y - centerRow)
                    if nearest == nil || distance < nearest!.distance {
                        nearest = (distance, value)
                    }
                }
            }
            if let nearest { return nearest.value }
        }
        return nil
    }

    private func validElevation(column: Int, row: Int) -> Double? {
        guard column >= 0, column < width, row >= 0, row < height else { return nil }
        let value = elevations[row * width + column]
        guard value.isFinite else { return nil }
        return Double(value)
    }
}
