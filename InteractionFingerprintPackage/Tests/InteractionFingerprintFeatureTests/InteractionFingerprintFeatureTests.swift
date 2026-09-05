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
    /// A fixed angular error, standing in for the offset between the eye's optical and
    /// visual axis. It is a property of the person and does not change with distance.
    var uScale = 0.85
    var uOffset = 0.09
    var vScale = 0.80
    var vOffset = -0.06
    var eyeX = 0.010
    var eyeY = -0.040
    /// Where the camera really is relative to where the nominal geometry assumes it is.
    /// On a Dynamic Island iPhone the camera sits inside the display area and off centre,
    /// so this is millimetres, not zero, and it is a distance rather than an angle.
    var cameraOffsetX = 0.0075
    var cameraOffsetY = -0.0110

    let geometry = ScreenGeometry(pointSize: CGSize(width: 393, height: 852), displayScale: 3)

    /// What the tracker reports when this person looks at `target` from `distance`.
    func measurement(lookingAt target: CGPoint, from distance: Double) -> GazeMeasurement {
        let nominal = geometry.cameraMetres(fromNormalised: target)
        let trueX = Double(nominal.x) + cameraOffsetX
        let trueY = Double(nominal.y) + cameraOffsetY
        let trueU = (trueX - eyeX) / distance
        let trueV = (trueY - eyeY) / distance
        return GazeMeasurement(
            u: uScale * trueU + uOffset,
            v: vScale * trueV + vOffset,
            eyeX: eyeX,
            eyeY: eyeY,
            distance: distance
        )
    }

    func point(_ index: Int, from distance: Double) -> GazeCalibrationPoint {
        let target = GazeCalibrationRun.targets[index]
        let measured = measurement(lookingAt: target, from: distance)
        return GazeCalibrationPoint(
            target: target,
            targetIndex: index,
            convergence: measured,
            perEye: measured,
            headYaw: 0,
            headPitch: 0
        )
    }

    /// A full calibration: the whole grid seen at two viewing distances, with a burst of
    /// frames per target as the real run produces.
    func calibration(near: Double = 0.32, far: Double = 0.46, framesPerTarget: Int = 20) -> [GazeCalibrationPoint] {
        GazeCalibrationRun.targets.indices.flatMap { index in
            (0..<framesPerTarget).flatMap { _ in
                [point(index, from: near), point(index, from: far)]
            }
        }
    }

    func grid(at distance: Double) -> [GazeCalibrationPoint] {
        GazeCalibrationRun.targets.indices.map { point($0, from: distance) }
    }
}


// MARK: - Blend shapes

@Test("V0 records exactly the nine blend shapes named in the setup guide")
func trackedBlendShapesMatchTheGuide() {
    #expect(TrackedBlendShapes.all.count == 9)
    // ARKit's raw values are not the Swift case names. Pinned here so an SDK change to the
    // exported column names fails a test instead of silently breaking every notebook.
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
            leftEye: left, rightEye: right,
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

    // Precisely why a correction learned as a distance on the screen cannot be reused at
    // another distance, and why the correction is applied to the angle instead.
    #expect(abs(Double(farHit.x) - 2 * Double(nearHit.x)) < 1e-9)
    #expect(abs(Double(farHit.y) - 2 * Double(nearHit.y)) < 1e-9)
}

@Test("A gaze travelling away from the device produces no estimate")
func rayPointingAwayIsRejected() {
    var eye = matrix_identity_float4x4
    eye.columns.3 = SIMD4(0, 0, -0.4, 1)
    #expect(
        GazeRay.convergenceEstimate(
            faceInCamera: matrix_identity_float4x4,
            leftEye: eye, rightEye: eye,
            lookAtPoint: SIMD3(0, 0, -1.0)
        ) == nil
    )
}

// MARK: - Least squares

@Test("The solver recovers the coefficients of a known system")
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

// MARK: - The two failures that were reported on device

@Test("Calibrating at two distances recovers where the camera actually is")
func calibrationSolvesCameraPosition() throws {
    // The nominal geometry assumes the camera sits at the top centre of the display. On a
    // Dynamic Island iPhone it does not, and the real offset is millimetres of fixed
    // distance rather than an angle. The two are only separable across viewing distances.
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry)
    )

    #expect(model.basis.solvesCameraOffset)
    let offset = model.cameraOffsetMillimetres
    #expect(abs(offset.x - 7.5) < 0.5)
    #expect(abs(offset.y + 11.0) < 0.5)
    #expect(model.accuracyPoints < 3)
}

