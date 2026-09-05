import CoreGraphics
import Foundation
import Testing
import CoreImage
import CoreVideo
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
    /// Where the head points, as direction ratios. ARKit reports this at full strength.
    var headU = 0.030
    var headV = -0.050
    /// The fraction of the eyes' true rotation within the head that ARKit reports. About a
    /// fifth on the real device, which is why the head has to be in the model.
    var eyeGain = 0.2
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
        // What the sensor reports: the head direction, plus a compressed, offset and scaled
        // version of the eyes' rotation within the head.
        let eyeInHeadU = trueU - headU
        let eyeInHeadV = trueV - headV
        return GazeMeasurement(
            u: headU + eyeGain * (uScale * eyeInHeadU + uOffset),
            v: headV + eyeGain * (vScale * eyeInHeadV + vOffset),
            eyeX: eyeX,
            eyeY: eyeY,
            distance: distance,
            headU: headU,
            headV: headV
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

@Test("V0 records the nine expression shapes named in the setup guide plus the eight eye-direction shapes")
func trackedBlendShapesMatchTheGuide() {
    #expect(TrackedBlendShapes.expression.count == 9)
    #expect(TrackedBlendShapes.eyeDirection.count == 8)
    #expect(TrackedBlendShapes.all.count == 17)
    // ARKit's raw values are not the Swift case names. Pinned here so an SDK change to the
    // exported column names fails a test instead of silently breaking every notebook.
    #expect(Set(TrackedBlendShapes.expressionKeys) == [
        "eyeBlink_L", "eyeBlink_R",
        "eyeSquint_L", "eyeSquint_R",
        "eyeWide_L", "eyeWide_R",
        "browInnerUp", "browOuterUp_L", "browOuterUp_R",
    ])
    #expect(Set(TrackedBlendShapes.eyeDirection.map(\.rawValue)) == [
        "eyeLookUp_L", "eyeLookDown_L", "eyeLookIn_L", "eyeLookOut_L",
        "eyeLookUp_R", "eyeLookDown_R", "eyeLookIn_R", "eyeLookOut_R",
    ])
}

@Test("The eight eye-direction shapes fold to one horizontal and one vertical term that agree across the two eyes")
func eyeLookShapesFold() {
    // Both eyes looking the same way: the left eye turns in towards the nose while the
    // right eye turns out, and the fold must add them rather than cancel them.
    let rightward = TrackedBlendShapes.eyeLookTerms(in: ["eyeLookIn_L": 0.6, "eyeLookOut_R": 0.6])
    #expect(abs(rightward.u - 0.6) < 1e-12)
    #expect(abs(rightward.v) < 1e-12)

    let upward = TrackedBlendShapes.eyeLookTerms(in: ["eyeLookUp_L": 0.4, "eyeLookUp_R": 0.4])
    #expect(abs(upward.v - 0.4) < 1e-12)
    #expect(abs(upward.u) < 1e-12)

    // Missing values read as zero, not as a crash.
    let none = TrackedBlendShapes.eyeLookTerms(in: [:])
    #expect(none.u == 0 && none.v == 0)
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
    #expect(GazeQuality.evaluate(isTracked: false, eyesOpen: true, distance: 0.35, headYaw: 0, headPitch: 0, model: nil) == .noFace)
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: false, distance: 0.35, headYaw: 0, headPitch: 0, model: nil) == .blinking)
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.15, headYaw: 0, headPitch: 0, model: nil) == .tooClose(0.15))
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.90, headYaw: 0, headPitch: 0, model: nil) == .tooFar(0.90))
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headYaw: 0.8, headPitch: 0, model: nil) == .headTurned(0.8))
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headYaw: 0, headPitch: 0, model: nil) == .notCalibrated)
}

@Test("Pitch has more room than yaw, because looking down at a phone is the ordinary posture")
func pitchLimitIsLooserThanYaw() {
    // 20° of pitch with no yaw is a person reading a phone held below eye level.
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headYaw: 0.02, headPitch: -0.36, model: nil) == .notCalibrated)
    // 20° of yaw is a face turned away from the camera.
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headYaw: 0.36, headPitch: 0, model: nil) != .notCalibrated)
    // Far enough down and pitch does count.
    if case .headTurned = GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.35, headYaw: 0, headPitch: -0.7, model: nil) {} else {
        Issue.record("steep pitch should be flagged")
    }
}

@Test("A calibration's frames are written to disk and read back whole")
func calibrationExportRoundTrips() throws {
    let observer = SyntheticObserver()
    let points = observer.calibration(framesPerTarget: 3)
    let model = GazeModelFitter.best(points: points, geometry: observer.geometry)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let url = try SessionExporter.writeCalibration(model: model, points: points, failedTargets: 1, to: folder)
    #expect(url.lastPathComponent.hasPrefix("calibration_"))
    #expect(SessionExporter.latestCalibration(in: folder) == url)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let document = try decoder.decode(SessionExporter.CalibrationDocument.self, from: Data(contentsOf: url))
    #expect(document.points == points)
    #expect(document.failedTargets == 1)
    #expect(document.model?.uCoefficients == model?.uCoefficients)
}

