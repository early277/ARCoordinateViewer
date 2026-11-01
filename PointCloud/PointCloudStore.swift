import Foundation
import CryptoKit
import simd
import Darwin

struct PCFrameEntry:Codable,Identifiable {
    var id:UUID {frame.id}
    var frame:PCFrame
    var sequence:Int
    var pointCount:Int
    var hashes:[String:String]
}
struct PCRecord:Identifiable {
    var id:UUID
    var frames:[PCFrameEntry]
    var checkpoint:PCCheckpoint?
    var selection:PCSelection?
    var warnings:[String]
    var control:PCControlState? = nil
    var captureStateReadable=true
    /// Transient derived view only; never written over original inputs.
    var posePrepared=false
    var poseTransforms:[UUID:PCPosePulseTransform]=[:]
}
/// Single writer. Inputs are immutable until explicit record deletion.
/// A committed pending directory is readable after interruption; incomplete files
/// remain available for diagnosis and are never treated as captured points.
final class PCStore: @unchecked Sendable {
    let root:URL
    let freeBytes:()->Int64
    let maximumBytes:Int64=PCLimits.maximumRecordBytes
    let minimumFree:Int64=256*1024*1024
    let hook:(String)throws->Void
    /// Only this writer's successfully committed prefix is cached. A directory
    /// mutation (including journal writes, interrupted appends or another writer)
    /// invalidates it. Full public loads still validate the on-disk record.
    private struct DirectoryStamp:Equatable {
        var device:Int64;var inode:UInt64
        var modified:Int64;var modifiedNS:Int64;var changed:Int64;var changedNS:Int64
    }
    private struct AppendState {var id:UUID;var record:PCRecord;var bytes:Int64;var entries:Int;var stamp:DirectoryStamp}
    private var appendState:AppendState?
    private func directoryStamp(_ id:UUID)throws->DirectoryStamp {
        try safe(directory(id));var value=stat()
        guard lstat(directory(id).path,&value)==0,(value.st_mode & mode_t(S_IFMT))==mode_t(S_IFDIR) else {throw PCFailure.corrupt}
        return DirectoryStamp(device:Int64(value.st_dev),inode:UInt64(value.st_ino),modified:Int64(value.st_mtimespec.tv_sec),modifiedNS:Int64(value.st_mtimespec.tv_nsec),changed:Int64(value.st_ctimespec.tv_sec),changedNS:Int64(value.st_ctimespec.tv_nsec))
    }
    init(root:URL,freeBytes:(()->Int64)?=nil,hook:@escaping(String)throws->Void={_ in}) {
        self.hook=hook
        self.root=root
        self.freeBytes=freeBytes ?? {Self.availableBytes(near:root)}
    }
    /// A fresh installation need not have Library/Application Support yet.
    /// Query the volume of the nearest existing ancestor without creating any
    /// directories; a missing storage parent is not a full disk. A failed query
    /// on an existing path remains fail-closed, and callers retain their limits.
    private static func availableBytes(near directory:URL)->Int64 {
        let manager=FileManager.default
        var existing=directory.standardizedFileURL
        while !manager.fileExists(atPath:existing.path) {
            let parent=existing.deletingLastPathComponent()
            guard parent.path != existing.path else {return 0}
            existing=parent
        }
        return ((try? manager.attributesOfFileSystem(forPath:existing.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
    }
    static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func safe(_ url:URL)throws {
        var u=url
        while u.path.hasPrefix(root.path),u.path != root.deletingLastPathComponent().path {
            if let v=try? u.resourceValues(forKeys:[.isSymbolicLinkKey]),v.isSymbolicLink==true {throw PCFailure.corrupt}
            if u==root {break};u.deleteLastPathComponent()
        }
    }
    func directory(_ id:UUID)->URL {root.appendingPathComponent(id.uuidString,isDirectory:true)}
    func create()throws->UUID {
        guard freeBytes()>minimumFree else {throw PCFailure.storageSpace}
        try safe(root);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let id=UUID(),url=directory(id);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        try write(Data("PointCloudRecord/1\n".utf8),to:url.appendingPathComponent("format.txt"));return id
    }
    private func write(_ data:Data,to url:URL)throws {
        try safe(url);guard !FileManager.default.fileExists(atPath:url.path) else {throw PCFailure.corrupt}
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else {throw PCFailure.capacity}
        let f=try FileHandle(forWritingTo:url);defer{try? f.close()};try f.write(contentsOf:data);try f.synchronize()
    }
    /// Complete an interrupted uncommitted write only if every existing byte is
    /// an exact prefix of the retained input. No existing byte is replaced.
    private func completePending(_ data:Data,to url:URL)throws {
        try safe(url)
        guard FileManager.default.fileExists(atPath:url.path) else {try write(data,to:url);return}
        let existing=try read(url,limit:PCLimits.maximumEventBytes)
        guard data.starts(with:existing) else {throw PCFailure.corrupt}
        guard existing.count<data.count else {return}
        let file=try FileHandle(forWritingTo:url);defer{try? file.close()}
        try file.seekToEnd();try file.write(contentsOf:data.dropFirst(existing.count));try file.synchronize()
    }
    private func read(_ url:URL,limit:Int)throws->Data {
        try safe(url);let n=(try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]))
        guard n.isRegularFile==true,let size=n.fileSize,size<=limit else {throw PCFailure.corrupt}
        return try Data(contentsOf:url)
    }
    func append(_ raw:PCRawFrame,to id:UUID)throws->(PCFrameEntry,[PCVertex]) {
        let stamp=try directoryStamp(id)
        let current:PCRecord,used:Int64,entries:Int
        if let cached=appendState,cached.id==id,cached.stamp==stamp {current=cached.record;used=cached.bytes;entries=cached.entries}
        else {
            current=try load(id,verify:false);used=try storageBytes(id)
            entries=try FileManager.default.contentsOfDirectory(at:directory(id),includingPropertiesForKeys:nil).count
        }
        // An uncertain write never leaves a trusted cached prefix behind.
        appendState=nil
        guard current.captureStateReadable,current.checkpoint?.stopped != true,
              !current.frames.contains(where:{$0.id==raw.frame.id}),
              current.frames.last.map({$0.frame.time<raw.frame.time && $0.frame.epoch==raw.frame.epoch}) ?? true else {throw PCFailure.invalidInput}
        guard current.frames.count<PCLimits.maximumFrames else {throw PCFailure.recordLimit}
        let points=try PCProjection.vertices(raw)
        guard current.frames.reduce(0,{$0+$1.pointCount})+points.count<=PCLimits.maximumPoints else {throw PCFailure.recordLimit}
        var data=Data();data.reserveCapacity(points.count*15);for p in points {p.append(to:&data)}
        let incoming=raw.image.count+raw.depth.count+raw.confidence.count+data.count+65536
        guard used+Int64(incoming)<maximumBytes else {throw PCFailure.recordLimit}
        guard freeBytes()>minimumFree+Int64(incoming) else {throw PCFailure.storageSpace}
        let blobs=["image.nv12":raw.image,"depth.f32":raw.depth,"confidence.u8":raw.confidence,"points.xyzrgb":data]
        let entry=PCFrameEntry(frame:raw.frame,sequence:current.frames.count,pointCount:points.count,hashes:blobs.mapValues(Self.digest))
        let pending=directory(id).appendingPathComponent("pending-"+raw.frame.id.uuidString,isDirectory:true)
        let alreadyPending=FileManager.default.fileExists(atPath:pending.path)
        guard entries+(alreadyPending ? 0:1)<=PCLimits.maximumRecordEntries else {throw PCFailure.recordLimit}
        if !alreadyPending {try FileManager.default.createDirectory(at:pending,withIntermediateDirectories:false)}
        for name in blobs.keys.sorted() {try completePending(blobs[name]!,to:pending.appendingPathComponent(name))}
        try hook("before-commit")
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let metadata=try encoder.encode(entry),envelope=try encoder.encode(PCEvent(data:metadata,hash:Self.digest(metadata)))
        try completePending(envelope,to:pending.appendingPathComponent("commit.json"))
        try hook("after-commit")
        try FileManager.default.moveItem(at:pending,to:directory(id).appendingPathComponent("frame-"+raw.frame.id.uuidString))
        var committed=current;committed.frames.append(entry)
        let bytes=try alreadyPending ? storageBytes(id):(used+Int64(blobs.values.reduce(0){$0+$1.count}+envelope.count))
        appendState=AppendState(id:id,record:committed,bytes:bytes,entries:entries+(alreadyPending ? 0:1),stamp:try directoryStamp(id))
        return (entry,points)
    }
    func checkpoint(_ checkpoint:PCCheckpoint,id:UUID)throws {
        // Older apps must not silently interpret new temporal/rotational
        // corrections as their legacy translation-only corrected selection.
        var checkpoint=checkpoint
        if checkpoint.imuInput != nil || checkpoint.poseEvents?.contains(where:{$0.imuEvidence != nil})==true || checkpoint.motionDecisions?.contains(where:{$0.imuEvidence != nil})==true {checkpoint.schema=4}
        else if (checkpoint.motionDecisionCount ?? 0)>0 || checkpoint.motionDecisions?.isEmpty==false || checkpoint.poseEvents?.contains(where:{$0.policy.motionFallback==true})==true {checkpoint.schema=3}
        else if checkpoint.poseEvents?.isEmpty==false {checkpoint.schema=2}
        guard [1,2,3,4].contains(checkpoint.schema),checkpoint.imuInput?.valid ?? true else {throw PCFailure.corrupt}
        guard freeBytes()>1_048_576 else {throw PCFailure.storageSpace}
        let data=try JSONEncoder().encode(checkpoint);guard data.count<PCLimits.maximumCheckpointBytes else {throw PCFailure.recordLimit}
        try event(data,prefix:"checkpoint",id:id)
    }
    /// A single immutable checkpoint commits continuation and invalidates all
    /// older derived selections atomically. Old snapshots/files remain readable.
    func resume(_ checkpoint:PCCheckpoint,id:UUID,expectedFrames:[UUID])throws->PCRecord {
        var checkpoint=checkpoint
        if checkpoint.imuInput != nil || checkpoint.poseEvents?.contains(where:{$0.imuEvidence != nil})==true || checkpoint.motionDecisions?.contains(where:{$0.imuEvidence != nil})==true {checkpoint.schema=4}
        else if (checkpoint.motionDecisionCount ?? 0)>0 || checkpoint.motionDecisions?.isEmpty==false || checkpoint.poseEvents?.contains(where:{$0.policy.motionFallback==true})==true {checkpoint.schema=3}
        else if checkpoint.poseEvents?.isEmpty==false {checkpoint.schema=2}
        let current=try load(id)
        guard let token=checkpoint.continuationID,!checkpoint.stopped,
              current.frames.map(\.id)==expectedFrames,let old=current.checkpoint,
              checkpoint.raw.id==old.raw.id,checkpoint.raw.observations.starts(with:old.raw.observations),
              checkpoint.raw.points.starts(with:old.raw.points),checkpoint.raw.trajectory.starts(with:old.raw.trajectory),
              (checkpoint.raw.captureOperations ?? []).starts(with:old.raw.captureOperations ?? []),
              (checkpoint.raw.captureCancellations ?? []).starts(with:old.raw.captureCancellations ?? []),
              (checkpoint.poseEvents ?? []).starts(with:old.poseEvents ?? []),
              (checkpoint.motionDecisions ?? []).starts(with:old.motionDecisions ?? []),
              (checkpoint.motionDecisionCount ?? 0)>=(old.motionDecisionCount ?? 0),
              checkpoint.imuInput?.valid ?? true else {throw PCFailure.invalidInput}
        if old.continuationID==token {
            // A completed rollback must not be mistaken for an active continuation.
            guard current.captureStateReadable,!old.stopped,old==checkpoint else {throw PCFailure.invalidInput}
            return current
        }
        guard old.stopped,current.captureStateReadable else {throw PCFailure.invalidInput}
        guard freeBytes()>minimumFree+Int64(try JSONEncoder().encode(checkpoint).count*2) else {throw PCFailure.storageSpace}
        try hook("before-resume-checkpoint")
        try self.checkpoint(checkpoint,id:id)
        try hook("after-resume-checkpoint")
        return try load(id)
    }
    func select(_ selection:PCSelection,id:UUID)throws {
        var value=selection;value.continuationID=try load(id,verify:false).checkpoint?.continuationID
        try event(try JSONEncoder().encode(value),prefix:"selection",id:id)
    }
    func saveControl(_ proposed:PCControlState,id:UUID)throws {
        let record=try load(id)
        var state=proposed;state.continuationID=record.checkpoint?.continuationID
        guard state.schema==1,state.proposal.targets.count<=5000,state.proposal.bindings.count<=128,
              (state.proposal.samePointGroups?.count ?? 0)<=128,
              (state.proposal.samePointGroups ?? []).reduce(0,{$0+$1.memberIDs.count})<=128 else {throw PCControlFailure.invalid}
        try state.proposal.validatedSamePointGroups(record:record)
        if let solution=state.solution {
            guard try PCControlMath.fit(record:record,proposal:state.proposal)==solution else {throw PCControlFailure.stale}
            if state.applied {guard solution.canApply(qualityOverride:state.qualityOverride==true),(state.proposal.usesFrames || state.proposal.driftCorrected==(record.selection?.corrected ?? false)) else {throw PCControlFailure.stale}}
        } else if state.applied {throw PCControlFailure.notApplied}
        let data=try JSONEncoder().encode(state)
        let used=try storageBytes(id)
        guard data.count<4*1024*1024,used+Int64(data.count*2)<maximumBytes else {throw PCFailure.recordLimit}
        guard freeBytes()>minimumFree+Int64(data.count*2) else {throw PCFailure.storageSpace}
        try event(data,prefix:"control",id:id)
    }
    private func event(_ data:Data,prefix:String,id:UUID)throws {
        appendState=nil
        let dir=directory(id);try safe(dir)
        let entries=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
        guard entries.count<PCLimits.maximumRecordEntries else {throw PCFailure.recordLimit} // Keep every committed record readable under the loader's cap.
        let sequences=try entries.filter{$0.lastPathComponent.hasPrefix(prefix+"-")}.map {url -> Int in
            guard let n=Self.eventSequence(url.lastPathComponent,prefix:prefix),n<Int.max else {throw PCFailure.corrupt};return n
        }
        let next=(sequences.max() ?? -1)+1
        let name=String(format:"%@-%06ld-%@.json",prefix,next,UUID().uuidString)
        let envelope=PCEvent(data:data,hash:Self.digest(data))
        let encoded=try JSONEncoder().encode(envelope)
        // Base64/envelope bytes must fit before creating any final event file.
        guard encoded.count<PCLimits.maximumEventBytes else {throw PCFailure.recordLimit}
        guard freeBytes()>Int64(encoded.count)+1_048_576 else {throw PCFailure.storageSpace}
        let pending=dir.appendingPathComponent(name+".writing"),destination=dir.appendingPathComponent(name)
        try safe(pending);try safe(destination)
        guard !FileManager.default.fileExists(atPath:pending.path),!FileManager.default.fileExists(atPath:destination.path) else {throw PCFailure.corrupt}
        guard FileManager.default.createFile(atPath:pending.path,contents:nil) else {throw PCFailure.capacity}
        // Persist the intent as well as the payload: an interrupted undo cannot
        // silently disappear and reactivate an older correction.
        try syncDirectory(dir);try hook("event-created")
        let file=try FileHandle(forWritingTo:pending);defer{try? file.close()}
        try file.write(contentsOf:encoded);try file.synchronize();try hook("event-after-sync")
        try FileManager.default.moveItem(at:pending,to:destination)
        try hook("event-after-rename");try syncDirectory(dir);try hook("event-after-directory-sync")
    }
    private func syncDirectory(_ directory:URL)throws {
        let fd=open(directory.path,O_RDONLY);guard fd>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer{close(fd)};guard fsync(fd)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    }
    private static func eventBase(_ name:String)->String {name.hasSuffix(".writing") ? String(name.dropLast(8)):name}
    private static func eventSequence(_ name:String,prefix:String)->Int? {
        let base=eventBase(name)
        guard base.hasPrefix(prefix+"-"),base.hasSuffix(".json") else {return nil}
        let parts=base.dropFirst(prefix.count+1).split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
        guard parts.count==2,!parts[0].isEmpty,parts[0].utf8.allSatisfy({(48...57).contains($0)}),parts[1].count>5 else {return nil}
        return Int(parts[0])
    }
    private static func eventOrder(_ url:URL)->(String,Int,String,Int) {
        let name=url.lastPathComponent,base=eventBase(name)
        if let prefix=["checkpoint","selection","control"].first(where:{name.hasPrefix($0+"-")}) {
            return (prefix,eventSequence(name,prefix:prefix) ?? Int.max,base,name.hasSuffix(".writing") ? 0:1)
        }
        return (name,0,name,0)
    }
    private func eventData(_ url:URL,prefix:String,limit:Int,siblings:[URL])throws->Data {
        guard let sequence=Self.eventSequence(url.lastPathComponent,prefix:prefix) else {throw PCFailure.corrupt}
        let logicalNames=Set(siblings.filter{Self.eventSequence($0.lastPathComponent,prefix:prefix)==sequence}.map{Self.eventBase($0.lastPathComponent)})
        guard logicalNames.count==1 else {throw PCFailure.corrupt} // Same sequence, different operation: order is unknown.
        let data=try read(url,limit:limit),base=Self.eventBase(url.lastPathComponent)
        let other=url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.hasSuffix(".writing") ? base:base+".writing")
        if FileManager.default.fileExists(atPath:other.path) {
            guard try read(other,limit:limit)==data else {throw PCFailure.corrupt}
        }
        return data
    }
    private struct PCEvent:Codable {var data:Data;var hash:String}
    func load(_ id:UUID,verify:Bool=true,work:PCWorkControl?=nil)throws->PCRecord {
        appendState=nil;try work?.check()
        let dir=directory(id);try safe(dir)
        guard try read(dir.appendingPathComponent("format.txt"),limit:128)==Data("PointCloudRecord/1\n".utf8) else {throw PCFailure.corrupt}
        let urls=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).sorted{Self.eventOrder($0)<Self.eventOrder($1)}
        guard urls.count<=PCLimits.maximumRecordEntries else {throw PCFailure.recordLimit}
        var frames:[PCFrameEntry]=[],warnings:[String]=[],checkpoint:PCCheckpoint?,selection:PCSelection?,control:PCControlState?,controlSeen=false,checkpointSeen=false,selectionSeen=false,captureStateReadable=true
        for url in urls.reversed() {
            try work?.check()
            let name=url.lastPathComponent
            if name.hasPrefix("frame-") || name.hasPrefix("pending-") {
                guard let bytes=try? read(url.appendingPathComponent("commit.json"),limit:65536),let envelope=try? JSONDecoder().decode(PCEvent.self,from:bytes),Self.digest(envelope.data)==envelope.hash,let entry=try? JSONDecoder().decode(PCFrameEntry.self,from:envelope.data) else {warnings.append("未完了入力: "+name);continue}
                try entry.frame.validate()
                guard name.hasSuffix(entry.id.uuidString),entry.pointCount>=0,entry.pointCount<=512*512,Set(entry.hashes.keys)==Set(["image.nv12","depth.f32","confidence.u8","points.xyzrgb"]) else {throw PCFailure.corrupt}
                if verify {
                    let expected=["image.nv12":entry.frame.intrinsics.width*entry.frame.intrinsics.height*3/2,"depth.f32":entry.frame.depthWidth*entry.frame.depthHeight*4,"confidence.u8":entry.frame.depthWidth*entry.frame.depthHeight,"points.xyzrgb":entry.pointCount*15]
                    for (name,hash) in entry.hashes {try work?.check();let data=try read(url.appendingPathComponent(name),limit:8*1024*1024);guard data.count==expected[name],Self.digest(data)==hash else {throw PCFailure.corrupt}}
                }
                if name.hasPrefix("pending-") {warnings.append("保存中断から読み取り復旧: "+name)}
                frames.append(entry)
            } else if name.hasPrefix("control-"),!controlSeen {
                // A damaged newest control event must not reactivate an older
                // transform after an attempted undo. Fall back to local display.
                controlSeen=true
                do {
                    let e=try JSONDecoder().decode(PCEvent.self,from:eventData(url,prefix:"control",limit:8*1024*1024,siblings:urls))
                    guard Self.digest(e.data)==e.hash else {throw PCFailure.corrupt}
                    let value=try JSONDecoder().decode(PCControlState.self,from:e.data)
                    guard value.schema==1,value.proposal.targets.count<=5000,value.proposal.bindings.count<=128,
                          (value.proposal.samePointGroups?.count ?? 0)<=128,
                          (value.proposal.samePointGroups ?? []).reduce(0,{$0+$1.memberIDs.count})<=128 else {throw PCFailure.corrupt}
                    control=value
                    if name.hasSuffix(".writing") {warnings.append("座標対応を保存途中ファイルから読み取り復旧: "+name)}
                } catch {warnings.append("座標対応の保存が未完了。変換を適用せず原データを表示します")}
            } else if (name.hasPrefix("checkpoint-") && !checkpointSeen) || (name.hasPrefix("selection-") && !selectionSeen) {
                if name.hasPrefix("checkpoint-") {checkpointSeen=true} else {selectionSeen=true}
                // Never resurrect an older corrected selection after an incomplete undo.
                do {
                    let prefix=name.hasPrefix("checkpoint-") ? "checkpoint":"selection"
                    let event=try JSONDecoder().decode(PCEvent.self,from:eventData(url,prefix:prefix,limit:PCLimits.maximumEventBytes,siblings:urls))
                    guard Self.digest(event.data)==event.hash else {throw PCFailure.corrupt}
                    if name.hasPrefix("checkpoint-") {let c=try JSONDecoder().decode(PCCheckpoint.self,from:event.data);guard [1,2,3,4].contains(c.schema) else {throw PCFailure.corrupt};checkpoint=c}
                    else {selection=try JSONDecoder().decode(PCSelection.self,from:event.data)}
                    if name.hasSuffix(".writing") {warnings.append("状態を保存途中ファイルから読み取り復旧: "+name)}
                } catch {
                    if name.hasPrefix("checkpoint-") {captureStateReadable=false}
                    warnings.append("未完了の状態保存: "+name)
                }
            }
        }
        frames.sort{$0.sequence<$1.sequence}
        guard frames.count<=PCLimits.maximumFrames,Set(frames.map(\.id)).count==frames.count,frames.enumerated().allSatisfy({$0.offset==$0.element.sequence}),frames.reduce(0,{$0+$1.pointCount})<=PCLimits.maximumPoints else {throw PCFailure.corrupt}
        for pair in zip(frames,frames.dropFirst()) {guard pair.0.frame.time<pair.1.frame.time,pair.0.frame.epoch==pair.1.frame.epoch else {throw PCFailure.foreignEpoch}}
        if !captureStateReadable || selection?.continuationID != checkpoint?.continuationID {selection=nil}
        if !captureStateReadable || control?.continuationID != checkpoint?.continuationID {
            control?.applied=false;control?.solution=nil // Keep correspondence draft/snapshots; require recalculation.
        }
        if checkpoint?.stopped != true {warnings.append("中断記録。保存確定済みの入力のみ表示します")}
        var result=PCRecord(id:id,frames:frames,checkpoint:checkpoint,selection:selection,warnings:warnings,control:control,captureStateReadable:captureStateReadable)
        if captureStateReadable,checkpoint != nil,let proposal=control?.proposal,proposal.hasSamePointGroups {
            do {try proposal.validatedSamePointGroups(record:result)}
            catch {result.control=nil;result.warnings.append("同一点の対応を確認できません。補正を適用せず原データを表示します")}
        }
        if result.checkpoint?.imuInput != nil || result.checkpoint?.poseEvents?.isEmpty==false || result.checkpoint?.motionDecisionCount != nil || result.checkpoint?.motionDecisions != nil {
            do {
                _=try PCPoseCorrection.schedule(result)
                if result.selection?.corrected==true || result.control?.applied==true {
                    let derived=try PCPoseCorrection.prepare(result)
                    _=try PCCorrection.checkedSelection(derived)
                    if result.control?.applied==true {_=try PCControlMath.active(derived)}
                }
            } catch {
                // Read-only rescue. Never rewrite the original journal or
                // resurrect an older applied selection after a failed undo.
                result.selection=nil;result.control?.applied=false;result.control?.solution=nil
                result.warnings.append("推定急変の補正を確認できないため未適用。原入力を表示・出力できます")
            }
        }
        try work?.check();return result
    }
    func points(_ entry:PCFrameEntry,id:UUID)throws->[PCVertex] {
        let dir=directory(id),regular=dir.appendingPathComponent("frame-"+entry.id.uuidString)
        let path=FileManager.default.fileExists(atPath:regular.path) ? regular:dir.appendingPathComponent("pending-"+entry.id.uuidString)
        let data=try read(path.appendingPathComponent("points.xyzrgb"),limit:4*1024*1024)
        guard Self.digest(data)==entry.hashes["points.xyzrgb"],data.count==entry.pointCount*15 else {throw PCFailure.corrupt}
        return try PCVertex.decode(data)
    }
    func list()throws->[UUID] {
        guard FileManager.default.fileExists(atPath:root.path) else {return []};try safe(root)
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).compactMap{UUID(uuidString:$0.lastPathComponent)}.sorted{$0.uuidString<$1.uuidString}
    }
}

