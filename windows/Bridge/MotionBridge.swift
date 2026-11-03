import PacerEngineSupport
import Foundation
import PacerCore

// Stable C ABI: Windows calls the original Swift transition at display time.
// The bridge converts coordinate systems; it contains no animation equation.
private final class MotionBox {
    var latest: IslandTransition.Sample
    var transition: IslandTransition?
    var anchor: IslandGeometry.Anchor
    init(frame: CGRect, expanded: Bool, black: Bool, anchor: IslandGeometry.Anchor) {
        latest = .resting(at: frame, expanded: expanded, hasBlackHeader: black)
        self.anchor = anchor
    }
}

private func anchor(_ position: Int32) -> IslandGeometry.Anchor? {
    guard (0...4).contains(position) else { return nil }
    return [IslandPosition.center, .topLeft, .bottomLeft, .topRight, .bottomRight][Int(position)].anchor
}

private func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect? {
    guard [x, y, width, height].allSatisfy(\.isFinite), abs(x) <= 1e8, abs(y) <= 1e8,
          width > 0, height > 0, width <= 100_000, height <= 100_000 else { return nil }
    return CGRect(x: x, y: -y - height, width: width, height: height)
}

@_cdecl("pacer_motion_abi_version")
public func pacerMotionABIVersion() -> Int32 { 1 }

@_cdecl("pacer_custom_position")
public func pacerCustomPosition(_ saved: Int32, _ attached: Int32) -> Int32 {
    let positions: [IslandPosition] = [.center, .topLeft, .bottomLeft, .topRight, .bottomRight]
    guard (-1...4).contains(saved) else { return -1 }
    let value = IslandPosition.custom(saved: saved < 0 ? nil : positions[Int(saved)], attached: attached != 0)
    return Int32(positions.firstIndex(of: value)!)
}

@_cdecl("pacer_motion_create")
public func pacerMotionCreate(_ x: Double, _ y: Double, _ width: Double, _ height: Double,
                              _ expanded: Int32, _ blackHeader: Int32, _ position: Int32) -> UnsafeMutableRawPointer? {
    guard let frame = frame(x, y, width, height), let anchor = anchor(position) else { return nil }
    return Unmanaged.passRetained(MotionBox(frame: frame, expanded: expanded != 0, black: blackHeader != 0, anchor: anchor)).toOpaque()
}

@_cdecl("pacer_motion_destroy")
public func pacerMotionDestroy(_ handle: UnsafeMutableRawPointer?) {
    if let handle { Unmanaged<MotionBox>.fromOpaque(handle).release() }
}

@_cdecl("pacer_motion_retarget")
public func pacerMotionRetarget(_ handle: UnsafeMutableRawPointer?, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
                                _ expanded: Int32, _ blackHeader: Int32, _ position: Int32, _ time: Double) -> Int32 {
    guard let handle, let frame = frame(x, y, width, height), let anchor = anchor(position), time.isFinite else { return 0 }
    let box = Unmanaged<MotionBox>.fromOpaque(handle).takeUnretainedValue()
    box.anchor = anchor
    // PanelController retargets from the last displayed sample, including its
    // velocity. Do the same when a hover reverses between display callbacks.
    box.transition = IslandTransition(from: box.latest, to: frame, opening: expanded != 0,
        hasBlackHeader: blackHeader != 0, anchor: anchor, start: time)
    return 1
}

// Output: raw x/y/w/h, expansion, content, black opacity, finished,
// width/height/anchor-x/anchor-y/expansion velocities, integral window x/y/w/h.
@_cdecl("pacer_motion_sample")
public func pacerMotionSample(_ handle: UnsafeMutableRawPointer?, _ time: Double,
                              _ output: UnsafeMutablePointer<Double>?, _ capacity: Int32) -> Int32 {
    guard let handle, let output, capacity >= 17, time.isFinite else { return 0 }
    let box = Unmanaged<MotionBox>.fromOpaque(handle).takeUnretainedValue()
    if var transition = box.transition {
        box.latest = transition.sample(at: time)
        box.transition = box.latest.finished ? nil : transition
    }
    let sample = box.latest, bounds = sample.frame
    let window = IslandGeometry.windowFrame(bounds, anchor: box.anchor)
    let velocity = sample.geometry.velocity
    let values: [Double] = [bounds.minX, -bounds.maxY, bounds.width, bounds.height,
        sample.expansion, sample.content, sample.blackOpacity, sample.finished ? 1.0 : 0.0,
        velocity.width, velocity.height, velocity.anchorX, -velocity.anchorY, velocity.expansion,
        window.minX, -window.maxY, window.width, window.height]
    for index in values.indices { output[index] = values[index] }
    return 1
}

