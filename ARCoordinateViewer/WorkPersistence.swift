import Foundation
import UIKit

struct SavedRaster: Codable {
    var name: String; var corners: [GeoCoordinate]
    var sourceWidth: Int; var sourceHeight: Int; var renderedWidth: Int; var renderedHeight: Int
    var notes: String; var imageFile: String; var tileDirectory: String?; var levels: [RasterTileStore.Level]?
}
struct SavedLayer: Codable {
    var documentID: UUID? = nil
    var dxfReference: DXFCoordinateReference? = nil
    var name: String; var features: [GeoFeature]; var points: [GeoCoordinate]
    var rasters: [SavedRaster]; var grids: [ElevationGrid]; var visible: Bool
}
struct SavedWork: Codable {
    var schema = 1
    var library: String? = nil
    var drawing: DrawingState
    var origin: GeoCoordinate?
    var planeSystem: Int
    var heading: Double; var east: Double; var north: Double; var height: Double; var committedHeight: Double
    var verticalDatum: Double? = nil
    var drawingLineWidth: Double? = nil
    var drawingPointReferenceWidth: Double? = nil
    var exportProfiles: [String:DrawingExportProfile]? = nil
    var exportDocument: String? = nil
    var drawingMetadataVersion: Int? = 1
    var photoMode:PhotoCaptureMode? = nil
    var useARPhotoPose:Bool? = nil
    var photoDocument:String? = nil
    var photoReferences:[String:PhotoReferenceSettings]? = nil
}
struct WorkPersistence {
    let root: URL
    var atomic: AtomicWorkStore { AtomicWorkStore(directory:root) }
    static var live: WorkPersistence {
        WorkPersistence(root: FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ARWork",isDirectory:true))
    }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN"); return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN"); return d
    }
    func collectUnusedLibraries() {
        let references = Set(atomic.candidates().compactMap { candidate -> String? in
            (try? Self.decoder().decode(SavedWork.self,from:candidate.payload))?.library
        })
        guard !references.isEmpty, let contents = try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) else { return }
        for directory in contents where UUID(uuidString:directory.lastPathComponent) != nil && !references.contains(directory.lastPathComponent) {
            try? FileManager.default.removeItem(at:directory)
        }
    }
    func saveLibrary(_ layers: [ImportedDataLayer]) throws -> String {
        let token = UUID().uuidString
        let directory = root.appendingPathComponent(token,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var packageFinished = false
        defer { if !packageFinished { try? FileManager.default.removeItem(at:directory) } }
        var saved: [SavedLayer] = []
        for layer in layers {
            var rasters: [SavedRaster] = []
            for raster in layer.rasters {
                let imageFile = UUID().uuidString+".png"
                guard let png = raster.image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to:directory.appendingPathComponent(imageFile),options:.atomic)
                var tileDirectory: String?
                if let tiles = raster.tileStore {
                    let name = UUID().uuidString
                    try FileManager.default.copyItem(at:tiles.directory,to:directory.appendingPathComponent(name))
                    tileDirectory = name
                }
                rasters.append(SavedRaster(name:raster.name,corners:raster.corners,sourceWidth:raster.sourcePixelWidth,sourceHeight:raster.sourcePixelHeight,renderedWidth:raster.renderedPixelWidth,renderedHeight:raster.renderedPixelHeight,notes:raster.notes,imageFile:imageFile,tileDirectory:tileDirectory,levels:raster.tileStore?.levels))
            }
            saved.append(SavedLayer(documentID:layer.documentID,dxfReference:layer.dxfReference,name:layer.name,features:layer.features,points:layer.points,rasters:rasters,grids:layer.elevationGrids,visible:layer.isVisible))
        }
        let payload = try Self.encoder().encode(saved)
        try payload.write(to:directory.appendingPathComponent("layers.json"),options:.atomic)
        try JSONEncoder().encode(AtomicWorkStore.checksum(payload)).write(to:directory.appendingPathComponent("checksum.json"),options:.atomic)
        packageFinished = true
        return token
    }
    func loadLibrary(_ token: String?) throws -> [ImportedDataLayer] {
        guard let token else { return [] }
        guard UUID(uuidString:token) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let directory = root.appendingPathComponent(token)
        let raw = try Data(contentsOf:directory.appendingPathComponent("layers.json"))
        let payload: Data
        if let checksum = try? JSONDecoder().decode(UInt64.self,from:Data(contentsOf:directory.appendingPathComponent("checksum.json"))) {
            guard AtomicWorkStore.checksum(raw) == checksum else { throw CocoaError(.fileReadCorruptFile) }
            payload = raw
        } else {
            let legacy = try JSONDecoder().decode(AtomicWorkStore.Envelope.self,from:raw)
            guard AtomicWorkStore.checksum(legacy.payload) == legacy.checksum else { throw CocoaError(.fileReadCorruptFile) }
            payload = legacy.payload
        }
        let saved = try Self.decoder().decode([SavedLayer].self,from:payload)
        return try saved.enumerated().map { index, layer in
            let rasters = try layer.rasters.map { r -> GeoRaster in
                guard !r.imageFile.contains("/"), r.imageFile.hasSuffix(".png"),
                      r.tileDirectory == nil || UUID(uuidString:r.tileDirectory!) != nil else { throw CocoaError(.fileReadCorruptFile) }
                guard let image = UIImage(contentsOfFile:directory.appendingPathComponent(r.imageFile).path) else { throw CocoaError(.fileReadCorruptFile) }
                let tiles: RasterTileStore?
                if let name = r.tileDirectory, let levels = r.levels {
                    let tilePath = directory.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath:tilePath.path) else { throw CocoaError(.fileReadNoSuchFile) }
                    for (index, level) in levels.enumerated() {
                        guard level.width > 0, level.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
                        for y in stride(from:0,to:level.height,by:512) { for x in stride(from:0,to:level.width,by:512) {
                            let file = tilePath.appendingPathComponent("\(index)-\(x/512)-\(y/512).png")
                            guard FileManager.default.fileExists(atPath:file.path) else { throw CocoaError(.fileReadNoSuchFile) }
                        } }
                    }
                    tiles = RasterTileStore(directory:tilePath,levels:levels,corners:r.corners)
                } else { tiles = nil }
                return GeoRaster(name:r.name,image:image,corners:r.corners,sourcePixelWidth:r.sourceWidth,sourcePixelHeight:r.sourceHeight,renderedPixelWidth:r.renderedWidth,renderedPixelHeight:r.renderedHeight,notes:r.notes,tileStore:tiles)
            }
            // Old immutable packages get a stable identity derived from their package
            // UUID and layer index. A later save writes this identity explicitly.
            var legacyID=UUID(uuidString:token)!.uuid
            withUnsafeMutableBytes(of:&legacyID) { bytes in
                for byte in 0..<8 { bytes[15-byte] ^= UInt8(truncatingIfNeeded:UInt64(index) >> (byte*8)) }
            }
            func recoverDXFZero(_ c:GeoCoordinate) -> GeoCoordinate {
                var c=c
                if layer.documentID == nil, layer.dxfReference != nil, c.dxfAltitude == nil { c.dxfAltitude=c.altitude ?? 0 }
                return c
            }
            let features=layer.features.map { f -> GeoFeature in var f=f; f.coordinates=f.coordinates.map(recoverDXFZero); return f }
            return ImportedDataLayer(name:layer.name,features:features,points:layer.points.map(recoverDXFZero),rasters:rasters,elevationGrids:layer.grids,isVisible:layer.visible,dxfReference:layer.dxfReference,documentID:layer.documentID ?? UUID(uuid:legacyID))
        }
    }
}

