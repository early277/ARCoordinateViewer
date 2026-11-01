import Foundation
import UIKit
import ImageIO
import CryptoKit

/// PNGタイルと縮小段階をディスクに保持。ARと平面図で共用する。
final class RasterTileStore: @unchecked Sendable {
    struct Level: Codable { var width: Int; var height: Int }
    struct Tile: Identifiable {
        var id: UUID
        var url: URL
        var corners: [GeoCoordinate]
        var sourceRect: CGRect
        var pixelWidth: Int
        var pixelHeight: Int
    }
    let directory: URL
    let levels: [Level]
    let corners: [GeoCoordinate]
    static let tileSize = 512
    private let ids: [[UUID]]
    init(directory: URL, levels: [Level], corners: [GeoCoordinate]) {
        self.directory = directory; self.levels = levels; self.corners = corners
        ids = levels.map { level in (0..<(((level.width + 511) / 512) * ((level.height + 511) / 512))).map { _ in UUID() } }
    }
    func tiles(level index: Int) -> [Tile] {
        guard levels.indices.contains(index) else { return [] }
        let level = levels[index], columns = (level.width + 511) / 512, rows = (level.height + 511) / 512
        func coordinate(_ x: Double, _ y: Double) -> GeoCoordinate {
            let a = corners[0], b = corners[1], d = corners[3]
            return GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * x + (d.latitude - a.latitude) * y,
                                 longitude: a.longitude + (b.longitude - a.longitude) * x + (d.longitude - a.longitude) * y)
        }
        return (0..<rows).flatMap { row in (0..<columns).map { col in
            let x = col * 512, y = row * 512, w = min(512, level.width - x), h = min(512, level.height - y)
            let x0 = Double(x) / Double(level.width), x1 = Double(x + w) / Double(level.width)
            let y0 = Double(y) / Double(level.height), y1 = Double(y + h) / Double(level.height)
            return Tile(id: ids[index][row * columns + col], url: directory.appendingPathComponent("\(index)-\(col)-\(row).png"),
                        corners: [coordinate(x0,y0), coordinate(x1,y0), coordinate(x1,y1), coordinate(x0,y1)], sourceRect: CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0), pixelWidth: w, pixelHeight: h)
        } }
    }
    func overview(maxDimension: Int = 2048) throws -> UIImage {
        let levelIndex = levels.firstIndex { max($0.width,$0.height) <= maxDimension } ?? levels.count-1
        let level = levels[levelIndex]
        guard let context=CGContext(data:nil,width:level.width,height:level.height,bitsPerComponent:8,bytesPerRow:level.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GeoTIFFError.imageDecodeFailed }
        for tile in tiles(level:levelIndex) {
            guard let source=CGImageSourceCreateWithURL(tile.url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw GeoTIFFError.imageDecodeFailed }
            let r=tile.sourceRect
            context.draw(image,in:CGRect(x:r.minX*Double(level.width),y:(1-r.maxY)*Double(level.height),width:Double(tile.pixelWidth),height:Double(tile.pixelHeight)))
        }
        guard let image=context.makeImage() else { throw GeoTIFFError.imageDecodeFailed }
        return UIImage(cgImage:image)
    }
    func preview(tile: Tile, image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let r = tile.sourceRect
        let rect = CGRect(x: r.minX * Double(cg.width), y: r.minY * Double(cg.height), width: r.width * Double(cg.width), height: r.height * Double(cg.height))
        return cg.cropping(to: rect.integral).map { UIImage(cgImage: $0) }
    }
    static func build(data: Data, source: CGImageSource, width: Int, height: Int, corners: [GeoCoordinate], progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> RasterTileStore {
        // この上限は解像度を落とさず、過大なデコードを明示的に拒否するためのもの。
        guard Int64(width) * Int64(height) <= 100_000_000 else {
            throw DXFParser.Failure(message: "画像が1億画素を超えています。GeoTIFFを複数の範囲に分けてください。")
        }
        let key = "v2-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RasterPyramids", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutableRoot = root; try? mutableRoot.setResourceValues(values)
        let final = root.appendingPathComponent(key, isDirectory: true)
        let manifest = final.appendingPathComponent("levels.json")
        if let bytes = try? Data(contentsOf: manifest), let levels = try? JSONDecoder().decode([Level].self, from: bytes) {
            return RasterTileStore(directory: final, levels: levels, corners: corners)
        }
        let temp = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var levels: [Level] = []
        var w = width, h = height
        repeat { levels.append(Level(width: w, height: h)); w = max(1, (w+1)/2); h = max(1, (h+1)/2) } while max(w,h) > 256
        let total = levels.reduce(0) { $0 + (($1.width+511)/512)*(($1.height+511)/512) }
        var completed = 0
        let raw = UncompressedTIFFPixels(data: data)
        func write(_ image: CGImage, to url: URL) throws {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw GeoTIFFError.imageDecodeFailed }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else { throw GeoTIFFError.imageDecodeFailed }
        }
        for (index, level) in levels.enumerated() {
            try autoreleasepool {
                if cancelled() { throw CancellationError() }
                let full: CGImage? = index == 0 && raw == nil ? CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary) : nil
                if index == 0 && raw == nil && full == nil { throw GeoTIFFError.imageDecodeFailed }
                for y in stride(from:0,to:level.height,by:512) { for x in stride(from:0,to:level.width,by:512) {
                    try autoreleasepool {
                        if cancelled() { throw CancellationError() }
                        let w=min(512,level.width-x),h=min(512,level.height-y)
                        let tile: CGImage
                        if index == 0 {
                            if let raw { tile = try raw.image(x:x,y:y,width:w,height:h) }
                            else if let cropped=full?.cropping(to:CGRect(x:x,y:y,width:w,height:h)) { tile=cropped }
                            else { throw GeoTIFFError.imageDecodeFailed }
                        } else {
                            guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GeoTIFFError.imageDecodeFailed }
                            context.interpolationQuality = .high
                            // 上位段階は直前のPNGタイル4枚から作り、元画像を再デコードしない。
                            context.translateBy(x:0,y:CGFloat(h)); context.scaleBy(x:1,y:-1)
                            let previous=levels[index-1]
                            for dy in 0..<2 { for dx in 0..<2 {
                                let column=x/256+dx,row=y/256+dy
                                guard column*512<previous.width,row*512<previous.height else { continue }
                                let childURL=temp.appendingPathComponent("\(index-1)-\(column)-\(row).png")
                                guard let childSource=CGImageSourceCreateWithURL(childURL as CFURL,nil),let child=CGImageSourceCreateImageAtIndex(childSource,0,nil) else { throw GeoTIFFError.imageDecodeFailed }
                                context.saveGState()
                                let childHeight=CGFloat(child.height)/2
                                context.translateBy(x:CGFloat(dx*256),y:CGFloat(dy*256)+childHeight);context.scaleBy(x:1,y:-1)
                                context.draw(child,in:CGRect(x:0,y:0,width:CGFloat(child.width)/2,height:childHeight))
                                context.restoreGState()
                            } }
                            guard let generated=context.makeImage() else { throw GeoTIFFError.imageDecodeFailed };tile=generated
                        }
                        try write(tile,to:temp.appendingPathComponent("\(index)-\(x/512)-\(y/512).png"))
                        completed += 1
                        if completed % 16 == 0 { progress(min(0.99,Double(completed)/Double(max(total,1)))) }
                    }
                } }
            }
        }
        try JSONEncoder().encode(levels).write(to: temp.appendingPathComponent("levels.json"), options: .atomic)
        if !FileManager.default.fileExists(atPath: final.path) { try FileManager.default.moveItem(at: temp, to: final) }
        progress(1)
        return RasterTileStore(directory: final, levels: levels, corners: corners)
    }
}