@Test("A calibration built at two distances holds at distances it never saw")
func calibrationSurvivesTheUserMovingThePhone() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(near: 0.32, far: 0.46), geometry: observer.geometry)
    )

    for distance in [0.26, 0.38, 0.55] {
        let score = try #require(
            GazeModelFitter.error(of: model, on: observer.grid(at: distance), geometry: observer.geometry)
        )
        #expect(score.mean < 6)
    }
}

@Test("One distance alone cannot separate the camera position from the eye's own offset")
func singleDistanceCannotSolveCameraPosition() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.grid(at: 0.35), geometry: observer.geometry)
    )

    // The fitter must refuse to pretend, and fall back to a shape it can identify.
    #expect(!model.basis.solvesCameraOffset)

    // That model looks excellent where it was built and drifts once the phone moves, which
    // is exactly the behaviour that was reported on device.
    let atFitDistance = try #require(
        GazeModelFitter.error(of: model, on: observer.grid(at: 0.35), geometry: observer.geometry)
    )
    let afterMoving = try #require(
        GazeModelFitter.error(of: model, on: observer.grid(at: 0.52), geometry: observer.geometry)
    )
    #expect(atFitDistance.mean < 2)
    #expect(afterMoving.mean > atFitDistance.mean * 5)
}

@Test("Correcting where the gaze lands, rather than its angle, breaks when the phone moves")
func positionalCalibrationFailsAcrossDistance() throws {
    // Reproduces the first version's approach, fitting straight from the landing position
    // in metres to a screen coordinate. Kept as a test so the mistake cannot return.
    let observer = SyntheticObserver()
    let geometry = observer.geometry

    func landing(_ m: GazeMeasurement) -> CGPoint {
        CGPoint(x: m.eyeX + m.distance * m.u, y: m.eyeY + m.distance * m.v)
    }

    let fitPoints = observer.grid(at: 0.35)
    let design = fitPoints.map { point -> [Double] in
        let hit = landing(point.convergence!)
        return [1, Double(hit.x), Double(hit.y)]
    }
    let xCoefficients = try #require(
        LeastSquares.solve(design: design, observations: fitPoints.map { Double($0.target.x) })
    )
    let yCoefficients = try #require(
        LeastSquares.solve(design: design, observations: fitPoints.map { Double($0.target.y) })
    )

    func positionalError(at distance: Double) -> Double {
        var total = 0.0
        for point in observer.grid(at: distance) {
            let hit = landing(point.convergence!)
            let terms = [1, Double(hit.x), Double(hit.y)]
            let predicted = CGPoint(
                x: zip(terms, xCoefficients).reduce(0) { $0 + $1.0 * $1.1 },
                y: zip(terms, yCoefficients).reduce(0) { $0 + $1.0 * $1.1 }
            )
            total += GazeModelFitter.distanceInPoints(predicted, point.target, geometry: geometry)
        }
        return total / 9
    }

    #expect(positionalError(at: 0.35) < 2)
    #expect(positionalError(at: 0.52) > 60)
}

// MARK: - Model selection

@Test("Candidates are ranked by cross-validated error, best first")
func fitterRanksCandidates() {
    let observer = SyntheticObserver()
    let ranked = GazeModelFitter.rank(points: observer.calibration(), geometry: observer.geometry)
    #expect(!ranked.isEmpty)
    let errors = ranked.map(\.model.accuracyPoints)
    #expect(errors == errors.sorted())
    #expect(ranked[0].model.accuracyPoints < 3)
}

@Test("Holding a target out removes it at every distance it was visited")
func crossValidationGroupsByTargetPosition() throws {
    // If the same screen position were held out at one distance but left in at the other,
    // the model would already know the answer and the reported error would be fiction.
    let observer = SyntheticObserver()
    let points = observer.calibration()
    let groups = Set(points.map(\.targetIndex))
    #expect(groups.count == GazeCalibrationRun.targets.count)
    #expect(points.count == GazeCalibrationRun.targets.count * 40)

    let model = try #require(GazeModelFitter.best(points: points, geometry: observer.geometry))
    #expect(model.targetCount == GazeCalibrationRun.targets.count)
    #expect(model.sampleCount == points.count)
}

@Test("A calibration built from too few targets is refused")
func fitterRejectsTooFewTargets() {
    let observer = SyntheticObserver()
    let points = (0..<3).map { observer.point($0, from: 0.35) }
    #expect(GazeModelFitter.best(points: points, geometry: observer.geometry) == nil)
}

