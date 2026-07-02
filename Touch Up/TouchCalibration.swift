//
//  TouchCalibration.swift
//  Touch Up
//

import AppKit
import TouchUpCore

struct TouchCalibrationSample {
    var raw: CGPoint
    var target: CGPoint
}

struct TouchCalibration: Codable, Equatable, Identifiable {
    var id: UUID
    var monitorKey: String
    var monitorName: String
    var createdAt: Date
    var enabled: Bool

    var xOffset: CGFloat
    var yOffset: CGFloat
    var xScale: CGFloat
    var yScale: CGFloat

    var xSkew: CGFloat
    var ySkew: CGFloat

    static func == (lhs: TouchCalibration, rhs: TouchCalibration) -> Bool {
        lhs.monitorKey == rhs.monitorKey &&
        lhs.enabled == rhs.enabled &&
        lhs.xOffset == rhs.xOffset &&
        lhs.yOffset == rhs.yOffset &&
        lhs.xScale == rhs.xScale &&
        lhs.yScale == rhs.yScale &&
        lhs.xSkew == rhs.xSkew &&
        lhs.ySkew == rhs.ySkew
    }

    static func identity(monitorKey: String, monitorName: String) -> TouchCalibration {
        TouchCalibration(
            id: UUID(),
            monitorKey: monitorKey,
            monitorName: monitorName,
            createdAt: Date(),
            enabled: false,
            xOffset: 0,
            yOffset: 0,
            xScale: 1,
            yScale: 1,
            xSkew: 0,
            ySkew: 0
        )
    }

    static func identity(for screen: TUCScreen) -> TouchCalibration {
        identity(monitorKey: screen.calibrationKey, monitorName: screen.name)
    }

    var isIdentity: Bool {
        !enabled &&
        xOffset == 0 &&
        yOffset == 0 &&
        xScale == 1 &&
        yScale == 1 &&
        xSkew == 0 &&
        ySkew == 0
    }

    func applying(to point: CGPoint) -> CGPoint {
        guard enabled else {
            return point
        }

        let x = point.x * xScale + point.y * xSkew + xOffset
        let y = point.y * yScale + point.x * ySkew + yOffset

        return CGPoint(
            x: min(1, max(0, x)),
            y: min(1, max(0, y))
        )
    }

    func sanitized(for screen: TUCScreen) -> TouchCalibration {
        sanitized(monitorKey: screen.calibrationKey, monitorName: screen.name)
    }

    func sanitized(monitorKey: String, monitorName: String) -> TouchCalibration {
        var calibration = self
        calibration.monitorKey = monitorKey
        calibration.monitorName = monitorName
        calibration.xOffset = calibration.xOffset.finiteOrDefault(0)
        calibration.yOffset = calibration.yOffset.finiteOrDefault(0)
        calibration.xScale = calibration.xScale.finiteOrDefault(1)
        calibration.yScale = calibration.yScale.finiteOrDefault(1)
        calibration.xSkew = calibration.xSkew.finiteOrDefault(0)
        calibration.ySkew = calibration.ySkew.finiteOrDefault(0)
        return calibration
    }

    func objectiveCCalibration() -> TUCTouchCalibration {
        let calibration = TUCTouchCalibration()
        calibration.enabled = enabled
        calibration.xOffset = xOffset
        calibration.yOffset = yOffset
        calibration.xScale = xScale
        calibration.yScale = yScale
        calibration.xSkew = xSkew
        calibration.ySkew = ySkew
        return calibration
    }

    static func fittingAffine(for screen: TUCScreen, samples: [TouchCalibrationSample]) -> TouchCalibration? {
        guard samples.count >= 3 else {
            return nil
        }

        var ata = Matrix3.zero
        var targetX = Vector3.zero
        var targetY = Vector3.zero

        for sample in samples {
            let row = Vector3(sample.raw.x, sample.raw.y, 1)
            ata.addOuterProduct(row)
            targetX.addScaled(row, by: sample.target.x)
            targetY.addScaled(row, by: sample.target.y)
        }

        guard let xParameters = ata.solving(targetX),
              let yParameters = ata.solving(targetY) else {
            return nil
        }

        var calibration = TouchCalibration.identity(for: screen)
        calibration.enabled = true
        calibration.xScale = xParameters.x
        calibration.xSkew = xParameters.y
        calibration.xOffset = xParameters.z
        calibration.ySkew = yParameters.x
        calibration.yScale = yParameters.y
        calibration.yOffset = yParameters.z
        return calibration.sanitized(for: screen)
    }
}

struct TouchCalibrationStore: Codable {
    static let currentSchemaVersion = 1
    static let historyLimit = 5

    var schemaVersion: Int
    var current: [String: TouchCalibration]
    var history: [String: [TouchCalibration]]

    static var empty: TouchCalibrationStore {
        TouchCalibrationStore(schemaVersion: currentSchemaVersion, current: [:], history: [:])
    }

    func calibration(for screen: TUCScreen) -> TouchCalibration {
        current[screen.calibrationKey]?.sanitized(for: screen) ?? .identity(for: screen)
    }

    func history(for screen: TUCScreen) -> [TouchCalibration] {
        history[screen.calibrationKey] ?? []
    }