@Test("A phone in motion is reported before any geometry test, because the geometry is stale")
func qualityFlagsDeviceMotionFirst() {
    // During movement the face anchor and the camera transform disagree, so the distance
    // those other checks rely on is itself unreliable.
    #expect(
        GazeQuality.evaluate(
            isTracked: true, eyesOpen: true, distance: 0.90,
            headYaw: 0, headPitch: 0, deviceIsSteady: false, model: nil
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
    #expect(GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.36, headYaw: 0, headPitch: 0, model: model) == .good)
    #expect(
        GazeQuality.evaluate(isTracked: true, eyesOpen: true, distance: 0.60, headYaw: 0, headPitch: 0, model: model)
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

@Test("The angle between two attitudes is the rotation that separates them, whatever the axis")
func attitudeAngleIsAxisFree() {
    let identity = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
    for axis in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), simd_normalize(SIMD3<Double>(1, 1, 0))] {
        let turned = simd_quatd(angle: 0.25, axis: axis)
        #expect(abs(DeviceMotionMonitor.angle(between: identity, and: turned) - 0.25) < 1e-9)
        // The sign of the quaternion is a representation detail, not a rotation.
        let negated = simd_quatd(vector: -turned.vector)
        #expect(abs(DeviceMotionMonitor.angle(between: identity, and: negated) - 0.25) < 1e-9)
    }
}

@Test("Net rotation looks back over the window, not over the whole history")
func netRotationUsesTheWindow() {
    // Turned 20° a second ago, then held still. Over a 120 ms window, nothing moved.
    let axis = SIMD3<Double>(1, 0, 0)
    var history: [(timestamp: TimeInterval, orientation: simd_quatd)] = []
    history.append((0.0, simd_quatd(angle: 0, axis: axis)))
    for step in 1...100 {
        history.append((Double(step) / 100, simd_quatd(angle: 0.35, axis: axis)))
    }
    #expect(DeviceMotionMonitor.netRotation(in: history, over: MotionGate.window) < 1e-9)

    // Turning steadily at 1 rad/s reads as 0.12 rad over the window.
    let steady = (0...100).map { step in
        (timestamp: Double(step) / 100, orientation: simd_quatd(angle: Double(step) / 100, axis: axis))
    }
    #expect(abs(DeviceMotionMonitor.netRotation(in: steady, over: 0.12) - 0.12) < 1e-6)
}

@MainActor
@Test("Tremor has high angular velocity but almost no net rotation, and the monitor sees the difference")
func tremorHasVelocityWithoutDisplacement() {
    let monitor = DeviceMotionMonitor()
    let axis = SIMD3<Double>(1, 0, 0)
    // Half a degree of amplitude at 8 Hz, sampled at 100 Hz for a second.
    let amplitude = 0.5 * .pi / 180
    let frequency = 8.0
    for step in 0..<100 {
        let t = Double(step) / 100
        let angle = amplitude * sin(2 * .pi * frequency * t)
        let rate = abs(amplitude * 2 * .pi * frequency * cos(2 * .pi * frequency * t))
        monitor.ingest(
            rotationRate: rate,
            acceleration: 0.02,
            attitude: simd_quatd(angle: angle, axis: axis),
            gravity: SIMD3(0, -1, 0),
            timestamp: t
        )
    }
    // Peak velocity about 25°/s, well above the old velocity gate.
    #expect(monitor.rotationRate > 0.2)
    // Net rotation over the window: at most twice the amplitude, about a degree.
    #expect(monitor.netRotation <= 2 * amplitude + 1e-9)
    // And the gate, at 40 cm, calls that steady.
    var gate = MotionGate()
    let steady = gate.update(netRotation: monitor.netRotation, acceleration: monitor.acceleration, distance: 0.40)
    #expect(steady)
    #expect(gate.disturbance < MotionGate.steadyThreshold)
}

@Test("Tilt and roll come straight from the gravity vector")
func leanFromGravity() {
    // Upright: gravity points down the long axis.
    let upright = DeviceMotionMonitor.lean(gravity: SIMD3(0, -1, 0))
    #expect(abs(upright.tilt) < 1e-9 && abs(upright.roll) < 1e-9)
    // Flat on a table, screen up: gravity points into the back of the phone.
    let flat = DeviceMotionMonitor.lean(gravity: SIMD3(0, 0, -1))
    #expect(abs(flat.tilt - .pi / 2) < 1e-9)
    // Leaned back thirty degrees, the usual reading posture.
    let reading = DeviceMotionMonitor.lean(gravity: SIMD3(0, -cos(Double.pi / 6), -sin(Double.pi / 6)))
    #expect(abs(reading.tilt - .pi / 6) < 1e-9)
    // Top of the phone leaning to the participant's right is a positive roll.
    let leaning = DeviceMotionMonitor.lean(gravity: SIMD3(sin(0.2), -cos(0.2), 0))
    #expect(abs(leaning.roll - 0.2) < 1e-9)
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
    for key in ["gazeX", "gazeY", "convergenceU", "perEyeV", "eyeZ", "head", "device"] {
        #expect(object?[key] is NSNull)
    }
}

