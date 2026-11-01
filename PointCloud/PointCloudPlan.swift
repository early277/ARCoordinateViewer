import Foundation

/// Flat, local drawing coordinates only. North/X goes up; east/Y goes right.
/// Subtract public-coordinate origins in Double before producing screen values.
struct PCPlanPoint:Equatable,Identifiable {
    var id:UUID
    var north:Double
    var east:Double
    var finite:Bool {north.isFinite && east.isFinite}
}

struct PCPlanScreenPoint:Equatable {
    var x:Double
    var y:Double
}

struct PCPlanViewport:Equatable {
    var north:Double
    var east:Double
    var metresPerPoint:Double
    static let minimumScale=0.000_001
    static let maximumScale=1_000_000.0

    static func fit(_ points:[PCPlanPoint],width:Double,height:Double)->PCPlanViewport? {
        let valid=points.filter(\.finite)
        guard width.isFinite,height.isFinite,width>0,height>0,
              let first=valid.first else {return nil}
        var minNorth=first.north,maxNorth=first.north,minEast=first.east,maxEast=first.east
        for point in valid.dropFirst() {
            minNorth=min(minNorth,point.north);maxNorth=max(maxNorth,point.north)
            minEast=min(minEast,point.east);maxEast=max(maxEast,point.east)
        }
        let northSpan=maxNorth-minNorth,eastSpan=maxEast-minEast
        guard northSpan.isFinite,eastSpan.isFinite else {return nil}
        // A single/coincident point still gets useful metre-scale context.
        let scale=max(max(2,eastSpan)/max(1,width-64),max(2,northSpan)/max(1,height-64))
        return PCPlanViewport(north:minNorth+northSpan/2,east:minEast+eastSpan/2,
                              metresPerPoint:min(maximumScale,max(minimumScale,scale)))
    }

    func screen(_ point:PCPlanPoint,width:Double,height:Double)->PCPlanScreenPoint? {
        guard point.finite,north.isFinite,east.isFinite,metresPerPoint.isFinite,metresPerPoint>0,
              width.isFinite,height.isFinite,width>0,height>0 else {return nil}
        let x=width/2+(point.east-east)/metresPerPoint
        let y=height/2-(point.north-north)/metresPerPoint
        guard x.isFinite,y.isFinite else {return nil}
        return PCPlanScreenPoint(x:x,y:y)
    }

    func transformed(zoom:Double=1,dx:Double=0,dy:Double=0)->PCPlanViewport {
        guard zoom.isFinite,zoom>0,dx.isFinite,dy.isFinite,
              north.isFinite,east.isFinite,metresPerPoint.isFinite,metresPerPoint>0 else {return self}
        let scale=min(Self.maximumScale,max(Self.minimumScale,metresPerPoint/zoom))
        let n=north+dy*scale,e=east-dx*scale
        guard n.isFinite,e.isFinite else {return self}
        return PCPlanViewport(north:n,east:e,metresPerPoint:scale)
    }

    /// Return every candidate within a screen radius. Never silently pick the
    /// closest item when multiple known points overlap (even identical X/Y).
    func candidates(_ points:[PCPlanPoint],at tap:PCPlanScreenPoint,width:Double,height:Double,radius:Double=24)->[UUID] {
        guard tap.x.isFinite,tap.y.isFinite,radius.isFinite,radius>0,
              tap.x>=0,tap.y>=0,tap.x<=width,tap.y<=height else {return []}
        return points.compactMap {point -> (UUID,Double)? in
            guard let p=screen(point,width:width,height:height),
                  p.x>=0,p.y>=0,p.x<=width,p.y<=height else {return nil}
            let distance=hypot(p.x-tap.x,p.y-tap.y)
            return distance<=radius ? (point.id,distance):nil
        }.sorted {a,b in a.1==b.1 ? a.0.uuidString<b.0.uuidString:a.1<b.1}.map(\.0)
    }
}
