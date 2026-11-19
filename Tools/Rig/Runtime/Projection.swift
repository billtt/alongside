// A view change has two different drawings of the same articulated animal.
// Register their visible contours before exchanging ink. A same-view motion
// is evaluated entirely by the joint hierarchy in Skeleton.swift.
import CoreGraphics
import Foundation

private typealias V2 = SIMD2<Float>
private typealias RGBA = SIMD4<Float>

private struct Field {
  let side: Int
  let vectors: [V2]
  func at(_ point: V2, mirror: Bool) -> V2 {
    let u = mirror ? 1 - point.x : point.x
    let x = min(max(u * Float(side - 1), 0), Float(side - 1))
    let y = min(max(point.y * Float(side - 1), 0), Float(side - 1))
    let i = min(Int(x), side - 2)
    let j = min(Int(y), side - 2)
    let k = j * side + i
    let fx = x - Float(i)
    let fy = y - Float(j)
    let a = vectors[k] + (vectors[k + 1] - vectors[k]) * fx
    let b = vectors[k + side] + (vectors[k + side + 1] - vectors[k + side]) * fx
    var v = a + (b - a) * fy
    if mirror { v.x = -v.x }
    return v
  }
  func inverse(_ point: V2, fraction: Float, mirror: Bool) -> V2 {
    var p = point
    for _ in 0..<4 { p = point - at(p, mirror: mirror) * fraction }
    return p
  }
}

private struct DistanceMask {
  let side: Int
  let values: [Int8]
  func at(_ p: V2) -> Float {
    let x = p.x * Float(side) - 0.5
    let y = p.y * Float(side) - 0.5
    if x < -0.5 || y < -0.5 || x >= Float(side) - 0.5 || y >= Float(side) - 0.5 { return -2 }
    let i = max(0, min(Int(x), side - 2))
    let j = max(0, min(Int(y), side - 2))
    let k = j * side + i
    let tx = max(0, x - Float(i))
    let ty = max(0, y - Float(j))
    let a = Float(values[k]) * (1 - tx) + Float(values[k + 1]) * tx
    let b = Float(values[k + side]) * (1 - tx) + Float(values[k + side + 1]) * tx
    return (a + (b - a) * ty) * 0.25
  }
}

final class ProjectionAtlas {
  private struct File: Decodable {
    let grid, dist: Int
    let fields, masks: [String: Data]
  }
  fileprivate let fields: [String: Field]
  fileprivate let masks: [String: DistanceMask]
  let maskSize: Int
  init(root: URL) throws {
    let f = try JSONDecoder().decode(
      File.self, from: Data(contentsOf: root.appendingPathComponent("projection.json")))
    guard (3...128).contains(f.grid), (8...256).contains(f.dist) else {
      throw ArtError.invalid("视角校准尺寸")
    }
    maskSize = f.dist
    fields = try f.fields.mapValues { bytes in
      guard bytes.count == f.grid * f.grid * 4 else { throw ArtError.invalid("视角位移图") }
      return bytes.withUnsafeBytes { raw in
        let points = (0..<f.grid * f.grid).map { i -> V2 in
          let x = raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self)
          let y = raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self)
          return V2(Float(Int16(littleEndian: x)), Float(Int16(littleEndian: y))) / 32767
        }
        return Field(side: f.grid, vectors: points)
      }
    }
    masks = try f.masks.mapValues { bytes in
      guard bytes.count == f.dist * f.dist else { throw ArtError.invalid("视角轮廓") }
      return DistanceMask(side: f.dist, values: bytes.map { Int8(bitPattern: $0) })
    }
  }
}

private struct Surface {
  let raster: RigRaster
  let w, h: Int
  let pixels: UnsafePointer<UInt8>
  init(_ image: RigRaster) {
    raster = image
    w = image.image.width
    h = image.image.height
    pixels = UnsafePointer(image.pixels)
  }
  @inline(__always) func texel(_ x: Int, _ y: Int) -> RGBA {
    let vec = UnsafeRawPointer(pixels + (y * w + x) * 4).loadUnaligned(as: SIMD4<UInt8>.self)
    return RGBA(vec)
  }
  @inline(__always) func color(_ point: V2) -> RGBA {
    let x = point.x * Float(w) - 0.5
    let y = point.y * Float(h) - 0.5
    guard x > -1, y > -1, x < Float(w), y < Float(h) else { return .zero }
    let i = Int(floor(x))
    let j = Int(floor(y))
    let fx = x - Float(i)
    let fy = y - Float(j)
    if i >= 0 && j >= 0 && i + 1 < w && j + 1 < h {
      let a = texel(i, j) * (1 - fx) + texel(i + 1, j) * fx
      let b = texel(i, j + 1) * (1 - fx) + texel(i + 1, j + 1) * fx
      return a + (b - a) * fy
    }
    func bounded(_ i: Int, _ j: Int) -> RGBA {
      (i >= 0 && j >= 0 && i < w && j < h) ? texel(i, j) : .zero
    }
    return (bounded(i, j) * (1 - fx) + bounded(i + 1, j) * fx) * (1 - fy)
      + (bounded(i, j + 1) * (1 - fx) + bounded(i + 1, j + 1) * fx) * fy
  }
}