struct PCSavedRecord:Identifiable {
    enum State {case saved,interrupted,unreadable,deletionPending}
    var id:UUID
    var date:Date?
    var pointCount:Int
    var gcpCount:Int
    var state:State
    var status:String
    var thumbnailKey:String?
    /// Logical bytes of this complete record subtree, including raw inputs and journals.
    /// Nil means the entire size could not be verified; never a partial total.
    var storedBytes:Int64? = nil
}
/// A bounded model thumbnail, not a camera image. Coordinates are normalized
/// for a 2D canvas; source points/RGB are never modified. Missing cache is benign.
struct PCThumbnail:Codable {
    struct Dot:Codable {var x:Float;var y:Float;var r:UInt8;var g:UInt8;var b:UInt8}
    var key:String
    var dots:[Dot]
    var valid:Bool {dots.count<=2048 && dots.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.x>=0 && $0.x<=1 && $0.y>=0 && $0.y<=1}}
}

enum PCDeletionFailure:Error,LocalizedError {
    case unsafePath,conflict,tooLarge
    var errorDescription:String? {
        switch self {
        case .unsafePath:return "削除対象の保存場所を安全に確認できません。残っている内容は保持しています"
        case .conflict:return "同じ記録IDに削除途中と元記録の両方があります。安全のため削除を保留しました"
        case .tooLarge:return "記録内のファイル数または階層が確認範囲を超えています。削除を保留しました"
        }
    }
}

