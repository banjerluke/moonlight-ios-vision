//
//  CurvedScreenMesh.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Mesh generation for the curved, rounded-corner stream screen.
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import RealityKit

let MAX_WIDTH_METERS: Float = 2.0
let MAX_CURVE_ANGLE: Float = 1.3
let CURVED_MAX_WIDTH_METERS: Float = MAX_WIDTH_METERS
let CURVED_MAX_ANGLE: Float = MAX_CURVE_ANGLE

/// Horizontal texture coordinate (0 = left edge, 1 = right edge) of the curved screen at `x` metres
/// from its centre, seen straight on. Points beyond the screen's edges clamp to 0 or 1.
func curvedScreenU(atX x: Float, curveMagnitude: Float) -> Float {
    let width = CURVED_MAX_WIDTH_METERS
    let angle = CURVED_MAX_ANGLE * max(0.0, min(curveMagnitude, 2.0))
    guard angle >= 0.001 else { return max(0, min(1, x / width + 0.5)) }

    let radius = width / angle
    let halfChord = radius * sin(angle / 2.0)
    let theta = asin(max(-halfChord, min(halfChord, x)) / radius)
    return theta / angle + 0.5
}

func generateCurvedRoundedPlane(
    width: Float,
    aspectRatio: Float,
    resolution: (UInt32, UInt32),
    curveMagnitude: Float,
    cornerRadiusFraction: Float,
    uvScale: Float = 1.0,
    isAmbilight: Bool = false,
    forcedRadius: Float? = nil
) throws -> MeshResource {
    var descr = MeshDescriptor(name: "curved_rounded_plane")
    let height = width * aspectRatio
    let vertexCount = Int(resolution.0 * resolution.1)
    let numQuadsX = resolution.0 - 1
    let numQuadsY = resolution.1 - 1
    let triangleCount = Int(numQuadsX * numQuadsY * 2)
    let indexCount = triangleCount * 3

    var positions = [SIMD3<Float>](repeating: .zero, count: vertexCount)
    var texcoords = [SIMD2<Float>](repeating: .zero, count: vertexCount)
    var indices = [UInt32](repeating: 0, count: indexCount)

    let maxCurveAngle: Float = CURVED_MAX_ANGLE

    let currentAngle: Float
    let radius: Float
    let isFlat: Bool

    if let fr = forcedRadius {
        radius = fr
        isFlat = !radius.isFinite || radius == 0
        currentAngle = isFlat ? 0.0 : (width / radius)
    } else {
        currentAngle = maxCurveAngle * max(0.0, min(curveMagnitude, 2.0))
        isFlat = currentAngle < 0.0001
        radius = isFlat ? .infinity : (width / currentAngle)
    }

    let halfAngle = currentAngle / 2.0

    let cornerRadius = max(0.0, min(0.25, cornerRadiusFraction)) * height
    let x0 = -width / 2.0
    let y0 = -height / 2.0

    let texInset: Float = 0.002

    var vi = 0
    var ii = 0

    for y_v in 0 ..< resolution.1 {
        let v_geo = Float(y_v) / Float(resolution.1 - 1)
        let yFlat = (0.5 - v_geo) * height
        let v_tex = (1.0 - v_geo) * (1.0 - 2.0 * texInset) + texInset

        for x_v in 0 ..< resolution.0 {
            let u = Float(x_v) / Float(resolution.0 - 1)
            let xFlat = (u - 0.5) * width

            var xr = xFlat, yr = yFlat
            if cornerRadius > 0 {
                if xr < x0 + cornerRadius && yr < y0 + cornerRadius {
                    let dx = xr - (x0 + cornerRadius), dy = yr - (y0 + cornerRadius)
                    if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (x0 + cornerRadius) + nx; yr = (y0 + cornerRadius) + ny }
                } else if xr > -x0 - cornerRadius && yr < y0 + cornerRadius {
                    let dx = xr - (-x0 - cornerRadius), dy = yr - (y0 + cornerRadius)
                    if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (-x0 - cornerRadius) + nx; yr = (y0 + cornerRadius) + ny }
                } else if xr < x0 + cornerRadius && yr > -y0 - cornerRadius {
                    let dx = xr - (x0 + cornerRadius), dy = yr - (-y0 - cornerRadius)
                    if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (x0 + cornerRadius) + nx; yr = (-y0 - cornerRadius) + ny }
                } else if xr > -x0 - cornerRadius && yr > -y0 - cornerRadius {
                    let dx = xr - (-x0 - cornerRadius), dy = yr - (-y0 - cornerRadius)
                    if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (-x0 - cornerRadius) + nx; yr = (-y0 - cornerRadius) + ny }
                }
            }

            var px = xr, pz: Float = 0.0
            if !isFlat, radius.isFinite {
                let t = xr / (width / 2.0)
                let theta = t * halfAngle
                px = radius * sin(theta)
                pz = radius - (radius * cos(theta))
            }

            positions[vi] = SIMD3<Float>(px, yr, pz)
            let u_tex = u * (1.0 - 2.0 * texInset) + texInset

            var final_u = u_tex
            var final_v = v_tex

            if isAmbilight {
                // Do not scale UVs. The texture itself has the video centered 
                // and fades to black at the edges via the new ambilight shader.
                final_u = u_tex
                final_v = v_tex
            }

            texcoords[vi] = SIMD2<Float>(final_u, final_v)

            if x_v < numQuadsX && y_v < numQuadsY {
                let current = UInt32(vi), nextRow = current + resolution.0
                indices[ii + 0] = current; indices[ii + 1] = nextRow; indices[ii + 2] = nextRow + 1
                indices[ii + 3] = current; indices[ii + 4] = nextRow + 1; indices[ii + 5] = current + 1
                ii += 6
            }
            vi += 1
        }
    }

    descr.positions = MeshBuffer(positions)
    descr.textureCoordinates = MeshBuffers.TextureCoordinates(texcoords)
    descr.primitives = .triangles(indices)
    return try MeshResource.generate(from: [descr])
}

private func normalizeAndScale(_ dx: Float, _ dy: Float, _ cornerRadius: Float) -> (Float, Float)? {
    let dist = sqrt(dx*dx + dy*dy)
    if dist > cornerRadius {
        let s = cornerRadius / dist
        return (dx * s, dy * s)
    }
    return nil
}
