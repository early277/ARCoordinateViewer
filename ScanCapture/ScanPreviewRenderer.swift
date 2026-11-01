import ARKit
import RealityKit
import UIKit

/// Separate raw-world anchor: never inherits the imported drawing's alignment/scale.
final class ScanPreviewRenderer {
    private var root:AnchorEntity?
    private var surface:ModelEntity?
    private var markers:[UUID:ModelEntity]=[:]
    private var labels:[UUID:UILabel]=[:]
    private var token:UUID?
    private var revision = -1
    private var lastLabels = -Double.infinity
    private var lastSurface = -Double.infinity
    private var sphere:MeshResource?

    @MainActor func update(_ controller:ScanCaptureController,view:ARView,frame:ARFrame?) {
        guard controller.previewVisible,let preview=controller.preview,let frame,
              case .normal=frame.camera.trackingState else {
            root?.isEnabled=false;for label in labels.values {label.isHidden=true};return
        }
        if root==nil {let anchor=AnchorEntity(world:.zero);root=anchor;view.scene.addAnchor(anchor)}
        guard let root else {return}
        root.isEnabled=true
        if token != preview.token {
            root.children.removeAll();surface=nil;markers=[:]
            for label in labels.values {label.removeFromSuperview()};labels=[:]
            token=preview.token;revision = -1;lastLabels = -.infinity;lastSurface = -.infinity
        }
        if revision != preview.geometryRevision,(frame.timestamp-lastSurface>=1 || frame.timestamp<lastSurface) {
            lastSurface=frame.timestamp
            surface?.removeFromParent();surface=nil
            let geometry=preview.geometry
            if !geometry.indices.isEmpty {
                var descriptor=MeshDescriptor(name:"Committed scan coverage")
                descriptor.positions=MeshBuffers.Positions(geometry.positions)
                descriptor.normals=MeshBuffers.Normals(geometry.normals)
                descriptor.primitives = .triangles(geometry.indices)
                do {
                    let mesh=try MeshResource.generate(from:[descriptor])
                    var material=UnlitMaterial(color:.systemCyan)
                    material.blending = .transparent(opacity:.init(floatLiteral:0.32))
                    material.faceCulling = .none
                    let entity=ModelEntity(mesh:mesh,materials:[material]);root.addChild(entity);surface=entity
                } catch {Task { @MainActor [weak controller] in controller?.reportPreviewRenderFailure(preview.token)}}
            }
            revision=preview.geometryRevision
        }
        surface?.isEnabled=controller.showCoverage
        guard frame.timestamp-lastLabels>=0.1 || frame.timestamp<lastLabels else {return}
        lastLabels=frame.timestamp
        let visibleIDs=Set(preview.points.map(\.id))
        for id in Array(markers.keys) where !visibleIDs.contains(id) {markers.removeValue(forKey:id)?.removeFromParent();labels.removeValue(forKey:id)?.removeFromSuperview()}
        let inverse=simd_inverse(frame.camera.transform)
        for point in preview.points {
            if markers[point.id]==nil {
                if sphere==nil {sphere=MeshResource.generateSphere(radius:0.025)}
                let marker=ModelEntity(mesh:sphere!,materials:[UnlitMaterial(color:.systemYellow)])
                root.addChild(marker);markers[point.id]=marker
                let label=UILabel();label.isUserInteractionEnabled=false;label.textColor = .yellow
                label.backgroundColor=UIColor.black.withAlphaComponent(0.7);label.layer.cornerRadius=5;label.clipsToBounds=true
                label.textAlignment = .center;label.font = .systemFont(ofSize:13,weight:.bold)
                label.accessibilityLabel="GCP \(point.number)";view.addSubview(label);labels[point.id]=label
            }
            markers[point.id]?.position=point.position
            let camera=inverse*SIMD4(point.position,1)
            guard camera.z < -0.02,let projected=view.project(point.position),projected.x.isFinite,projected.y.isFinite,
                  view.bounds.insetBy(dx:35,dy:20).contains(projected),let label=labels[point.id] else {labels[point.id]?.isHidden=true;continue}
            label.text="GCP \(point.number)";label.frame=CGRect(x:projected.x-32,y:projected.y-26,width:64,height:23);label.isHidden=false
        }
    }
}
