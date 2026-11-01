import Foundation

final class KMLParser: NSObject, XMLParserDelegate {
    private struct Style {
        var line: SourceColor?
        var point: SourceColor?
        var polygon: SourceColor?
        func merging(_ other: Style) -> Style {
            Style(line: other.line ?? line, point: other.point ?? point, polygon: other.polygon ?? polygon)
        }
    }
    private struct Placemark {
        var name = "Placemark"
        var reference = ""
        var inline = Style()
        var features: [GeoFeature] = []
    }
    private var stack: [String] = []
    private var text = ""
    private var placemark: Placemark?
    private var placemarks: [Placemark] = []
    private var styles: [String: Style] = [:]
    private var maps: [String: String] = [:]
    private var style: Style?
    private var styleID: String?
    private var mapID: String?
    private var pairKey = ""
    private var pairReference = ""

    static func parse(data: Data) throws -> [GeoFeature] {
        let delegate = KMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "KMLParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "KMLを解析できませんでした。"])
        }
        func resolve(_ reference: String, visited: Set<String> = []) -> Style {
            // Only same-document references: imported files never trigger network access.
            guard reference.hasPrefix("#"), !visited.contains(reference), visited.count < 32 else { return Style() }
            let id = String(reference.dropFirst())
            if let style = delegate.styles[id] { return style }
            if let next = delegate.maps[id] { return resolve(next, visited: visited.union([reference])) }
            return Style()
        }
        return delegate.placemarks.flatMap { mark in
            let style = resolve(mark.reference).merging(mark.inline)
            return mark.features.map { feature in
                var result = feature
                result.name = mark.name
                result.coordinates = feature.coordinates.map { c in var c = c; c.name = mark.name; return c }
                switch feature.kind {
                case .point: result.sourceColor = style.point
                case .line: result.sourceColor = style.line
                case .polygon: result.sourceColor = style.line ?? style.polygon
                }
                return result
            }
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        stack.append(name); text = ""
        switch name {
        case "placemark": placemark = Placemark()
        case "style": style = Style(); styleID = attributes["id"]
        case "stylemap": mapID = attributes["id"]
        case "pair": pairKey = ""; pairReference = ""
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased(), value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.dropLast().last
        switch name {
        case "name" where parent == "placemark": placemark?.name = value
        case "styleurl":
            if parent == "pair" { pairReference = value }
            else if parent == "placemark" { placemark?.reference = value }
        case "key" where parent == "pair": pairKey = value
        case "pair": if pairKey == "normal", let id = mapID { maps[id] = pairReference }
        case "stylemap": mapID = nil
        case "color":
            if let color = SourceColor.kml(value) {
                switch parent {
                case "linestyle": style?.line = color
                case "iconstyle": style?.point = color
                case "polystyle": style?.polygon = color
                default: break
                }
            }
        case "style":
            if let style {
                if let mark = placemark { placemark?.inline = mark.inline.merging(style) }
                else if let id = styleID { styles[id] = style }
            }
            style = nil; styleID = nil
        case "coordinates":
            guard let mark = placemark else { break }
            let kind: GeometryKind = stack.contains("polygon") ? .polygon : (stack.contains("point") ? .point : .line)
            let coordinates = value.split(whereSeparator: { $0.isWhitespace }).compactMap { tuple -> GeoCoordinate? in
                let parts = tuple.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]), lon.isFinite, lat.isFinite else { return nil }
                return GeoCoordinate(name: mark.name, latitude: lat, longitude: lon, altitude: parts.count > 2 ? Double(parts[2]) : nil)
            }
            if !coordinates.isEmpty { placemark?.features.append(GeoFeature(name: mark.name, kind: coordinates.count == 1 ? .point : kind, coordinates: coordinates)) }
        case "placemark":
            if let placemark { placemarks.append(placemark) }
            placemark = nil
        default: break
        }
        if !stack.isEmpty { stack.removeLast() }; text = ""
    }
}