struct RestoredWork {
    var snapshot: SavedWork
    var layers: [ImportedDataLayer]
    var recovered: Bool
}

/// At most one running and one latest pending snapshot. Replacing a pending snapshot
/// retains its accumulated geometry, so rapid taps never create an unbounded queue.
/// Acknowledgement means the atomic write completed, never merely that it was queued.
final class WorkSaveQueue: @unchecked Sendable {
    private struct Request {
        var sequence: Int
        var snapshot: SavedWork
        var libraryRevision: Int
        var layers: [ImportedDataLayer]
        var completion: (Int, Result<Void, Error>) -> Void
    }
    private let store: WorkPersistence
    private let worker = DispatchQueue(label:"ARWork.persistence",qos:.userInitiated)
    private let lock = NSLock()
    private var pending: Request?
    private var draining = false
    // Accessed only on worker.
    private var libraryRevision = 0
    private var libraryToken: String?
    private let snapshotWriter: (Data) throws -> Void
    init(store: WorkPersistence, snapshotWriter: ((Data) throws -> Void)? = nil) {
        self.store = store
        self.snapshotWriter = snapshotWriter ?? { try store.atomic.save($0) }
    }
    func submit(sequence: Int, snapshot: SavedWork, libraryRevision: Int, layers: [ImportedDataLayer], completion: @escaping (Int, Result<Void, Error>) -> Void) {
        lock.lock()
        pending = Request(sequence:sequence,snapshot:snapshot,libraryRevision:libraryRevision,layers:layers,completion:completion)
        let start = !draining
        draining = true
        lock.unlock()
        if start { worker.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else { draining = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            let result: Result<Void, Error> = Result {
                if request.libraryRevision != libraryRevision {
                    libraryToken = try store.saveLibrary(request.layers)
                    libraryRevision = request.libraryRevision
                }
                var snapshot = request.snapshot
                snapshot.library = libraryToken
                try snapshotWriter(WorkPersistence.encoder().encode(snapshot))
                store.collectUnusedLibraries()
            }
            DispatchQueue.main.async { request.completion(request.sequence,result) }
        }
    }
    func restore(completion: @escaping (Result<RestoredWork?,Error>) -> Void) {
        worker.async {
            let candidates = self.store.atomic.candidates()
            let slotCount = (0...1).filter { FileManager.default.fileExists(atPath:self.store.root.appendingPathComponent("work-\($0).json").path) }.count
            var restored: RestoredWork?
            for (index, candidate) in candidates.enumerated() {
                guard let work = try? WorkPersistence.decoder().decode(SavedWork.self,from:candidate.payload), work.schema == 1,
                      let layers = try? self.store.loadLibrary(work.library) else { continue }
                restored = RestoredWork(snapshot:work,layers:layers,recovered:index > 0 || candidates.count < slotCount)
                self.libraryToken = work.library; self.libraryRevision = 0
                break
            }
            let result: Result<RestoredWork?,Error> = restored != nil || slotCount == 0
                ? .success(restored) : .failure(CocoaError(.fileReadCorruptFile))
            DispatchQueue.main.async { completion(result) }
        }
    }
    func whenIdle(_ completion: @escaping () -> Void) {
        worker.async { DispatchQueue.main.async(execute:completion) }
    }
}
