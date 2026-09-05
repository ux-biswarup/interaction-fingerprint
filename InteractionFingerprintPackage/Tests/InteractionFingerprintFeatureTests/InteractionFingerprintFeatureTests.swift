import CoreGraphics
import Foundation
import Testing
import simd
@testable import InteractionFingerprintFeature

// MARK: - Shared synthetic observer

/// A simulated person whose gaze estimate carries a fixed angular error.
///
/// This is the physical situation being modelled: the offset between the eye's optical and
/// visual axis is a constant angle for a given person, so the sensor reports an angle that
/// is a fixed affine function of the true one, whatever the distance.
private struct SyntheticObserver {
    var uScale = 0.85
    var uOffset = 0.09
    var vScale = 0.80
    var vOffset = -0.06
    var eyeX = 0.010
    var eyeY = -0.040

    let geometry = ScreenGeometry(pointSize: CGSize(width: 393, height: 852), displayScale: 3)

    /// What the tracker reports when this person looks at `target` from `distance`.
    func measurement(lookingAt target: CGPoint, from distance: Double) -> GazeMeasurement {
        let hit = geometry.cameraMetres(fromNormalised: target)
        let trueU = (Double(hit.x) - eyeX) / distance
        let trueV = (Double(hit.y) - eyeY) / distance
        return GazeMeasurement(
            u: uScale * trueU + uOffset,
            v: vScale * trueV + vOffset,
            eyeX: eyeX,
            eyeY: eyeY,
            distance: distance
        )
    }

    func point(lookingAt target: CGPoint, from distance: Double) -> GazeCalibrationPoint {
        let measured = measurement(lookingAt: target, from: distance)
        return GazeCalibrationPoint(
            target: target,
            convergence: measured,
            perEye: measured,
            headYaw: 0,
            headPitch: 0
        )
    }
}

private let nineTargets = GazeCalibrationRun.fitTargets
private let fourCheckTargets = GazeCalibrationRun.checkTargets

// MARK: - Blend shapes

@Test("V0 records exactly the nine blend shapes named in the setup guide")
func trackedBlendShapesMatchTheGuide() {
    #expect(TrackedBlendShapes.all.count == 9)
    // ARKit's raw values are not the Swift case names. Pinned here so that an SDK change
    // to the exported column names fails a test instead of silently breaking every
    // analysis notebook.
    #expect(Set(TrackedBlendShapes.keys) == [
        "eyeBlink_L", "eyeBlink_R",
        "eyeSquint_L", "eyeSquint_R",
        "eyeWide_L", "eyeWide_R",
        "browInnerUp", "browOuterUp_L", "browOuterUp_R",
    ])
}

@Test("Blend shape key order is stable, so exported columns keep a fixed order")
func blendShapeKeyOrderIsStable() {
    #expect(TrackedBlendShapes.keys == TrackedBlendShapes.all.map(\.rawValue))
    #expect(TrackedBlendShapes.keys.first == "eyeBlink_L")
}

@Test("Either eye closed marks the frame as a blink")
func blinkGateRejectsClosedEyes() {
    #expect(TrackedBlendShapes.eyesOpen(in: ["eyeBlink_L": 0.02, "eyeBlink_R": 0.03]))
    #expect(!TrackedBlendShapes.eyesOpen(in: ["eyeBlink_L": 0.9, "eyeBlink_R": 0.03]))
    #expect(!TrackedBlendShapes.eyesOpen(in: ["eyeBlink_L": 0.01, "eyeBlink_R": 0.7]))
    // Missing values must not read as a blink, or a dropout would look like one.
    #expect(TrackedBlendShapes.eyesOpen(in: [:]))
}

// MARK: - Screen geometry

@Test("An iPhone 15 sized display resolves to roughly its real physical size")
func screenGeometryEstimatesPhysicalSize() {
    let geometry = ScreenGeometry(pointSize: CGSize(width: 393, height: 852), displayScale: 3)
    // 6.1 inch diagonal, so about 65 mm by 141 mm of active area.
    #expect(abs(geometry.physicalSize.width - 0.0651) < 0.002)
    #expect(abs(geometry.physicalSize.height - 0.1411) < 0.002)
}