@Test("How the phone was held rides along with every sample and every gaze row")
func deviceAttitudeIsRecorded() throws {
    let attitude = DeviceAttitude(tilt: 0.5, roll: -0.1, rotationRate: 0.3, disturbance: 0.004)
    let sample = FaceSample(
        timestamp: 1, isTracked: true, eyesOpen: true, quality: "good",
        eyeX: 0, eyeY: 0, eyeZ: -0.35,
        convergenceU: 0, convergenceV: 0, perEyeU: nil, perEyeV: nil,
        gazeX: 0.5, gazeY: 0.5, isCalibrated: true, signals: [:], head: nil,
        device: attitude
    )
    let data = try JSONEncoder().encode(sample)
    #expect(try JSONDecoder().decode(FaceSample.self, from: data).device == attitude)

    let metrics = EventRecorder.deviceMetrics(attitude)
    #expect(metrics["deviceTiltRad"] == 0.5)
    #expect(metrics["deviceRollRad"] == -0.1)
    #expect(metrics["deviceRotationRadPerS"] == 0.3)
    #expect(abs((metrics["deviceDisturbanceMm"] ?? 0) - 4) < 1e-9)
    #expect(EventRecorder.deviceMetrics(nil).isEmpty)
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
    // The synthetic observer is noise free, so both figures sit at numerical zero; the
    // claim is that aggregating never makes things worse. The noisy case is covered below.
    #expect(model.fixationErrorPoints(samples: 18) <= model.accuracyPoints + 1e-6)
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

@Test("The head direction is always in the model and passes through with a gain of one")
func headDirectionPassesThroughUnscaled() throws {
    let observer = SyntheticObserver()
    let model = try #require(GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry))
    #expect(model.basis.usesHeadPose)
    #expect(model.summary.contains("head"))
    // Turn the head by δ with the eyes fixed in the head: the measured gaze moves by δ,
    // the head direction moves by δ, and so must the corrected gaze. Exactly δ, not 5δ.
    let base = model.correct(u: 0.04, v: -0.03, headU: 0.03, headV: -0.05)
    let turned = model.correct(u: 0.04 + 0.1, v: -0.03, headU: 0.03 + 0.1, headV: -0.05)
    #expect(abs((turned.u - base.u) - 0.1) < 1e-9)
    #expect(abs(turned.v - base.v) < 1e-9)
}

@Test("A compressed eye signal is recovered exactly through the head-plus-eye structure")
func compressedEyeSignalIsRecovered() throws {
    var observer = SyntheticObserver()
    observer.eyeGain = 0.18
    let model = try #require(GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry))
    #expect(model.accuracyPoints < 0.5)
    for target in GazeCalibrationRun.targets {
        let hit = observer.geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: observer.measurement(lookingAt: target, from: 0.38)))
        #expect(abs(Double(hit.x) - Double(target.x)) < 1e-6)
        #expect(abs(Double(hit.y) - Double(target.y)) < 1e-6)
    }
}

@Test("The eye-direction blend shapes are recorded but never fitted")
func eyeLookShapesAreNotModelInputs() {
    #expect(GazeBasis.allCases.allSatisfy { !$0.usesEyeLook })
    #expect(GazeBasis.allCases.allSatisfy { $0.usesHeadPose })
    #expect(GazeBasis.allCases.count == 4)
    #expect(TrackedBlendShapes.keys.contains("eyeLookUp_L"))
}

@Test("The pupil offset is measured from the centre of the eye opening in units of its width")
func pupilOffsetIsNormalisedByEyeWidth() throws {
    // An eye opening 40 px wide and 16 px tall, pupil 6 px right of centre and 2 px up.
    let contour = [CGPoint(x: 100, y: 200), CGPoint(x: 120, y: 208), CGPoint(x: 140, y: 200), CGPoint(x: 120, y: 192)]
    let offset = try #require(PupilGeometry.offset(pupil: CGPoint(x: 126, y: 202), contour: contour))
    #expect(abs(offset.x - 0.15) < 1e-9)
    #expect(abs(offset.y - 0.05) < 1e-9)
    // Too few points, or a degenerate opening, is no reading rather than a wild one.
    #expect(PupilGeometry.offset(pupil: .zero, contour: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]) == nil)
    #expect(PupilGeometry.offset(pupil: .zero, contour: Array(repeating: CGPoint(x: 5, y: 5), count: 6)) == nil)
}

@Test("Landmark image axes are paired with the display according to how the buffer was turned")
func pupilAxesArePairedWithTheDisplay() {
    // Buffer turned a quarter: the upright image's x already runs across the screen.
    let turned = PupilGeometry.displayPaired(x: 0.1, y: 0.02, quarterTurned: true)
    #expect(turned.u == 0.1 && turned.v == 0.02)
    // Not turned: the buffer's long axis is the phone's long axis, so x runs up the screen.
    let flat = PupilGeometry.displayPaired(x: 0.1, y: 0.02, quarterTurned: false)
    #expect(flat.u == 0.02 && flat.v == -0.1)
    #expect(PupilGeometry.isQuarterTurn(.right) && PupilGeometry.isQuarterTurn(.leftMirrored))
    #expect(!PupilGeometry.isQuarterTurn(.up) && !PupilGeometry.isQuarterTurn(.downMirrored))
}

