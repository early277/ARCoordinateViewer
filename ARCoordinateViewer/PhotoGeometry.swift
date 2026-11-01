import Foundation
import simd

/// The same diagram-local frame used by imported features and new drawing points:
/// +X east, +Y up, -Z north, in metres. Root already contains all display alignment.
enum DiagramTransform {
    static func localPoint(_ world:SIMD3<Float>,root:simd_float4x4) -> SIMD3<Float> {
        DrawingGeometry.point(world,transformedBy:simd_inverse(root))
    }
    static func localPose(_ camera:simd_float4x4,root:simd_float4x4) -> simd_float4x4 {
        simd_inverse(root)*camera
    }
    static func values(_ matrix:simd_float4x4) -> [Double] {
        (0..<4).flatMap { column in (0..<4).map { Double(matrix[column][$0]) } }
    }
    static func validRigid(_ matrix:simd_float4x4) -> Bool {
        guard values(matrix).allSatisfy(\.isFinite), abs(matrix[3].w-1)<0.001 else { return false }
        let r=simd_float3x3(columns:(SIMD3(matrix[0].x,matrix[0].y,matrix[0].z),SIMD3(matrix[1].x,matrix[1].y,matrix[1].z),SIMD3(matrix[2].x,matrix[2].y,matrix[2].z)))
        return abs(simd_determinant(r)-1)<0.001 && (0..<3).allSatisfy { abs(simd_length(r[$0])-1)<0.001 && abs(matrix[$0].w)<0.001 }
    }
}

struct PhotoCoordinateContext:Codable {
    var origin:GeoCoordinate?
    var verticalDatum:Double?
    var documentID:String?
    var documentName:String?
    var reference:DXFCoordinateReference?
    var settings:PhotoReferenceSettings
    var alignmentRevision:Int
}

struct PhotoPose:Codable {
    /// Column-major camera-to-diagram matrix. Camera convention: +X right,+Y up,-Z optical axis.
    var cameraToDiagram:[Double]
    var localEastNorthUpMetres:[Double]
    var sourceXYZ:[Double?]?
    var altitudeMetres:Double?
    var latitude:Double?
    var longitude:Double?
    var trueDirectionDegrees:Double?
    var gridDirectionDegrees:Double?
    var pitchDegrees:Double
    var rollDegrees:Double?
}

struct DeviceLocationObservation:Codable {
    var timestamp:Date
    var latitude:Double
    var longitude:Double
    var altitudeMeanSeaLevel:Double?
    var ellipsoidalAltitude:Double?
    var horizontalAccuracy:Double
    var verticalAccuracy:Double
    var simulatedBySoftware:Bool
    var producedByAccessory:Bool
    func usable(at date:Date) -> Bool {
        let age=date.timeIntervalSince(timestamp)
        return age >= -1 && age <= 5 && latitude.isFinite && longitude.isFinite && abs(latitude)<=90 && abs(longitude)<=180 && horizontalAccuracy.isFinite && horizontalAccuracy>=0
    }
}
struct DeviceHeadingObservation:Codable {
    var timestamp:Date
    var trueHeading:Double?
    var magneticHeading:Double?
    var accuracyDegrees:Double
    var magneticFieldDeviceXYZ:[Double]
    var convention="CoreLocation device-top heading and calibrated magnetic field; not GPS travel course"
}
struct DevicePhotoObservation:Codable {
    var location:DeviceLocationObservation?
    var heading:DeviceHeadingObservation?
    var cameraDirectionDegrees:Double?
    var cameraDirectionReference:String?
    var cameraDirectionMethod="Device magnetic field + AR gravity/camera orientation; diagram alignment is not used"
}