@Test("Normalised and camera-space conversions are exact inverses")
func screenGeometryRoundTrips() {
    let geometry = ScreenGeometry(pointSize: CGSize(width: 393, height: 852), displayScale: 3)
    for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.37, y: 0.62)] {
        let round = geometry.normalised(fromCameraMetres: geometry.cameraMetres(fromNormalised: point))
        #expect(abs(Double(round.x) - Double(point.x)) < 1e-9)
        #expect(abs(Double(round.y) - Double(point.y)) < 1e-9)
    }
}

// MARK: - Gaze ray

@Test("Looking straight back at the camera gives zero gaze angle")
func rayStraightAtCameraHasZeroAngle() throws {
    var left = matrix_identity_float4x4
    left.columns.3 = SIMD4(-0.03, 0, -0.4, 1)
    var right = matrix_identity_float4x4
    right.columns.3 = SIMD4(0.03, 0, -0.4, 1)

    let estimate = try #require(
        GazeRay.convergenceEstimate(
            faceInCamera: matrix_identity_float4x4,
            leftEye: left,
            rightEye: right,
            lookAtPoint: SIMD3(0, 0, 0.4)
        )
    )
    #expect(abs(estimate.u) < 1e-6)
    #expect(abs(estimate.v) < 1e-6)
    #expect(abs(estimate.viewingDistance - 0.4) < 1e-6)
}

@Test("The same angle lands twice as far from centre when held twice as far away")
func angleScalesWithDistance() throws {
    let near = GazeRay.Estimate(eye: SIMD3(0, 0, -0.30), u: 0.1, v: -0.2)
    let far = GazeRay.Estimate(eye: SIMD3(0, 0, -0.60), u: 0.1, v: -0.2)

    let nearHit = try #require(near.screenPlaneHit())
    let farHit = try #require(far.screenPlaneHit())

    // This is precisely why a correction learned as a distance on the screen cannot be
    // reused at another distance, and why the correction is applied to the angle instead.
    #expect(abs(Double(farHit.x) - 2 * Double(nearHit.x)) < 1e-9)
    #expect(abs(Double(farHit.y) - 2 * Double(nearHit.y)) < 1e-9)
}

@Test("A gaze travelling away from the device produces no estimate")
func rayPointingAwayIsRejected() {
    var eye = matrix_identity_float4x4
    eye.columns.3 = SIMD4(0, 0, -0.4, 1)
    // Convergence point further from the device than the eyes are.
    #expect(
        GazeRay.convergenceEstimate(
            faceInCamera: matrix_identity_float4x4,
            leftEye: eye,
            rightEye: eye,
            lookAtPoint: SIMD3(0, 0, -1.0)
        ) == nil
    )
}

// MARK: - Least squares

@Test("The solver recovers the coefficients of an exactly determined system")
func leastSquaresSolvesKnownSystem() throws {
    // y = 2 + 3a - 1.5b
    let rows: [(Double, Double)] = [(0, 0), (1, 0), (0, 1), (2, 1), (1, 3)]
    let design = rows.map { [1, $0.0, $0.1] }
    let observations = rows.map { 2 + 3 * $0.0 - 1.5 * $0.1 }

    let solution = try #require(LeastSquares.solve(design: design, observations: observations))
    #expect(abs(solution[0] - 2) < 1e-9)
    #expect(abs(solution[1] - 3) < 1e-9)
    #expect(abs(solution[2] + 1.5) < 1e-9)
}

@Test("A rank deficient system is reported as a failure rather than a wild answer")
func leastSquaresRejectsSingularSystem() {
    // Second column is a copy of the first, so the system cannot be inverted.
    let design = [[1.0, 1.0, 1.0], [1.0, 2.0, 2.0], [1.0, 3.0, 3.0], [1.0, 4.0, 4.0]]
    #expect(LeastSquares.solve(design: design, observations: [1, 2, 3, 4]) == nil)
}