final class RasterTileImages: @unchecked Sendable {
    static let shared = RasterTileImages()
    private let cache = NSCache<NSURL, UIImage>()
    private let queue = DispatchQueue(label: "raster.tile.decode", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Set<URL> = []
    init() { cache.totalCostLimit = 64 * 1024 * 1024 }
    func image(_ url: URL, onReady: @escaping () -> Void) -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        lock.lock(); let inserted = pending.insert(url).inserted; lock.unlock()
        guard inserted else { return nil }
        queue.async {
            if let image = UIImage(contentsOfFile: url.path) {
                self.cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
            }
            self.lock.lock(); self.pending.remove(url); self.lock.unlock()
            DispatchQueue.main.async(execute: onReady)
        }
        return nil
    }
}

final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// 非圧縮8bit TIFFは必要な行だけ読む。巨大な1-strip TIFFでも画像全体をデコードしない。
private struct UncompressedTIFFPixels {
    let data: Data
    let width: Int
    let height: Int
    let samples: Int
    let photometric: Int
    let offsets: [Int]
    let rowsPerStrip: Int
    init?(data: Data) {
        guard data.count >= 8 else { return nil }
        let little = data[0] == 73 && data[1] == 73
        guard little || (data[0] == 77 && data[1] == 77) else { return nil }
        func number(_ offset: Int, _ bytes: Int) -> Int {
            guard offset >= 0, offset <= data.count-bytes else { return 0 }
            var value = 0
            for i in 0..<bytes { value |= Int(data[offset+i]) << ((little ? i : bytes-1-i)*8) }
            return value
        }
        guard number(2,2) == 42 else { return nil }
        let ifd = number(4,4)
        guard ifd >= 8, ifd <= data.count-2 else { return nil }
        let count = number(ifd,2)
        var tags: [Int:[Int]] = [:]
        for i in 0..<count {
            let p = ifd+2+i*12
            guard p <= data.count-12 else { return nil }
            let tag = number(p,2), type = number(p+2,2), n = number(p+4,4)
            guard [256,257,258,259,262,273,277,278,284,274].contains(tag), [3,4].contains(type), n < 1_000_000 else { continue }
            let bytes = type == 3 ? 2 : 4
            let offset = n*bytes <= 4 ? p+8 : number(p+8,4)
            guard offset >= 0, n*bytes <= data.count-offset else { return nil }
            tags[tag] = (0..<n).map { number(offset+$0*bytes,bytes) }
        }
        guard let w=tags[256]?.first, let h=tags[257]?.first, w>0,h>0,
              tags[259]?.first == 1, tags[258]?.allSatisfy({ $0 == 8 }) == true,
              (tags[284]?.first ?? 1) == 1, (tags[274]?.first ?? 1) == 1,
              let photo=tags[262]?.first, [0,1,2].contains(photo),
              let offsets=tags[273], !offsets.isEmpty else { return nil }
        let samples=tags[277]?.first ?? 1
        guard (photo == 2 && samples == 3) || (photo != 2 && samples == 1) else { return nil }
        self.data=data; width=w; height=h; self.samples=samples; photometric=photo; self.offsets=offsets
        rowsPerStrip=max(1,tags[278]?.first ?? h)
        guard offsets.count >= (h+rowsPerStrip-1)/rowsPerStrip else { return nil }
    }
    func image(x: Int,y: Int,width w: Int,height h: Int) throws -> CGImage {
        var bytes=Data(count:w*h*4)
        try bytes.withUnsafeMutableBytes { destination in
            try data.withUnsafeBytes { source in
                let src=source.bindMemory(to:UInt8.self), dst=destination.bindMemory(to:UInt8.self)
                for row in 0..<h {
                    let y0=y+row, strip=y0/rowsPerStrip
                    let start=offsets[strip]+((y0%rowsPerStrip)*width+x)*samples
                    guard start >= 0,start <= data.count-w*samples else { throw GeoTIFFError.imageDecodeFailed }
                    for col in 0..<w {
                        let a=start+col*samples,b=(row*w+col)*4
                        if samples==3 { dst[b]=src[a];dst[b+1]=src[a+1];dst[b+2]=src[a+2] }
                        else { let value=photometric==0 ? 255-src[a] : src[a];dst[b]=value;dst[b+1]=value;dst[b+2]=value }
                        dst[b+3]=255
                    }
                }
            }
        }
        guard let provider=CGDataProvider(data:bytes as CFData), let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw GeoTIFFError.imageDecodeFailed }
        return image
    }
}