enum PhotoGeometry {
    /// The normalized JPEG has upright pixels. Rotate its right/up basis with
    /// the pixels, while preserving the optical axis and optical center.
    static func outputCameraToDiagram(raw:[Double],rotation:UInt32) -> [Double] {
        guard raw.count==16 else { return [] }
        var output=raw
        let (c,s):(Double,Double)=rotation==6 ? (0,1) : rotation==8 ? (0,-1) : rotation==3 ? (-1,0) : (1,0)
        for row in 0..<3 { output[row]=c*raw[row]+s*raw[4+row]; output[4+row] = -s*raw[row]+c*raw[4+row] }
        return output
    }
    /// CLHeading.x/y/z are in the device's fixed portrait axes. AR's portrait
    /// camera basis maps those axes to a gravity-aligned world. Project both
    /// magnetic north and the optical axis horizontally; never use GPS course.
    static func deviceCameraDirection(heading:DeviceHeadingObservation?,portraitCamera:simd_float4x4,date:Date) -> (degrees:Double,reference:String)? {
        guard let heading,heading.accuracyDegrees.isFinite,heading.accuracyDegrees>=0,heading.accuracyDegrees<=45,
              abs(date.timeIntervalSince(heading.timestamp))<=2,heading.magneticFieldDeviceXYZ.count==3,
              heading.magneticFieldDeviceXYZ.allSatisfy(\.isFinite),DiagramTransform.validRigid(portraitCamera) else { return nil }
        let field=heading.magneticFieldDeviceXYZ.map(Float.init)
        let world=portraitCamera*SIMD4(field[0],field[1],field[2],0)
        var north=SIMD3(world.x,0,world.z)
        var forward = -SIMD3(portraitCamera[2].x,0,portraitCamera[2].z)
        guard simd_length(north)>0.01,simd_length(forward)>0.08 else { return nil }
        north=simd_normalize(north);forward=simd_normalize(forward)
        let east=simd_cross(north,SIMD3<Float>(0,1,0))
        guard var degrees=direction(east:Double(simd_dot(forward,east)),north:Double(simd_dot(forward,north))) else { return nil }
        var reference="M"
        if let t=heading.trueHeading,let m=heading.magneticHeading,t.isFinite,m.isFinite,t>=0,t<360,m>=0,m<360 {
            degrees=(degrees+t-m+720).truncatingRemainder(dividingBy:360);reference="T"
        }
        return (degrees,reference)
    }
    /// Rotation part of ARFrame.displayTransform, independent of viewport crop.
    static func imageRotation(a:Double,b:Double) -> UInt32 {
        abs(a)>abs(b) ? (a>=0 ? 1 : 3) : (b>=0 ? 6 : 8)
    }
    static func direction(east:Double,north:Double) -> Double? {
        guard east.isFinite,north.isFinite,hypot(east,north)>0.01 else { return nil }
        return (atan2(east,north)*180 / .pi+360).truncatingRemainder(dividingBy:360)
    }
    static func bearing(_ a:GeoCoordinate,_ b:GeoCoordinate) -> Double? {
        let lat1=a.latitude * .pi/180, lat2=b.latitude * .pi/180, d=(b.longitude-a.longitude) * .pi/180
        let east=sin(d)*cos(lat2), north=cos(lat1)*sin(lat2)-sin(lat1)*cos(lat2)*cos(d)
        guard hypot(east,north)>1e-12 else { return nil }
        return (atan2(east,north)*180 / .pi+360).truncatingRemainder(dividingBy:360)
    }
    static func pose(camera:simd_float4x4,root:simd_float4x4,context:PhotoCoordinateContext) -> PhotoPose? {
        guard DiagramTransform.validRigid(camera),DiagramTransform.validRigid(root) else { return nil }
        let local=DiagramTransform.localPose(camera,root:root)
        let p=local[3], forward = -SIMD3(local[2].x,local[2].y,local[2].z)
        let east=Double(p.x), north = -Double(p.z), up=Double(p.y)
        let altitude=context.verticalDatum.flatMap { $0.isFinite ? $0+up : nil }
        var xyz:[Double?]?, latitude:Double?, longitude:Double?, trueDirection:Double?, gridDirection:Double?
        if let origin=context.origin, let geo=try? DXFDrawingExport.coordinate(east:east,north:north,origin:origin) {
            let next=try? DXFDrawingExport.coordinate(east:east+Double(forward.x),north:north-Double(forward.z),origin:origin)
            if context.settings.datum != .unknown {
                latitude=geo.latitude; longitude=geo.longitude
                if hypot(Double(forward.x),Double(forward.z))>0.01, let next { trueDirection=bearing(geo,next) }
            }
            if let r=context.reference, r.metersPerUnit.isFinite, r.metersPerUnit>0,
               let plane=try? JapanesePlaneRectangularSystem.fromGeodetic(system:r.planeSystem,latitude:geo.latitude,longitude:geo.longitude) {
                xyz=[r.xIsEasting ? plane.y/r.metersPerUnit : plane.x/r.metersPerUnit,r.xIsEasting ? plane.x/r.metersPerUnit : plane.y/r.metersPerUnit,altitude.map { $0/r.metersPerUnit }]
                if hypot(Double(forward.x),Double(forward.z))>0.01, let next,
                   let n=try? JapanesePlaneRectangularSystem.fromGeodetic(system:r.planeSystem,latitude:next.latitude,longitude:next.longitude) {
                    gridDirection=direction(east:n.y-plane.y,north:n.x-plane.x)
                }
            }
        }
        let vertical=SIMD3<Float>(0,1,0)
        let right=SIMD3(local[0].x,local[0].y,local[0].z), imageUp=SIMD3(local[1].x,local[1].y,local[1].z)
        let pitch=asin(max(-1,min(1,Double(forward.y))))*180 / .pi
        let roll=hypot(Double(forward.x),Double(forward.z))>0.01 ? atan2(Double(simd_dot(right,vertical)),Double(simd_dot(imageUp,vertical)))*180 / .pi : nil
        return PhotoPose(cameraToDiagram:DiagramTransform.values(local),localEastNorthUpMetres:[east,north,up],sourceXYZ:xyz,altitudeMetres:altitude,latitude:latitude,longitude:longitude,trueDirectionDegrees:trueDirection,gridDirectionDegrees:gridDirection,pitchDegrees:pitch,rollDegrees:roll)
    }
    static func stable(before:simd_float4x4,after:simd_float4x4,seconds:Double) -> Bool {
        guard seconds>=0,seconds<=0.15,DiagramTransform.validRigid(before),DiagramTransform.validRigid(after) else { return false }
        let a=SIMD3(before[3].x,before[3].y,before[3].z),b=SIMD3(after[3].x,after[3].y,after[3].z)
        func rotationPart(_ m:simd_float4x4) -> simd_float3x3 { simd_float3x3(columns:(SIMD3(m[0].x,m[0].y,m[0].z),SIMD3(m[1].x,m[1].y,m[1].z),SIMD3(m[2].x,m[2].y,m[2].z))) }
        let rotation=simd_transpose(rotationPart(before))*rotationPart(after)
        let cosine=max(-1,min(1,(rotation[0].x+rotation[1].y+rotation[2].z-1)/2))
        return simd_distance(a,b)<=0.02 && acos(cosine)<=Float.pi/180
    }
}