@Test("The pupil source is offered only when it was captured, and rides on the fixation-gated frames")
func pupilSourceFollowsTheFixationGate() throws {
    let observer = SyntheticObserver()
    let m = observer.measurement(lookingAt: GazeCalibrationRun.targets[0], from: 0.35)
    let pupil = GazeMeasurement(u: 0.3, v: 0.1, eyeX: m.eyeX, eyeY: m.eyeY, distance: 0.35, headU: 0.03, headV: -0.05)
    let samples = (0..<12).map { _ in
        GazeCalibrationRun.Sample(convergence: m, perEye: m, headYaw: 0, headPitch: 0, pupil: pupil)
    }
    let points = GazeCalibrationRun.reduce(samples: samples, target: GazeCalibrationRun.targets[0], targetIndex: 0)
    #expect(points.count == 12)
    #expect(points.allSatisfy { $0.pupil == pupil })
    #expect(points[0].measurement(for: .pupil) == pupil)
    // Without pupil readings the source contributes nothing and the fit proceeds on the rest.
    let model = try #require(GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry))
    #expect(model.source != .pupil)
}

@Test("Eye crops use the training geometry: a square around the box widened by a quarter on each side")
func eyeCropGeometryMatchesTraining() {
    // The same box the Python test uses: 70 wide, 40 tall at (160, 290).
    let square = EyeCropGeometry.squareCrop(around: CGRect(x: 160, y: 290, width: 70, height: 40))
    #expect(abs(square.width - 105) < 1e-9 && abs(square.height - 105) < 1e-9)
    #expect(abs(square.midX - 195) < 1e-9 && abs(square.midY - 310) < 1e-9)
    let bounds = EyeCropGeometry.bounds(of: [CGPoint(x: 3, y: 9), CGPoint(x: 10, y: 4), CGPoint(x: 7, y: 12)])
    #expect(bounds == CGRect(x: 3, y: 4, width: 7, height: 8))
    #expect(EyeCropGeometry.bounds(of: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 5)]) == nil)
}

@Test("The cropper renders a 64 pixel greyscale buffer and keeps the eye in the middle")
func eyeCropperRendersGreyscale() throws {
    // A dark image with a bright rectangle where the eye box is.
    let dark = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
    let bright = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 160, y: 290, width: 70, height: 40))
    let image = bright.composited(over: dark)
    let buffer = try #require(EyeCropper().crop(image, eye: CGRect(x: 160, y: 290, width: 70, height: 40)))
    #expect(CVPixelBufferGetWidth(buffer) == 64 && CVPixelBufferGetHeight(buffer) == 64)
    #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    func pixel(_ x: Int, _ y: Int) -> UInt8 { base.load(fromByteOffset: y * stride + x, as: UInt8.self) }
    #expect(pixel(32, 32) > 200)
    #expect(pixel(2, 2) < 60)
}

@Test("The bundled learned model loads and produces a finite estimate")
func learnedModelLoadsFromTheBundle() throws {
    let model = try #require(LearnedEyeModel())
    let dark = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
    let cropper = EyeCropper()
    let left = try #require(cropper.crop(dark, eye: CGRect(x: 40, y: 80, width: 50, height: 30)))
    let right = try #require(cropper.crop(dark, eye: CGRect(x: 110, y: 80, width: 50, height: 30)))
    let estimate = try #require(model.predict(leftEye: left, rightEye: right, headU: 0.02, headV: -0.1))
    #expect(estimate.u.isFinite && estimate.v.isFinite)
    #expect(abs(estimate.u) < 2 && abs(estimate.v) < 2)
}

@Test("Camera axes are rotated into the display frame: display X is camera y, display Y is minus camera x")
func displayFrameRotation() {
    // A point 10 cm along the camera's y axis, 30 cm in front: to the participant's right.
    let right = DisplayFrame.vector(SIMD3<Float>(0, 0.1, -0.3))
    #expect(abs(right.x - 0.1) < 1e-6 && abs(right.y) < 1e-6 && abs(right.z + 0.3) < 1e-6)
    // A point 10 cm along the camera's x axis, the phone's long axis towards the bottom: down the screen.
    let down = DisplayFrame.vector(SIMD3<Float>(0.1, 0, -0.3))
    #expect(abs(down.x) < 1e-6 && abs(down.y + 0.1) < 1e-6)
    // A proper rotation, not a mirror.
    let r = DisplayFrame.fromCamera
    let det = simd_determinant(simd_float3x3(
        SIMD3(r.columns.0.x, r.columns.0.y, r.columns.0.z),
        SIMD3(r.columns.1.x, r.columns.1.y, r.columns.1.z),
        SIMD3(r.columns.2.x, r.columns.2.y, r.columns.2.z)
    ))
    #expect(abs(det - 1) < 1e-6)
    // Transforming a pose agrees with transforming its translation.
    var pose = matrix_identity_float4x4
    pose.columns.3 = SIMD4(0.1, 0.02, -0.3, 1)
    let moved = DisplayFrame.transform(pose).columns.3
    let expected = DisplayFrame.vector(SIMD3(0.1, 0.02, -0.3))
    #expect(abs(moved.x - expected.x) < 1e-6 && abs(moved.y - expected.y) < 1e-6 && abs(moved.z - expected.z) < 1e-6)
}

