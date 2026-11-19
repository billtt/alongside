import Foundation

func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    min(max(value, low), max(low, high))
}

struct Terrain: Equatable {
    let screen: CGRect
    let dock: CGRect?
    var floor: CGFloat { screen.minY }
    func bound(_ x: CGFloat, radius: CGFloat) -> CGFloat {
        let radius = min(radius, screen.width / 2)
        return clamp(x, screen.minX + radius, screen.maxX - radius)
    }
    func overlaps(_ x: CGFloat, _ radius: CGFloat) -> Bool {
        guard let dock else { return false }
        return x > dock.minX - radius && x < dock.maxX + radius
    }
    func support(_ x: CGFloat, _ radius: CGFloat) -> CGFloat {
        overlaps(x, radius) ? max(floor, dock?.maxY ?? floor) : floor
    }
    // A collision with the side of the Dock needs only an overlap. A place to stand
    // needs enough of the cat over the flat top, inside its rounded corners.
    func dockStandingRange(radius:CGFloat) -> ClosedRange<CGFloat>? {
        guard let dock else {return nil}
        let corner = dock.height * 0.35
        let inset = corner + radius * 0.85
        let left = max(screen.minX + radius, dock.minX + inset)
        let right = min(screen.maxX - radius, dock.maxX - inset)
        return left <= right ? left...right : nil
    }
    // On exceptionally small displays a large pet may fit neither on top nor beside
    // the Dock. Limit its on-screen size to the wider stretch of floor in that case.
    func fittingRadius(_ radius:CGFloat) -> CGFloat {
        guard let dock, dockStandingRange(radius:radius) == nil else {return radius}
        let floorWidth = max(dock.minX - screen.minX, screen.maxX - dock.maxX)
        return min(radius, floorWidth / 2)
    }
    func landingX(near x:CGFloat, radius:CGFloat) -> CGFloat {
        let x=bound(x,radius:radius)
        guard let dock,overlaps(x,radius) else {return x}
        let top=dockStandingRange(radius:radius).map {clamp(x,$0.lowerBound,$0.upperBound)}
        if let top, (dock.minX...dock.maxX).contains(x) {return top}
        let left=dock.minX-radius, right=dock.maxX+radius
        var candidates:[CGFloat]=[]
        if left>=screen.minX+radius {candidates.append(left)}
        if right<=screen.maxX-radius {candidates.append(right)}
        if let top {candidates.append(top)}
        return candidates.min {abs($0-x)<abs($1-x)} ?? bound(dock.midX,radius:radius)
    }
    // A stance change stays on the same surface, even at the lip of a narrow Dock.
    func turnX(from x:CGFloat,delta:CGFloat,radius:CGFloat,onDock:Bool)->CGFloat {
        let next=bound(x+delta,radius:radius)
        guard let dock else {return next}
        if onDock, let top=dockStandingRange(radius:radius) {return clamp(next,top.lowerBound,top.upperBound)}
        return x<=dock.midX ? min(next,dock.minX-radius):max(next,dock.maxX+radius)
    }
    // Returns a takeoff/landing pair. All coordinates are AppKit screen points.
    func crossing(from x: CGFloat, to next: CGFloat, direction: CGFloat, radius: CGFloat, onDock: Bool) -> Hop? {
        guard let dock, let top=dockStandingRange(radius:radius) else { return nil }
        if !onDock && overlaps(next, radius) {
            let end = direction > 0 ? top.lowerBound : top.upperBound
            return Hop(startX:x, endX:end, startY:floor, endY:dock.maxY, clearance:max(12, radius*0.43))
        }
        if onDock {
            let exit = direction > 0 ? dock.maxX : dock.minX
            let takeoff = direction > 0 ? top.upperBound : top.lowerBound
            guard direction*(next-takeoff) >= 0 else { return nil }
            let end = bound(exit + direction*(radius+2), radius:radius)
            guard !overlaps(end, radius) else { return nil }
            return Hop(startX:x, endX:end, startY:dock.maxY, endY:floor, clearance:0)
        }
        return nil
    }
}

struct Hop {
    let startX, endX, startY, endY, clearance: CGFloat
    var descending:Bool {endY<startY}
    func position(_ fraction: CGFloat) -> CGPoint {
        let t = clamp(fraction,0,1)
        if descending {
            let travel=clamp(t/0.84,0,1)
            let lower=clamp((t-0.19)/0.73,0,1)
            return CGPoint(x:startX+(endX-startX)*travel*travel*(3-2*travel),
                           y:startY+(endY-startY)*lower*lower*(3-2*lower))
        }
        let u = clamp((t-0.36)/0.56,0,1)
        let x = startX + (endX-startX)*u*u*(3-2*u)
        let crest = max(startY,endY) + clearance
        let apex = 0.56
        let v = t < apex ? (1-t/apex) : (t-apex)/(1-apex)
        let y = crest - (crest - (t < apex ? startY : endY))*v*v
        return CGPoint(x:x,y:y)
    }
}
