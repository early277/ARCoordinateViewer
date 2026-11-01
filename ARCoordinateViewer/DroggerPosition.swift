import Foundation
import simd

/// Receive time and measurement UTC are deliberately distinct. Heights never drive AR Y.
struct DroggerFix: Equatable {
    var utc: Date
    var receivedAt: Date
    var receivedUptime: TimeInterval
    var latitude: Double
    var longitude: Double
    var quality: Int
    var satellites: Int
    var hdop: Double
    var horizontalSigma: Double
    var meanSeaLevelHeight: Double?
    var geoidSeparation: Double?
    var correctionAge: Double?
    var ellipsoidHeight: Double? {
        guard let h=meanSeaLevelHeight, let n=geoidSeparation else { return nil }; return h+n
    }
    var reliable: Bool {
        quality == 4 && satellites >= 6 && hdop.isFinite && hdop > 0 && hdop <= 2 &&
        horizontalSigma.isFinite && horizontalSigma > 0 && horizontalSigma <= 0.10 &&
        (correctionAge.map { $0.isFinite && $0 >= 0 && $0 <= 10 } ?? true)
    }
}

/// Bounded streaming NMEA parser: split/coalesced BLE notifications, checksums and lost bytes.
struct DroggerNMEA {
    enum Event { case fix(DroggerFix), hold(String) }
    private var bytes: [UInt8] = []
    private struct Epoch {
        var seconds: Double
        var gga: [String]?
        var sigma: Double?
        var receivedAt: Date
        var uptime: Double
    }
    private var epochs: [Int:Epoch] = [:]
    private var anchor: (date:Date,received:Date)?
    private var emitted: Date?
    private(set) var rejected = 0
    mutating func feed(_ data:Data, receivedAt:Date, uptime:Double) -> [Event] {
        var events: [Event] = []
        for byte in data {
            if byte == 36 { bytes=[byte]; continue }
            guard !bytes.isEmpty else { continue }
            bytes.append(byte)
            if bytes.count > 512 { bytes=[]; rejected+=1; events.append(.hold("受信データ不正")); continue }
            guard byte == 10 else { continue }
            let line=bytes; bytes=[]
            guard line.count >= 7, line[line.count-2] == 13,
                  let star=line.firstIndex(of:42), star == line.count-5,
                  let checksum=UInt8(String(decoding:line[(star+1)..<(star+3)],as:UTF8.self),radix:16),
                  line[1..<star].reduce(UInt8(0),^) == checksum,
                  line[1..<star].allSatisfy({ $0 >= 32 && $0 < 127 }) else {
                rejected+=1; events.append(.hold("チェックサム・受信データ不正")); continue
            }
            let fields=String(decoding:line[1..<star],as:UTF8.self).components(separatedBy:",")
            guard let header=fields.first, header.count == 5, ["GP","GN","GL","GA","GB","GQ"].contains(String(header.prefix(2))) else { continue }
            let type=String(header.suffix(3))
            guard ["GGA","GST","RMC"].contains(type) else { continue }
            guard fields.count > 1, let seconds=Self.seconds(fields[1]) else { events.append(.hold("測位時刻不明")); continue }
            epochs=epochs.filter { receivedAt.timeIntervalSince($0.value.receivedAt) < 2 }
            if type == "RMC" {
                guard fields.count >= 10, fields[2] == "A", let date=Self.date(fields[9],seconds:seconds) else {
                    anchor=nil; epochs=[:]; events.append(.hold("有効なGNSS日付待ち")); continue
                }
                anchor=(date,receivedAt)
            } else {
                let key=Int((seconds*1000).rounded())
                var epoch=epochs[key] ?? Epoch(seconds:seconds,receivedAt:receivedAt,uptime:uptime)
                if type == "GGA" {
                    guard fields.count >= 15, Int(fields[6]) == 4 else {
                        epochs=[:]; events.append(.hold("RTK FIX待ち")); continue
                    }
                    guard Self.coordinate(fields[2],hemisphere:fields[3],latitude:true) != nil,
                          Self.coordinate(fields[4],hemisphere:fields[5],latitude:false) != nil,
                          Int(fields[7]) != nil, let hdop=Double(fields[8]), hdop.isFinite,
                          fields[13].isEmpty || Double(fields[13]).map({ $0.isFinite && $0 >= 0 }) == true else {
                        epochs=[:]; events.append(.hold("GNSS値が不正・補正保留")); continue
                    }
                    epoch.gga=fields; epoch.receivedAt=receivedAt; epoch.uptime=uptime
                } else if fields.count >= 9, let lat=Double(fields[6]), let lon=Double(fields[7]),
                          lat.isFinite, lon.isFinite, lat > 0, lon > 0 {
                    epoch.sigma=hypot(lat,lon)
                } else { events.append(.hold("GNSS精度情報不明")); continue }
                epochs[key]=epoch
                if epochs.count > 12, let oldest=epochs.min(by: { $0.value.uptime < $1.value.uptime })?.key { epochs.removeValue(forKey:oldest) }
            }
            guard let anchor, abs(receivedAt.timeIntervalSince(anchor.received)) <= 2 else { continue }
            for key in epochs.keys.sorted() {
                guard let epoch=epochs[key], let g=epoch.gga, let sigma=epoch.sigma,
                      let latitude=Self.coordinate(g[2],hemisphere:g[3],latitude:true),
                      let longitude=Self.coordinate(g[4],hemisphere:g[5],latitude:false),
                      let quality=Int(g[6]), let satellites=Int(g[7]), let hdop=Double(g[8]) else { continue }
                let day=Calendar.utc.startOfDay(for:anchor.date)
                let candidate=day.addingTimeInterval(epoch.seconds)
                let date=[candidate.addingTimeInterval(-86400),candidate,candidate.addingTimeInterval(86400)].min { abs($0.timeIntervalSince(anchor.date)) < abs($1.timeIntervalSince(anchor.date)) }!
                guard abs(date.timeIntervalSince(anchor.date)) <= 2 else { continue }
                epochs.removeValue(forKey:key)
                guard emitted.map({ date > $0 }) ?? true else { continue }
                emitted=date
                func finite(_ s:String) -> Double? { Double(s).flatMap { $0.isFinite ? $0 : nil } }
                let fix=DroggerFix(utc:date,receivedAt:epoch.receivedAt,receivedUptime:epoch.uptime,latitude:latitude,longitude:longitude,quality:quality,satellites:satellites,hdop:hdop,horizontalSigma:sigma,meanSeaLevelHeight:g[10] == "M" ? finite(g[9]) : nil,geoidSeparation:g[12] == "M" ? finite(g[11]) : nil,correctionAge:finite(g[13]))
                events.append(.fix(fix))
            }
        }
        return events
    }
    private static func seconds(_ value:String) -> Double? {
        guard value.count >= 6, let number=Double(value), number.isFinite, number >= 0 else { return nil }
        let hour=Int(number/10000), minute=Int(number/100)%100, second=number-Double(hour*10000+minute*100)
        guard hour < 24, minute < 60, second >= 0, second < 60 else { return nil }
        return Double(hour*3600+minute*60)+second
    }
    private static func date(_ value:String,seconds:Double) -> Date? {
        guard value.count == 6, value.allSatisfy(\.isNumber), let day=Int(value.prefix(2)), let month=Int(value.dropFirst(2).prefix(2)), let year=Int(value.suffix(2)) else { return nil }
        let components=DateComponents(year:2000+year,month:month,day:day)
        guard let date=Calendar.utc.date(from:components), Calendar.utc.component(.month,from:date)==month,
              Calendar.utc.component(.day,from:date)==day else { return nil }
        return date.addingTimeInterval(seconds)
    }
    private static func coordinate(_ value:String,hemisphere:String,latitude:Bool) -> Double? {
        guard let number=Double(value), number.isFinite, number >= 0 else { return nil }
        let degrees=floor(number/100), minutes=number-degrees*100, limit=latitude ? 90.0 : 180.0
        guard minutes < 60, degrees+minutes/60 <= limit,
              (latitude ? ["N","S"] : ["E","W"]).contains(hemisphere) else { return nil }
        return (degrees+minutes/60)*(["S","W"].contains(hemisphere) ? -1 : 1)
    }
}
private extension Calendar {
    static var utc:Calendar { var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!;return c }
}