extension PCStore {
    // Serialises explicit deletion even when gallery controllers have different
    // worker queues. The controller separately protects live/open recordings.
    private static let deletionLock=NSLock()
    private static let deletionPrefix=".deleting-"

    /// Logical bytes within one record only, including unfinished inputs and
    /// internal export files. No payload is opened and no symbolic link followed.
    /// External PLY exports and the separate thumbnail cache are outside this root.
    func storageBytes(_ id:UUID)throws->Int64 {
        guard let rootFD=try deletionRootFD() else {throw PCFailure.corrupt}
        defer{close(rootFD)}
        let children=try Self.deletionNames(rootFD)
        let matches=children.filter {name in
            UUID(uuidString:name)==id || (name.hasPrefix(Self.deletionPrefix) && UUID(uuidString:String(name.dropFirst(Self.deletionPrefix.count)))==id)
        }
        guard matches.count==1,let name=matches.first,
              try Self.deletionType(at:rootFD,name:name)==mode_t(S_IFDIR) else {throw PCFailure.corrupt}
        let fd=try Self.deletionOpen(at:rootFD,name:name);defer{close(fd)}
        var remaining=50_000
        return try Self.storageBytes(fd,depth:0,remaining:&remaining)
    }
    private static func storageBytes(_ fd:Int32,depth:Int,remaining:inout Int)throws->Int64 {
        guard depth<=16 else {throw PCFailure.corrupt}
        var total:Int64=0
        for name in try deletionNames(fd) {
            remaining-=1;guard remaining>=0 else {throw PCFailure.corrupt}
            var info=stat()
            guard fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW)==0 else {throw deletionPOSIX()}
            let type=info.st_mode & mode_t(S_IFMT)
            let bytes:Int64
            if type==mode_t(S_IFDIR) {
                let child=try deletionOpen(at:fd,name:name);defer{close(child)}
                bytes=try storageBytes(child,depth:depth+1,remaining:&remaining)
            } else {
                guard type==mode_t(S_IFREG),info.st_size>=0 else {throw PCFailure.corrupt}
                bytes=Int64(info.st_size)
            }
            let sum=total.addingReportingOverflow(bytes);guard !sum.overflow else {throw PCFailure.corrupt};total=sum.partialValue
        }
        return total
    }

    /// Permanent deletion, called only after the user confirms this exact ID.
    /// First unpublish one record by an atomic same-directory rename. A crash
    /// or partial I/O error leaves an explicit, retryable pending-deletion row.
    /// Directory-FD-relative operations never follow links or escape this root.
    func deleteRecord(_ id:UUID)throws {
        appendState=nil
        Self.deletionLock.lock();defer{Self.deletionLock.unlock()}
        guard let rootFD=try deletionRootFD() else {return}
        defer{close(rootFD)}
        let children=try Self.deletionNames(rootFD)
        let originals=children.filter{UUID(uuidString:$0)==id}
        let markedNames=children.filter{$0.hasPrefix(Self.deletionPrefix) && UUID(uuidString:String($0.dropFirst(Self.deletionPrefix.count)))==id}
        guard originals.count<=1,markedNames.count<=1 else {throw PCDeletionFailure.conflict}
        let name=originals.first ?? id.uuidString,pending=markedNames.first ?? Self.deletionPrefix+id.uuidString
        let original=try Self.deletionType(at:rootFD,name:name)
        let marked=try Self.deletionType(at:rootFD,name:pending)
        guard original==nil || marked==nil else {throw PCDeletionFailure.conflict}
        guard original != nil || marked != nil else {return} // idempotent retry
        var remaining=50_000
        if let original {
            guard original==mode_t(S_IFDIR) else {throw PCDeletionFailure.unsafePath}
            let fd=try Self.deletionOpen(at:rootFD,name:name)
            defer{close(fd)}
            try Self.deletionCheck(fd,depth:0,remaining:&remaining)
            try hook("before-delete-mark")
            guard renameatx_np(rootFD,name,rootFD,pending,UInt32(RENAME_EXCL))==0 else {throw Self.deletionPOSIX()}
            try Self.deletionSync(rootFD)
            try hook("after-delete-mark")
        } else {
            guard marked==mode_t(S_IFDIR) else {throw PCDeletionFailure.unsafePath}
        }
        let fd=try Self.deletionOpen(at:rootFD,name:pending)
        defer{close(fd)}
        remaining=50_000
        try Self.deletionCheck(fd,depth:0,remaining:&remaining)
        remaining=50_000
        try deletionPurge(fd,depth:0,remaining:&remaining)
        try hook("before-delete-finish")
        guard unlinkat(rootFD,pending,AT_REMOVEDIR)==0 else {throw Self.deletionPOSIX()}
        try Self.deletionSync(rootFD)
    }

    /// Metadata only; pending records never masquerade as readable point data.
    func pendingDeletionIDs()throws->[UUID] {
        guard let fd=try deletionRootFD() else {return []}
        defer{close(fd)}
        return Array(Set(try Self.deletionNames(fd).compactMap {name -> UUID? in
            guard name.hasPrefix(Self.deletionPrefix) else {return nil}
            return UUID(uuidString:String(name.dropFirst(Self.deletionPrefix.count)))
        })).sorted{$0.uuidString<$1.uuidString}
    }

    private func deletionRootFD()throws->Int32? {
        guard root.isFileURL else {throw PCDeletionFailure.unsafePath}
        func platformPath(_ url:URL)->String {
            var path=url.standardizedFileURL.path
            // These Darwin aliases are platform-owned. Never resolve arbitrary
            // user-controlled descendants before checking O_NOFOLLOW.
            for alias in ["/tmp","/var"] where path==alias || path.hasPrefix(alias+"/") {
                path="/private"+path;break
            }
            return path
        }
        let path=platformPath(root)
        // Open the app's own trusted container directly: an iOS sandbox need
        // not grant read access to /private/var or other container ancestors.
        // Only walk descendants of that anchor. The home and temp anchors are
        // supplied by the OS, never by imported record data.
        let home=platformPath(URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true))
        let anchors=[home,platformPath(FileManager.default.temporaryDirectory),"/private/tmp"]
        guard let anchor=anchors.first(where:{path==$0 || path.hasPrefix($0+"/")}) else {throw PCDeletionFailure.unsafePath}
        let pieces=path.dropFirst(anchor.count).split(separator:"/").map(String.init)
        var fd=open(anchor,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else {throw Self.deletionPOSIX()}
        for component in pieces {
            let next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            let failure=errno;close(fd)
            if next<0 {
                if failure==ENOENT {return nil}
                if failure==ELOOP || failure==ENOTDIR {throw PCDeletionFailure.unsafePath}
                throw POSIXError(POSIXErrorCode(rawValue:failure) ?? .EIO)
            }
            fd=next
        }
        return fd
    }
    private static func deletionPOSIX()->POSIXError {POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    private static func deletionOpen(at parent:Int32,name:String)throws->Int32 {
        let fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else {
            if errno==ELOOP || errno==ENOTDIR {throw PCDeletionFailure.unsafePath}
            throw deletionPOSIX()
        }
        return fd
    }
    private static func deletionType(at fd:Int32,name:String)throws->mode_t? {
        var value=stat()
        guard fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW)==0 else {
            if errno==ENOENT {return nil};throw deletionPOSIX()
        }
        return value.st_mode & mode_t(S_IFMT)
    }
    private static func deletionNames(_ fd:Int32)throws->[String] {
        let copy=dup(fd);guard copy>=0 else {throw deletionPOSIX()}
        guard let directory=fdopendir(copy) else {let error=deletionPOSIX();close(copy);throw error}
        defer{closedir(directory)}
        rewinddir(directory)
        var names:[String]=[]
        while true {
            errno=0
            guard let entry=readdir(directory) else {
                guard errno==0 else {throw deletionPOSIX()};break
            }
            let name=withUnsafeBytes(of:entry.pointee.d_name) {String(cString:$0.baseAddress!.assumingMemoryBound(to:CChar.self))}
            if name=="." || name==".." {continue}
            guard names.count<50_000 else {throw PCDeletionFailure.tooLarge}
            names.append(name)
        }
        return names.sorted()
    }
    private static func deletionCheck(_ fd:Int32,depth:Int,remaining:inout Int)throws {
        guard depth<=16 else {throw PCDeletionFailure.tooLarge}
        for name in try deletionNames(fd) {
            remaining-=1;guard remaining>=0 else {throw PCDeletionFailure.tooLarge}
            guard let type=try deletionType(at:fd,name:name) else {throw PCDeletionFailure.unsafePath}
            if type==mode_t(S_IFDIR) {
                let child=try deletionOpen(at:fd,name:name);defer{close(child)}
                try deletionCheck(child,depth:depth+1,remaining:&remaining)
            } else if type != mode_t(S_IFREG) {throw PCDeletionFailure.unsafePath}
        }
    }
    private func deletionPurge(_ fd:Int32,depth:Int,remaining:inout Int)throws {
        guard depth<=16 else {throw PCDeletionFailure.tooLarge}
        for name in try Self.deletionNames(fd) {
            remaining-=1;guard remaining>=0 else {throw PCDeletionFailure.tooLarge}
            guard let type=try Self.deletionType(at:fd,name:name) else {throw PCDeletionFailure.unsafePath}
            try hook("before-delete-item")
            if type==mode_t(S_IFDIR) {
                let child=try Self.deletionOpen(at:fd,name:name);defer{close(child)}
                try deletionPurge(child,depth:depth+1,remaining:&remaining)
                guard unlinkat(fd,name,AT_REMOVEDIR)==0 else {throw Self.deletionPOSIX()}
            } else {
                guard type==mode_t(S_IFREG) else {throw PCDeletionFailure.unsafePath}
                guard unlinkat(fd,name,0)==0 else {throw Self.deletionPOSIX()}
            }
        }
    }
    private static func deletionSync(_ fd:Int32)throws {
        if fsync(fd) != 0 {
            // Some non-APFS test volumes do not support directory fsync.
            if errno != EINVAL && errno != ENOTSUP {throw deletionPOSIX()}
        }
    }
}