@Test("Shrinkage pulls the slope towards zero without touching the intercept")
func ridgeShrinksCoefficients() throws {
    let design = (0..<8).map { [1.0, Double($0)] }
    let observations = (0..<8).map { 5.0 + 2.0 * Double($0) }

    let plain = try #require(LeastSquares.solve(design: design, observations: observations))
    let shrunk = try #require(LeastSquares.solve(design: design, observations: observations, ridge: 0.5))

    #expect(abs(plain[1] - 2) < 1e-9)
    #expect(shrunk[1] < plain[1])
    #expect(shrunk[1] > 0)
}

// MARK: - The distance invariance regression

@Test("A calibration fitted at one distance still holds at another")
func calibrationSurvivesTheUserMovingThePhone() throws {
    let observer = SyntheticObserver()
    let fitPoints = nineTargets.map { observer.point(lookingAt: $0, from: 0.35) }

    let model = try #require(GazeModelFitter.best(points: fitPoints, geometry: observer.geometry))

    // Held out at the distance it was fitted at.
    #expect(model.heldOutErrorPoints < 2)

    // The same person, the same angular error, the phone now much further away.
    let movedPoints = fourCheckTargets.map { observer.point(lookingAt: $0, from: 0.52) }
    let moved = try #require(
        GazeModelFitter.error(of: model, on: movedPoints, geometry: observer.geometry)
    )
    #expect(moved.mean < 5)

    // And much closer.
    let closePoints = fourCheckTargets.map { observer.point(lookingAt: $0, from: 0.25) }
    let close = try #require(
        GazeModelFitter.error(of: model, on: closePoints, geometry: observer.geometry)
    )
    #expect(close.mean < 5)
}

@Test("Correcting where the gaze lands, rather than its angle, breaks when the phone moves")
func positionalCalibrationFailsAcrossDistance() throws {
    // This reproduces the bug that was shipped and then fixed. It fits the mapping the old
    // way, from the landing position in metres straight to a screen coordinate, and shows
    // that the result falls apart at a different distance. Keeping it as a test means the
    // mistake cannot quietly return.
    let observer = SyntheticObserver()
    let geometry = observer.geometry

    func landingPosition(_ measurement: GazeMeasurement) -> CGPoint {
        CGPoint(
            x: measurement.eyeX + measurement.distance * measurement.u,
            y: measurement.eyeY + measurement.distance * measurement.v
        )
    }

    let fitPoints = nineTargets.map { observer.point(lookingAt: $0, from: 0.35) }
    let design = fitPoints.map { point -> [Double] in
        let hit = landingPosition(point.convergence!)
        return [1, Double(hit.x), Double(hit.y)]
    }
    let xCoefficients = try #require(
        LeastSquares.solve(design: design, observations: fitPoints.map { Double($0.target.x) })
    )
    let yCoefficients = try #require(
        LeastSquares.solve(design: design, observations: fitPoints.map { Double($0.target.y) })
    )

    func positionalError(at distance: Double, targets: [CGPoint]) -> Double {
        var total = 0.0
        for target in targets {
            let hit = landingPosition(observer.measurement(lookingAt: target, from: distance))
            let terms = [1, Double(hit.x), Double(hit.y)]
            let predicted = CGPoint(
                x: zip(terms, xCoefficients).reduce(0) { $0 + $1.0 * $1.1 },
                y: zip(terms, yCoefficients).reduce(0) { $0 + $1.0 * $1.1 }
            )
            total += GazeModelFitter.distanceInPoints(predicted, target, geometry: geometry)
        }
        return total / Double(targets.count)
    }

    // Accurate at the distance it was fitted at.
    #expect(positionalError(at: 0.35, targets: nineTargets) < 2)
    // And badly wrong once the phone moves, which is exactly what was reported on device.
    #expect(positionalError(at: 0.52, targets: fourCheckTargets) > 60)
}

// MARK: - Model fitting