    mutating func apply(_ calibration: TouchCalibration, for screen: TUCScreen) {
        let key = screen.calibrationKey
        let newCalibration = calibration.sanitized(for: screen).freshVersion()
        let oldCalibration = current[key]?.sanitized(for: screen) ?? .identity(for: screen)

        guard newCalibration != oldCalibration else {
            return
        }

        pushHistory(oldCalibration, for: key)
        current[key] = newCalibration
    }

    mutating func undo(for screen: TUCScreen) {
        let key = screen.calibrationKey
        var versions = history[key] ?? []

        guard !versions.isEmpty else {
            return
        }

        let restored = versions.removeFirst().sanitized(for: screen).freshVersion()
        history[key] = Array(versions.prefix(Self.historyLimit))
        current[key] = restored
    }

    mutating func reset(for screen: TUCScreen) {
        let key = screen.calibrationKey
        let oldCalibration = current[key]?.sanitized(for: screen) ?? .identity(for: screen)
        let identity = TouchCalibration.identity(for: screen).freshVersion()

        if oldCalibration != identity && !oldCalibration.isIdentity {
            pushHistory(oldCalibration, for: key)
        }

        current[key] = identity
    }

    mutating func restore(_ calibration: TouchCalibration, for screen: TUCScreen) {
        apply(calibration, for: screen)
    }

    mutating func normalize() {
        schemaVersion = Self.currentSchemaVersion
        current = current.mapValues { calibration in
            calibration.sanitized()
        }

        for key in history.keys {
            history[key] = normalizedHistory(history[key] ?? [])
        }
    }

    private mutating func pushHistory(_ calibration: TouchCalibration, for key: String) {
        var versions = history[key] ?? []
        let version = calibration.freshVersion()

        if versions.first != version {
            versions.insert(version, at: 0)
        }

        history[key] = normalizedHistory(versions)
    }

    private func normalizedHistory(_ versions: [TouchCalibration]) -> [TouchCalibration] {
        var result: [TouchCalibration] = []

        for version in versions {
            let sanitizedVersion = version.sanitized()
            if result.last != sanitizedVersion {
                result.append(sanitizedVersion)
            }
            if result.count == Self.historyLimit {
                break
            }
        }

        return result
    }
}

private extension TouchCalibration {
    func sanitized() -> TouchCalibration {
        sanitized(monitorKey: monitorKey, monitorName: monitorName)
    }

    func freshVersion() -> TouchCalibration {
        var calibration = self
        calibration.id = UUID()
        calibration.createdAt = Date()
        return calibration
    }
}

private extension CGFloat {
    func finiteOrDefault(_ defaultValue: CGFloat) -> CGFloat {
        isFinite ? self : defaultValue
    }
}

private struct Vector3 {
    static let zero = Vector3(0, 0, 0)

    var x: CGFloat
    var y: CGFloat
    var z: CGFloat

    init(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) {
        self.x = x
        self.y = y
        self.z = z
    }

    mutating func addScaled(_ vector: Vector3, by scale: CGFloat) {
        x += vector.x * scale
        y += vector.y * scale
        z += vector.z * scale
    }
}

private struct Matrix3 {
    static let zero = Matrix3()

    var m00: CGFloat = 0
    var m01: CGFloat = 0
    var m02: CGFloat = 0
    var m10: CGFloat = 0
    var m11: CGFloat = 0
    var m12: CGFloat = 0
    var m20: CGFloat = 0
    var m21: CGFloat = 0
    var m22: CGFloat = 0

    mutating func addOuterProduct(_ vector: Vector3) {
        m00 += vector.x * vector.x
        m01 += vector.x * vector.y
        m02 += vector.x * vector.z
        m10 += vector.y * vector.x
        m11 += vector.y * vector.y
        m12 += vector.y * vector.z
        m20 += vector.z * vector.x
        m21 += vector.z * vector.y
        m22 += vector.z * vector.z
    }

    func solving(_ vector: Vector3) -> Vector3? {
        let determinant =
            m00 * (m11 * m22 - m12 * m21) -
            m01 * (m10 * m22 - m12 * m20) +
            m02 * (m10 * m21 - m11 * m20)

        guard abs(determinant) > 0.000000001 else {
            return nil
        }

        let inv00 = (m11 * m22 - m12 * m21) / determinant
        let inv01 = (m02 * m21 - m01 * m22) / determinant
        let inv02 = (m01 * m12 - m02 * m11) / determinant

        let inv10 = (m12 * m20 - m10 * m22) / determinant
        let inv11 = (m00 * m22 - m02 * m20) / determinant
        let inv12 = (m02 * m10 - m00 * m12) / determinant

        let inv20 = (m10 * m21 - m11 * m20) / determinant
        let inv21 = (m01 * m20 - m00 * m21) / determinant
        let inv22 = (m00 * m11 - m01 * m10) / determinant

        return Vector3(
            inv00 * vector.x + inv01 * vector.y + inv02 * vector.z,
            inv10 * vector.x + inv11 * vector.y + inv12 * vector.z,
            inv20 * vector.x + inv21 * vector.y + inv22 * vector.z
        )
    }
}