@Test("The calibrated distance range records what was actually measured")
func modelRecordsDistanceRange() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(near: 0.30, far: 0.44), geometry: observer.geometry)
    )
    #expect(abs(model.calibratedDistanceRange.lowerBound - 0.30) < 1e-9)
    #expect(abs(model.calibratedDistanceRange.upperBound - 0.44) < 1e-9)
}

@Test("A round trip through storage preserves the model")
func modelSurvivesStorage() throws {
    let observer = SyntheticObserver()
    let defaults = try #require(UserDefaults(suiteName: "gaze.test.\(UUID().uuidString)"))
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry)
    )

    GazeModelStore.save(model, to: defaults)
    #expect(GazeModelStore.load(from: defaults) == model)

    GazeModelStore.clear(from: defaults)
    #expect(GazeModelStore.load(from: defaults) == nil)
}

// MARK: - Quality envelope

@Test("The envelope names the specific reason a frame cannot be trusted")
func qualityEnvelopeReportsReasons() {
    #expect(GazeQuality.evaluate(isTracked: false, eyesOpen: true, distance: 0.35, headRotation: 0, model: nil) == .noFace)
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: false, distance: 0.35, headRotation: 0, model: nil) == .blinking)
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.15, headRotation: 0, model: nil) == .tooClose(0.15))
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.90, headRotation: 0, model: nil) == .tooFar(0.90))
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headRotation: 0.8, model: nil) == .headTurned(0.8))
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headRotation: 0, model: nil) == .notCalibrated)
}

@Test("A phone in motion is reported before any geometry test, because the geometry is stale")
func qualityFlagsDeviceMotionFirst() {
    // During movement the face anchor and the camera transform disagree, so the distance
    // those other checks rely on is itself unreliable.
    #expect(
        GazeQuality.evaluate(
            isTracked: true, eyesOpen: true, distance: 0.90,
            headRotation: 0, deviceIsSteady: false, model: nil
        ) == .deviceMoving
    )
    #expect(!GazeQuality.deviceMoving.isUsable)
}

@Test("Drifting well outside the calibrated distance is flagged, small drift is not")
func qualityEnvelopeChecksCalibratedRange() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(near: 0.32, far: 0.40), geometry: observer.geometry)
    )
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.36, headRotation: 0, model: model) == .good)
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.60, headRotation: 0, model: model)
            == .outsideCalibratedRange(0.60)
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

// MARK: - Robust reduction

@Test("A single stray sample does not drag the per-target median")
func medianIgnoresOutliers() {
    #expect(abs(GazeCalibrationRun.median([0.01, 0.011, 0.012, 0.0105, 5.0]) - 0.011) < 1e-12)
    #expect(abs(GazeCalibrationRun.median([1, 2, 3, 4]) - 2.5) < 1e-12)
}

@Test("Median absolute deviation is not inflated by one outlier")
func madResistsOutliers() {
    #expect(abs(GazeCalibrationRun.medianAbsoluteDeviation([1, 1, 1, 1, 100]) - 0) < 1e-12)
    #expect(GazeCalibrationRun.medianAbsoluteDeviation([1, 2, 3, 4, 5]) > 0.9)
}

// MARK: - Device motion

@Test("Motion magnitude combines all three axes")
func motionMagnitudeCombinesAxes() {
    #expect(abs(DeviceMotionMonitor.magnitude(3, 4, 0) - 5) < 1e-12)
    #expect(abs(DeviceMotionMonitor.magnitude(0, 0, 0)) < 1e-12)
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
        isTracked: true, eyesOpen: true, quality: "good",
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
        isTracked: false, eyesOpen: false, quality: "no_face",
        eyeX: nil, eyeY: nil, eyeZ: nil,
        convergenceU: nil, convergenceV: nil,
        perEyeU: nil, perEyeV: nil,
        gazeX: nil, gazeY: nil,
        isCalibrated: false,
        signals: [:], head: nil
    )
    let data = try JSONEncoder().encode(sample)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

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


// MARK: - Frame level calibration data

@Test("A burst becomes many calibration points, not one")
func burstProducesEveryFrame() {
    // Collapsing thirty frames into a single median discards almost all the calibration
    // data, and the published smartphone gaze work needs on the order of a hundred frames
    // before personalisation helps at all.
    let samples = (0..<30).map { index in
        GazeCalibrationRun.Sample(
            convergence: GazeMeasurement(
                u: 0.10 + Double(index % 3) * 0.001, v: -0.20,
                eyeX: 0.01, eyeY: -0.04, distance: 0.35
            ),
            perEye: nil, headYaw: 0, headPitch: 0
        )
    }
    let produced = GazeCalibrationRun.reduce(samples: samples, target: CGPoint(x: 0.5, y: 0.5), targetIndex: 4)
    #expect(produced.count == 30)
    #expect(produced.allSatisfy { $0.targetIndex == 4 })
}

