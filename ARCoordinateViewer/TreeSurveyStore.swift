import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct TreeSurveySnapshot {
    var frame: TreeSurveyFrame?
    var records: [TreeRecord]
    var deletedRecords: [TreeRecord]
    var lastChange: TreeRecordChange?
    var changeHistoryHealthy: Bool
    var draft: TreeDraft?
    var warnings: [String]
    var unreadableIDs: [UUID]
    var recentSpecies: [String] = []
}

/// Independent TreeSurvey storage. Never opens, migrates or collects ARWork files.
/// One record per UUID, two durable copies. Metadata edits cannot change geometry.
final class TreeSurveyStore: @unchecked Sendable {
    struct Envelope: Codable { var schema = 1; var revision: Int; var payload: Data; var checksum: UInt64 }
    let root: URL
    private let writerHook: ((String) throws -> Void)?
    private var highestCreationOrder = 0
    private var highestChangeSequence = 0
    private var speciesHistory=TreeSpeciesHistory(sequence:0,names:[])
    private var speciesHistoryLoaded=false
    var recentSpecies:[String] {TreeSpecies.recent(speciesHistory.names)}
    init(root: URL, writerHook: ((String) throws -> Void)? = nil) { self.root=root;self.writerHook=writerHook }
    static var live: TreeSurveyStore {
        TreeSurveyStore(root:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TreeSurvey",isDirectory:true))
    }
    static func checksum(_ data: Data) -> UInt64 {
        data.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    private func url(_ stem: String, slot: Int) -> URL { root.appendingPathComponent("\(stem).\(slot).json") }
    private func candidates<T: Decodable>(_ stem: String, type: T.Type) -> [(Envelope,T)] {
        (0...1).compactMap { slot -> (Envelope,T)? in
            guard let raw=try? Data(contentsOf:url(stem,slot:slot)),
                  let envelope=try? JSONDecoder().decode(Envelope.self,from:raw), envelope.schema==1,
                  Self.checksum(envelope.payload)==envelope.checksum,
                  let value=try? JSONDecoder().decode(T.self,from:envelope.payload) else { return nil }
            return (envelope,value)
        }.sorted {$0.0.revision>$1.0.revision}
    }
    private func pairExists(_ stem: String) -> Bool {
        (0...1).contains { FileManager.default.fileExists(atPath:url(stem,slot:$0).path) }
    }
    private func savePair<T: Codable>(_ value: T, stem: String) throws {
        let revision=(candidates(stem,type:T.self).first?.0.revision ?? 0)+1
        let payload=try JSONEncoder().encode(value)
        let data=try JSONEncoder().encode(Envelope(revision:revision,payload:payload,checksum:Self.checksum(payload)))
        // ACK is after BOTH copies and directory sync. A crash between copies can
        // recover the new valid copy; a pre-rename crash retains the protected draft.
        for slot in [revision%2,1-revision%2] {
            try Self.durableWrite(data,to:url(stem,slot:slot),hook:writerHook)
        }
    }
    private func recordIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath:root.path) else { return [] }
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        return Array(Set(files.compactMap { file -> UUID? in
            let name=file.lastPathComponent
            guard name.hasPrefix("tree-"), name.hasSuffix(".0.json") || name.hasSuffix(".1.json") else { return nil }
            return UUID(uuidString:String(name.dropFirst(5).dropLast(7)))
        }))
    }
    func load() throws -> TreeSurveySnapshot {
        let header=candidates("frame",type:TreeSurveyFrame.self)
        guard let frame=header.first?.1 else {
            guard !pairExists("frame"), try recordIDs().isEmpty, try changeIDs().isEmpty else {
                throw TreeSurveyFailure("調査基準を読み込めません。既存ファイルを保護しています")
            }
            return TreeSurveySnapshot(frame:nil,records:[],deletedRecords:[],lastChange:nil,changeHistoryHealthy:true,draft:nil,warnings:[],unreadableIDs:[])
        }
        var records: [TreeRecord]=[], warnings: [String]=[], unreadable: [UUID]=[]
        if header.count<2 { warnings.append("調査基準の片側から復旧しました") }
        for id in try recordIDs() {
            let copies=candidates("tree-"+id.uuidString,type:TreeRecord.self)
            let valid=copies.filter { $0.1.id==id && (try? TreeSurveyMath.validate($0.1,frame:frame)) != nil }
            guard let record=valid.first?.1 else { unreadable.append(id);continue }
            records.append(record)
            if valid.count<2 { warnings.append("記録 \(record.number) の片側から復旧しました") }
        }
        records.sort {$0.creationOrder<$1.creationOrder}
        highestCreationOrder=records.map(\.creationOrder).max() ?? 0
        speciesHistory=records.compactMap(\.speciesHistory).filter {$0.sequence>0}.max(by:{$0.sequence<$1.sequence}) ?? TreeSpeciesHistory(sequence:0,names:[])
        speciesHistoryLoaded=true
        let drafts=candidates("draft",type:TreeDraft.self)
        var draft=drafts.first?.1
        if let candidate=draft?.record,
           records.contains(where:{$0.id==candidate.id}) { draft=nil }
        if draft?.discarded==true { draft=nil }
        if let candidate=draft?.record, (try? TreeSurveyMath.validate(candidate,frame:frame))==nil {
            draft=nil;warnings.append("下書きを読み込めません。ファイルは保護しています")
        }
        if pairExists("draft"), drafts.isEmpty { warnings.append("下書きが破損しています。ファイルは保護しています") }
        let changes=try loadChanges(frame:frame,records:records)
        warnings += changes.warnings
        let deleted=records.filter {changes.deleted.contains($0.id)}
        let active=records.filter {!changes.deleted.contains($0.id)}
        return TreeSurveySnapshot(frame:frame,records:active,deletedRecords:deleted,lastChange:changes.last,changeHistoryHealthy:changes.healthy,draft:draft,warnings:warnings,unreadableIDs:unreadable,recentSpecies:recentSpecies)
    }
    private func changeIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath:root.path) else {return []}
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        return Array(Set(files.compactMap {file -> UUID? in
            let name=file.lastPathComponent
            guard name.hasPrefix("change-"),name.hasSuffix(".0.json") || name.hasSuffix(".1.json") else {return nil}
            return UUID(uuidString:String(name.dropFirst(7).dropLast(7)))
        }))
    }
    private func loadChanges(frame:TreeSurveyFrame,records:[TreeRecord]) throws -> (deleted:Set<UUID>,last:TreeRecordChange?,healthy:Bool,warnings:[String]) {
        var changes:[TreeRecordChange]=[],warnings:[String]=[],healthy=true
        let known=Set(records.filter {$0.geometry.frameID==frame.id}.map(\.id))
        for id in try changeIDs() {
            let values=candidates("change-"+id.uuidString,type:TreeRecordChange.self)
            guard let change=values.first?.1,change.id==id,change.sequence>0 else {
                healthy=false;warnings.append("削除・復元履歴の一部を読み込めません。元の樹木ファイルは保持しています");continue
            }
            highestChangeSequence=max(highestChangeSequence,change.sequence)
            // A different survey's operation can never affect the open survey.
            guard change.frameID==frame.id else {continue}
            guard !change.recordIDs.isEmpty,Set(change.recordIDs).count==change.recordIDs.count,Set(change.recordIDs).isSubset(of:known) else {
                healthy=false;warnings.append("削除・復元履歴と調査の対応を確認できません。追加操作を停止しています");continue
            }
            changes.append(change)
            if values.count<2 {warnings.append("削除・復元履歴の片側から復旧しました。元の樹木ファイルは保持しています")}
        }
        changes.sort {if $0.sequence != $1.sequence {return $0.sequence<$1.sequence};return $0.id.uuidString<$1.id.uuidString}
        var deleted=Set<UUID>()
        for change in changes {
            if change.kind == .delete {deleted.formUnion(change.recordIDs)}
            else {deleted.subtract(change.recordIDs)}
        }
        return (deleted,changes.last,healthy,warnings)
    }
    /// Whole-batch visibility is one durable operation, never N destructive record writes.
    /// Retrying the same UUID repairs the mirrors without adding another logical operation.
    func saveChange(_ proposed:TreeRecordChange) throws -> TreeSurveySnapshot {
        let snapshot=try load()
        guard let frame=snapshot.frame,frame.id==proposed.frameID,snapshot.changeHistoryHealthy,snapshot.unreadableIDs.isEmpty else {throw TreeSurveyFailure("現在の調査と保存履歴を確認してから操作してください")}
        let known=Set((snapshot.records+snapshot.deletedRecords).filter {$0.geometry.frameID==frame.id}.map(\.id))
        guard !proposed.recordIDs.isEmpty,Set(proposed.recordIDs).count==proposed.recordIDs.count,Set(proposed.recordIDs).isSubset(of:known) else {throw TreeSurveyFailure("対象の樹木が現在の調査にありません")}
        let stem="change-"+proposed.id.uuidString
        var change=proposed
        if let existing=candidates(stem,type:TreeRecordChange.self).first?.1 {
            guard existing.id==proposed.id,existing.frameID==proposed.frameID,existing.kind==proposed.kind,existing.recordIDs==proposed.recordIDs,existing.created==proposed.created else {throw TreeSurveyFailure("同じ操作IDの内容は変更できません")}
            change=existing
        } else {
            guard !pairExists(stem) else {throw TreeSurveyFailure("既存の操作履歴を保護しています")}
            let available=proposed.kind == .delete ? snapshot.records:snapshot.deletedRecords
            guard Set(proposed.recordIDs).isSubset(of:Set(available.map(\.id))) else {throw TreeSurveyFailure("対象の状態が変わりました。選び直してください")}
            change.sequence=highestChangeSequence+1
        }
        try savePair(change,stem:stem)
        return try load()
    }
    func prepare(_ proposed: TreeSurveyFrame) throws -> TreeSurveyFrame {
        let headers=candidates("frame",type:TreeSurveyFrame.self)
        if let existing=headers.first?.1 {
            if headers.count<2 {try savePair(existing,stem:"frame")}
            return existing
        }
        guard !pairExists("frame"), try recordIDs().isEmpty, try changeIDs().isEmpty else { throw TreeSurveyFailure("既存調査を保護するため新しい基準を上書きできません") }
        try savePair(proposed,stem:"frame")
        return proposed
    }
    func saveDraft(_ draft: TreeDraft) throws { try savePair(draft,stem:"draft") }
    func discardDraft(color: TreeColor, number: String) throws {
        try savePair(TreeDraft(record:nil,numberInput:number,color:color,discarded:true),stem:"draft")
    }
    func save(_ proposed: TreeRecord) throws -> TreeRecord {
        // A direct store client need not have called load(). Never reset the MRU
        // when reopening an existing survey just to edit one record.
        if !speciesHistoryLoaded {_=try load()}
        guard let frame=candidates("frame",type:TreeSurveyFrame.self).first?.1 else { throw TreeSurveyFailure("調査基準が未保存です") }
        try TreeSurveyMath.validate(proposed,frame:frame)
        let stem="tree-"+proposed.id.uuidString
        var record=proposed
        record.species=TreeSpecies.name(proposed.species)
        var nextHistory=speciesHistory
        if let old=candidates(stem,type:TreeRecord.self).first?.1 {
            guard old.geometry==proposed.geometry, old.created==proposed.created else {
                throw TreeSurveyFailure("確定座標・直径・樹高は上書きできません")
            }
            record.creationOrder=old.creationOrder
            record.speciesHistory=old.speciesHistory
            if let history=old.speciesHistory,history.sequence>nextHistory.sequence {nextHistory=history}
        } else {
            guard !pairExists(stem) else { throw TreeSurveyFailure("既存の記録ファイルを保護しています") }
            record.creationOrder=highestCreationOrder+1
            record.speciesHistory=nil
        }
        if let name=record.species {
            guard nextHistory.sequence<Int.max else {throw TreeSurveyFailure("樹種履歴を更新できません。入力は保持してください")}
            nextHistory=TreeSpeciesHistory(sequence:nextHistory.sequence+1,names:TreeSpecies.recent([name]+nextHistory.names))
            record.speciesHistory=nextHistory
        }
        try savePair(record,stem:stem)
        highestCreationOrder=max(highestCreationOrder,record.creationOrder)
        speciesHistory=nextHistory
        return record
    }

    /// Own transaction temp files are retained on failure for diagnosis. No user
    /// records are removed. Atomic rename replaces only this store's designated slot.
    static func durableWrite(_ data: Data, to destination: URL, hook: ((String) throws -> Void)? = nil) throws {
        let directory=destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let temporary=directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).pending")
        try hook?("before-open")
        let fd=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL,mode_t(0o600))
        guard fd>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset=0
            while offset<bytes.count {
                let written=write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if written<0 && errno==EINTR { continue }
                guard written>0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(fd)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        #if canImport(Darwin)
        if fcntl(fd,F_FULLFSYNC)<0, errno != EINVAL, errno != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        #endif
        try hook?("after-file-sync")
        guard rename(temporary.path,destination.path)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        try hook?("after-rename")
        let parent=open(directory.path,O_RDONLY)
        guard parent>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { close(parent) }
        guard fsync(parent)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        try hook?("after-directory-sync")
    }
}
