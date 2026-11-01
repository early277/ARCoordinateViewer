import Foundation
import CryptoKit
import Darwin

/// Reusable coordinate snapshots, independent of scan records and GCP bindings.
/// .ready means the manifest is complete; opening also verifies payload bytes.
enum PCCoordinateSetState:String,Codable {case ready,incomplete,unreadable}
struct PCCoordinateSetSummary:Codable,Equatable,Identifiable {
    var schema=1
    var id:UUID
    var name:String
    var reference:PCControlReference
    var pointCount:Int
    var payloadBytes:Int64
    var createdAt:Date
    var lastUsedAt:Date
    var fingerprint:String
    var payloadHash:String
    var state=PCCoordinateSetState.ready
    var isUsable:Bool {state == .ready}
    var status:String {
        switch state {
        case .ready:return "アプリ内保存済み"
        case .incomplete:return "保存未完了・元の入力を保持しています"
        case .unreadable:return "読み取り不可・元の入力を保持しています"
        }
    }
}
struct PCCoordinateSet:Equatable {var summary:PCCoordinateSetSummary;var points:[PCKnownPoint]}
enum PCCoordinateLibraryFailure:Error,LocalizedError {
    case invalid,corrupt,incomplete,unsafePath,capacity,notFound
    var errorDescription:String? {
        switch self {
        case .invalid:return "座標セットの点名・座標・系番号・高さ基準を確認してください"
        case .corrupt:return "保存した座標セットの整合性を確認できません。原本は保持しています"
        case .incomplete:return "座標セットの保存が未完了です。元の入力は保持しています"
        case .unsafePath:return "座標セットの安全な保存先を確認できません"
        case .capacity:return "座標セットの保存上限です（5,000点・16MiB）"
        case .notFound:return "保存した座標セットが見つかりません"
        }
    }
}

