import Foundation
import Darwin
import ImageIO
import CoreVideo

/// Append-only transactions in a namespace independent of work, tree and GCP stores.
/// Each pending directory is retained on every failure, including process death.
final class ScanArchive:@unchecked Sendable {
    // Public operations serialize cache and filesystem transactions; CV buffers never enter this class.
    private let mutex=NSLock()
    struct FileEntry:Codable {var name:String;var bytes:Int;var checksum:UInt64}
    struct Commit:Codable {var schema=1;var packetID:UUID;var sequence:Int;var files:[FileEntry]}
    let root:URL
    let limits:ScanLimits
    let freeBytes:()->Int64
    private var cached:[UUID:ScanRecovery]=[:]
    let hook:((String)throws->Void)?
    init(root:URL,limits:ScanLimits=ScanLimits(),freeBytes:(()->Int64)?=nil,hook:((String)throws->Void)?=nil) {
        self.root=root;self.limits=limits;self.hook=hook
        self.freeBytes=freeBytes ?? {
            let path=root.path
            var stats=statfs();guard statfs(path,&stats)==0 else {return 0}
            return Int64(stats.f_bavail)*Int64(stats.f_bsize)
        }
    }
    static var suggestedRoot:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LiDARScanRecords",isDirectory:true)}
    private func safe(_ url:URL) throws {
        guard url.isFileURL,url.standardizedFileURL.path==url.resolvingSymlinksInPath().standardizedFileURL.path,
              !url.pathComponents.contains(where:{["ARWork","TreeSurvey","Documents","Archives"].contains($0)}) else {throw ScanFailure.foreignPath}
    }
    private func folder(_ id:UUID)->URL {root.appendingPathComponent(id.uuidString,isDirectory:true)}
    func discover() throws -> [UUID] {
        try safe(root);guard FileManager.default.fileExists(atPath:root.path) else {return []}
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).compactMap {UUID(uuidString:$0.lastPathComponent)}.sorted {$0.uuidString<$1.uuidString}
    }
    private func locked<T>(_ action:()throws->T) throws -> T {
        mutex.lock();defer {mutex.unlock()}
        try safe(root);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent(".capture.lock");try safe(url)
        let fd=open(url.path,O_CREAT|O_RDWR|O_NOFOLLOW,mode_t(0o600));guard fd>=0 else {throw ScanFailure.busy};defer {close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else {throw ScanFailure.busy};defer {flock(fd,LOCK_UN)}
        return try action()
    }
    private func decode(_ dir:URL) throws -> (ScanPacket,Int) {
        try safe(dir)
        let manifest=dir.appendingPathComponent("commit.json");try safe(manifest)
        guard let manifestSize=try manifest.resourceValues(forKeys:[.fileSizeKey]).fileSize,manifestSize>0,manifestSize<65536 else {throw ScanFailure.corrupt}
        let c=try JSONDecoder().decode(Commit.self,from:Data(contentsOf:manifest))
        guard c.schema==1,c.files.count>=1,c.files.count<=3,Set(c.files.map(\.name)).count==c.files.count,
              c.files.map(\.name).allSatisfy({["packet.json","image.jpg","image.nv12"].contains($0)}) else {throw ScanFailure.corrupt}
        var bytes=0,payload:Data?
        for f in c.files {
            guard f.bytes>0,f.bytes<=limits.maximumPacketBytes,bytes<=limits.maximumPacketBytes-f.bytes else {throw ScanFailure.corrupt}
            let path=dir.appendingPathComponent(f.name);try safe(path)
            guard (try path.resourceValues(forKeys:[.fileSizeKey])).fileSize==f.bytes else {throw ScanFailure.incomplete}
            let data=try Data(contentsOf:path);guard GCPStore.checksum(data)==f.checksum else {throw ScanFailure.corrupt}
            if f.name=="packet.json" {payload=data};bytes+=f.bytes
        }
        guard let payload else {throw ScanFailure.corrupt}
        let packet=try JSONDecoder().decode(ScanPacket.self,from:payload)
        guard packet.id==c.packetID,packet.sequence==c.sequence,(!c.files.contains(where:{$0.name=="image.jpg"}) || packet.hasImage),packet.hasImage==c.files.contains(where:{$0.name=="image.nv12"}),(!packet.hasImage || c.files.first(where:{$0.name=="image.nv12"})?.bytes==packet.frame?.imageInfo?.byteCount) else {throw ScanFailure.corrupt}
        try validate(packet)
        return (packet,bytes)
    }
    private func validate(_ p:ScanPacket) throws {
        guard p.schema==1,p.sessionID==p.raw.id,p.sequence>0,p.time.isFinite,p.segmentStart.isFinite,p.time>=p.segmentStart,
              p.epoch.generation>=0,p.epoch.alignmentRevision>=0,p.meshes.count<=limits.maximumAnchors*2,Set(p.meshes.map(\.anchorID)).count==p.meshes.count else {throw ScanFailure.corrupt}
        try GCPStore(root:root).validateRawForCapture(p.raw)
        if let map=p.depthMap {guard p.hasImage,let frame=p.frame else {throw ScanFailure.mixedFrame};try map.validate(frame)}
        if let corrections=p.corrections {try ScanCorrection.validate(corrections,raw:p.raw)}
        if let fit=p.proposedFit {try ScanCorrection.validateFit(fit,raw:p.raw)}
        guard p.terminalEvent==nil || p.terminalEvent == .ended || p.terminalEvent == .cancelled else {throw ScanFailure.corrupt}
        if let f=p.frame {try f.validate();guard f.time==p.time else {throw ScanFailure.mixedFrame}}
        guard !p.hasImage || (p.event == .capture && p.frame != nil && p.frame?.tracking == .normal) else {throw ScanFailure.mixedFrame}
        guard p.event != .capture || p.frame != nil else {throw ScanFailure.mixedFrame}
        guard p.event == .capture || (p.frame==nil && p.meshes.isEmpty && !p.hasImage) else {throw ScanFailure.corrupt}
        var vertices=0,indices=0
        if p.hasImage {
            guard let image=p.frame?.imageInfo,image.width==p.frame?.width,image.height==p.frame?.height,
                  image.width>0,image.height>0,image.width<=limits.maximumImageSide,image.height<=limits.maximumImageSide,image.width<=limits.maximumImagePixels/image.height,
                  [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(image.pixelFormat),
                  image.planeWidths==[image.width,(image.width+1)/2],image.planeHeights==[image.height,(image.height+1)/2],image.packedRowBytes==[image.width,((image.width+1)/2)*2],image.byteCount<=limits.maximumImageBytes else {throw ScanFailure.unsupportedImage}
        }
        for m in p.meshes {
            guard m.observedFrom>=p.segmentStart,m.observedFrom<=m.observedAt,m.observedAt==p.time,m.mesh?.anchorID==nil || m.mesh?.anchorID==m.anchorID else {throw ScanFailure.invalidGeometry}
            try m.mesh?.validate(limits);vertices += (m.mesh?.vertices.count ?? 0)/12;indices += (m.mesh?.indices.count ?? 0)/4
            guard vertices<=limits.maximumVertices,indices<=limits.maximumIndices else {throw ScanFailure.capacity}
        }
    }
    private func follows(_ p:ScanPacket,_ prior:ScanPacket?) -> Bool {
        guard let prior else {return p.sequence==1 && p.event == .began}
        let ended=prior.terminalEvent ?? ([ScanEvent.ended,.cancelled].contains(prior.event) ? prior.event:nil)
        let old=prior.corrections ?? ScanCorrection.empty(prior.sessionID),new=p.corrections ?? ScanCorrection.empty(p.sessionID)
        return p.sequence==prior.sequence+1 && p.sessionID==prior.sessionID
            && (ended==nil || (p.event == .correction && p.terminalEvent==ended && p.raw==prior.raw))
            && (prior.segmentID != p.segmentID || (prior.epoch==p.epoch && prior.segmentStart==p.segmentStart && prior.time<=p.time))
            && p.raw.observations.starts(with:prior.raw.observations) && p.raw.points.starts(with:prior.raw.points) && p.raw.trajectory.starts(with:prior.raw.trajectory)
            && new.journal.changes.starts(with:old.journal.changes) && new.scopes.starts(with:old.scopes)
    }
    private func inspectUnlocked(_ id:UUID,promote:Bool) throws -> ScanRecovery {
        let dir=folder(id);try safe(dir)
        guard FileManager.default.fileExists(atPath:dir.path) else {return ScanRecovery(sessionID:id)}
        let entries=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
        var values:[(URL,ScanPacket,Int)]=[],result=ScanRecovery(sessionID:id)
        for entry in entries {
            do {
                guard entry.lastPathComponent.hasSuffix(".scan") || entry.lastPathComponent.hasPrefix(".pending-") else {throw ScanFailure.foreignPath}
                let (p,n)=try decode(entry);guard p.sessionID==id else {throw ScanFailure.corrupt}
                if entry.lastPathComponent.hasPrefix(".pending-"),!promote {result.issues.append("保存途中: "+entry.lastPathComponent);continue}
                values.append((entry,p,n))
            } catch {result.issues.append(entry.lastPathComponent+": "+String(describing:error))}
        }
        values.sort {$0.1.sequence<$1.1.sequence}
        for (entry,p,n) in values {
            guard follows(p,result.last) else {result.issues.append("連続性不一致: "+entry.lastPathComponent);break}
            if entry.lastPathComponent.hasPrefix(".pending-") {
                let target=dir.appendingPathComponent(name(p))
                guard !FileManager.default.fileExists(atPath:target.path) else {result.issues.append("重複: "+entry.lastPathComponent);break}
                guard rename(entry.path,target.path)==0 else {throw POSIXError(.EIO)};try syncDirectory(dir)
            }
            result.last=p;result.packets+=1;result.images += p.hasImage ? 1:0;result.previewFailures += p.previewIssue==nil ? 0:1;result.normalWarnings+=p.meshes.filter {$0.mesh?.normalStatus != nil}.count;result.bytes+=n
        }
        return result
    }
    func recover(_ id:UUID,promoteCompletePending:Bool=false) throws -> ScanRecovery {try locked {try inspectUnlocked(id,promote:promoteCompletePending)}}
    private func name(_ p:ScanPacket)->String {String(format:"%08d",p.sequence)+"-"+p.id.uuidString+".scan"}
    func append(_ p:ScanPacket,jpeg:Data?,original:Data?=nil) throws -> Int {
        try locked {
            try validate(p);guard (jpeg==nil || p.hasImage),p.hasImage==(original != nil),original?.count==p.frame?.imageInfo?.byteCount,jpeg.map({!$0.isEmpty && $0.count<=limits.maximumImageBytes}) ?? true else {throw ScanFailure.unsupportedImage}
            let dir=folder(p.sessionID);try safe(dir)
            let final=dir.appendingPathComponent(name(p))
            if FileManager.default.fileExists(atPath:final.path) {
                let (saved,bytes)=try decode(final)
                guard saved==p else {throw ScanFailure.corrupt};try syncDirectory(dir);return bytes
            }
            var success=false
            defer {if !success {cached[p.sessionID]=nil}}
            var old=try cached[p.sessionID] ?? inspectUnlocked(p.sessionID,promote:true)
            if FileManager.default.fileExists(atPath:dir.path) {
                let count=try FileManager.default.contentsOfDirectory(atPath:dir.path).filter {$0.hasSuffix(".scan")}.count
                if count != old.packets {old=try inspectUnlocked(p.sessionID,promote:false)}
            }
            if FileManager.default.fileExists(atPath:final.path) {
                let (saved,bytes)=try decode(final);guard saved==p else {throw ScanFailure.corrupt};try syncDirectory(dir);cached[p.sessionID]=old;success=true;return bytes
            }
            guard old.packets>0 || p.event == .began else {throw ScanFailure.incomplete}
            // In-process retries may retain incomplete attempts; committed prefix is still authoritative.
            guard p.sequence==old.packets+1,old.issues.allSatisfy({$0.hasPrefix(".pending-")}) else {throw ScanFailure.incomplete}
            guard follows(p,old.last) else {throw GCPFailure.originalsImmutable}
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            if let jpeg {
                guard let source=CGImageSourceCreateWithData(jpeg as CFData,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                      (properties[kCGImagePropertyPixelWidth] as? Int)==p.frame?.width,(properties[kCGImagePropertyPixelHeight] as? Int)==p.frame?.height,
                      p.frame!.width<=limits.maximumImageSide,p.frame!.height<=limits.maximumImageSide,p.frame!.width<=limits.maximumImagePixels/p.frame!.height else {throw ScanFailure.unsupportedImage}
            }
            let data=try encoder.encode(p);let bytes=data.count+(jpeg?.count ?? 0)+(original?.count ?? 0)
            guard bytes<=limits.maximumPacketBytes,old.bytes<=limits.maximumSessionBytes-bytes,old.images+(p.hasImage ? 1:0)<=limits.maximumImages else {throw ScanFailure.capacity}
            guard freeBytes()>=Int64(limits.minimumFreeBytes+bytes*2) else {throw ScanFailure.lowSpace}
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);try syncDirectory(root)
            let pending=dir.appendingPathComponent(".pending-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:pending,withIntermediateDirectories:false);try syncDirectory(dir);try hook?("created-pending")
            var files=[FileEntry(name:"packet.json",bytes:data.count,checksum:GCPStore.checksum(data))]
            try write(data,to:pending.appendingPathComponent("packet.json"));try hook?("after-packet")
            if let jpeg {files.append(FileEntry(name:"image.jpg",bytes:jpeg.count,checksum:GCPStore.checksum(jpeg)));try write(jpeg,to:pending.appendingPathComponent("image.jpg"));try hook?("after-image")}
            if let original {files.append(FileEntry(name:"image.nv12",bytes:original.count,checksum:GCPStore.checksum(original)));try write(original,to:pending.appendingPathComponent("image.nv12"));try hook?("after-original")}
            try write(try encoder.encode(Commit(packetID:p.id,sequence:p.sequence,files:files)),to:pending.appendingPathComponent("commit.json"))
            try syncDirectory(pending);try hook?("before-publish")
            guard !FileManager.default.fileExists(atPath:final.path),rename(pending.path,final.path)==0 else {throw ScanFailure.corrupt}
            try hook?("after-publish");try syncDirectory(dir);try hook?("after-sync")
            old.last=p;old.packets+=1;old.images += p.hasImage ? 1:0;old.previewFailures += p.previewIssue==nil ? 0:1;old.normalWarnings+=p.meshes.filter {$0.mesh?.normalStatus != nil}.count;old.bytes+=bytes;cached[p.sessionID]=old;success=true;return bytes
        }
    }
    /// Streams only fully verified committed records. Any pending or damaged entry stops export.
    @discardableResult func visit(_ id:UUID,control:ScanExportControl?=nil,_ body:(ScanPacket,URL)throws->Void) throws -> ScanPacket {
        try locked {
            let dir=folder(id);try safe(dir)
            let entries=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).sorted {$0.lastPathComponent<$1.lastPathComponent}
            var last:ScanPacket?
            for (index,entry) in entries.enumerated() {
                try control?.check("原本を確認 \(index+1)/\(entries.count)",fraction:0.25*Double(index)/Double(max(1,entries.count)))
                guard entry.lastPathComponent.hasSuffix(".scan") else {throw ScanFailure.incomplete}
                let (p,_)=try decode(entry);guard p.sessionID==id,follows(p,last) else {throw ScanFailure.corrupt}
                try body(p,entry);last=p
            }
            guard let last else {throw ScanFailure.incomplete};return last
        }
    }
    /// Copies the validated committed prefix under a NEW record id. Source pending files are never promoted or edited here.
    func recoveryCopy(_ id:UUID) throws -> UUID {
        let source=try recover(id)
        guard source.packets>0 else {throw ScanFailure.incomplete}
        guard freeBytes()>=Int64(limits.minimumFreeBytes+source.bytes*2) else {throw ScanFailure.lowSpace}
        let copyID=UUID(),dir=folder(id)
        let entries=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter {$0.lastPathComponent.hasSuffix(".scan")}.sorted {$0.lastPathComponent<$1.lastPathComponent}
        let destination=ScanArchive(root:root,limits:limits,freeBytes:freeBytes)
        var copied=0
        for entry in entries {
            guard copied<source.packets else {break}
            var p=try locked {try decode(entry).0}
            let sourceID=p.id,packetURL=entry.appendingPathComponent("packet.json");try safe(packetURL)
            let checksum=GCPStore.checksum(try Data(contentsOf:packetURL))
            let imageURL=entry.appendingPathComponent("image.jpg"),originalURL=entry.appendingPathComponent("image.nv12")
            try safe(imageURL);try safe(originalURL)
            let jpeg=FileManager.default.fileExists(atPath:imageURL.path) ? try Data(contentsOf:imageURL):nil
            let original=p.hasImage ? try Data(contentsOf:originalURL):nil
            p.sessionID=copyID;p.raw.id=copyID;p.corrections?.journal.sessionID=copyID
            p.recoverySource=ScanRecoverySource(sessionID:id,packetID:sourceID,packetChecksum:checksum,retainedIssues:source.issues)
            _=try destination.append(p,jpeg:jpeg,original:original);copied+=1
        }
        guard copied==source.packets else {throw ScanFailure.incomplete};return copyID
    }
    private func write(_ data:Data,to url:URL) throws {
        let fd=open(url.path,O_CREAT|O_WRONLY|O_EXCL|O_NOFOLLOW,mode_t(0o600));guard fd>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)};defer {close(fd)}
        try data.withUnsafeBytes {buffer in
            var offset=0
            while offset<buffer.count {let n=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset);if n<0 && errno==EINTR {continue};guard n>0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)};offset+=n}
        }
        guard fsync(fd)==0 else {throw POSIXError(.EIO)}
        if fcntl(fd,F_FULLFSYNC)<0,errno != EINVAL,errno != ENOTSUP {throw POSIXError(.EIO)}
    }
    private func syncDirectory(_ url:URL) throws {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw POSIXError(.EIO)};defer {close(fd)}
        guard fsync(fd)==0 else {throw POSIXError(.EIO)}
    }
}
