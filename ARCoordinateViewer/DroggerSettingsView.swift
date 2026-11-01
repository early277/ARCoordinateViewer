import SwiftUI

struct DroggerSettingsView:View {
    @ObservedObject var receiver:DroggerReceiver
    var body:some View {
        Form {
            Section {
                Text("Drogger BLE連携（試験機能）").font(.headline)
                Text("受信機との実機接続・精度は未検証です。位置はDrogger、向きと短い移動は端末のARを使います。高さは自動補正しません。")
                    .font(.footnote)
            }
            Section("受信機") {
                Text(receiver.connection)
                Button("BLE受信機を検索") { receiver.scan() }
                ForEach(receiver.devices) { device in
                    Button(device.name) { receiver.connect(device.id) }
                }
                Button("切断") { receiver.disconnect() }
                Text("BLE版ファームウェアが必要です。独自BLEと4.4.2以降のNordic UARTに対応します。受信機側でRTK補正とGGA・RMC・GSTの出力を準備してください。このアプリから受信機設定やNtrip接続は変更しません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("水平位置の補正") {
                Toggle("図面とGNSSの測地系・元期を確認した",isOn:$receiver.datumConfirmed)
                Toggle("端末時計をUTCと照合した（差0.1秒以内）",isOn:$receiver.clockConfirmed)
                Text("GNSSの緯度経度を図面の基準と同一として扱います。JGD・WGS84や今期／元期の変換は行いません。BLE受信時刻を測位時刻の代わりには使いません。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("取付位置を確認した（端末に固定）",isOn:$receiver.mountConfirmed)
                Text("背面カメラからアンテナ位相中心までの距離。端末を横向きにしても、以下はARカメラ固定の軸です。持ち替えや別のポールで位置が変わる場合は補正を使わないでください。")
                    .font(.footnote).foregroundStyle(.secondary)
                lever("カメラ右 +X（m）",value:$receiver.leverX)
                lever("カメラ上 +Y（m）",value:$receiver.leverY)
                lever("カメラ後方 +Z（m）",value:$receiver.leverZ)
                Toggle("水平補正を開始",isOn:$receiver.enabled).disabled(!receiver.ready || !receiver.connected)
                Text(receiver.correction).font(.footnote)
                Text("連続したFIX・精度情報・同時刻のAR姿勢が揃ってから緩やかに補正します。FIX外れ、外れ値、遅延、追跡不良では補正を止め、最後の位置合わせを維持します。手動で位置合わせを変えた後は、ここで補正を再開してください。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let fix=receiver.latestFix {
                Section("直近のFIX受信値") {
                    Text(String(format:"緯度 %.8f　経度 %.8f",fix.latitude,fix.longitude)).monospacedDigit()
                    Text("品質 \(fix.quality)（4=RTK FIX）／衛星 \(fix.satellites)")
                    Text(String(format:"水平標準偏差 %.3f m",fix.horizontalSigma))
                    Text("測位UTC \(fix.utc.formatted(.iso8601))")
                    Text("受信UTC \(fix.receivedAt.formatted(.iso8601))")
                    Text(String(format:"受信遅延 %.3f 秒",fix.receivedAt.timeIntervalSince(fix.utc)))
                    if let height=fix.meanSeaLevelHeight { Text(String(format:"GGA海面基準高 %.3f m",height)) }
                    if let height=fix.ellipsoidHeight { Text(String(format:"楕円体高（GGA高＋ジオイド高）%.3f m",height)) }
                    Text("高さの基準・ジオイドは受信機設定に依存します。日本の標高へ自動変換せず、AR高さ・写真の標高へも転用しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.navigationTitle("Drogger（試験）")
    }
    private func lever(_ title:String,value:Binding<Double>) -> some View {
        HStack { Text(title); TextField("m",value:value,format:.number.precision(.fractionLength(0...3))).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation) }
    }
}

struct DroggerStatusView:View {
    @ObservedObject var receiver:DroggerReceiver
    var body:some View {
        if receiver.connected || receiver.enabled {
            Text("Drogger（試験）: \(receiver.correction)")
                .font(.caption2).foregroundStyle(.white).padding(6)
                .arControlSurface(in:Capsule())
                .allowsHitTesting(false)
        }
    }
}
