import Foundation
import CoreBluetooth
import simd

@MainActor
// Both delegates are delivered on the CBCentralManager's explicit main queue.
final class DroggerReceiver: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    struct Device:Identifiable { var id:UUID; var name:String }
    static let legacyService=CBUUID(string:"0BABA001-0000-1000-8000-00805F9B34FB")
    static let legacyRead=CBUUID(string:"0BABA002-0000-1000-8000-00805F9B34FB")
    static let nordicService=CBUUID(string:"6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nordicRead=CBUUID(string:"6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    @Published private(set) var devices:[Device]=[]
    @Published private(set) var connection="未接続"
    @Published private(set) var correction="補正停止"
    @Published private(set) var latestFix:DroggerFix?
    @Published private(set) var connected=false
    @Published var datumConfirmed=false { didSet { configurationChanged() } }
    @Published var clockConfirmed=false { didSet { configurationChanged() } }
    @Published var mountConfirmed=false { didSet { configurationChanged() } }
    @Published var leverX=0.0 { didSet { configurationChanged() } }
    @Published var leverY=0.0 { didSet { configurationChanged() } }
    @Published var leverZ=0.0 { didSet { configurationChanged() } }
    @Published var enabled=false {
        didSet { fusion.reset(clearOffset:false); correction=enabled ? "時刻の合うFIX待ち" : "補正停止" }
    }
    var ready:Bool { datumConfirmed && clockConfirmed && mountConfirmed && [leverX,leverY,leverZ].allSatisfy { $0.isFinite && abs($0)<=5 } }
    private var central:CBCentralManager?
    private var peripherals:[UUID:CBPeripheral]=[:]
    private var selected:CBPeripheral?
    private var readUUID:CBUUID?
    private var timeout:Task<Void,Never>?
    private var wantsScan=false
    private var parser=DroggerNMEA()
    private var fusion=DroggerFusion()
    private var currentOrigin:GeoCoordinate?
    private var revision:Int?
    private var epoch:Int?
    private var originKey:String?
    private var lastStatusUpdate=0.0
    var worldOffset:SIMD3<Float> { fusion.offset }
    var needsARUpdates:Bool { connected || enabled || fusion.offset != .zero }
    private func configurationChanged() { if enabled { enabled=false }; fusion.reset(clearOffset:false) }
    func scan() {
        disconnect()
        devices=[]; peripherals=[:]; wantsScan=true
        if central == nil { central=CBCentralManager(delegate:self,queue:.main) }
        else { beginScanIfReady() }
    }
    private func beginScanIfReady() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        connection="Droggerを検索中"
        central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        timeout?.cancel()
        timeout=Task { [weak self] in
            try? await Task.sleep(for:.seconds(15)); guard !Task.isCancelled, let self else { return }
            self.central?.stopScan(); self.wantsScan=false
            self.connection=self.devices.isEmpty ? "見つかりません・BLE版FWを確認" : "受信機を選択"
        }
    }
    func connect(_ id:UUID) {
        guard let p=peripherals[id], let central, central.state == .poweredOn else { return }
        guard selected?.identifier != id else { return }
        enabled=false; datumConfirmed=false; mountConfirmed=false
        central.stopScan(); wantsScan=false; timeout?.cancel()
        if let selected { central.cancelPeripheralConnection(selected) }
        selected=p; p.delegate=self; parser=DroggerNMEA(); fusion.reset(clearOffset:false)
        latestFix=nil; connected=false; connection="接続中：\(p.name ?? "Drogger")"
        central.connect(p)
        timeout=Task { [weak self] in
            try? await Task.sleep(for:.seconds(15)); guard !Task.isCancelled, let self, !self.connected else { return }
            self.disconnect(); self.connection="接続時間切れ"
        }
    }
    func disconnect() {
        enabled=false
        wantsScan=false; timeout?.cancel(); central?.stopScan()
        let old=selected; selected=nil
        if let old { central?.cancelPeripheralConnection(old) }
        connected=false; connection="未接続"; latestFix=nil; readUUID=nil
        parser=DroggerNMEA(); fusion.reset(clearOffset:false); correction="接続停止・補正保留"
    }
    func suspendAR() { fusion.reset(clearOffset:false); correction="AR停止中・補正保留" }
    func synchronizeContext(origin:GeoCoordinate?,revision:Int,epoch:Int) {
        let key=origin.map { "\($0.latitude),\($0.longitude)" }
        if let old=self.epoch, old != epoch { fusion.reset(clearOffset:true) }
        if let old=originKey, old != key { fusion.reset(clearOffset:true) }
        // Manual realignment wins; do not pull the user's adjustment back toward GNSS.
        if let old=self.revision, old != revision, enabled {
            enabled=false; correction="位置合わせ変更・補正を再開してください"
        }
        self.epoch=epoch; originKey=key; self.revision=revision; currentOrigin=origin
    }
    func recordFrame(time:Double,camera:simd_float4x4,baseRoot:simd_float4x4,origin:GeoCoordinate?,revision:Int,epoch:Int,normal:Bool) -> SIMD3<Float> {
        synchronizeContext(origin:origin,revision:revision,epoch:epoch)
        fusion.record(time:time,camera:camera,root:baseRoot,lever:SIMD3(Float(leverX),Float(leverY),Float(leverZ)),normal:normal)
        if !enabled || !ready || !connected { fusion.hold("水平補正停止") }
        else if origin == nil { fusion.hold("立ち位置を設定してください") }
        let offset=fusion.step(time:ProcessInfo.processInfo.systemUptime)
        if time-lastStatusUpdate>0.25 {
            lastStatusUpdate=time
            let message=enabled ? fusion.status : correction
            if correction != message { correction=message }
        }
        return offset
    }
    private func receive(_ data:Data) {
        let events=parser.feed(data,receivedAt:Date(),uptime:ProcessInfo.processInfo.systemUptime)
        for event in events {
            switch event {
            case .hold(let reason): fusion.hold(reason); correction=reason
            case .fix(let fix):
                latestFix=fix
                guard enabled, ready, connected, let origin=currentOrigin else { continue }
                let coordinate=GeoCoordinate(latitude:fix.latitude,longitude:fix.longitude,altitude:origin.altitude)
                let local=CoordinateConverter.enuMeters(from:coordinate,origin:origin)
                fusion.accept(fix,localAntenna:SIMD3(Float(local.east),0,-Float(local.north)))
                correction=fusion.status
            }
        }
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        switch central.state {
        case .poweredOn: beginScanIfReady()
        case .unauthorized: disconnect(); connection="Bluetoothの利用が許可されていません"
        case .poweredOff: disconnect(); connection="BluetoothがOFFです"
        case .unsupported: disconnect(); connection="Bluetooth非対応"
        default: connected=false; fusion.hold("Bluetooth準備待ち"); connection="Bluetooth準備待ち"
        }
    }
    func centralManager(_ central:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi:NSNumber) {
        guard wantsScan else { return }
        let name=(advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.hasPrefix("RWS") || name.hasPrefix("RZS") || name.hasPrefix("DG-PRO1RWS") else { return }
        peripherals[p.identifier]=p
        if !devices.contains(where: { $0.id==p.identifier }) { devices.append(Device(id:p.identifier,name:name)) }
    }
    func centralManager(_ central:CBCentralManager,didConnect p:CBPeripheral) {
        guard p == selected else { central.cancelPeripheralConnection(p); return }
        p.discoverServices([Self.legacyService,Self.nordicService])
    }
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?) {
        guard p == selected else { return }; disconnect(); connection="切断されました・再接続してください"
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) {
        guard p == selected else { return }; disconnect(); connection="接続できませんでした"
    }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        guard p == selected else { return }
        guard error == nil else { disconnect(); return }
        // Subscribe to one stream only, even when FW exposes both services.
        guard let service=p.services?.first(where: { $0.uuid==Self.nordicService }) ?? p.services?.first(where: { $0.uuid==Self.legacyService }) else {
            disconnect(); connection="対応するDrogger BLEサービスがありません"; return
        }
        readUUID=service.uuid==Self.nordicService ? Self.nordicRead : Self.legacyRead
        p.discoverCharacteristics([readUUID!],for:service)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard p == selected else { return }
        guard error == nil, let c=service.characteristics?.first(where: { $0.uuid==readUUID && $0.properties.contains(.notify) }) else {
            disconnect(); connection="NMEA通知を開始できません"; return
        }
        p.setNotifyValue(true,for:c)
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor c:CBCharacteristic,error:Error?) {
        guard p == selected, c.uuid==readUUID else { return }
        guard error == nil, c.isNotifying else { disconnect(); connection="NMEA通知に失敗"; return }
        timeout?.cancel(); connected=true; connection="受信中：\(p.name ?? "Drogger")"
    }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor c:CBCharacteristic,error:Error?) {
        guard p == selected, c.uuid==readUUID, connected else { return }
        guard error == nil, let data=c.value else { fusion.hold("受信エラー"); correction="受信エラー"; return }
        receive(data)
    }
}