// A transient pose (for example a paw caught midway through a reach) has no
// baked contour. Measure its signed distance using the same normalised units.
private func contour(_ surface: Surface, side: Int) -> DistanceMask {
  let stride = side + 2
  var inside = [Bool](repeating: false, count: stride * stride)
  for y in 0..<side {
    for x in 0..<side {
      let uv = (V2(Float(x), Float(y)) + 0.5) / Float(side)
      inside[(y + 1) * stride + x + 1] = surface.color(uv).w >= 128
    }
  }
  func distance(to target: Bool) -> [Int] {
    var result = inside.map { $0 == target ? 0 : 512 }
    for y in 1...side {
      for x in 1...side {
        let k = y * stride + x
        result[k] = min(
          result[k], result[k - 1] + 4, result[k - stride] + 4, result[k - stride - 1] + 6,
          result[k - stride + 1] + 6)
      }
    }
    for y in (1...side).reversed() {
      for x in (1...side).reversed() {
        let k = y * stride + x
        result[k] = min(
          result[k], result[k + 1] + 4, result[k + stride] + 4, result[k + stride + 1] + 6,
          result[k + stride - 1] + 6)
      }
    }
    return result
  }
  let exterior = distance(to: false)
  let interior = distance(to: true)
  let values = (0..<side * side).map { i -> Int8 in
    let k = (i / side + 1) * stride + i % side + 1
    return Int8(clamping: exterior[k] - interior[k])
  }
  return DistanceMask(side: side, values: values)
}

// Interruptions can start on any displayed pose, including a partially turned
// one. Match small patches of that exact pose once when the new motion begins.
private func match(_ a: Surface, _ b: Surface, flip: Bool) -> (Field, Field) {
  let n = 48
  let side = 13
  func thumbnail(_ s: Surface, mirrored: Bool) -> [Float] {
    (0..<n * n).map { i in
      var p = V2(Float(i % n) + 0.5, Float(i / n) + 0.5) / Float(n)
      if mirrored { p.x = 1 - p.x }
      let c = s.color(p)
      return (c.w - (c.x + c.y + c.z) / 3) / 255
    }
  }
  func fit(_ first: [Float], _ last: [Float]) -> Field {
    var values = [V2](repeating: .zero, count: side * side)
    for j in 0..<side {
      for i in 0..<side {
        let x = i * 4
        let y = j * 4
        var best: Float = .infinity
        for dy in stride(from: -6, through: 6, by: 2) {
          for dx in stride(from: -6, through: 6, by: 2) {
            var cost = Float(dx * dx + dy * dy) * 0.0008
            for v in stride(from: -4, through: 4, by: 2) {
              for u in stride(from: -4, through: 4, by: 2) {
                let ax = x + u
                let ay = y + v
                let bx = ax + dx
                let by = ay + dy
                let l = (ax >= 0 && ay >= 0 && ax < n && ay < n) ? first[ay * n + ax] : 0
                let r = (bx >= 0 && by >= 0 && bx < n && by < n) ? last[by * n + bx] : 0
                cost += (l - r) * (l - r)
              }
            }
            if cost < best {
              best = cost
              values[j * side + i] = V2(Float(dx), Float(dy)) / Float(n)
            }
          }
        }
      }
    }
    let raw = values
    for j in 1..<side - 1 {
      for i in 1..<side - 1 {
        let k = j * side + i
        values[k] = (4 * raw[k] + raw[k - 1] + raw[k + 1] + raw[k - side] + raw[k + side]) / 8
      }
    }
    // Limit the displacement gradient here too. A suddenly occluded feature
    // must not invert a cell when the next action interrupts a half-turn.
    var maximum: Float = 0
    for j in 0..<side {
      for i in 0..<side {
        let k = j * side + i
        if i > 0 {
          let d = values[k] - values[k - 1]
          maximum = max(maximum, hypot(d.x, d.y))
        }
        if j > 0 {
          let d = values[k] - values[k - side]
          maximum = max(maximum, hypot(d.x, d.y))
        }
      }
    }
    let factor = min(1, 0.52 / (Float(side - 1) * max(0.00001, maximum)))
    let mean = values.reduce(V2.zero, +) / Float(values.count)
    values = values.map { mean + ($0 - mean) * factor }
    return Field(side: side, vectors: values)
  }
  let left = thumbnail(a, mirrored: false)
  let right = thumbnail(b, mirrored: flip)
  return (fit(left, right), fit(right, left))
}