struct PhotoCaptureRecord:Codable {
    var schema=1
    var id:UUID
    var mode:PhotoCaptureMode
    var capturedAt:Date
    var frameTimestamp:Double
    var followingFrameTimestamp:Double?
    var sessionID:UUID
    var tracking:String
    var synchronization:String
    var georeferenceUsable:Bool
    var issues:[String]
    var context:PhotoCoordinateContext
    var pose:PhotoPose?
    var rootToARWorld:[Double]
    var rawCameraToARWorld:[Double]
    var followingRawCameraToARWorld:[Double]?
    var rawImageWidth:Int
    var rawImageHeight:Int
    var intrinsicsColumnMajor:[Double]
    var interfaceOrientation:String
    var displayTransform:[Double]
    var positionSource:PhotoPositionSource = .ar
    var arPoseUsable=false
    var arGeoreferenceUsable=false
    var deviceObservation:DevicePhotoObservation?=nil
    var deviceCameraDirectionUsable=false
    var outputCameraToDiagram:[Double]?=nil
    var imageFileName=""
    var rawToOutputExifRotation:UInt32=1
    var followingRootToARWorld:[Double]?=nil
    var wallClockTimeMethod="UTC estimated from capture callback clock and AR frame age; frameTimestamp is the original monotonic timestamp"
    var imageWidth=0
    var imageHeight=0
    var imageOrientation=1
    var cameraConvention="+X right, +Y up, -Z optical axis; matrices column-major"
    var diagramConvention="+X east, +Y up, -Z north, metres; sourceXYZ uses source reference axis order/unit"
    var anglesConvention="raw camera axes: direction clockwise from north; pitch positive above horizon; roll atan2(cameraRight.up,cameraUp.up); image pixel rotation is separate"
    var accuracy="AR alignment estimate; not a surveyed position or accuracy guarantee"
    mutating func updateSelectedValidity() {
        georeferenceUsable=positionSource == .ar ? arGeoreferenceUsable : (deviceObservation?.location?.usable(at:capturedAt) ?? false)
    }
    var selectedPositionUsable:Bool { positionSource == .ar ? arPoseUsable : georeferenceUsable }
}

