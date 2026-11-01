import Foundation
import simd
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Separate namespace and mirrored raw/journal documents. No ARWork/TreeSurvey
/// migration, collection or deletion. Call from one serial worker.
final class GCPStore {
    struct Envelope:Codable {var schema=1;var revision:Int;var payload:Data;var checksum:UInt64}
    struct Loaded<T> {var value:T;var recovered:Bool;var damaged:Bool}
    let root:URL
    private let hook:((String)throws->Void)?
    init(root:URL,hook:((String)throws->Void)?=nil) {self.root=root;self.hook=hook}
    static var suggestedRoot:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LiDARScanGCP",isDirectory:true)
    }
    private func directory(_ id:UUID) throws -> URL {
        let path=root.standardizedFileURL.resolvingSymlinksInPath()
        guard !path.pathComponents.contains(where:{["ARWork","TreeSurvey","Documents","Archives"].contains($0)}) else {throw GCPFailure.foreignStore}
        let dir=path.appendingPathComponent(id.uuidString,isDirectory:true)
        guard dir.resolvingSymlinksInPath().standardizedFileURL.path==dir.path else {throw GCPFailure.foreignStore}
        return dir
    }
    static func checksum(_ data:Data)->UInt64 {data.reduce(UInt64(14695981039346656037)){($0 ^ UInt64($1)) &* 1099511628211}}
    private func read<T:Decodable>(_ id:UUID,_ stem:String,_ type:T.Type) throws -> (Loaded<T>,Int)? {
        let dir=try directory(id);var values:[(Int,T,UInt64)]=[],existing=0
        for slot in 0...1 {
            let url=dir.appendingPathComponent("\(stem).\(slot).json")
            guard FileManager.default.fileExists(atPath:url.path) else {continue};existing+=1
            guard url.resolvingSymlinksInPath().path==url.path else {throw GCPFailure.foreignStore}
            let data=try Data(contentsOf:url)
            guard let envelope=try? JSONDecoder().decode(Envelope.self,from:data) else {continue}
            guard envelope.schema==1 else {throw GCPFailure.unsupportedSchema}
            if envelope.revision>0,Self.checksum(envelope.payload)==envelope.checksum,
               let value=try? JSONDecoder().decode(T.self,from:envelope.payload) {values.append((envelope.revision,value,envelope.checksum))}
        }
        values.sort {$0.0>$1.0}
        guard let latest=values.first else {if existing>0 {throw GCPFailure.corruptStore};return nil}
        if values.count==2,values[0].0==values[1].0,values[0].2 != values[1].2 {throw GCPFailure.corruptStore}
        return (Loaded(value:latest.1,recovered:values.count != 2 || values[0].0 != values[1].0,damaged:existing>values.count),latest.0)
    }
    private func writePair<T:Codable>(_ value:T,id:UUID,stem:String) throws {
        let old=try read(id,stem,T.self)
        guard old?.0.damaged != true else {throw GCPFailure.corruptStore}
        guard (old?.1 ?? 0)<Int.max else {throw GCPFailure.corruptStore}
        let revision=(old?.1 ?? 0)+1
        let payload=try JSONEncoder().encode(value)
        let data=try JSONEncoder().encode(Envelope(revision:revision,payload:payload,checksum:Self.checksum(payload)))
        let dir=try directory(id)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        for slot in [revision%2,1-revision%2] {try durable(data,to:dir.appendingPathComponent("\(stem).\(slot).json"))}
    }
    func validateRawForCapture(_ raw:GCPRawSession) throws {try validate(raw)}
    private func validate(_ raw:GCPRawSession) throws {
        guard raw.schema==1 else {throw GCPFailure.unsupportedSchema}
        guard Set(raw.observations.map(\.id)).count==raw.observations.count,
              Set(raw.points.map(\.id)).count==raw.points.count,
              Set(raw.trajectory.map(\.id)).count==raw.trajectory.count else {throw GCPFailure.invalidSession}
        for o in raw.observations {
            _=try o.ray()
            try o.captureEvidence?.validate(o)
            if let d=o.depth {guard d.cameraZ.isFinite,d.neighbourhoodSpread.isFinite else {throw GCPFailure.invalidObservation}}
        }
        for p in raw.points {
            guard let o=raw.observations.first(where:{$0.id==p.registrationObservationID}),o.epoch==p.epoch else {throw GCPFailure.invalidSession}
            let expected:GCPPoint
            if let secondID=p.secondRegistrationObservationID {
                guard secondID != o.id,let second=raw.observations.first(where:{$0.id==secondID}) else {throw GCPFailure.invalidSession}
                expected=try GCPMath.register(o,second,translation:p.registrationTranslation)
                guard p.triangulation==expected.triangulation else {throw GCPFailure.invalidSession}
            } else {
                guard p.triangulation==nil else {throw GCPFailure.invalidSession}
                expected=try GCPMath.register(o,translation:p.registrationTranslation)
            }
            guard p.position.finite,simdDistance(p.position,expected.position)<1e-9 else {throw GCPFailure.invalidSession}
        }
        let operations=raw.captureOperations ?? [],cancellations=raw.captureCancellations ?? []
        guard Set(operations.map(\.id)).count==operations.count,Set(cancellations.map(\.id)).count==cancellations.count else {throw GCPFailure.invalidSession}
        let knownObservations=Set(raw.observations.map(\.id))
        let registrationIDs=Set(raw.points.flatMap {[$0.registrationObservationID]+($0.secondRegistrationObservationID.map {[$0]} ?? [])})
        var used=Set<UUID>(),cancelled=Set<UUID>(),cancelledOperations=Set<UUID>()
        for operation in operations {
            let ids=Set(operation.observationIDs)
            guard !ids.isEmpty,ids.count<=2,ids.count==operation.observationIDs.count,ids.isSubset(of:knownObservations),used.isDisjoint(with:ids),
                  let point=raw.points.first(where:{$0.id==operation.pointID}) else {throw GCPFailure.invalidSession}
            used.formUnion(ids)
            if operation.registered {
                let expected=Set([point.registrationObservationID]+(point.secondRegistrationObservationID.map {[$0]} ?? []))
                guard ids==expected else {throw GCPFailure.invalidSession}
            } else {
                guard ids.isDisjoint(with:registrationIDs) else {throw GCPFailure.invalidSession}
            }
            guard operation.observationIDs.allSatisfy({id in raw.observations.contains {$0.id==id && $0.epoch==point.epoch}}) else {throw GCPFailure.invalidSession}
        }
        for cancellation in cancellations {
            let ids=Set(cancellation.observationIDs)
            guard !ids.isEmpty,ids.count==cancellation.observationIDs.count,ids.isSubset(of:knownObservations),cancelled.isDisjoint(with:ids) else {throw GCPFailure.invalidSession}
            if let operationID=cancellation.operationID {
                guard cancelledOperations.insert(operationID).inserted,let operation=operations.first(where:{$0.id==operationID}),operation.observationIDs==cancellation.observationIDs else {throw GCPFailure.invalidSession}
            } else {
                guard ids.count==1,used.isDisjoint(with:ids),registrationIDs.isDisjoint(with:ids),
                      let observation=raw.observations.first(where:{$0.id==cancellation.observationIDs[0]}),
                      observation.associationEvidence?.directionOnly==true,
                      observation.associationEvidence?.outcome=="awaiting-second-ray" else {throw GCPFailure.invalidSession}
            }
            cancelled.formUnion(ids)
        }
        // Cancelling a registration cannot orphan a later active reobservation.
        let active=Set(raw.activePoints.map(\.id))
        guard operations.filter({!cancelledOperations.contains($0.id)}).allSatisfy({active.contains($0.pointID)}) else {throw GCPFailure.invalidSession}
        for s in raw.trajectory {
            guard s.rawPose.valid,s.time.isFinite,s.time>=0,s.epoch.generation>=0,s.epoch.alignmentRevision>=0 else {throw GCPFailure.invalidTrajectory}
            if let m=s.cameraTransform {
                let p=try GCPCaptureEvidence.pose(m)
                guard s.frameID != nil,simdDistance(p.position,s.rawPose.position)<1e-6,abs(simd_dot(p.rotation.vector,s.rawPose.rotation.vector))>1-1e-10 else {throw GCPFailure.invalidTrajectory}
            }
        }
    }
    private func simdDistance(_ a:GCPVector,_ b:GCPVector)->Double {
        let d=a.v-b.v;return sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
    }
    func loadRaw(_ id:UUID) throws -> Loaded<GCPRawSession>? {
        guard let loaded=try read(id,"raw",GCPRawSession.self)?.0 else {return nil}
        guard loaded.value.id==id else {throw GCPFailure.invalidSession};try validate(loaded.value);return loaded
    }
    func saveRaw(_ raw:GCPRawSession) throws {
        try validate(raw)
        if let old=try loadRaw(raw.id)?.value {
            guard raw.observations.starts(with:old.observations),raw.points.starts(with:old.points),raw.trajectory.starts(with:old.trajectory),(raw.captureOperations ?? []).starts(with:old.captureOperations ?? []),(raw.captureCancellations ?? []).starts(with:old.captureCancellations ?? []) else {throw GCPFailure.originalsImmutable}
        } else {
            let dir=try directory(raw.id)
            if FileManager.default.fileExists(atPath:dir.path) {
                let names=try FileManager.default.contentsOfDirectory(atPath:dir.path)
                guard names.allSatisfy({$0.hasPrefix(".raw.") && $0.hasSuffix(".pending")}) else {throw GCPFailure.foreignStore}
            }
        }
        try writePair(raw,id:raw.id,stem:"raw")
    }
    func validateJournalForCapture(_ journal:GCPJournal,raw:GCPRawSession) throws {try validate(raw);try validate(journal,raw:raw)}
    private func validate(_ journal:GCPJournal,raw:GCPRawSession) throws {
        guard journal.schema==1 else {throw GCPFailure.unsupportedSchema}
        guard journal.sessionID==raw.id else {throw GCPFailure.invalidJournal}
        _=try journal.active()
        for change in journal.changes where change.kind == .apply {
            guard let a=change.adjustment,a.fit.policyVersion==1 else {throw GCPFailure.invalidJournal}
            let fit=try GCPMath.fit(raw:raw,bindings:a.fit.bindings,context:a.fit.context,includeCancelled:true)
            guard fit.rank==3,fit.rank==a.fit.rank,simdDistance(fit.translation,a.fit.translation)<1e-9,
                  fit.firstTime==a.fit.firstTime,fit.lastTime==a.fit.lastTime,fit.lastPose==a.fit.lastPose,
                  fit.information.count==a.fit.information.count,
                  zip(fit.information,a.fit.information).allSatisfy({abs($0-$1)<1e-9}),a.fit.unconstrainedDirections.isEmpty,
                  let c=fit.conditionNumber,let saved=a.fit.conditionNumber,abs(c-saved)<=max(1,c)*1e-9,
                  let first=a.trajectoryIDs.first,let last=a.trajectoryIDs.last,
                  let start=raw.trajectory.firstIndex(where:{$0.id==first}),let end=raw.trajectory.firstIndex(where:{$0.id==last}),start<end else {throw GCPFailure.invalidJournal}
            let samples=Array(raw.trajectory[start...end])
            guard samples.map(\.id)==a.trajectoryIDs else {throw GCPFailure.invalidJournal}
            let computed=try GCPMath.adjustment(fit:fit,samples:samples,start:a.startTranslation)
            guard computed.offsets.count==a.offsets.count,zip(computed.offsets,a.offsets).allSatisfy({simdDistance($0,$1)<1e-9}) else {throw GCPFailure.invalidJournal}
        }
    }
    func loadJournal(_ id:UUID) throws -> Loaded<GCPJournal>? {
        guard let loaded=try read(id,"corrections",GCPJournal.self)?.0 else {return nil}
        guard let raw=try loadRaw(id) else {throw GCPFailure.invalidJournal}
        try validate(loaded.value,raw:raw.value)
        var result=loaded;result.recovered = result.recovered || raw.recovered;result.damaged = result.damaged || raw.damaged
        return result
    }
    func saveJournal(_ journal:GCPJournal) throws {
        guard let raw=try loadRaw(journal.sessionID) else {throw GCPFailure.invalidSession}
        guard !raw.damaged else {throw GCPFailure.corruptStore}
        try validate(journal,raw:raw.value)
        if let old=try loadJournal(journal.sessionID)?.value {
            guard journal.changes.starts(with:old.changes) else {throw GCPFailure.originalsImmutable}
        }
        try writePair(journal,id:journal.sessionID,stem:"corrections")
    }
    private func durable(_ data:Data,to url:URL) throws {
        let dir=url.deletingLastPathComponent(),temp=dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).pending")
        try hook?("before-open")
        let fd=open(temp.path,O_WRONLY|O_CREAT|O_EXCL,mode_t(0o600));guard fd>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer {close(fd)}
        try data.withUnsafeBytes {bytes in
            var offset=0
            while offset<bytes.count {
                let n=write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if n<0 && errno==EINTR {continue}
                guard n>0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)};offset+=n
            }
        }
        guard fsync(fd)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        #if canImport(Darwin)
        if fcntl(fd,F_FULLFSYNC)<0,errno != EINVAL,errno != ENOTSUP {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        #endif
        try hook?("after-file-sync")
        guard rename(temp.path,url.path)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        try hook?("after-rename")
        let parent=open(dir.path,O_RDONLY);guard parent>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)};defer {close(parent)}
        guard fsync(parent)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        try hook?("after-directory-sync")
    }
}
