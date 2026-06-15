import Foundation

final class KMLParser: NSObject, XMLParserDelegate {
    private var features: [GeoFeature] = []
    private var elementStack: [String] = []
    private var currentPlacemarkName: String = "Placemark"
    private var currentText: String = ""
    private var currentGeometry: GeometryKind?
    private var insidePlacemark = false

    static func parse(data: Data) throws -> [GeoFeature] {
        let delegate = KMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if parser.parse() {
            return delegate.features
        } else {
            throw parser.parserError ?? NSError(domain: "KMLParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "KMLを解析できませんでした。"])
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = elementName.lowercased()
        elementStack.append(name)
        currentText = ""

        switch name {
        case "placemark":
            insidePlacemark = true
            currentPlacemarkName = "Placemark"
            currentGeometry = nil
        case "point":
            if insidePlacemark { currentGeometry = .point }
        case "polygon":
            if insidePlacemark { currentGeometry = .polygon }
        case "linestring", "linearring":
            if insidePlacemark, currentGeometry != .polygon { currentGeometry = .line }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if insidePlacemark, name == "name", !text.isEmpty, !isInsideCoordinates() {
            currentPlacemarkName = text
        }

        if insidePlacemark, name == "coordinates", let kind = currentGeometry {
            let coordinates = parseCoordinates(text, featureName: currentPlacemarkName)
            if !coordinates.isEmpty {
                let actualKind: GeometryKind = coordinates.count == 1 ? .point : kind
                features.append(GeoFeature(name: currentPlacemarkName, kind: actualKind, coordinates: coordinates))
            }
        }

        if name == "placemark" {
            insidePlacemark = false
            currentGeometry = nil
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
        currentText = ""
    }

    private func isInsideCoordinates() -> Bool {
        elementStack.contains("coordinates")
    }

    private func parseCoordinates(_ text: String, featureName: String) -> [GeoCoordinate] {
        text
            .split { $0 == " " || $0 == "\n" || $0 == "\t" }
            .compactMap { tuple -> GeoCoordinate? in
                let parts = tuple.split(separator: ",").map(String.init)
                guard parts.count >= 2,
                      let lon = Double(parts[0]),
                      let lat = Double(parts[1]) else {
                    return nil
                }
                let alt = parts.count >= 3 ? Double(parts[2]) : nil
                return GeoCoordinate(name: featureName, latitude: lat, longitude: lon, altitude: alt)
            }
    }
}