/// Photogrammetry uses a right-handed local frame: X east, Y north, Z up (m).
/// Source DXF axes/units and absolute heights remain separate in the lossless JSON.
enum PhotoPriors {
    static func cameraToENU(_ record:PhotoCaptureRecord) -> simd_double3x3? {
        guard record.positionSource == .ar,record.arPoseUsable,
              let c=record.outputCameraToDiagram,c.count==16,c.allSatisfy(\.isFinite) else { return nil }
        func column(_ i:Int) -> SIMD3<Double> { SIMD3(c[4*i],-c[4*i+2],c[4*i+1]) }
        let rotation=simd_double3x3(columns:(column(0),column(1),column(2)))
        // AR matrices are Float; remove rounding drift before Euler extraction,
        // especially for cameras facing exactly along an ENU axis.
        return simd_double3x3(simd_normalize(simd_quatd(rotation)))
    }
    static func number(_ value:Double) -> String { String(format:"%.12g",locale:Locale(identifier:"en_US_POSIX"),value) }
    static func csvCell(_ value:String) -> String { "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
    /// Matches Metashape 2.2.3 utils.opk2mat: R=Rx(omega) Ry(phi) Rz(kappa).
    /// R is image right/up/back to ENU, after the official camera-to-antenna
    /// diag(1,-1,-1) basis change. No drone YPR assumptions are used.
    static func metashapeOPK(_ r:simd_double3x3) -> [Double] {
        let phi=asin(max(-1,min(1,r[2].x)))
        let omega:Double,kappa:Double
        if abs(cos(phi))>1e-7 { omega=atan2(-r[2].y,r[2].z);kappa=atan2(-r[1].x,r[0].x) }
        else { omega=atan2(r[0].y,r[1].y)*(phi>=0 ? 1 : -1);kappa=0 }
        return [omega,phi,kappa].map { $0*180 / .pi }
    }
    static func referenceCSV(_ record:PhotoCaptureRecord) -> String {
        let header="filename,x,y,z,omega,phi,kappa\n"
        guard record.selectedPositionUsable else { return header }
        let xyz:[Double?]
        if record.positionSource == .ar,let pose=record.pose { xyz=pose.localEastNorthUpMetres.map { Optional($0) } }
        else if let location=record.deviceObservation?.location { xyz=[location.longitude,location.latitude,location.verticalAccuracy>=0 ? location.ellipsoidalAltitude : nil] }
        else { return header }
        let angles=cameraToENU(record).map(metashapeOPK)?.map(number) ?? ["","",""]
        return header+csvCell(record.imageFileName)+","+(xyz.map { $0.map(number) ?? "" }+angles).joined(separator:",")+"\n"
    }
    /// RealityScan xcr:Rotation is world-to-camera, row-major. Its camera axes
    /// are +X image-right,+Y image-down,+Z forward. PosePrior=initial is draft.
    static func realityScanXMP(_ record:PhotoCaptureRecord) -> String? {
        guard let camera=cameraToENU(record),let pose=record.pose else { return nil }
        let flip=simd_double3x3(diagonal:SIMD3(1,-1,-1))
        let rotation=flip*simd_transpose(camera)
        let values=(0..<3).flatMap { row in (0..<3).map { number(rotation[$0][row]) } }.joined(separator:" ")
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:xcr="http://www.capturingreality.com/ns/xcr/1.1#" xcr:Version="3" xcr:PosePrior="initial" xcr:Coordinates="absolute" xcr:Rotation="\(values)">
              <xcr:Position>\(pose.localEastNorthUpMetres.map(number).joined(separator:" "))</xcr:Position>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }
    static func guide(_ record:PhotoCaptureRecord) -> String {
        """
        撮影記録 \(record.imageFileName)
        位置ソース: \(record.positionSource.rawValue)
        ARセッション: \(record.sessionID.uuidString) / 位置合わせ変更番号: \(record.context.alignmentRevision)

        JPEGと同名JSONを一緒に保管してください。JSONに撮影時の生の4×4姿勢、図面変換、元図面XYZ、GPS/方位観測、画像回転、カメラ内部パラメータ、追跡状態を記録しています。
        ARのreference.csv: ローカル直交座標、X=東、Y=北、Z=上、単位m。Z=0は図面ローカル原点です。元図面標高ではありません。原点の緯度経度と標高基準はJSONのcontextにあります。
        GPSのreference.csv: WGS84経度・緯度・楕円体高（度・度・m）。高さ不明は空欄です。
        精度未評価のAR値は確定測量値ではありません。accuracyを0にしたり、カメラをlocked/exactに固定しないでください。未評価の精度は出力しません。

        Metashape Pro: 写真を追加し、Referenceからreference.csvをカンマ区切り、先頭1行スキップで読み込みます。filename列を写真名、x/y/z列を座標に指定。ARはLocal Coordinates、GPSはWGS84を選びます。回転CSVがある場合はOmega/Phi/Kappaを選択してください。位置・回転精度は現地検証後に設定します。
        RealityScan: ARの同名.jpg/.xmpを同じフォルダに置いて写真を追加します。XMPは任意のローカル直交座標でdraft/initial priorです。全写真で同じローカル座標を使い、プロジェクトに誤った地理CRSを指定しないでください。GPSモードはJPEG内のGPSまたは位置CSVを使用し、AR姿勢XMPは生成しません。
        複数写真を集める際、別ARセッション、図面原点、位置合わせ変更番号の記録を無確認で混ぜないでください。移動/回転による位置合わせを変更した前後は別グループとして検証します。
        AR写真には図形が写るため、写真測量には「写真のみ」を使ってください。写真アプリから転送すると名前やメタデータが変わることがあるため、この撮影記録の元JPEGを使います。
        各ソフトの実際の取込・画像照合結果と現地精度は別途確認が必要です。画像間の特徴点照合は省略できません。

        https://www.agisoft.com/pdf/metashape-pro_2_2_en.pdf
        https://rshelp.capturingreality.com/en-US/tools/xmpalign.htm
        """
    }
}
