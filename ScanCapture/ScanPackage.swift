import Foundation
import Darwin

struct ScanPrototypeIdentity:Codable,Equatable {
    var version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "開発"
    var build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "開発"
    var label:String {"スキャン試作 · \(version) build\(build)"}
}
enum ScanPackageFailure:Error {
    case corrupt,collision,capacity
    var message:String {
        switch self {
        case .corrupt:return "出力パッケージの整合を確認できません"
        case .collision:return "同名ファイルを保持しました。保存の準備を再実行してください"
        case .capacity:return "出力パッケージの大きさまたはファイル数が上限を超えています"
        }
    }
}
struct ScanFilesRequest:Identifiable {let id=UUID();var url:URL}
enum ScanFilesOutcome {case saved,cancelled,failed(String)}
struct ScanPackageMetadata:Codable,Equatable {
    struct Entry:Codable,Equatable {var name:String;var bytes:Int;var checksum:UInt64}
    var schema=1
    var prototype=true
    var identity:ScanPrototypeIdentity
    var sessionID:UUID
    var kind:String
    var units="metres"
    var coordinates="ARKit local Y-up; separate unregistered epochs; no accuracy guarantee"
    var files:[Entry]
}
/// Own minimal ZIP stored-method codec. No compression, encryption, ZIP64 or external dependency.
/// A single flat folder preserves the existing OBJ/MTL/PNG relative references.
enum ScanStoredZIP {
    static let maximumBytes=ScanShapeExport.maximumBytes+256*1024
    private static let crcTable:[UInt32]=(0..<256).map {n in
        var value=UInt32(n);for _ in 0..<8 {value=(value>>1)^((value&1)==1 ? 0xedb88320:0)};return value
    }
    static func crc(_ data:Data)->UInt32 {var c=UInt32.max;for b in data {c=(c>>8)^crcTable[Int((c^UInt32(b))&255)]};return c^UInt32.max}
    private static func checkedCRC(_ data:Data,control:ScanExportControl?) throws -> UInt32 {
        guard let control else {return crc(data)}
        var c=UInt32.max
        try data.withUnsafeBytes {(bytes:UnsafeRawBufferPointer) in
            for offset in stride(from:0,to:bytes.count,by:65536) {
                try control.check()
                for i in offset..<min(bytes.count,offset+65536) {let b=bytes[i];c=(c>>8)^crcTable[Int((c^UInt32(b))&255)]}
            }
        }
        return c^UInt32.max
    }
    static func safeName(_ name:String)->Bool {
        let parts=name.split(separator:"/",omittingEmptySubsequences:false)
        return parts.count==2 && parts.allSatisfy {p in !p.isEmpty && p != "." && p != ".." && p.utf8.count<=180 && p.utf8.allSatisfy {b in (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || [45,46,95].contains(b)}}
    }
    static func encode(_ files:[String:Data])->Data? {try? encode(files,control:nil)}
    static func encode(_ files:[String:Data],control:ScanExportControl?) throws -> Data? {
        guard !files.isEmpty,files.count<=104,files.keys.allSatisfy(safeName),files.values.reduce(0,{$0+$1.count})<=maximumBytes-65536 else {return nil}
        var output=Data(),central=Data()
        func u16(_ x:Int,_ data:inout Data) {var v=UInt16(x).littleEndian;withUnsafeBytes(of:&v) {data.append(contentsOf:$0)}}
        func u32(_ x:UInt32,_ data:inout Data) {var v=x.littleEndian;withUnsafeBytes(of:&v) {data.append(contentsOf:$0)}}
        for name in files.keys.sorted() {
            let value=files[name]!,bytes=Data(name.utf8),checksum=try checkedCRC(value,control:control),offset=output.count
            u32(0x04034b50,&output);for n in [20,0x800,0,0,33] {u16(n,&output)}
            u32(checksum,&output);u32(UInt32(value.count),&output);u32(UInt32(value.count),&output);u16(bytes.count,&output);u16(0,&output);output.append(bytes);output.append(value)
            u32(0x02014b50,&central);for n in [20,20,0x800,0,0,33] {u16(n,&central)}
            u32(checksum,&central);u32(UInt32(value.count),&central);u32(UInt32(value.count),&central)
            for n in [bytes.count,0,0,0,0] {u16(n,&central)};u32(0,&central);u32(UInt32(offset),&central);central.append(bytes)
        }
        let offset=output.count;output.append(central);u32(0x06054b50,&output)
        for n in [0,0,files.count,files.count] {u16(n,&output)};u32(UInt32(central.count),&output);u32(UInt32(offset),&output);u16(0,&output)
        return output.count<=maximumBytes ? output:nil
    }
    /// Strictly reads our bounded stored ZIP profile; never extracts arbitrary paths.
    static func decode(_ data:Data,control:ScanExportControl?=nil) throws -> [String:Data] {
        guard data.count>=22,data.count<=maximumBytes else {throw ScanPackageFailure.capacity}
        func word(_ offset:Int,_ count:Int)throws->UInt32 {
            guard offset>=0,offset<=data.count-count else {throw ScanPackageFailure.corrupt}
            return (0..<count).reduce(0) {$0|UInt32(data[offset+$1])<<($1*8)}
        }
        struct Record {var offset:Int;var size:Int;var crc:UInt32}
        var files:[String:Data]=[:],records:[String:Record]=[:],position=0,total=0
        while try word(position,4)==0x04034b50 {
            guard files.count<104,try word(position+4,2)==20,try word(position+6,2)==0x800,try word(position+8,2)==0,try word(position+10,2)==0,try word(position+12,2)==33,try word(position+28,2)==0 else {throw ScanPackageFailure.corrupt}
            let checksum=try word(position+14,4),size=Int(try word(position+18,4)),length=Int(try word(position+26,2)),start=position+30
            guard size==Int(try word(position+22,4)),length>0,length<=361,start<=data.count-length,size<=maximumBytes-total,start+length<=data.count-size,let name=String(data:data.subdata(in:start..<start+length),encoding:.utf8),safeName(name),files[name]==nil else {throw ScanPackageFailure.corrupt}
            let value=data.subdata(in:start+length..<start+length+size);guard try checkedCRC(value,control:control)==checksum else {throw ScanPackageFailure.corrupt}
            files[name]=value;records[name]=Record(offset:position,size:size,crc:checksum);total+=size;position=start+length+size
        }
        let centralOffset=position;var seen=Set<String>()
        while try word(position,4)==0x02014b50 {
            guard try word(position+4,2)==20,try word(position+6,2)==20,try word(position+8,2)==0x800,try word(position+10,2)==0,try word(position+12,2)==0,try word(position+14,2)==33 else {throw ScanPackageFailure.corrupt}
            let length=Int(try word(position+28,2)),start=position+46
            guard length>0,length<=361,start<=data.count-length,let name=String(data:data.subdata(in:start..<start+length),encoding:.utf8),seen.insert(name).inserted,let record=records[name],try word(position+16,4)==record.crc,Int(try word(position+20,4))==record.size,Int(try word(position+24,4))==record.size,Int(try word(position+42,4))==record.offset else {throw ScanPackageFailure.corrupt}
            for offset in [30,32,34,36] {guard try word(position+offset,2)==0 else {throw ScanPackageFailure.corrupt}};guard try word(position+38,4)==0 else {throw ScanPackageFailure.corrupt}
            position=start+length
        }
        guard !files.isEmpty,seen.count==files.count,try word(position,4)==0x06054b50,try word(position+4,2)==0,try word(position+6,2)==0,Int(try word(position+8,2))==files.count,Int(try word(position+10,2))==files.count,Int(try word(position+12,4))==position-centralOffset,Int(try word(position+16,4))==centralOffset,try word(position+20,2)==0,position+22==data.count else {throw ScanPackageFailure.corrupt}
        return files
    }
}

enum ScanPackage {
    static func safe(_ url:URL)throws {
        guard url.isFileURL,url.standardizedFileURL.path==url.resolvingSymlinksInPath().standardizedFileURL.path else {throw ScanFailure.foreignPath}
    }
    static func allowed(_ name:String,kind:String)->Bool {
        if ["manifest.json","gcp.json","gcp.csv"].contains(name) {return true}
        if kind=="shape" {return ["geometry.json","geometry.obj"].contains(name) || uuidFile(name,prefix:"geometry-",suffix:".obj")}
        return name==(kind=="surface" ? "surface.json":"texture.json") || uuidFile(name,prefix:"raw-",suffix:".obj") || uuidFile(name,prefix:"corrected-",suffix:".obj") || uuidFile(name,prefix:"materials-",suffix:".mtl") || uuidFile(name,prefix:"texture-",suffix:".png")
    }
    private static func uuidFile(_ name:String,prefix:String,suffix:String)->Bool {
        name.hasPrefix(prefix) && name.hasSuffix(suffix) && name.count==prefix.count+36+suffix.count && UUID(uuidString:String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }
    static func make(source:URL,sessionID:UUID,root:URL,identity:ScanPrototypeIdentity=ScanPrototypeIdentity(),identifier:UUID=UUID(),freeBytes:()->Int64,control:ScanExportControl?=nil,hook:((String)throws->Void)?=nil)throws->URL {
        try control?.check("ZIPを準備",fraction:0.85);try safe(source);try safe(root)
        let manifestURL=source.appendingPathComponent("manifest.json");try safe(manifestURL)
        guard ((try manifestURL.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max) < 65536 else {throw ScanPackageFailure.capacity}
        let manifestData=try Data(contentsOf:manifestURL),manifest=try JSONDecoder().decode(ScanOutput.Manifest.self,from:manifestData)
        guard manifest.schema==1,manifest.units=="metres" else {throw ScanPackageFailure.corrupt}
        let kind:String
        if manifest.files.contains(where:{$0.name=="surface.json"}) {kind="surface";guard try ScanSurfaceExport.read(source,control:control).sessionID==sessionID else {throw ScanPackageFailure.corrupt}}
        else if manifest.files.contains(where:{$0.name=="texture.json"}) {kind="texture";guard try ScanTextureExport.read(source).sessionID==sessionID else {throw ScanPackageFailure.corrupt}}
        else {kind="shape";guard try ScanOutput.read(source).sessionID==sessionID else {throw ScanPackageFailure.corrupt}}
        guard manifest.files.allSatisfy({allowed($0.name,kind:kind)}) else {throw ScanFailure.foreignPath}
        guard freeBytes()>=Int64(512*1024*1024+ScanStoredZIP.maximumBytes*2) else {throw ScanFailure.lowSpace}
        var files=["manifest.json":manifestData],total=manifestData.count
        for entry in manifest.files {
            try control?.check()
            let url=source.appendingPathComponent(entry.name);try safe(url)
            guard entry.bytes>0,entry.bytes<=ScanShapeExport.maximumBytes-total,(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize==entry.bytes else {throw ScanPackageFailure.capacity}
            let data=try Data(contentsOf:url);guard GCPStore.checksum(data)==entry.checksum else {throw ScanPackageFailure.corrupt};files[entry.name]=data;total+=data.count
        }
        let gcp=try JSONDecoder().decode(ScanGCPDocument.self,from:files["gcp.json"]!);guard gcp.raw.id==sessionID else {throw ScanPackageFailure.corrupt}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let metadata=ScanPackageMetadata(identity:identity,sessionID:sessionID,kind:kind,files:files.keys.sorted().map {ScanPackageMetadata.Entry(name:$0,bytes:files[$0]!.count,checksum:GCPStore.checksum(files[$0]!))})
        files["package.json"]=try encoder.encode(metadata)
        let limits:String
        if kind=="surface" {let doc=try JSONDecoder().decode(ScanSurfaceDocument.self,from:files["surface.json"]!);limits=doc.limitations.joined(separator:"\n")}
        else if kind=="texture" {let doc=try JSONDecoder().decode(ScanTextureDocument.self,from:files["texture.json"]!);limits=doc.limitations.joined(separator:"\n")}
        else {let doc=try JSONDecoder().decode(ScanShapeDocument.self,from:files["geometry.json"]!);limits=doc.limitations.joined(separator:"\n")}
        files["README.txt"]=Data(("\(identity.label)\n試作・実機精度は未検証\n単位: m / ARKitローカル右手系・Y上向き。区間/世代は未結合。\nZIPを展開し、OBJ・MTL・PNGを同じフォルダに置いたまま開いてください。\n画像付き出力のrawは補正前、correctedは補正済み。形状のみのgeometry OBJの補正状態はgeometry.jsonを参照。補正を二重適用しないでください。補正量が0のsurface出力はraw/correctedが同じOBJを参照します。\n形状のみの場合、テクスチャ画像は含みません。GCP原観測と補正journalはgcp.json、要約はgcp.csvです。\n灰色面・穴・未観測領域は未確認です。10cm精度や完全な被覆は保証しません。\nこれは出力用派生データです。原画像・収録メッシュの全履歴はアプリ内の元記録に保持されます。\n元記録はこの保存操作で移動・削除しません。\nSession: \(sessionID.uuidString)\n\nLimitations:\n"+limits+"\n").utf8)
        let folder="ARScan-Prototype-"+identifier.uuidString
        try control?.check("ZIPを作成",fraction:0.9)
        guard let zip=try ScanStoredZIP.encode(Dictionary(uniqueKeysWithValues:files.map {(folder+"/"+$0.key,$0.value)}),control:control) else {throw ScanPackageFailure.capacity}
        try control?.check()
        guard try ScanStoredZIP.decode(zip,control:control)==Dictionary(uniqueKeysWithValues:files.map {(folder+"/"+$0.key,$0.value)}) else {throw ScanPackageFailure.corrupt}
        try control?.check()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let build=identity.build.utf8.allSatisfy({(48...57).contains($0)}) && !identity.build.isEmpty ? identity.build:"dev"
        let final=root.appendingPathComponent("ARScan-Prototype-b\(build)-\(identifier.uuidString).zip"),pending=root.appendingPathComponent(".pending-"+identifier.uuidString)
        guard !FileManager.default.fileExists(atPath:final.path) else {throw ScanPackageFailure.collision}
        let fd=open(pending.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode_t(0o600));guard fd>=0 else {throw ScanPackageFailure.collision};defer {close(fd)}
        try hook?("created-pending")
        try zip.withUnsafeBytes {p in var offset=0;while offset<p.count {try control?.check();let n=Darwin.write(fd,p.baseAddress!.advanced(by:offset),min(1024*1024,p.count-offset));if n<0 && errno==EINTR {continue};guard n>0 else {throw POSIXError(.EIO)};offset+=n}}
        guard fsync(fd)==0 else {throw POSIXError(.EIO)}
        if fcntl(fd,F_FULLFSYNC)<0,errno != EINVAL,errno != ENOTSUP {throw POSIXError(.EIO)}
        try hook?("after-write")
        guard freeBytes()>=Int64(512*1024*1024+zip.count) else {throw ScanFailure.lowSpace}
        guard renameatx_np(AT_FDCWD,pending.path,AT_FDCWD,final.path,UInt32(RENAME_EXCL))==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        let directory=open(root.path,O_RDONLY|O_NOFOLLOW);guard directory>=0 else {throw POSIXError(.EIO)};defer {close(directory)};guard fsync(directory)==0 else {throw POSIXError(.EIO)}
        try hook?("after-publish");try control?.check("ZIPを最終確認",fraction:0.97);_=try read(final,control:control);return final
    }
    static func read(_ url:URL,control:ScanExportControl?=nil)throws->ScanPackageMetadata {
        try control?.check();try safe(url);guard ((try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max) <= ScanStoredZIP.maximumBytes else {throw ScanPackageFailure.capacity}
        let zipped=try ScanStoredZIP.decode(Data(contentsOf:url),control:control),folders=Set(zipped.keys.compactMap {$0.split(separator:"/").first.map(String.init)})
        guard folders.count==1,let folder=folders.first,folder.hasPrefix("ARScan-Prototype-"),UUID(uuidString:String(folder.dropFirst(17))) != nil else {throw ScanPackageFailure.corrupt}
        let files=Dictionary(uniqueKeysWithValues:zipped.map {(String($0.key.dropFirst(folder.count+1)),$0.value)})
        guard let header=files["package.json"],let explanation=files["README.txt"],!explanation.isEmpty else {throw ScanPackageFailure.corrupt}
        let metadata=try JSONDecoder().decode(ScanPackageMetadata.self,from:header)
        guard metadata.schema==1,metadata.prototype,metadata.units=="metres",["shape","texture","surface"].contains(metadata.kind),Set(metadata.files.map(\.name)).count==metadata.files.count,Set(files.keys)==Set(metadata.files.map(\.name)).union(["package.json","README.txt"]) else {throw ScanPackageFailure.corrupt}
        for entry in metadata.files {try control?.check();guard allowed(entry.name,kind:metadata.kind),let value=files[entry.name],value.count==entry.bytes,GCPStore.checksum(value)==entry.checksum else {throw ScanPackageFailure.corrupt}}
        guard let source=files["manifest.json"],let reference=files["gcp.json"] else {throw ScanPackageFailure.corrupt}
        let manifest=try JSONDecoder().decode(ScanOutput.Manifest.self,from:source),gcp=try JSONDecoder().decode(ScanGCPDocument.self,from:reference)
        guard manifest.schema==1,manifest.units=="metres",gcp.raw.id==metadata.sessionID,Set(manifest.files.map(\.name)).union(["manifest.json"])==Set(metadata.files.map(\.name)) else {throw ScanPackageFailure.corrupt}
        try ScanCorrection.validate(gcp.corrections,raw:gcp.raw)
        for entry in manifest.files {try control?.check();guard let value=files[entry.name],value.count==entry.bytes,GCPStore.checksum(value)==entry.checksum else {throw ScanPackageFailure.corrupt}}
        return metadata
    }
}