/// A read-only allocation bound for the Windows transparent drawing surface.
/// Geometry is evaluated on copies of the original transition. Neither the
/// displayed sample nor the state used by the next retarget is advanced.
@_cdecl("pacer_motion_canvas")
public func pacerMotionCanvas(_ handle: UnsafeMutableRawPointer?, _ time: Double,
                              _ output: UnsafeMutablePointer<Double>?, _ capacity: Int32) -> Int32 {
    guard let handle, let output, capacity >= 4, time.isFinite else { return 0 }
    let box = Unmanaged<MotionBox>.fromOpaque(handle).takeUnretainedValue()
    var bounds = box.latest.frame
    func evaluate(_ instant: Double) -> (CGRect, [Double]) {
        var transition = box.transition
        let sample = transition?.sample(at: instant) ?? box.latest
        let velocity = sample.geometry.velocity
        let horizontal: Double = box.anchor.horizontal == .left ? 0 : box.anchor.horizontal == .right ? 1 : 0.5
        let vertical: Double = box.anchor.vertical == .top ? 1 : 0
        return (sample.frame, [velocity.anchorX - horizontal * velocity.width,
            velocity.anchorX + (1 - horizontal) * velocity.width,
            velocity.anchorY - vertical * velocity.height,
            velocity.anchorY + (1 - vertical) * velocity.height])
    }
    var previousTime = time, previous = evaluate(time)
    bounds = bounds.union(previous.0)
    // Every edge of the original critically damped spring has at most one
    // velocity reversal. Bracket it, then ask that same spring for its extremum.
    for step in 1...75 {
        let nextTime = time + Double(step) / 50
        let next = evaluate(nextTime)
        bounds = bounds.union(next.0)
        for edge in 0..<4 where previous.1[edge] * next.1[edge] < 0 {
            var lower = previousTime, upper = nextTime
            let sign = previous.1[edge] > 0
            for _ in 0..<48 {
                let middle = (lower + upper) / 2
                if (evaluate(middle).1[edge] > 0) == sign { lower = middle } else { upper = middle }
            }
            bounds = bounds.union(evaluate((lower + upper) / 2).0)
        }
        previousTime = nextTime; previous = next
    }
    // Cover the original integral-window quantization, including odd widths.
    bounds = bounds.insetBy(dx: -2, dy: -2).integral
    let values: [Double] = [bounds.minX, -bounds.maxY, bounds.width, bounds.height]
    for index in values.indices { output[index] = values[index] }
    return 1
}

// Input: screen x/y/w/h, work area x/y/w/h (Windows coordinates), display
// mode (automatic/notch/floating), safe top, notch width, position, expanded,
// measured content width/height, measured header width, measured strip height.
// Output: target x/y/w/h, expanded canvas w/h, header height, attached,
// effective position and notch width. All measurements are logical points.
@_cdecl("pacer_layout_frame")
public func pacerLayoutFrame(_ input: UnsafePointer<Double>?, _ count: Int32,
                             _ output: UnsafeMutablePointer<Double>?, _ capacity: Int32) -> Int32 {
    guard let input, count == 17, let output, capacity >= 10 else { return 0 }
    let values = Array(UnsafeBufferPointer(start: input, count: 17))
    guard values.allSatisfy(\.isFinite), values[8].rounded() == values[8], (0...2).contains(values[8]),
          values[11].rounded() == values[11], (0...4).contains(values[11]),
          let screen = frame(values[0], values[1], values[2], values[3]),
          let visible = frame(values[4], values[5], values[6], values[7]),
          values[9...10].allSatisfy({ $0 >= 0 && $0 <= 10_000 }),
          values[13...16].allSatisfy({ $0 >= 0 && $0 <= 100_000 }) else { return 0 }
    let mode = [IslandDisplayMode.automatic, .notch, .floating][Int(values[8])]
    let layout = mode.layout(safeAreaTop: values[9], hardwareNotchWidth: values[10])
    let positionIndex = layout.attached ? 0 : Int(values[11])
    let position = [IslandPosition.center, .topLeft, .bottomLeft, .topRight, .bottomRight][positionIndex]
    func bounds(expanded: Bool) -> CGRect {
        if position.side != nil {
            return IslandGeometry.sideFrame(visible: visible, position: position, stripHeight: values[16], expanded: expanded,
                panelWidth: IslandWidth.sidePanel(contentWidth: values[13]), contentHeight: values[14])
        }
        let width = IslandWidth.desired(expanded: expanded, notchWidth: layout.notchWidth, leading: 80, trailing: 65,
            contentWidth: values[13], headerWidth: values[15])
        return IslandGeometry.frame(screen: screen, visible: visible, notchWidth: layout.notchWidth,
            topHeight: layout.topHeight, expanded: expanded, attached: layout.attached,
            contentHeight: values[14], desiredWidth: width)
    }
    let target = bounds(expanded: values[12] != 0), canvas = bounds(expanded: true)
    let result: [Double] = [target.minX, -target.maxY, target.width, target.height, canvas.width, canvas.height,
        layout.topHeight, layout.attached ? 1 : 0, Double(positionIndex), layout.notchWidth]
    for index in result.indices { output[index] = result[index] }
    return 1
}