extension PCStore {
    /// Metadata only: no RGB/depth/point blobs are read to populate the list.
    func summaries()throws->[PCSavedRecord] {
        // Avoid publishing a ghost pending row while another gallery finishes
        // its deletion on a separate worker queue.
        Self.deletionLock.lock();defer{Self.deletionLock.unlock()}
        let pending=Set(try pendingDeletionIDs())
        var records=try list().filter{!pending.contains($0)}.map { id in
            let date=try? directory(id).resourceValues(forKeys:[.creationDateKey]).creationDate
            let bytes=try? storageBytes(id)
            do {
                let record=try load(id,verify:false)
                let selectionKey=String(record.selection?.corrected ?? false)+(record.selection?.offsets.keys.sorted{$0.uuidString<$1.uuidString}.map { id in
                    let p=record.selection!.offsets[id]!;return id.uuidString+"/\(p.x)/\(p.y)/\(p.z)"
                }.joined() ?? "")
                var poseKey=""
                if let events=record.checkpoint?.poseEvents,!events.isEmpty {
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                    poseKey=Self.digest(try encoder.encode(events))+PCPoseCorrection.recipe
                }
                let key=Self.digest(Data((record.frames.map{$0.id.uuidString+($0.hashes["points.xyzrgb"] ?? "")}.joined()+selectionKey+poseKey+(record.control?.id.uuidString ?? "")).utf8))
                let complete=record.checkpoint?.stopped==true && record.warnings.isEmpty
                return PCSavedRecord(id:id,date:date,pointCount:record.frames.reduce(0){$0+$1.pointCount},gcpCount:record.checkpoint?.raw.activePoints.count ?? 0,state:complete ? .saved:.interrupted,
                    status:complete ? "アプリ内保存済み・開くと内容を検証":"保存中断／一部未完了・確定済み入力のみ閲覧",thumbnailKey:key,storedBytes:bytes)
            } catch {
                return PCSavedRecord(id:id,date:date,pointCount:0,gcpCount:0,state:.unreadable,status:"読み取り不可: \(PCMessage.error(error))",thumbnailKey:nil,storedBytes:bytes)
            }
        }
        records += pending.map {PCSavedRecord(id:$0,date:nil,pointCount:0,gcpCount:0,state:.deletionPending,
                                              status:"削除未完了・もう一度「削除」で処理を続けられます",thumbnailKey:nil,storedBytes:try? storageBytes($0))}
        return records.sorted {
            if ($0.state == .deletionPending) != ($1.state == .deletionPending) {return $0.state == .deletionPending}
            return ($0.date ?? .distantPast)>($1.date ?? .distantPast)
        }
    }
    func thumbnail(_ summary:PCSavedRecord,cache:URL)throws->PCThumbnail {
        // Finish any in-flight cache write before permanent deletion returns,
        // so the controller can then remove this record's cache deterministically.
        Self.deletionLock.lock();defer{Self.deletionLock.unlock()}
        guard let key=summary.thumbnailKey else {throw PCFailure.corrupt}
        let path=cache.appendingPathComponent(summary.id.uuidString+"-"+key+".json")
        if let size=try? path.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]),size.isSymbolicLink != true,(size.fileSize ?? Int.max)<256*1024,
           let data=try? Data(contentsOf:path),let value=try? JSONDecoder().decode(PCThumbnail.self,from:data),value.key==key,value.valid {return value}
        let original=try load(summary.id,verify:false),solution=try? PCControlMath.active(original)
        let record=(solution != nil || original.selection?.corrected==true) ? try PCPoseCorrection.prepare(original):original
        let offsets=try PCControlMath.selectedOffsets(record,solution:solution),transform=solution?.transform
        let step=max(1,Int(ceil(Double(record.frames.count)/12)))
        var sample:[PCVertex]=[]
        for index in stride(from:0,to:record.frames.count,by:step) {
            let entry=record.frames[index],points=try self.points(entry,id:record.id),pointStep=max(1,Int(ceil(Double(points.count)/170)))
            let offset=SIMD3<Float>((offsets[entry.id] ?? GCPVector()).v)
            for i in stride(from:0,to:points.count,by:pointStep) {
                var p=points[i];let base=record.poseTransforms[entry.id]?.point(SIMD3<Double>(p.position)) ?? SIMD3<Double>(p.position)
                p.position=transform.map{$0.display(base+SIMD3<Double>(offset))} ?? SIMD3<Float>(base+SIMD3<Double>(offset));sample.append(p)
            }
        }
        // Fixed oblique orthographic view, no dependence on live camera/session.
        let projected=sample.map {p in SIMD2<Float>(p.position.x*0.8-p.position.z*0.6,p.position.y*0.9+(p.position.x*0.6+p.position.z*0.8)*0.3)}
        var lo=SIMD2<Float>(repeating:.infinity),hi=SIMD2<Float>(repeating:-.infinity)
        for p in projected {lo=SIMD2(min(lo.x,p.x),min(lo.y,p.y));hi=SIMD2(max(hi.x,p.x),max(hi.y,p.y))}
        let centre=(lo+hi)/2,span=max(0.01,max(hi.x-lo.x,hi.y-lo.y))
        let dots=zip(sample,projected).prefix(2048).map {p,v in PCThumbnail.Dot(x:0.5+0.9*(v.x-centre.x)/span,y:0.5-0.9*(v.y-centre.y)/span,r:p.r,g:p.g,b:p.b)}
        let result=PCThumbnail(key:key,dots:dots);guard result.valid else {throw PCFailure.corrupt}
        // Cache failure, including low space, must never block browsing the source.
        if freeBytes()>minimumFree {
            try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            if (try? cache.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true {
                try? JSONEncoder().encode(result).write(to:path,options:.atomic)
            }
        }
        return result
    }
}