@Test("Beyond the calibrated range the correction continues along its slope instead of exploding")
func predictionContinuesLinearlyBeyondTheRange() {
    // Terms on standardised eye-in-head inputs: [1, u, v, u², v², uv]. Identity scaling and
    // a zero head so the arithmetic can be checked by hand.
    let basis = GazeBasis(order: 2, solvesCameraOffset: false)
    let range = GazeInputRange(
        u: -0.2...0.2, v: -0.3...0.1, yaw: 0...0, pitch: 0...0, lookU: 0...0, lookV: 0...0
    )
    func model(_ inputRange: GazeInputRange?) -> GazeModel {
        GazeModel(
            source: .convergence, basis: basis,
            uCoefficients: [0, 1, 0, 0, 0, 0],
            vCoefficients: [0, 0, 1, 0, 230, 0],
            cameraOffsetX: 0, cameraOffsetY: 0, ridge: 0, inputRange: inputRange, scaling: .identity,
            accuracyPoints: 0, accuracyDegrees: 0, worstTargetPoints: 0, perSampleErrorPoints: 0,
            inSampleAccuracyPoints: 0, precisionPoints: 0, sampleCount: 0, targetCount: 0,
            meanCalibrationDistance: 0.37, calibratedDistanceRange: 0.3...0.4, createdAt: Date()
        )
    }
    let bounded = model(range)
    let unbounded = model(nil)

    // Inside the range the two agree exactly.
    #expect(abs(bounded.correct(u: 0.1, v: -0.1, headU: 0, headV: 0).v - unbounded.correct(u: 0.1, v: -0.1, headU: 0, headV: 0).v) < 1e-12)

    // v below the range: the quadratic 230·v² becomes a straight line from the boundary
    // with the boundary slope 460·vb, instead of exploding.
    let vb = -0.3 - 0.4 * GazeInputRange.margin
    let expected = vb + 230 * vb * vb + (1 + 460 * vb) * (-0.9 - vb)
    #expect(abs(bounded.correct(u: 0, v: -0.9, headU: 0, headV: 0).v - expected) < 1e-9)
    #expect(abs(unbounded.correct(u: 0, v: -0.9, headU: 0, headV: 0).v - (-0.9 + 230 * 0.81)) < 1e-9)

    // Continuous at the boundary.
    let just = bounded.correct(u: 0, v: vb - 1e-9, headU: 0, headV: 0).v
    let at = bounded.correct(u: 0, v: vb, headU: 0, headV: 0).v
    #expect(abs(just - at) < 1e-6)

    // And the head is added back on top, unbounded, whatever the eye term does.
    #expect(abs(bounded.correct(u: 0.5, v: 0, headU: 0.5, headV: 0).u - bounded.correct(u: 0, v: 0, headU: 0, headV: 0).u - 0.5) < 1e-9)
}

@Test("The fit is done on standardised inputs and the stored scaling reproduces it")
func fitUsesStandardisedInputs() throws {
    let observer = SyntheticObserver()
    let model = try #require(GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry))
    let scaling = try #require(model.scaling)
    #expect(scaling.centre.count == 6 && scaling.scale.count == 6)
    // Inputs that never varied pass through with unit scale rather than dividing by zero.
    #expect(scaling.scale[2] == 1 && scaling.scale[3] == 1)
    // And the model still lands on the target it was shown.
    let target = GazeCalibrationRun.targets[4]
    let hit = observer.geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: observer.measurement(lookingAt: target, from: 0.40)))
    #expect(abs(Double(hit.x) - Double(target.x)) < 1e-6)
    #expect(abs(Double(hit.y) - Double(target.y)) < 1e-6)
}

@Test("The simplest model within the margin wins, not the best")
func parsimonyPrefersTheSimplerModel() throws {
    // A person whose error is exactly linear. Every candidate fits within noise; the
    // quadratic and covariate models must not win on a rounding error.
    let observer = SyntheticObserver()
    let model = try #require(GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry))
    #expect(model.basis.order == 1)
    #expect(!model.basis.usesEyeLook)
    // But a term that pays for itself is kept: the camera offset is real in this observer.
    #expect(model.basis.solvesCameraOffset)
}

@Test("The fitter records what its inputs spanned")
func fitterRecordsInputRange() throws {
    let observer = SyntheticObserver()
    let points = observer.calibration()
    let model = try #require(GazeModelFitter.best(points: points, geometry: observer.geometry))
    let range = try #require(model.inputRange)
    // The fitted inputs are the eye-in-head angles.
    let us = points.compactMap { $0.convergence?.eyeInHeadU }
    #expect(abs(range.u.lowerBound - (us.min() ?? 0)) < 1e-12)
    #expect(abs(range.u.upperBound - (us.max() ?? 0)) < 1e-12)
    // And the head direction, which never varied in the synthetic run, is on record.
    #expect(range.yaw == observer.headU...observer.headU)
}

