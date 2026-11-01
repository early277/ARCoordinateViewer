import Foundation
import CoreMotion
import ARKit
import UIKit
import simd

/// A bounded, transient sensor input. Samples remain in Core Motion's device
/// axes (portrait +X right, +Y up, +Z out of the screen), never AR world axes.
/// No motion object or ARFrame is retained and no raw stream is persisted.
final class PCIMUCollector {
    private static let maximumCount=400
    private static let maximumAge=2.0
    private static let standardGravity=9.80665
    private let manager=CMMotionManager()
    private let queue:OperationQueue
    /// Manager calls never run under the sample lock: stopping a stream may
    /// otherwise wait for a delivery that is itself waiting for that lock.
    private let lifecycleLock=NSLock()
    private let lock=NSLock()
    private var buffer:[PCIMUSample]=[]
    private var running=false
    private var generation:UInt64=0
    private var startedAt=0.0
    private var lastAcceptedTime = -Double.infinity
    private var status="stopped"

    init() {
        queue=OperationQueue()
        queue.name="PointCloud.IMU"
        queue.maxConcurrentOperationCount=1
        queue.qualityOfService = .userInitiated
        buffer.reserveCapacity(Self.maximumCount)
    }

    deinit {stop()}

    /// Requests 100 Hz; consumers use the sensor timestamps, not that nominal
    /// interval. This reference frame does not request a magnetic heading.
    func start() {
        lifecycleLock.lock();defer {lifecycleLock.unlock()}
        lock.lock()
        guard !running else {lock.unlock();return}
        generation &+= 1
        buffer.removeAll(keepingCapacity:true)
        lastAcceptedTime = -Double.infinity
        guard manager.isDeviceMotionAvailable else {status="unavailable";lock.unlock();return}
        guard CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) else {
            status="referenceFrameUnavailable";lock.unlock();return
        }
        let token=generation
        startedAt=ProcessInfo.processInfo.systemUptime
        running=true;status="starting"
        lock.unlock()
        manager.deviceMotionUpdateInterval=1.0/100.0
        manager.showsDeviceMovementDisplay=false
        manager.startDeviceMotionUpdates(using:.xArbitraryZVertical,to:queue) { [weak self] motion,error in
            self?.receive(motion,error:error,generation:token)
        }
    }

    /// Cancels the stream and invalidates already queued deliveries. Restarting
    /// begins an empty generation; evidence from a previous run cannot leak in.
    func stop() {
        lifecycleLock.lock();defer {lifecycleLock.unlock()}
        lock.lock()
        generation &+= 1
        running=false;status="stopped"
        buffer.removeAll(keepingCapacity:true)
        lastAcceptedTime = -Double.infinity
        lock.unlock()
        manager.stopDeviceMotionUpdates()
        queue.cancelAllOperations()
    }

    /// Copies at most 400 values from the preceding two seconds. A frame never
    /// receives sensor samples from its future; querying does not consume data.
    func samples(through time:Double)->[PCIMUSample] {
        guard time.isFinite,time>=0 else {return []}
        lock.lock();defer {lock.unlock()}
        let cutoff=time-Self.maximumAge
        return buffer.filter {$0.time>=cutoff && $0.time<=time}
    }

    var stateDescription:String {
        lock.lock();defer {lock.unlock()}
        return status
    }

    private func receive(_ motion:CMDeviceMotion?,error:Error?,generation token:UInt64) {
        if let error=error {fail(error,generation:token);return}
        lock.lock();defer {lock.unlock()}
        guard running,generation==token else {return}
        guard let motion=motion else {return}
        let time=motion.timestamp,now=ProcessInfo.processInfo.systemUptime
        let a=motion.userAcceleration,w=motion.rotationRate
        let acceleration=GCPVector(a.x*Self.standardGravity,a.y*Self.standardGravity,a.z*Self.standardGravity)
        let rotationRate=GCPVector(w.x,w.y,w.z)
        guard time.isFinite,time>=startedAt,time>lastAcceptedTime,
              time<=now,now-time<=Self.maximumAge,
              acceleration.finite,rotationRate.finite else {return}
        buffer.append(PCIMUSample(time:time,acceleration:acceleration,rotationRate:rotationRate))
        lastAcceptedTime=time;status="collecting"
        let cutoff=time-Self.maximumAge
        if let first=buffer.firstIndex(where:{$0.time>=cutoff}),first>0 {buffer.removeFirst(first)}
        if buffer.count>Self.maximumCount {buffer.removeFirst(buffer.count-Self.maximumCount)}
    }

    private func fail(_ error:Error,generation token:UInt64) {
        lifecycleLock.lock();defer {lifecycleLock.unlock()}
        lock.lock()
        guard running,generation==token else {lock.unlock();return}
        // Do not leave stale evidence available after a sensor failure.
        let failure=error as NSError
        status="error:\(failure.domain):\(failure.code)"
        running=false;generation &+= 1
        buffer.removeAll(keepingCapacity:true)
        lastAcceptedTime = -Double.infinity
        lock.unlock()
        manager.stopDeviceMotionUpdates()
        queue.cancelAllOperations()
    }

    /// Rotation from Core Motion device components into the raw ARCamera basis
    /// used by `camera.transform` / GCPPose, not the current interface basis.
    ///
    /// Apple's ARCamera transform uses a fixed landscape camera basis, while
    /// viewMatrix(for:) maps world to the requested interface orientation.
    /// A portrait view therefore supplies deviceFromWorld. Compose its inverse
    /// with cameraFromWorld to derive the conversion without guessing a sign or
    /// using the current UI orientation. Translation is irrelevant to vectors.
    /// References: developer.apple.com/documentation/arkit/arcamera/transform
    /// and ARCamera.h viewMatrixForOrientation: in the iOS SDK.
    static func cameraFromDevice(frame:ARFrame)->simd_quatd? {
        let worldFromCamera=rotation(frame.camera.transform)
        let deviceFromWorld=rotation(frame.camera.viewMatrix(for:.portrait))
        return cameraFromDevice(worldFromCamera:worldFromCamera,deviceFromWorld:deviceFromWorld)
    }

    /// Numeric form for checking the coordinate composition without a camera.
    static func cameraFromDevice(worldFromCamera:simd_double3x3,deviceFromWorld:simd_double3x3)->simd_quatd? {
        guard validRotation(worldFromCamera),validRotation(deviceFromWorld) else {return nil}
        let cameraFromDevice=simd_transpose(worldFromCamera)*simd_transpose(deviceFromWorld)
        guard validRotation(cameraFromDevice) else {return nil}
        let q=simd_normalize(simd_quatd(cameraFromDevice))
        guard q.vector.x.isFinite,q.vector.y.isFinite,q.vector.z.isFinite,q.vector.w.isFinite else {return nil}
        return q.real<0 ? simd_quatd(vector:-q.vector):q
    }

    private static func rotation(_ matrix:simd_float4x4)->simd_double3x3 {
        simd_double3x3(columns:(
            SIMD3(Double(matrix.columns.0.x),Double(matrix.columns.0.y),Double(matrix.columns.0.z)),
            SIMD3(Double(matrix.columns.1.x),Double(matrix.columns.1.y),Double(matrix.columns.1.z)),
            SIMD3(Double(matrix.columns.2.x),Double(matrix.columns.2.y),Double(matrix.columns.2.z))))
    }

    private static func validRotation(_ matrix:simd_double3x3)->Bool {
        let x=matrix.columns.0,y=matrix.columns.1,z=matrix.columns.2
        return [x.x,x.y,x.z,y.x,y.y,y.z,z.x,z.y,z.z].allSatisfy(\.isFinite)
            && abs(simd_length_squared(x)-1)<1e-3
            && abs(simd_length_squared(y)-1)<1e-3
            && abs(simd_length_squared(z)-1)<1e-3
            && abs(simd_dot(x,y))<1e-3 && abs(simd_dot(x,z))<1e-3 && abs(simd_dot(y,z))<1e-3
            && abs(simd_determinant(matrix)-1)<1e-3
    }
}