@Test("A burst where the eyes wandered is discarded whole, not averaged")
func wanderingBurstIsRejected() {
    let samples = (0..<20).map { index in
        GazeCalibrationRun.Sample(
            convergence: GazeMeasurement(
                u: index < 10 ? 0.10 : 0.35, v: -0.20,
                eyeX: 0.01, eyeY: -0.04, distance: 0.35
            ),
            perEye: nil, headYaw: 0, headPitch: 0
        )
    }
    #expect(GazeCalibrationRun.reduce(samples: samples, target: .zero, targetIndex: 0).isEmpty)
}

@Test("A stray frame inside an otherwise steady burst is dropped")
func strayFrameIsDropped() {
    var samples = (0..<20).map { _ in
        GazeCalibrationRun.Sample(
            convergence: GazeMeasurement(u: 0.10, v: -0.20, eyeX: 0.01, eyeY: -0.04, distance: 0.35),
            perEye: nil, headYaw: 0, headPitch: 0
        )
    }
    samples[7] = GazeCalibrationRun.Sample(
        convergence: GazeMeasurement(u: 0.9, v: -0.9, eyeX: 0.01, eyeY: -0.04, distance: 0.35),
        perEye: nil, headYaw: 0, headPitch: 0
    )
    let produced = GazeCalibrationRun.reduce(samples: samples, target: .zero, targetIndex: 0)
    #expect(produced.count == 19)
}

@Test("A burst that is too short is discarded")
func shortBurstIsRejected() {
    let samples = (0..<4).map { _ in
        GazeCalibrationRun.Sample(
            convergence: GazeMeasurement(u: 0.1, v: -0.2, eyeX: 0.01, eyeY: -0.04, distance: 0.35),
            perEye: nil, headYaw: 0, headPitch: 0
        )
    }
    #expect(GazeCalibrationRun.reduce(samples: samples, target: .zero, targetIndex: 0).isEmpty)
}

// MARK: - Reporting accuracy in comparable units

@Test("Error is reported as a visual angle so it can be compared with the literature")
func errorIsReportedInDegrees() {
    let geometry = ScreenGeometry(pointSize: CGSize(width: 393, height: 852), displayScale: 3)
    // Published ARKit geometric gaze is about 3.18 degrees, which is 1.44 cm on screen and
    // about 87 points on this display. That is the ceiling this project is measured against.
    let degrees = GazeModelFitter.degrees(points: 87, distance: 0.26, geometry: geometry)
    #expect(abs(degrees - 3.18) < 0.35)
}

@Test("Aggregating a fixation is more accurate than any single sample")
func fixationAveragingBeatsSingleSamples() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry)
    )
    // Analysis works on fixations, not raw samples, so this is the number that governs
    // whether two areas of interest can be told apart.
    #expect(model.fixationErrorPoints(samples: 18) < model.accuracyPoints)
    #expect(model.fixationErrorPoints(samples: 1) == model.perSampleErrorPoints)
}


// MARK: - Accuracy versus precision

/// A synthetic observer whose estimate also jitters frame to frame, so the split between
/// bias and scatter can be checked.
private struct NoisyObserver {
    let base = SyntheticObserver()
    var jitter = 0.010

    func calibration(framesPerTarget: Int = 40) -> [GazeCalibrationPoint] {
        var seed = UInt64(20260905)
        func next() -> Double {
            // Deterministic so the test cannot flake.
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53) - 0.5
        }
        return GazeCalibrationRun.targets.indices.flatMap { index -> [GazeCalibrationPoint] in
            (0..<framesPerTarget).flatMap { _ -> [GazeCalibrationPoint] in
                [0.32, 0.46].map { distance in
                    let clean = base.measurement(lookingAt: GazeCalibrationRun.targets[index], from: distance)
                    let noisy = GazeMeasurement(
                        u: clean.u + next() * jitter,
                        v: clean.v + next() * jitter,
                        eyeX: clean.eyeX, eyeY: clean.eyeY, distance: clean.distance
                    )
                    return GazeCalibrationPoint(
                        target: GazeCalibrationRun.targets[index],
                        targetIndex: index,
                        convergence: noisy, perEye: noisy,
                        headYaw: 0, headPitch: 0
                    )
                }
            }
        }
    }
}