@Test("Cross-validation prefers a model that generalises over one that merely fits")
func fitterRanksCandidatesByHeldOutError() throws {
    let observer = SyntheticObserver()
    let points = nineTargets.map { observer.point(lookingAt: $0, from: 0.38) }

    let ranked = GazeModelFitter.rank(points: points, geometry: observer.geometry)
    #expect(!ranked.isEmpty)

    // Sorted best first.
    let errors = ranked.map(\.model.heldOutErrorPoints)
    #expect(errors == errors.sorted())

    // The truth here is affine, so an affine model should win outright.
    #expect(ranked[0].basis == .affine)
    #expect(ranked[0].model.heldOutErrorPoints < 2)
}

@Test("A calibration built from too few targets is refused")
func fitterRejectsTooFewTargets() {
    let observer = SyntheticObserver()
    let points = Array(nineTargets.prefix(3)).map { observer.point(lookingAt: $0, from: 0.35) }
    #expect(GazeModelFitter.best(points: points, geometry: observer.geometry) == nil)
}

@Test("The calibrated distance range records what was actually measured")
func modelRecordsDistanceRange() throws {
    let observer = SyntheticObserver()
    var points = nineTargets.map { observer.point(lookingAt: $0, from: 0.34) }
    points[4] = observer.point(lookingAt: nineTargets[4], from: 0.41)

    let model = try #require(GazeModelFitter.best(points: points, geometry: observer.geometry))
    #expect(abs(model.calibratedDistanceRange.lowerBound - 0.34) < 1e-9)
    #expect(abs(model.calibratedDistanceRange.upperBound - 0.41) < 1e-9)
}

@Test("A round trip through storage preserves the model")
func modelSurvivesStorage() throws {
    let observer = SyntheticObserver()
    let defaults = try #require(UserDefaults(suiteName: "gaze.test.\(UUID().uuidString)"))
    let model = try #require(
        GazeModelFitter.best(
            points: nineTargets.map { observer.point(lookingAt: $0, from: 0.35) },
            geometry: observer.geometry
        )
    )

    GazeModelStore.save(model, to: defaults)
    #expect(GazeModelStore.load(from: defaults) == model)

    GazeModelStore.clear(from: defaults)
    #expect(GazeModelStore.load(from: defaults) == nil)
}

// MARK: - Quality envelope

@Test("The envelope names the specific reason a frame cannot be trusted")
func qualityEnvelopeReportsReasons() {
    #expect(
        GazeQuality.evaluate(isTracked: false, eyesOpen: true, distance: 0.35, headRotation: 0, model: nil)
            == .noFace
    )
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: false, distance: 0.35, headRotation: 0, model: nil)
            == .blinking
    )
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.15, headRotation: 0, model: nil)
            == .tooClose(0.15)
    )
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.90, headRotation: 0, model: nil)
            == .tooFar(0.90)
    )
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headRotation: 0.8, model: nil)
            == .headTurned(0.8)
    )
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headRotation: 0, model: nil)
            == .notCalibrated
    )
}

@Test("Drifting well outside the calibrated distance is flagged, small drift is not")
func qualityEnvelopeChecksCalibratedRange() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(
            points: nineTargets.map { observer.point(lookingAt: $0, from: 0.35) },
            geometry: observer.geometry
        )
    )

    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.36, headRotation: 0, model: model)
            == .good
    )
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.55, headRotation: 0, model: model)
            == .outsideCalibratedRange(0.55)
    )
}

@Test("Frames outside the envelope are excluded from analysis but a rough estimate is not")
func qualityUsabilityRules() {
    #expect(GazeQuality.good.isUsable)
    #expect(GazeQuality.notCalibrated.isUsable)
    #expect(!GazeQuality.blinking.isUsable)
    #expect(!GazeQuality.noFace.isUsable)
    #expect(!GazeQuality.tooFar(0.9).isUsable)
    #expect(GazeQuality.good.isConfident)
    #expect(!GazeQuality.notCalibrated.isConfident)
}

// MARK: - Robust averaging

