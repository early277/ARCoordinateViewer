import Foundation
import simd

enum PCCorrection {
    /// Keep historic fits as evidence; cancellation changes only the derived active fit.
    static func activeFits(raw:GCPRawSession,fits:[GCPTranslationFit])throws->[GCPTranslationFit] {
        var result:[GCPTranslationFit]=[]
        for saved in fits {
            guard try GCPMath.fit(raw:raw,bindings:saved.bindings,context:saved.context,includeCancelled:true)==saved else {throw PCFailure.corrupt}
            let bindings=raw.activeBindings(saved.bindings)
            guard !bindings.isEmpty else {continue}
            let fit=try GCPMath.fit(raw:raw,bindings:bindings,context:saved.context)
            if !result.contains(fit) {result.append(fit)}
        }
        return result
    }
    /// Live acquisition reference belongs to the current accepted pose interval.
    /// Historical fits remain immutable evidence for the stopped recomputation;
    /// cancelling a new operation must not reintroduce a pre-refinement offset.
    static func liveReference(raw:GCPRawSession,fits:[GCPTranslationFit],after boundary:Double?)throws->GCPVector {
        guard boundary.map({$0.isFinite && $0>=0}) ?? true else {throw PCFailure.invalidInput}
        let active=try activeFits(raw:raw,fits:fits)
        // activeFits recomputes firstTime from every surviving source binding.
        return active.last(where:{fit in fit.rank==3 && (boundary.map{fit.firstTime>$0} ?? true)})?.translation ?? GCPVector()
    }
    /// Translation only, fixed ARKit attitude. Automatic frame ordinal supplies
    /// the weights; extra manual frames never change automatic-frame corrections.
    static func offsets(record:PCRecord)throws->[UUID:GCPVector] {
        try PCPoseCorrection.validateMotionDecisions(record)
        if !record.posePrepared,record.checkpoint?.poseEvents?.isEmpty==false {return try offsets(record:PCPoseCorrection.prepare(record))}
        guard let checkpoint=record.checkpoint,checkpoint.stopped,let epoch=record.frames.first?.frame.epoch else {throw PCFailure.correctionUnavailable}
        let autos=record.frames.filter{$0.frame.automatic}.map(\.frame)
        guard autos.count>=2,record.frames.allSatisfy({$0.frame.epoch==epoch}) else {throw PCFailure.correctionUnavailable}
        func ordinal(_ time:Double)throws->Double {
            guard time>=autos[0].time,time<=autos.last!.time else {throw PCFailure.correctionUnavailable}
            if time==autos.last!.time {return Double(autos.count-1)}
            guard let i=(0..<autos.count-1).first(where:{autos[$0].time<=time && time<autos[$0+1].time}) else {throw PCFailure.correctionUnavailable}
            return Double(i)+(time-autos[i].time)/(autos[i+1].time-autos[i].time)
        }
        var knots:[(Double,SIMD3<Double>)]=[(0,.zero)]
        for fit in try activeFits(raw:checkpoint.raw,fits:checkpoint.fits).sorted(by:{$0.lastTime<$1.lastTime}) {
            guard fit.context.epoch==epoch else {throw PCFailure.foreignEpoch}
            guard fit.rank==3 else {continue} // A single bearing leaves depth unknown.
            let x=try ordinal(fit.lastTime)
            guard x>0 else {continue}
            if abs(x-knots.last!.0)<1e-9 {knots[knots.count-1]=(x,fit.translation.v)}
            else {knots.append((x,fit.translation.v))}
        }
        guard knots.count>1 else {
            if record.posePrepared,record.checkpoint?.poseEvents?.isEmpty==false {return Dictionary(uniqueKeysWithValues:record.frames.map{($0.id,GCPVector())})}
            throw PCFailure.correctionUnavailable
        }
        func atOrdinal(_ x:Double)->SIMD3<Double> {
            if x>=knots.last!.0 {return knots.last!.1}
            let j=(0..<knots.count-1).first{knots[$0].0<=x && x<knots[$0+1].0}!
            let a=knots[j],b=knots[j+1],t=(x-a.0)/(b.0-a.0)
            return a.1*(1-t)+b.1*t
        }
        let automatic=autos.enumerated().map{atOrdinal(Double($0.offset))}
        var result:[UUID:GCPVector]=[:]
        for entry in record.frames {
            let x=try ordinal(entry.frame.time),lo=min(autos.count-1,Int(floor(x))),hi=min(autos.count-1,lo+1),t=x-Double(lo)
            result[entry.id]=GCPVector(automatic[lo]*(1-t)+automatic[hi]*t)
        }
        return result
    }
    /// Prepare once per model, never once per GCP marker or per render frame.
    static func markers(_ record:PCRecord)->[SIMD3<Float>?] {
        guard let derived=try? PCPoseCorrection.prepare(record) else {return record.checkpoint?.raw.activePoints.map{_ in nil} ?? []}
        return (derived.checkpoint?.raw.activePoints ?? []).map {point in
            (try? PCControlMath.source(point,record:derived,corrected:true)).map(SIMD3<Float>.init)
        }
    }
    static func checkedSelection(_ record:PCRecord)throws->[UUID:GCPVector] {
        guard let s=record.selection,s.corrected else {return [:]}
        let calculated=try offsets(record:record)
        guard calculated==s.offsets else {throw PCFailure.corrupt}
        return calculated
    }
}
final class PCWorkControl:@unchecked Sendable {
    private let lock=NSLock();private var stopped=false
    private let deadline:Date
    private var cancelAction:(()->Void)?
    init(seconds:TimeInterval=120) {
        deadline=Date().addingTimeInterval(seconds)
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+seconds) {[weak self] in
            guard let self else {return};self.lock.lock();let action=self.cancelAction;self.lock.unlock();action?()
        }
    }
    func cancel(){lock.lock();stopped=true;let action=cancelAction;lock.unlock();action?()}
    func onCancel(_ action:@escaping()->Void){lock.lock();cancelAction=action;let value=stopped;lock.unlock();if value {action()}}
    func check()throws {lock.lock();let value=stopped;lock.unlock();if value {throw PCFailure.cancelled};if Date()>deadline {throw PCFailure.interrupted}}
}
enum PCPly {
    /// Chunked copy keeps cancellation responsive and never labels partial bytes
    /// as a finished PLY. Original and incomplete destination are retained.
    static func deliver(_ source:URL,to destination:URL,control:PCWorkControl)throws {
        try control.check()
        guard !FileManager.default.fileExists(atPath:destination.path) else {throw PCFailure.corrupt}
        let partial=destination.appendingPathExtension("partial")
        guard !FileManager.default.fileExists(atPath:partial.path),FileManager.default.createFile(atPath:partial.path,contents:nil) else {throw PCFailure.capacity}
        let input=try FileHandle(forReadingFrom:source),output=try FileHandle(forWritingTo:partial)
        defer {try? input.close();try? output.close()}
        var copied:Int64=0
        let expected=(try source.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? -1
        while true {
            try control.check();let chunk=try input.read(upToCount:1_048_576) ?? Data();if chunk.isEmpty {break}
            try output.write(contentsOf:chunk);copied+=Int64(chunk.count)
        }
        guard copied==expected else {throw PCFailure.corrupt}
        try output.synchronize();try output.close();try control.check()
        try FileManager.default.moveItem(at:partial,to:destination)
    }
    /// Stream a complete private output before asking the folder provider to save.
    /// A partial output has a .partial extension and is never reported as success.
    static func export(store:PCStore,id:UUID,folder:URL,corrected:Bool,control:PCWorkControl=PCWorkControl(),progress:(Double)->Void={_ in})throws->URL {
        try control.check();let original=try store.load(id)
        let record=corrected ? try PCPoseCorrection.prepare(original):original
        guard !record.frames.isEmpty else {throw PCFailure.empty}
        let offsets=corrected ? try PCCorrection.offsets(record:record):[:]
        let count=record.frames.reduce(0,{$0+$1.pointCount}),required=Int64(count*15+65536)
        guard count>0 else {throw PCFailure.empty}
        guard store.freeBytes()>store.minimumFree+required else {throw PCFailure.capacity}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let stem="point-cloud-"+id.uuidString+"-"+(corrected ? "corrected-":"raw-")+UUID().uuidString
        let partial=folder.appendingPathComponent(stem+".partial"),final=folder.appendingPathComponent(stem+".ply")
        guard FileManager.default.createFile(atPath:partial.path,contents:nil) else {throw PCFailure.capacity}
        let handle=try FileHandle(forWritingTo:partial);defer{try? handle.close()}
        let header="""
        ply
        format binary_little_endian 1.0
        comment units metre; local ARKit Y-up; no geographic datum
        comment motion-fallback \(record.checkpoint?.motionDecisionCount ?? 0); physical-motion-by-rule, not a verified cause; no delta added for those decisions
        comment RGB sRGB; measured points only; missing regions are not filled
        comment state \(corrected ? "GCP translation correction; automatic-frame interpolation":"raw")
        comment pose-step \(corrected && record.checkpoint?.poseEvents?.isEmpty==false ? "heuristic segment-local temporal correction applied BEFORE recomputed GCP; no ARKit cause assertion":"not applied")
        comment no accuracy guarantee; overlapping frames remain separate samples
        comment preserved-record \(id.uuidString); warnings \(record.warnings.count)
        element vertex \(count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header
        """+"\n"
        try handle.write(contentsOf:Data(header.utf8))
        for (i,entry) in record.frames.enumerated() {
            try control.check();guard store.freeBytes()>store.minimumFree else {throw PCFailure.capacity}
            var data=Data();data.reserveCapacity(entry.pointCount*15)
            for var point in try store.points(entry,id:id) {
                let source=record.poseTransforms[entry.id]?.point(SIMD3<Double>(point.position)) ?? SIMD3<Double>(point.position)
                point.position=SIMD3<Float>(source+(offsets[entry.id] ?? GCPVector()).v);point.append(to:&data)
            }
            try handle.write(contentsOf:data);progress(Double(i+1)/Double(record.frames.count))
        }
        try control.check();try handle.synchronize();try handle.close()
        try FileManager.default.moveItem(at:partial,to:final);return final
    }
}