@Test("Frame to frame scatter is measured separately from systematic bias")
func precisionIsMeasuredSeparately() throws {
    let observer = NoisyObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.base.geometry)
    )
    // The simulated tracker jitters, so scatter must be reported as non-zero.
    #expect(model.precisionPoints > 1)
    // Total error and scatter combine in quadrature, so bias can never exceed the total.
    #expect(model.biasPoints <= model.perSampleErrorPoints + 1e-9)
}

@Test("A fixation is more accurate than a sample, but never better than the bias floor")
func fixationErrorApproachesTheBiasFloor() throws {
    let observer = NoisyObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.base.geometry)
    )
    let single = model.fixationErrorPoints(samples: 1)
    let fixation = model.fixationErrorPoints(samples: 18)
    let huge = model.fixationErrorPoints(samples: 100_000)

    #expect(single == model.perSampleErrorPoints)
    #expect(fixation <= single)
    // No amount of averaging removes the systematic part.
    #expect(abs(huge - model.biasPoints) < 0.5)
}

@Test("Head pose terms are refused when the head never moved")
func headPoseTermsNeedHeadMovement() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry)
    )
    // Every synthetic frame has zero yaw and pitch, so those columns carry no information
    // and fitting them would be inventing signal.
    #expect(!model.basis.usesHeadPose)
}

@Test("The calibration grid is taller than it is wide, matching the display")
func calibrationGridMatchesScreenShape() {
    let targets = GazeCalibrationRun.targets
    #expect(targets.count == 12)
    #expect(Set(targets.map { $0.x }).count == 3)
    #expect(Set(targets.map { $0.y }).count == 4)
}

// MARK: - Eye laterality

@Test("A verified mapping names the participant's own eye for each channel")
func lateralityMapsChannelsToPhysicalEyes() {
    let mirrored = EyeLaterality(arkitLeftIsParticipantRight: true, separation: 0.8)
    #expect(mirrored.participantSide(forARKitKey: "eyeBlink_L") == "right")
    #expect(mirrored.participantSide(forARKitKey: "eyeSquint_R") == "left")
    // Channels with no side, like browInnerUp, have no answer to give.
    #expect(mirrored.participantSide(forARKitKey: "browInnerUp") == nil)

    let asDocumented = EyeLaterality(arkitLeftIsParticipantRight: false, separation: 0.8)
    #expect(asDocumented.participantSide(forARKitKey: "eyeBlink_L") == "left")
    #expect(asDocumented.participantSide(forARKitKey: "eyeWide_R") == "right")
}

@Test("A mapping that barely separated is not trusted")
func lateralityNeedsCleanSeparation() {
    #expect(EyeLaterality(arkitLeftIsParticipantRight: true, separation: 0.9).isTrustworthy)
    #expect(!EyeLaterality(arkitLeftIsParticipantRight: true, separation: 0.1).isTrustworthy)
}

@Test("A round trip through storage preserves the mapping")
func lateralitySurvivesStorage() throws {
    let defaults = try #require(UserDefaults(suiteName: "laterality.test.\(UUID().uuidString)"))
    let value = EyeLaterality(arkitLeftIsParticipantRight: true, separation: 0.72)

    EyeLateralityStore.save(value, to: defaults)
    #expect(EyeLateralityStore.load(from: defaults) == value)

    EyeLateralityStore.clear(from: defaults)
    #expect(EyeLateralityStore.load(from: defaults) == nil)
}

@MainActor
@Test("Winking the named eye resolves which channel reports on it")
func winkTestResolvesTheMapping() {
    let check = EyeLateralityCheck()
    let settle = EyeLateralityCheck.settleDuration
    let measure = EyeLateralityCheck.measureDuration

    // First prompt asks for the right eye. Simulate the _L channel responding, which is
    // the behaviour observed on device and the opposite of Apple's documentation.
    func feed(from start: Double, leftChannel: Double, rightChannel: Double) {
        var t = start
        while t <= start + settle + measure + 0.05 {
            check.receive(
                signals: ["eyeBlink_L": leftChannel, "eyeBlink_R": rightChannel],
                isTracked: true,
                timestamp: t
            )
            t += 1.0 / 60.0
        }
    }

    feed(from: 0, leftChannel: 0.95, rightChannel: 0.05)
    // Second prompt asks for the left eye, so the other channel should respond.
    feed(from: 100, leftChannel: 0.04, rightChannel: 0.93)

    guard case .finished(let result, let disagreed) = check.phase else {
        Issue.record("the check did not finish")
        return
    }
    #expect(!disagreed)
    #expect(result?.arkitLeftIsParticipantRight == true)
}