@Test("A calibration saved before the input range existed still loads, unbounded")
func modelDecodesWithoutInputRange() throws {
    let observer = SyntheticObserver()
    let model = try #require(GazeModelFitter.best(points: observer.calibration(), geometry: observer.geometry))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
    object.removeValue(forKey: "inputRange")
    object.removeValue(forKey: "scaling")
    let legacy = try JSONDecoder().decode(GazeModel.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.inputRange == nil)
    #expect(legacy.scaling == nil)
    #expect(legacy.uCoefficients == model.uCoefficients)
}

@Test("Every gaze row carries the physical measurement, so a session can be re-mapped offline")
func gazeRowsCarryTheMeasurement() {
    let sample = FaceSample(
        timestamp: 1, isTracked: true, eyesOpen: true, quality: "good",
        eyeX: 0.01, eyeY: -0.04, eyeZ: -0.37,
        convergenceU: 0.12, convergenceV: -0.31, perEyeU: nil, perEyeV: -0.30,
        gazeX: 0.5, gazeY: 0.5, isCalibrated: true, signals: [:],
        head: HeadPose(x: 0, y: 0, z: -0.37, pitch: 0.05, yaw: -0.02, roll: 0.01)
    )
    let m = EventRecorder.measurementMetrics(sample)
    #expect(m["eyeZ"] == -0.37)
    #expect(m["convergenceU"] == 0.12)
    #expect(m["perEyeV"] == -0.30)
    #expect(m["perEyeU"] == nil)
    #expect(m["headYawRad"] == -0.02)
    #expect(m["headPitchRad"] == 0.05)
}