/// Every public operation is serialized across instances. Call from a background
/// queue. Fixed UUID paths and no-follow directory descriptors never follow a
/// source filename, imported path, or symbolic link. No operation deletes data.
final class PCCoordinateLibrary:@unchecked Sendable {
    static let maximumPoints=5_000
    static let maximumPayloadBytes=16*1024*1024
    static let maximumSets=10_000
    private static let lock=NSRecursiveLock()
    private static let format=Data("PointCloudCoordinateSets/1\n".utf8)
    let root:URL
    let freeBytes:()->Int64
    let hook:(String)throws->Void
    private let anchor:URL?
    private let components:[String]
    init(root:URL,freeBytes:(()->Int64)?=nil,hook:@escaping(String)throws->Void={_ in}) {
        let normalized=Self.alias(root.standardizedFileURL)
        self.root=normalized;self.hook=hook
        let choices=[URL(fileURLWithPath:NSHomeDirectory()),URL(fileURLWithPath:NSTemporaryDirectory()),URL(fileURLWithPath:"/private/tmp")].map(Self.alias).sorted{$0.path.count>$1.path.count}
        let anchor=choices.first{normalized.path.hasPrefix($0.path+"/")}
        self.anchor=anchor
        self.components=anchor.map{Array(normalized.path.dropFirst($0.path.count+1).split(separator:"/")).map(String.init)} ?? []
        self.freeBytes=freeBytes ?? {Self.availableBytes(near:normalized)}
    }
    private static func alias(_ url:URL)->URL {
        let p=url.path
        if p=="/tmp" || p.hasPrefix("/tmp/") {return URL(fileURLWithPath:"/private/tmp"+p.dropFirst(4),isDirectory:true)}
        if p=="/var" || p.hasPrefix("/var/") {return URL(fileURLWithPath:"/private/var"+p.dropFirst(4),isDirectory:true)}
        return url
    }
    private static func availableBytes(near root:URL)->Int64 {
        var p=root;let fm=FileManager.default
        while !fm.fileExists(atPath:p.path) {let parent=p.deletingLastPathComponent();guard parent.path != p.path else{return 0};p=parent}
        return ((try? fm.attributesOfFileSystem(forPath:p.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
    }
    private static func posix()->Error {POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func timestamp()->Date {Date(timeIntervalSince1970:Date().timeIntervalSince1970)}
    private static func encoder()->JSONEncoder {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];e.dateEncodingStrategy = .secondsSince1970;return e}
    private static func decoder()->JSONDecoder {let d=JSONDecoder();d.dateDecodingStrategy = .secondsSince1970;return d}
    private func directory(create:Bool)throws->Int32? {
        guard let anchor,!components.isEmpty,components.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else {throw PCCoordinateLibraryFailure.unsafePath}
        var fd=open(anchor.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else {throw PCCoordinateLibraryFailure.unsafePath}
        do {
            for component in components {
                var child=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                if child<0,errno==ENOENT {
                    if !create {close(fd);return nil}
                    let made=mkdirat(fd,component,mode_t(0o700))==0
                    guard made || errno==EEXIST else {throw Self.posix()}
                    if made {guard fsync(fd)==0 else {throw Self.posix()}}
                    child=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                }
                guard child>=0 else {throw PCCoordinateLibraryFailure.unsafePath}
                close(fd);fd=child
            }
            return fd
        } catch {close(fd);throw error}
    }
    private static func names(_ fd:Int32)throws->[String] {
        let copied=dup(fd);guard copied>=0 else {throw posix()}
        guard let stream=fdopendir(copied) else {close(copied);throw posix()};defer{closedir(stream)}
        rewinddir(stream);var result:[String]=[]
        while let entry=readdir(stream) {
            var name=entry.pointee.d_name
            let size=MemoryLayout.size(ofValue:name)
            let value=withUnsafePointer(to:&name){$0.withMemoryRebound(to:CChar.self,capacity:size){String(cString:$0)}}
            if value != "." && value != ".." {result.append(value);guard result.count<=maximumSets*2+128 else {throw PCCoordinateLibraryFailure.capacity}}
        }
        return result
    }
    private static func info(_ fd:Int32,_ name:String)throws->stat {
        var s=stat();guard fstatat(fd,name,&s,AT_SYMLINK_NOFOLLOW)==0 else {throw posix()};return s
    }
    private static func child(_ fd:Int32,_ name:String)throws->Int32 {
        let value=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard value>=0 else {throw PCCoordinateLibraryFailure.unsafePath};return value
    }
    private static func read(_ fd:Int32,_ name:String,limit:Int)throws->Data {
        let file=openat(fd,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard file>=0 else {throw PCCoordinateLibraryFailure.corrupt};defer{close(file)}
        var s=stat();guard fstat(file,&s)==0,(s.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG),s.st_size>=0,s.st_size<=limit else {throw PCCoordinateLibraryFailure.corrupt}
        var result=Data();result.reserveCapacity(Int(s.st_size));var buffer=[UInt8](repeating:0,count:min(65536,max(1,Int(s.st_size))))
        while true {
            let n=Darwin.read(file,&buffer,buffer.count)
            if n==0 {break};if n<0 {if errno==EINTR {continue};throw posix()}
            guard result.count+n<=limit else {throw PCCoordinateLibraryFailure.corrupt};result.append(contentsOf:buffer.prefix(n))
        }
        guard result.count==s.st_size else {throw PCCoordinateLibraryFailure.corrupt};return result
    }
    private static func write(_ data:Data,fd:Int32,name:String)throws {
        let file=openat(fd,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode_t(0o600));guard file>=0 else {throw posix()};defer{close(file)}
        try data.withUnsafeBytes {bytes in
            var offset=0
            while offset<data.count {
                let n=Darwin.write(file,bytes.baseAddress!.advanced(by:offset),data.count-offset)
                if n<0 {if errno==EINTR {continue};throw posix()};guard n>0 else {throw POSIXError(.EIO)};offset+=n
            }
        }
        guard fsync(file)==0 else {throw posix()}
    }
    private static func id(_ name:String)->UUID? {UUID(uuidString:name.hasPrefix(".pending-") ? String(name.dropFirst(9)):name)}
    private func format(_ fd:Int32,create:Bool)throws {
        if let existing=try? Self.read(fd,"format.txt",limit:128) {guard existing==Self.format else {throw PCCoordinateLibraryFailure.corrupt};return}
        let names=try Self.names(fd)
        guard create,names.allSatisfy({$0.hasPrefix(".format-")}) else {throw PCCoordinateLibraryFailure.incomplete}
        let pending=".format-"+UUID().uuidString
        try Self.write(Self.format,fd:fd,name:pending)
        guard renameatx_np(fd,pending,fd,"format.txt",UInt32(RENAME_EXCL))==0 else {throw Self.posix()}
        guard fsync(fd)==0 else {throw Self.posix()}
    }
    private static func valid(_ s:PCCoordinateSetSummary,id:UUID)throws {
        guard s.schema==1,s.id==id,s.state == .ready,!s.name.isEmpty,s.name.utf8.count<=512,s.reference.valid,
              s.pointCount>0,s.pointCount<=maximumPoints,s.payloadBytes>0,s.payloadBytes<=maximumPayloadBytes,
              s.createdAt.timeIntervalSince1970.isFinite,s.lastUsedAt.timeIntervalSince1970.isFinite,
              [s.fingerprint,s.payloadHash].allSatisfy({$0.count==64 && $0.allSatisfy{"0123456789abcdef".contains($0)}}) else {throw PCCoordinateLibraryFailure.corrupt}
    }
    private static func summary(_ fd:Int32,id:UUID)throws->PCCoordinateSetSummary {
        let s=try decoder().decode(PCCoordinateSetSummary.self,from:read(fd,"manifest.json",limit:16384));try valid(s,id:id)
        let p=try info(fd,"points.json")
        guard (p.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG),p.st_size==s.payloadBytes else {throw PCCoordinateLibraryFailure.corrupt};return s
    }
    private static func unavailable(_ id:UUID,state:PCCoordinateSetState)->PCCoordinateSetSummary {
        PCCoordinateSetSummary(id:id,name:state == .incomplete ? "保存未完了の座標セット":"読み取り不可の座標セット",reference:PCControlReference(),pointCount:0,payloadBytes:0,createdAt:.distantPast,lastUsedAt:.distantPast,fingerprint:"",payloadHash:"",state:state)
    }
    func list(control:PCWorkControl=PCWorkControl())throws->[PCCoordinateSetSummary] {
        Self.lock.lock();defer{Self.lock.unlock()};try control.check();guard let rootFD=try directory(create:false) else {return []};defer{close(rootFD)}
        try format(rootFD,create:false)
        let names=try Self.names(rootFD);var result:[PCCoordinateSetSummary]=[]
        let groups=Dictionary(grouping:names.compactMap{name in Self.id(name).map{($0,name)}},by:{$0.0})
        for id in groups.keys.sorted(by:{$0.uuidString<$1.uuidString}) {
            try control.check();let items=groups[id]!.map(\.1)
            guard items.count==1 else {result.append(Self.unavailable(id,state:.unreadable));continue}
            let name=items[0]
            if name.hasPrefix(".pending-") {result.append(Self.unavailable(id,state:.incomplete));continue}
            do {let child=try Self.child(rootFD,name);defer{close(child)};result.append(try Self.summary(child,id:id))}
            catch {result.append(Self.unavailable(id,state:.unreadable))}
        }
        guard result.count<=Self.maximumSets else {throw PCCoordinateLibraryFailure.capacity}
        return result.sorted {if $0.isUsable != $1.isUsable{return $0.isUsable};if $0.lastUsedAt != $1.lastUsedAt{return $0.lastUsedAt>$1.lastUsedAt};return $0.id.uuidString<$1.id.uuidString}
    }
    private static func validate(_ points:[PCKnownPoint],reference:PCControlReference,control:PCWorkControl?=nil)throws {
        guard reference.valid,!points.isEmpty,points.count<=maximumPoints,Set(points.map(\.id)).count==points.count else {throw PCCoordinateLibraryFailure.invalid}
        var sources:[SourceKey:IdentityPoint]=[:],bytes=points.count*512
        for p in points {
            try control?.check()
            let name=p.name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard p.finite,p.planeSystem==reference.planeSystem,!name.isEmpty,p.name.utf8.count<=512,
                  p.originalCells.count<=64,(p.reviewedCells?.count ?? 0)<=64 else {throw PCCoordinateLibraryFailure.invalid}
            if !p.sourceID.isEmpty {
                let key=SourceKey(source:p.source,id:p.sourceID),value=IdentityPoint(name:name,north:p.north,east:p.east,height:p.height)
                if let old=sources[key],old != value {throw PCCoordinateLibraryFailure.invalid}
                sources[key]=value
            }
            let strings=[p.name,p.source,p.sourceID,p.importDetails]+p.originalCells+(p.reviewedCells ?? [])+[p.reviewDetails ?? ""]
            for text in strings {
                guard text.utf8.count<=8192 else {throw PCCoordinateLibraryFailure.capacity}
                // Bound JSON escaping before asking the encoder to allocate.
                bytes+=2
                for scalar in text.unicodeScalars {
                    if scalar.value<32 {bytes += [8,9,10,12,13].contains(scalar.value) ? 2:6}
                    else if [34,47,92].contains(scalar.value) {bytes+=2}
                    else if scalar.value==0x2028 || scalar.value==0x2029 {bytes+=6}
                    else {bytes+=scalar.utf8.count}
                    guard bytes<=maximumPayloadBytes else {throw PCCoordinateLibraryFailure.capacity}
                }
            }
        }
    }
    private struct SourceKey:Hashable {var source:String;var id:String}
    private struct IdentityPoint:Codable,Equatable {var name:String;var north:Double;var east:Double;var height:Double?}
    private struct Identity:Codable {var reference:PCControlReference;var points:[IdentityPoint];var localName:String?}
    private static func fingerprint(_ points:[PCKnownPoint],_ reference:PCControlReference,name:String)throws->String {
        let canonical=points.map{IdentityPoint(name:$0.name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping,north:$0.north==0 ? 0:$0.north,east:$0.east==0 ? 0:$0.east,height:$0.height.map{$0==0 ? 0:$0})}.sorted {
            if $0.name != $1.name {return $0.name<$1.name}
            if $0.north != $1.north {return $0.north<$1.north}
            if $0.east != $1.east {return $0.east<$1.east}
            if ($0.height==nil) != ($1.height==nil) {return $0.height==nil}
            return ($0.height ?? 0)<($1.height ?? 0)
        }
        return digest(try encoder().encode(Identity(reference:reference,points:canonical,localName:reference.datum=="任意座標" ? name.precomposedStringWithCanonicalMapping:nil)))
    }
    private func readSet(_ fd:Int32,id:UUID,control:PCWorkControl)throws->PCCoordinateSet {
        let summary=try Self.summary(fd,id:id);try control.check();try hook("read-payload")
        let bytes=try Self.read(fd,"points.json",limit:Self.maximumPayloadBytes);guard Self.digest(bytes)==summary.payloadHash else {throw PCCoordinateLibraryFailure.corrupt}
        let points=try Self.decoder().decode([PCKnownPoint].self,from:bytes);try Self.validate(points,reference:summary.reference,control:control)
        guard points.count==summary.pointCount,try Self.fingerprint(points,summary.reference,name:summary.name)==summary.fingerprint else {throw PCCoordinateLibraryFailure.corrupt}
        try control.check();return PCCoordinateSet(summary:summary,points:points)
    }
    func load(_ id:UUID,control:PCWorkControl=PCWorkControl())throws->PCCoordinateSet {
        Self.lock.lock();defer{Self.lock.unlock()};try control.check();guard let rootFD=try directory(create:false) else {throw PCCoordinateLibraryFailure.notFound};defer{close(rootFD)};try format(rootFD,create:false)
        let matches=try Self.names(rootFD).filter{Self.id($0)==id}
        guard !matches.isEmpty else {throw PCCoordinateLibraryFailure.notFound}
        guard matches.count==1 else {throw PCCoordinateLibraryFailure.corrupt}
        guard !matches[0].hasPrefix(".pending-") else {throw PCCoordinateLibraryFailure.incomplete}
        let fd=try Self.child(rootFD,matches[0]);defer{close(fd)};return try readSet(fd,id:id,control:control)
    }
    private func touch(_ summary:PCCoordinateSetSummary,fd:Int32,control:PCWorkControl)throws->PCCoordinateSetSummary {
        try control.check();var value=summary;value.lastUsedAt=Self.timestamp();let data=try Self.encoder().encode(value),temp=".touch-"+UUID().uuidString
        guard freeBytes()>Int64(data.count)+1_048_576 else {throw PCFailure.storageSpace}
        try Self.write(data,fd:fd,name:temp);try hook("before-touch");try control.check()
        guard renameat(fd,temp,fd,"manifest.json")==0,fsync(fd)==0 else {throw Self.posix()};try hook("after-touch");return value
    }
    func touch(_ id:UUID,control:PCWorkControl=PCWorkControl())throws->PCCoordinateSetSummary {
        Self.lock.lock();defer{Self.lock.unlock()};let value=try load(id,control:control)
        guard let rootFD=try directory(create:false) else {throw PCCoordinateLibraryFailure.notFound};defer{close(rootFD)}
        let matches=try Self.names(rootFD).filter{Self.id($0)==id && !$0.hasPrefix(".pending-")}
        guard matches.count==1 else {throw PCCoordinateLibraryFailure.corrupt}
        let fd=try Self.child(rootFD,matches[0]);defer{close(fd)};return try touch(value.summary,fd:fd,control:control)
    }
    func save(name:String,reference:PCControlReference,points:[PCKnownPoint],control:PCWorkControl=PCWorkControl())throws->PCCoordinateSetSummary {
        Self.lock.lock();defer{Self.lock.unlock()};try control.check();try Self.validate(points,reference:reference,control:control)
        let bytes=try Self.encoder().encode(points);guard bytes.count<=Self.maximumPayloadBytes else {throw PCCoordinateLibraryFailure.capacity}
        let supplied=name.trimmingCharacters(in:.whitespacesAndNewlines)
        let sourceValue=points[0].source.components(separatedBy:" / ")[0]
        let source=sourceValue.isEmpty ? "":URL(fileURLWithPath:sourceValue).lastPathComponent
        let label=String((supplied.isEmpty ? (source.isEmpty ? "座標セット":source):supplied).prefix(128))
        let fingerprint=try Self.fingerprint(points,reference,name:label),hash=Self.digest(bytes)
        let rootFD:Int32
        if let existing=try directory(create:false) {rootFD=existing}
        else {
            guard freeBytes()>Int64(bytes.count)+32*1024*1024 else {throw PCFailure.storageSpace}
            guard let created=try directory(create:true) else {throw PCCoordinateLibraryFailure.unsafePath};rootFD=created
        }
        defer{close(rootFD)};try format(rootFD,create:true)
        let names=try Self.names(rootFD)
        let idCounts=Dictionary(grouping:names.compactMap(Self.id),by:{$0}).mapValues(\.count)
        // Read only a matching candidate's payload. Preserve its original IDs,
        // provenance and name; importing the same rows never creates new sets.
        for item in names.sorted() {
            try control.check();guard let id=Self.id(item),let fd=try? Self.child(rootFD,item) else {continue};defer{close(fd)}
            guard let summary=try? Self.summary(fd,id:id),summary.fingerprint==fingerprint else {continue}
            guard idCounts[id]==1 else {throw PCCoordinateLibraryFailure.corrupt}
            _=try readSet(fd,id:id,control:control)
            if item.hasPrefix(".pending-") {
                try hook("before-publish");try control.check()
                guard renameatx_np(rootFD,item,rootFD,id.uuidString,UInt32(RENAME_EXCL))==0,fsync(rootFD)==0 else {throw Self.posix()}
            }
            return try touch(summary,fd:fd,control:control)
        }
        guard names.filter({Self.id($0) != nil}).count<Self.maximumSets else {throw PCCoordinateLibraryFailure.capacity}
        guard freeBytes()>Int64(bytes.count)+32*1024*1024 else {throw PCFailure.storageSpace}
        let id=UUID(),pending=".pending-"+id.uuidString
        guard mkdirat(rootFD,pending,mode_t(0o700))==0 else {throw Self.posix()}
        let fd=try Self.child(rootFD,pending);defer{close(fd)}
        try hook("before-payload");try Self.write(bytes,fd:fd,name:"points.json");try hook("after-payload");try control.check()
        let now=Self.timestamp(),summary=PCCoordinateSetSummary(id:id,name:label,reference:reference,pointCount:points.count,payloadBytes:Int64(bytes.count),createdAt:now,lastUsedAt:now,fingerprint:fingerprint,payloadHash:hash)
        try Self.valid(summary,id:id);try hook("before-manifest");try Self.write(Self.encoder().encode(summary),fd:fd,name:"manifest.json");guard fsync(fd)==0 else {throw Self.posix()};try hook("after-manifest");try control.check()
        try hook("before-publish");try control.check();guard renameatx_np(rootFD,pending,rootFD,id.uuidString,UInt32(RENAME_EXCL))==0,fsync(rootFD)==0 else {throw Self.posix()};try hook("after-publish")
        return summary
    }
}