@MainActor
@Test("Two winks that contradict each other are reported rather than averaged")
func winkTestRejectsContradiction() {
    let check = EyeLateralityCheck()
    let span = EyeLateralityCheck.settleDuration + EyeLateralityCheck.measureDuration + 0.05

    func feed(from start: Double, leftChannel: Double, rightChannel: Double) {
        var t = start
        while t <= start + span {
            check.receive(
                signals: ["eyeBlink_L": leftChannel, "eyeBlink_R": rightChannel],
                isTracked: true,
                timestamp: t
            )
            t += 1.0 / 60.0
        }
    }

    // The same channel responds to both prompts, which means one wink closed the wrong eye.
    feed(from: 0, leftChannel: 0.95, rightChannel: 0.05)
    feed(from: 100, leftChannel: 0.95, rightChannel: 0.05)

    guard case .finished(let result, let disagreed) = check.phase else {
        Issue.record("the check did not finish")
        return
    }
    #expect(disagreed)
    #expect(result == nil)
}


@Test("Accuracy averages within a target, per-frame error does not, so the second is larger")
func accuracyAndPerSampleErrorAreDistinct() throws {
    let observer = NoisyObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.base.geometry)
    )
    // The eye-tracking field defines accuracy as the offset of the mean gaze during a
    // fixation. Judging every 60 Hz frame separately mixes in jitter that no analysis
    // would ever be exposed to, and reports a larger number for the same tracker.
    #expect(model.perSampleErrorPoints > model.accuracyPoints)
}

@Test("The gap between fitted and held-out accuracy shows whether more targets would help")
func generalisationGapIsReported() throws {
    let observer = SyntheticObserver()
    let model = try #require(
        GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry)
    )
    #expect(model.generalisationGapPoints >= 0)
    // A noiseless observer is modelled exactly, so there is nothing left to generalise.
    #expect(model.generalisationGapPoints < 3)
}


// MARK: - Device motion gating

@Test("Ordinary hand tremor does not count as the phone being moved")
func handTremorIsNotMotion() {
    // A hand at rest still rotates a few tenths of a radian per second. A gate that fires
    // on that discards frames dozens of times a second and makes the dot lurch.
    #expect(DeviceMotionMonitor.updatedSteadiness(wasSteady: true, rotation: 0.25, acceleration: 0.08))
    #expect(DeviceMotionMonitor.updatedSteadiness(wasSteady: true, rotation: 0.6, acceleration: 0.2))
}

@Test("A deliberate reposition does count")
func repositionIsMotion() {
    #expect(!DeviceMotionMonitor.updatedSteadiness(wasSteady: true, rotation: 2.0, acceleration: 0.1))
    #expect(!DeviceMotionMonitor.updatedSteadiness(wasSteady: true, rotation: 0.1, acceleration: 0.9))
}

@Test("The verdict does not flicker in the band between the two thresholds")
func steadinessHasHysteresis() {
    // Sitting between the thresholds, the previous verdict stands. Without this the gate
    // chatters, and every flip is a discarded frame and a visible jump.
    let between = 1.2
    #expect(DeviceMotionMonitor.updatedSteadiness(wasSteady: true, rotation: between, acceleration: 0))
    #expect(!DeviceMotionMonitor.updatedSteadiness(wasSteady: false, rotation: between, acceleration: 0))
}

@MainActor
@Test("A single jolt does not trip the gate, sustained movement does")
func motionIsSmoothedBeforeJudging() {
    let monitor = DeviceMotionMonitor()
    var t = 0.0
    for _ in 0..<30 {
        monitor.ingest(rotation: 0.1, acceleration: 0.05, timestamp: t)
        t += 1.0 / 60.0
    }
    #expect(monitor.isSteady)

    // One wild frame, the kind a knuckle knock produces.
    monitor.ingest(rotation: 6.0, acceleration: 2.0, timestamp: t)
    t += 1.0 / 60.0
    #expect(monitor.isSteady)

    // Sustained movement gets through.
    for _ in 0..<30 {
        monitor.ingest(rotation: 3.0, acceleration: 1.0, timestamp: t)
        t += 1.0 / 60.0
    }
    #expect(!monitor.isSteady)
}