@Test("A calibration saved before the eye-direction terms existed still loads")
func basisDecodesWithoutEyeLookKey() throws {
    let legacy = Data(#"{"order":2,"solvesCameraOffset":true,"usesHeadPose":false}"#.utf8)
    let basis = try JSONDecoder().decode(GazeBasis.self, from: legacy)
    #expect(basis.order == 2)
    #expect(basis.solvesCameraOffset)
    #expect(!basis.usesEyeLook)
    #expect(basis.parameterCount == 7)
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

@Test("The gate measures how far the screen moved under the eyes, in metres")
func gateMeasuresDisplacementOnTheScreen() {
    // One degree of net rotation at 40 cm is seven millimetres.
    let rotationOnly = MotionGate.disturbance(netRotation: .pi / 180, acceleration: 0, distance: 0.40)
    #expect(abs(rotationOnly - 0.40 * .pi / 180) < 1e-9)
    // The same angle further away moves the screen further.
    #expect(MotionGate.disturbance(netRotation: .pi / 180, acceleration: 0, distance: 0.60) > rotationOnly)
    // Half a g for the whole window is about 35 mm of translation.
    let translationOnly = MotionGate.disturbance(netRotation: 0, acceleration: 0.5, distance: 0.40)
    #expect(abs(translationOnly - 0.5 * 0.5 * 9.80665 * 0.12 * 0.12) < 1e-9)
    // No face: a nominal reading distance is assumed rather than dividing by nothing.
    #expect(MotionGate.disturbance(netRotation: 0.1, acceleration: 0, distance: nil) == 0.1 * MotionGate.fallbackDistance)
}

@Test("Ordinary hand tremor does not count as the phone being moved, a reposition does")
func gateSeparatesTremorFromReposition() {
    var gate = MotionGate()
    // A degree of drift while reading, and the faint acceleration of a resting hand.
    let drift = gate.update(netRotation: .pi / 180, acceleration: 0.03, distance: 0.40)
    #expect(drift)
    // Ten degrees in the reaction window is a deliberate movement.
    let reposition = gate.update(netRotation: 10 * .pi / 180, acceleration: 0.03, distance: 0.40)
    #expect(!reposition)
    // Translation alone can do it too.
    var another = MotionGate()
    let shove = another.update(netRotation: 0, acceleration: 0.6, distance: 0.40)
    #expect(!shove)
}

@Test("The verdict does not flicker in the band between the two thresholds")
func gateHasHysteresis() {
    // Sitting between the thresholds, the previous verdict stands. Without this the gate
    // chatters, and every flip is a discarded frame.
    let between = (MotionGate.steadyThreshold + MotionGate.movingThreshold) / 2
    #expect(MotionGate.verdict(wasSteady: true, disturbance: between))
    #expect(!MotionGate.verdict(wasSteady: false, disturbance: between))
    #expect(MotionGate.verdict(wasSteady: false, disturbance: MotionGate.steadyThreshold / 2))
}

@MainActor
@Test("A sharp knock has a large velocity but no net rotation, so it does not trip the gate")
func knockDoesNotTripTheGate() {
    let monitor = DeviceMotionMonitor()
    let axis = SIMD3<Double>(0, 1, 0)
    var t = 0.0
    for _ in 0..<30 {
        monitor.ingest(rotationRate: 0.05, acceleration: 0.02, attitude: simd_quatd(angle: 0, axis: axis), gravity: SIMD3(0, -1, 0), timestamp: t)
        t += 0.01
    }
    // Two samples of a jolt: the phone twitches a degree and comes straight back.
    monitor.ingest(rotationRate: 6.0, acceleration: 0.2, attitude: simd_quatd(angle: 0.017, axis: axis), gravity: SIMD3(0, -1, 0), timestamp: t)
    t += 0.01
    monitor.ingest(rotationRate: 6.0, acceleration: 0.2, attitude: simd_quatd(angle: 0, axis: axis), gravity: SIMD3(0, -1, 0), timestamp: t)
    var gate = MotionGate()
    let afterKnock = gate.update(netRotation: monitor.netRotation, acceleration: monitor.acceleration, distance: 0.40)
    #expect(afterKnock)

    // A sustained turn, however, does count.
    for step in 1...20 {
        t += 0.01
        monitor.ingest(rotationRate: 1.5, acceleration: 0.05, attitude: simd_quatd(angle: 0.015 * Double(step), axis: axis), gravity: SIMD3(0, -1, 0), timestamp: t)
    }
    let afterTurn = gate.update(netRotation: monitor.netRotation, acceleration: monitor.acceleration, distance: 0.40)
    #expect(!afterTurn)
}

// MARK: - Instrumentation

private func makeSession() -> SessionRecord {
    SessionRecord(
        appID: "test", appVersion: "1",
        device: DeviceRecord(
            model: "iPhone", systemVersion: "26.5",
            screenPointWidth: 393, screenPointHeight: 852, displayScale: 3
        ),
        calibration: nil, eyeLaterality: nil
    )
}

private func makeGaze(x: Double?, y: Double?, at time: TimeInterval) -> FaceSample {
    FaceSample(
        timestamp: time, isTracked: x != nil, eyesOpen: true, quality: "good",
        eyeX: 0, eyeY: 0, eyeZ: -0.35,
        convergenceU: 0, convergenceV: 0, perEyeU: nil, perEyeV: nil,
        gazeX: x, gazeY: y, isCalibrated: true,
        signals: ["eyeBlink_L": 0.02], head: nil
    )
}

@Test("Every event carries a gapless sequence number so lost data is detectable")
@MainActor
func eventSequenceIsGapless() {
    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    recorder.screenAppeared(.productList)
    recorder.wentBack(from: .productDetail, productID: "sku_101")
    recorder.productSelected("sku_101", on: .productDetail)
    let result = recorder.stop()

    let sequences = result?.events.map(\.sequence) ?? []
    #expect(sequences == Array(1...sequences.count))
}

@Test("A session opens and closes with explicit markers")
@MainActor
func sessionIsBracketed() throws {
    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    let result = try #require(recorder.stop())
    #expect(result.events.first?.event == EventKind.sessionStart.rawValue)
    #expect(result.events.last?.event == EventKind.sessionEnd.rawValue)
    #expect(result.session.endedAt != nil)
}

@Test("Gaze crossing between regions produces enter and exit events with a dwell")
@MainActor
func areaTransitionsProduceDwell() throws {
    let price = AreaOfInterest(
        screen: .productDetail, target: .price, productID: "sku_101",
        frame: CGRect(x: 0, y: 200, width: 393, height: 100)
    )
    let cta = AreaOfInterest(
        screen: .productDetail, target: .cta, productID: "sku_101",
        frame: CGRect(x: 0, y: 600, width: 393, height: 100)
    )

    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    // Two seconds on the price, then a look at the button.
    recorder.recordGaze(makeGaze(x: 0.5, y: 0.3, at: 10), screen: .productDetail, area: price)
    recorder.recordGaze(makeGaze(x: 0.5, y: 0.3, at: 12), screen: .productDetail, area: price)
    recorder.recordGaze(makeGaze(x: 0.5, y: 0.8, at: 12.5), screen: .productDetail, area: cta)
    let events = try #require(recorder.stop()).events

    let enters = events.filter { $0.event == EventKind.areaEnter.rawValue }
    let exits = events.filter { $0.event == EventKind.areaExit.rawValue }
    #expect(enters.map(\.target) == ["price", "cta"])
    // The dwell on the price is the gap between entering it and leaving it, not the gap
    // between samples, so it must survive the sampling rate changing.
    #expect(exits.first?.target == "price")
    #expect(abs((exits.first?.durationMs ?? 0) - 2500) < 1)
}

@Test("Staying inside a region does not emit a transition on every frame")
@MainActor
func staringDoesNotSpam() throws {
    let area = AreaOfInterest(
        screen: .productDetail, target: .reviews, productID: "sku_101",
        frame: CGRect(x: 0, y: 0, width: 393, height: 852)
    )
    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    for step in 0..<60 {
        recorder.recordGaze(
            makeGaze(x: 0.5, y: 0.5, at: Double(step) / 60), screen: .productDetail, area: area
        )
    }
    let events = try #require(recorder.stop()).events
    #expect(events.filter { $0.event == EventKind.areaEnter.rawValue }.count == 1)
}

@Test("A tap records where it landed, how long it was held and how broad the contact was")
@MainActor
func tapCarriesTouchMetrics() throws {
    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    recorder.tapped(
        screen: .productDetail, target: .cta, productID: "sku_101",
        at: CGPoint(x: 196.5, y: 426), viewport: CGSize(width: 393, height: 852),
        contactArea: 9.4, pressDurationMs: 118
    )
    let events = try #require(recorder.stop()).events
    let tap = try #require(events.first { $0.event == EventKind.tap.rawValue })
    #expect(abs((tap.x ?? 0) - 0.5) < 1e-9)
    #expect(abs((tap.y ?? 0) - 0.5) < 1e-9)
    #expect(tap.durationMs == 118)
    #expect(tap.metrics["contactRadiusPt"] == 9.4)
}

@Test("Scrolling records velocity and counts direction reversals")
@MainActor
func scrollRecordsReversals() throws {
    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    // Down, down, then back up. The reversal is the interesting part: steady scrolling is
    // reading, back and forth is searching.
    for offset in [0.0, 120.0, 260.0, 140.0, 40.0] {
        recorder.scrolled(screen: .productDetail, offset: offset, productID: "sku_101")
        try? await_briefly()
    }
    let scrolls = try #require(recorder.stop()).events
        .filter { $0.event == EventKind.scroll.rawValue }
    #expect(scrolls.count >= 2)
    #expect((scrolls.last?.metrics["reversals"] ?? 0) >= 1)
}

/// The recorder throttles scrolls, so a test has to let real time pass between them.
private func await_briefly() throws {
    Thread.sleep(forTimeInterval: EventRecorder.scrollThrottle + 0.01)
}

@Test("Gaze is attributed to whichever region is on top")
func hitTestPrefersTheTopmostRegion() {
    let background = AreaOfInterest(
        screen: .productDetail, target: .description, productID: nil,
        frame: CGRect(x: 0, y: 0, width: 393, height: 852)
    )
    let button = AreaOfInterest(
        screen: .productDetail, target: .cta, productID: nil,
        frame: CGRect(x: 40, y: 700, width: 313, height: 96)
    )
    let registry = AreaOfInterestRegistry(areas: [background, button])
    let viewport = CGSize(width: 393, height: 852)

    #expect(
        registry.hitTest(normalised: CGPoint(x: 0.5, y: 0.87), viewport: viewport)?.target == .cta
    )
    #expect(
        registry.hitTest(normalised: CGPoint(x: 0.5, y: 0.2), viewport: viewport)?.target == .description
    )
}