final class ProjectionInterpolator {
  private let a, b: Surface
  private let forward, backward: Field
  private let maskA, maskB: DistanceMask
  private let mirrorA, mirrorB, flip: Bool
  init(a: RigRaster, b: RigRaster, from: SkeletalPose, to: SkeletalPose, flip: Bool) {
    let left = Surface(a)
    let right = Surface(b)
    self.a = left
    self.b = right
    self.flip = flip
    let suffix = from.reflected != to.reflected ? "|1" : "|0"
    let table = from.registration
    let maskSize = table?.maskSize ?? 96
    maskA = table?.masks[from.key] ?? contour(left, side: maskSize)
    maskB = table?.masks[to.key] ?? contour(right, side: maskSize)
    if let f = table?.fields[from.key + "|" + to.key + suffix],
      let r = table?.fields[to.key + "|" + from.key + suffix]
    {
      forward = f
      backward = r
      mirrorA = from.reflected
      mirrorB = to.reflected
    } else {
      (forward, backward) = match(left, right, flip: flip)
      mirrorA = false
      mirrorB = false
    }
  }
  func draw(time: CGFloat, in ctx: CGContext, size: CGSize) {
    let w = Int(size.width)
    let h = Int(size.height)
    let n = max(forward.side, backward.side)
    let t = Float(time)
    let q = t * t * (3 - 2 * t)
    var grid = [SIMD4<Float>]()
    grid.reserveCapacity(n * n)
    let groundA = Float(a.raster.grounded.height) / Float(a.h)
    let groundB = Float(b.raster.grounded.height) / Float(b.h)
    let floor = groundA + (groundB - groundA) * t
    for j in 0..<n {
      for i in 0..<n {
        let uv = V2(Float(i), Float(j)) / Float(n - 1)
        var l = forward.inverse(uv, fraction: t, mirror: mirrorA)
        var r = backward.inverse(uv, fraction: 1 - t, mirror: mirrorB)
        let contact = min(1, max(0, (uv.y - floor + 0.12) / 0.12))
        let lock = contact * contact * (3 - 2 * contact)
        l.y += (uv.y + groundA - floor - l.y) * lock
        r.y += (uv.y + groundB - floor - r.y) * lock
        if flip { r.x = 1 - r.x }
        grid.append(SIMD4(l.x, l.y, r.x, r.y))
      }
    }
    // RigRaster provides the native RGBA render target used for both
    // drawing and picking. Coordinates in these rows start at the top.
    let out = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
      let gy = (Float(y) + 0.5) * Float(n - 1) / Float(h)
      let j = min(Int(gy), n - 2)
      let fy = gy - Float(j)
      var x = 0
      for i in 0..<n - 1 {
        let k = j * n + i
        let l = grid[k] + (grid[k + n] - grid[k]) * fy
        let r = grid[k + 1] + (grid[k + n + 1] - grid[k + 1]) * fy
        let step = (r - l) * Float(n - 1) / Float(w)
        var uv = l + (r - l) * ((Float(x) + 0.5) * Float(n - 1) / Float(w) - Float(i))
        let end = min(w, Int(ceil(Float(i + 1) * Float(w) / Float(n - 1) - 0.5)))
        while x < end {
          let pa = V2(uv.x, uv.y)
          let pb = V2(uv.z, uv.w)
          let ca = a.color(pa)
          let cb = b.color(pb)
          var c = ca + (cb - ca) * q
          if abs(ca.w - cb.w) > 8, c.w > 0.1 {
            let sd = (1 - t) * maskA.at(pa) + t * maskB.at(pb)
            let coverage = min(1, max(0, 0.5 + sd * Float(min(w, h)) / Float(maskA.side)))
            let correction = 4 * t * (1 - t)
            let alpha = c.w + (255 * coverage - c.w) * correction
            c *= alpha / c.w
          }
          let bytes = SIMD4<UInt8>(clamping: SIMD4<Int32>(c + 0.5))
          UnsafeMutableRawPointer(out + (y * w + x) * 4).storeBytes(
            of: bytes, as: SIMD4<UInt8>.self)
          x += 1
          uv += step
        }
      }
    }
  }
}

struct ProjectionSample {
  let pair: ProjectionInterpolator
  let time: CGFloat
  func draw(in ctx: CGContext, size: CGSize) { pair.draw(time: time, in: ctx, size: size) }
}
