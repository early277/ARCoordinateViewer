import Foundation

enum ScanExportFailure:Error {
    case cancelled
    case timedOut(String)
    case noTexture
    case limit(String)
    var message:String {
        switch self {
        case .cancelled:return "出力を取り消しました。元のスキャンは保持しています"
        case .timedOut(let stage):return "出力の制限時間に達しました（\(stage)）。元のスキャンは保持しています"
        case .limit(let detail):return "出力上限: "+detail+"。元記録は保持しています"
        case .noTexture:return "保存画像と形状の重なりを確認できず、画像を貼り付けられませんでした。形状のみの出力と元記録は利用できます"
        }
    }
}
/// Cooperative cancellation: the worker must exit before controls become editable again.
final class ScanExportControl:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    private let clock:()->Double
    private let started:Double
    let maximumSeconds:Double
    private let progress:(String,Double)->Void
    private var lastProgress = -Double.infinity
    private var stage="準備"
    private var fraction=0.0
    init(maximumSeconds:Double=120,clock:@escaping()->Double={ProcessInfo.processInfo.systemUptime},progress:@escaping(String,Double)->Void={_,_ in}) {
        self.clock=clock;self.started=clock();self.maximumSeconds=maximumSeconds;self.progress=progress
    }
    func cancel() {lock.lock();cancelled=true;lock.unlock()}
    var isCancelled:Bool {lock.lock();defer {lock.unlock()};return cancelled}
    var shouldContinue:Bool {!isCancelled && clock()-started<maximumSeconds}
    func check(_ stage:String?=nil,fraction:Double?=nil) throws {
        lock.lock();let cancelled=self.cancelled;lock.unlock()
        if cancelled {throw ScanExportFailure.cancelled}
        if let stage {self.stage=stage}
        let now=clock()
        guard now-started<maximumSeconds else {throw ScanExportFailure.timedOut(self.stage)}
        if let fraction {self.fraction=max(self.fraction,min(1,max(0,fraction)))}
        if stage != nil,now-lastProgress>=0.1 {lastProgress=now;progress(self.stage,self.fraction)}
    }
}