@Test("A single stray sample does not drag the per-target median")
func medianIgnoresOutliers() {
    // Sorted: 0.01, 0.0105, 0.011, 0.012, 5.0 -> 0.011
    #expect(abs(GazeCalibrationRun.median([0.01, 0.011, 0.012, 0.0105, 5.0]) - 0.011) < 1e-12)
    // Even count averages the middle pair.
    #expect(abs(GazeCalibrationRun.median([1, 2, 3, 4]) - 2.5) < 1e-12)
}

@Test("Median measurement combines every component independently")
func medianMeasurementCombinesComponents() throws {
    let values = [
        GazeMeasurement(u: 0.10, v: -0.20, eyeX: 0.01, eyeY: -0.04, distance: 0.35),
        GazeMeasurement(u: 0.11, v: -0.21, eyeX: 0.011, eyeY: -0.041, distance: 0.36),
        GazeMeasurement(u: 9.00, v: 9.00, eyeX: 9.0, eyeY: 9.0, distance: 9.0),
    ]
    // Sorted v: -0.21, -0.20, 9.00 -> -0.20
    let median = try #require(GazeCalibrationRun.medianMeasurement(values))
    #expect(abs(median.u - 0.11) < 1e-12)
    #expect(abs(median.v + 0.20) < 1e-12)
    #expect(abs(median.distance - 0.36) < 1e-12)
}

// MARK: - Smoothing

@Test("The filter passes the first sample through and then converges on a steady value")
func oneEuroFilterConverges() {
    var filter = OneEuroFilter()
    #expect(filter.filter(0.5, timestamp: 0) == 0.5)

    var value = 0.0
    for step in 1...120 {
        value = filter.filter(0.9, timestamp: Double(step) / 60.0)
    }
    #expect(abs(value - 0.9) < 0.01)
}

// MARK: - Sample encoding

@Test("A tracked sample survives a JSON round trip unchanged")
func faceSampleRoundTripsThroughJSON() throws {
    let sample = FaceSample(
        timestamp: 1234.5,
        isTracked: true,
        eyesOpen: true,
        quality: "good",
        eyeX: 0.01, eyeY: -0.04, eyeZ: -0.35,
        convergenceU: 0.12, convergenceV: -0.31,
        perEyeU: 0.11, perEyeV: -0.30,
        gazeX: 0.61, gazeY: 0.38,
        isCalibrated: true,
        signals: ["eyeSquint_L": 0.21, "eyeBlink_R": 0.04],
        head: HeadPose(x: 0.01, y: -0.02, z: -0.35, pitch: 0.05, yaw: -0.02, roll: 0)
    )

    let data = try JSONEncoder().encode(sample)
    #expect(try JSONDecoder().decode(FaceSample.self, from: data) == sample)
}

@Test("Tracking loss is recorded rather than dropped, with explicit nulls")
func untrackedSampleKeepsNullGaze() throws {
    let sample = FaceSample(
        timestamp: 99,
        isTracked: false,
        eyesOpen: false,
        quality: "no_face",
        eyeX: nil, eyeY: nil, eyeZ: nil,
        convergenceU: nil, convergenceV: nil,
        perEyeU: nil, perEyeV: nil,
        gazeX: nil, gazeY: nil,
        isCalibrated: false,
        signals: [:],
        head: nil
    )

    let data = try JSONEncoder().encode(sample)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    // Analysis reads these as a stable column set, so the keys must be present as nulls
    // rather than omitted.
    #expect(object?["isTracked"] as? Bool == false)
    #expect(object?["quality"] as? String == "no_face")
    for key in ["gazeX", "gazeY", "convergenceU", "perEyeV", "eyeZ", "head"] {
        #expect(object?[key] is NSNull)
    }
}

@Test("Head pose reports combined off-axis rotation for the envelope check")
func headPoseCombinesRotation() {
    let pose = HeadPose(x: 0, y: 0, z: -0.35, pitch: 0.3, yaw: 0.4, roll: 1.0)
    #expect(abs(pose.offAxisRotation - 0.5) < 1e-12)
}
