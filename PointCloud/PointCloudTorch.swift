import Foundation
import Combine
#if os(iOS) && canImport(ARKit)
import ARKit
import AVFoundation
#endif

struct PCTorchState:Sendable {var available=false;var isOn=false;var owned=false}
protocol PCTorchDriver:AnyObject,Sendable {
    var changed:(@Sendable ()->Void)? {get set}
    func read(active:Bool)->PCTorchState
    func set(_ on:Bool)throws
    func cleanup()throws // Only devices this driver explicitly switched on.
}
private final class PCTorchGate:@unchecked Sendable {
    private let lock=NSLock();private var revision=0,active=false
    func advance(_ value:Bool)->Int {lock.withLock{active=value;revision+=1;return revision}}
    func permits(_ token:Int)->Bool {lock.withLock{active && revision==token}}
    var isActive:Bool {lock.withLock{active}}
}

@MainActor final class PCTorchControl:ObservableObject {
    @Published private(set) var isOn=false
    @Published private(set) var available=false
    @Published private(set) var busy=false
    @Published private(set) var cameraActive=false
    @Published var errorMessage:String?
    var canToggle:Bool {!busy && ((cameraActive && available) || isOn)}
    private let driver:any PCTorchDriver,gate=PCTorchGate()
    private let queue=DispatchQueue(label:"point-cloud-torch",qos:.userInitiated)
    private var revision=0,refreshPending=false
    init(driver:any PCTorchDriver=PCTorchNativeDriver()) {
        self.driver=driver
        driver.changed={ [weak self] in Task{@MainActor [weak self] in self?.refreshAvailability()} }
    }
    func setCameraActive(_ active:Bool) {
        guard active != cameraActive else {return}
        cameraActive=active;refreshPending=false
        if !active {available=false}
        submit(nil)
    }
    func refreshAvailability() {
        guard cameraActive else {return}
        if busy {refreshPending=true;return}
        submit(nil)
    }
    func toggle() {
        guard canToggle else {return}
        errorMessage=nil;submit(!isOn)
    }
    private func submit(_ on:Bool?) {
        revision=gate.advance(cameraActive);let token=revision
        busy=true
        queue.async { [driver,gate,weak self] in
            var error:String?
            do {
                if on==true {
                    if gate.permits(token) {try driver.set(true)}
                    // Deactivation may arrive while lock/set was in progress.
                    if !gate.permits(token) {try driver.cleanup()}
                } else if on==false {if gate.isActive {try driver.set(false)} else {try driver.cleanup()}}
                else if !gate.isActive {try driver.cleanup()}
            } catch let failure {
                error="ライトを切り替えられません: "+failure.localizedDescription
                if on==true {do {try driver.cleanup()} catch let cleanupFailure {error! += "（消灯も確認できません: "+cleanupFailure.localizedDescription+"）"}}
            }
            var state=driver.read(active:gate.isActive)
            // Clear our ON mode after thermal unavailability so recovery never
            // silently restores illumination. Other owners remain untouched.
            if gate.isActive,!state.available,state.owned {
                do {try driver.cleanup()} catch let failure {error="ライトの消灯を確認できません: "+failure.localizedDescription}
                state=driver.read(active:gate.isActive)
            }
            let result=state,failure=error
            Task{@MainActor [weak self] in
                guard let self,self.revision==token else {return}
                let becameUnavailable=self.available && !result.available
                self.isOn=result.isOn;self.available=self.cameraActive && result.available;self.busy=false
                if let failure {self.errorMessage=failure}
                else if becameUnavailable,self.cameraActive {self.errorMessage="ライトは一時的に使用できません（温度など）"}
                if self.refreshPending {self.refreshPending=false;self.refreshAvailability()}
            }
        }
    }
    deinit {
        _=gate.advance(false)
        let driver=driver
        queue.async {driver.changed=nil;try? driver.cleanup()}
    }
}

private enum PCTorchFailure:LocalizedError {case unavailable
    var errorDescription:String? {"ライト非対応、または現在利用できません"}
}
/// Called only on the control's serial worker. KVO sends a signal, never UI work.
final class PCTorchNativeDriver:PCTorchDriver,@unchecked Sendable {
    var changed:(@Sendable ()->Void)?
    #if os(iOS) && canImport(ARKit)
    private var current:AVCaptureDevice?,owned:[String:AVCaptureDevice]=[:]
    private var observations:[NSKeyValueObservation]=[]
    func read(active:Bool)->PCTorchState {
        var device:AVCaptureDevice?
        if active,#available(iOS 16.0,*) {device=ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera}
        if current !== device {
            observations=[];current=device
            if let device {let notify=changed
                observations=[device.observe(\.isTorchAvailable,options:[.new]){_,_ in notify?()},device.observe(\.isTorchActive,options:[.new]){_,_ in notify?()},device.observe(\.torchMode,options:[.new]){_,_ in notify?()}]
            }
        }
        return PCTorchState(available:device.map{$0.hasTorch && $0.isTorchAvailable && $0.isTorchModeSupported(.on) && $0.isTorchModeSupported(.off)} ?? false,isOn:device?.isTorchActive == true || owned.values.contains{$0.isTorchActive},owned:!owned.isEmpty)
    }
    func set(_ on:Bool)throws {
        if !on {
            if let device=current {
                guard device.hasTorch,device.isTorchModeSupported(.off) else {throw PCTorchFailure.unavailable}
                try device.lockForConfiguration();defer{device.unlockForConfiguration()}
                device.torchMode = .off;owned.removeValue(forKey:device.uniqueID)
            }
            try cleanup();return
        }
        guard let device=current,device.hasTorch,device.isTorchModeSupported(.on),device.isTorchAvailable else {throw PCTorchFailure.unavailable}
        try device.lockForConfiguration();defer{device.unlockForConfiguration()}
        owned[device.uniqueID]=device
        try device.setTorchModeOn(level:0.5)
    }
    func cleanup()throws {
        var firstError:Error?
        for (id,device) in owned {
            do {
                guard device.hasTorch,device.isTorchModeSupported(.off) else {throw PCTorchFailure.unavailable}
                try device.lockForConfiguration();defer{device.unlockForConfiguration()}
                device.torchMode = .off;owned.removeValue(forKey:id)
            } catch {if firstError==nil {firstError=error}}
        }
        observations=[];current=nil
        if let firstError {throw firstError}
    }
    #else
    func read(active:Bool)->PCTorchState {PCTorchState()}
    func set(_ on:Bool)throws {throw PCTorchFailure.unavailable}
    func cleanup()throws {}
    #endif
}