struct DroggerFusion {
    static func renderedPan(east:Double,north:Double,heading:Double,offset:SIMD3<Float>) -> SIMD2<Double> {
        let a=Float(heading * .pi/180), c=cos(a), s=sin(a)
        return SIMD2(east-Double(offset.x*c-offset.z*s),north+Double(offset.x*s+offset.z*c))
    }
    struct Pose { var time:Double; var antenna:SIMD3<Float>; var root:simd_float4x4 }
    private var poses: [Pose] = []
    private var target: SIMD3<Float>?
    private var previousCandidate: SIMD3<Float>?
    private var stableCount=0
    private var lastGood:Double?
    private var lastMeasurement:Double?
    private var wallOffset:Double?
    private var lastStep:Double?
    private(set) var offset = SIMD3<Float>.zero
    private(set) var status = "補正停止"
    mutating func hold(_ reason:String) { target=nil; stableCount=0; previousCandidate=nil; status=reason }
    mutating func reset(clearOffset:Bool) {
        poses=[]; lastGood=nil; lastMeasurement=nil; lastStep=nil; wallOffset=nil
        if clearOffset { offset = .zero }
        hold("時刻の合うFIX待ち")
    }
    mutating func record(time:Double,camera:simd_float4x4,root:simd_float4x4,lever:SIMD3<Float>,normal:Bool) {
        guard normal, time.isFinite else { poses=[]; hold("AR追跡待ち"); return }
        if let last=poses.last, time <= last.time { return }
        let a=camera*SIMD4(lever,1)
        guard [a.x,a.y,a.z].allSatisfy(\.isFinite) else { hold("取付位置不正"); return }
        poses.append(Pose(time:time,antenna:SIMD3(a.x,a.y,a.z),root:root))
        poses.removeAll { time-$0.time > 3 }
        if poses.count > 400 { poses.removeFirst(poses.count-400) }
    }
    mutating func accept(_ fix:DroggerFix,localAntenna:SIMD3<Float>) {
        guard fix.reliable else { hold("FIX・精度条件待ち"); return }
        let age=fix.receivedAt.timeIntervalSince(fix.utc)
        guard age >= 0, age <= 1.5 else { hold("GNSS時刻・遅延を確認"); return }
        let clock=fix.receivedAt.timeIntervalSince1970-fix.receivedUptime
        if let old=wallOffset, abs(old-clock)>0.10 { reset(clearOffset:false); wallOffset=clock; hold("端末時計が変化・再観測待ち"); return }
        wallOffset=clock
        let time=fix.receivedUptime-age
        guard lastMeasurement.map({ time > $0 }) ?? true else { hold("重複・逆順の測位時刻"); return }
        lastMeasurement=time
        guard let upper=poses.firstIndex(where: { $0.time >= time }), upper > 0 else { hold("測位時刻のAR姿勢待ち"); return }
        let a=poses[upper-1], b=poses[upper]
        guard b.time-a.time <= 0.15, time-a.time >= 0 else { hold("AR姿勢の時間差が大きい"); return }
        let fraction=Float((time-a.time)/(b.time-a.time))
        let antenna=a.antenna+(b.antenna-a.antenna)*fraction
        let expected=(a.root*SIMD4(localAntenna,1))*(1-fraction)+(b.root*SIMD4(localAntenna,1))*fraction
        var candidate=antenna-SIMD3(expected.x,expected.y,expected.z); candidate.y=0
        guard [candidate.x,candidate.z].allSatisfy(\.isFinite), simd_length(candidate-offset) <= 3 else { hold("位置差が大きい・位置合わせを確認"); return }
        if let previous=previousCandidate, simd_length(candidate-previous)>0.25 { hold("GNSS外れ値・補正保留"); return }
        previousCandidate=candidate; stableCount+=1
        guard stableCount >= 3 else { status="連続FIXを確認中"; return }
        target=candidate; lastGood=fix.receivedUptime; status="水平位置を補正中"
    }
    mutating func step(time:Double) -> SIMD3<Float> {
        defer { lastStep=time }
        guard let target, let lastGood, time-lastGood >= -0.000001, time-lastGood <= 1.5 else {
            if target != nil { hold("GNSS更新待ち・補正保留") }; return offset
        }
        let dt=max(0,min(0.1,time-(lastStep ?? time)))
        var delta=(target-offset)*Float(1-exp(-dt/3))
        let length=simd_length(delta), maximum=Float(dt*0.15)
        if length>maximum, length>0 { delta *= maximum/length }
        offset+=delta; offset.y=0
        return offset
    }
}