@Test("A gaze that lands on nothing is attributed to nothing")
func hitTestReturnsNilOutsideAnyRegion() {
    let registry = AreaOfInterestRegistry(areas: [
        AreaOfInterest(
            screen: .productDetail, target: .price, productID: nil,
            frame: CGRect(x: 0, y: 100, width: 393, height: 80)
        )
    ])
    #expect(
        registry.hitTest(normalised: CGPoint(x: 0.5, y: 0.9), viewport: CGSize(width: 393, height: 852)) == nil
    )
}

@Test("Every field is written on every row, as null when absent")
@MainActor
func exportedRowsHaveAStableColumnSet() throws {
    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    recorder.recordGaze(makeGaze(x: nil, y: nil, at: 5), screen: nil, area: nil)
    let events = try #require(recorder.stop()).events

    let encoder = JSONEncoder()
    let expected: Set<String> = [
        "schemaVersion", "sequence", "timestamp", "event", "screen", "target",
        "productID", "x", "y", "durationMs", "metrics", "eyesOpen", "quality", "signals",
    ]
    for event in events {
        let object = try JSONSerialization.jsonObject(
            with: try encoder.encode(event)
        ) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == expected)
    }
}

@Test("A session writes a readable document and a line-per-event file")
@MainActor
func exportWritesBothFiles() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let recorder = EventRecorder()
    recorder.start(session: makeSession())
    recorder.screenAppeared(.productList)
    let result = try #require(recorder.stop())

    let export = try SessionExporter.write(
        session: result.session, events: result.events, to: folder
    )
    #expect(export.eventCount == result.events.count)

    let document = try JSONDecoder().decode(
        SessionExporter.Document.self, from: Data(contentsOf: export.documentURL)
    )
    #expect(document.events.count == result.events.count)
    #expect(document.session.id == result.session.id)

    // One line per event, which is what pandas reads with lines=True.
    let lines = try String(contentsOf: export.eventsURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == result.events.count)
}

@Test("The clock anchor converts monotonic time to wall time without being used for order")
func clockAnchorConverts() {
    let anchor = SessionClock.Anchor(uptime: 1000, wallClock: Date(timeIntervalSince1970: 1_700_000_000))
    let converted = anchor.wallClock(forUptime: 1042.5)
    #expect(abs(converted.timeIntervalSince1970 - 1_700_000_042.5) < 1e-6)
}
