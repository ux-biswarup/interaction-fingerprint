import CoreGraphics
import Foundation
import Testing
import simd
@testable import InteractionFingerprintFeature

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
    // Missing values must not be read as a blink, or a dropout would look like one.
    #expect(TrackedBlendShapes.eyesOpen(in: [:]))
}

// MARK: - Gaze geometry

@Test("A ray aimed straight back at the camera hits the screen plane at the origin")
func rayStraightAtCameraHitsOrigin() throws {
    // Eyes 40 cm in front of the camera, looking straight along +z back at the device.
    let ray = GazeRay.Ray(origin: SIMD3(0, 0, -0.4), direction: SIMD3(0, 0, 1))
    let hit = try #require(GazeRay.intersectScreenPlane(ray))
    #expect(abs(hit.x) < 1e-6)
    #expect(abs(hit.y) < 1e-6)
}

@Test("Looking downwards moves the intersection down the screen plane")
func rayAngledDownMovesHitDown() throws {
    // From 40 cm out, angled so it descends 10 cm over the 40 cm of travel.
    let direction = simd_normalize(SIMD3<Float>(0, -0.25, 1))
    let ray = GazeRay.Ray(origin: SIMD3(0, 0, -0.4), direction: direction)
    let hit = try #require(GazeRay.intersectScreenPlane(ray))
    #expect(hit.y < -0.09)
    #expect(hit.y > -0.11)
}

@Test("A ray parallel to the screen never meets it")
func rayParallelToScreenMisses() {
    let ray = GazeRay.Ray(origin: SIMD3(0, 0, -0.4), direction: SIMD3(1, 0, 0))
    #expect(GazeRay.intersectScreenPlane(ray) == nil)
}

@Test("A ray pointing away from the device does not report a hit behind the eyes")
func rayPointingAwayMisses() {
    let ray = GazeRay.Ray(origin: SIMD3(0, 0, -0.4), direction: SIMD3(0, 0, -1))
    #expect(GazeRay.intersectScreenPlane(ray) == nil)
}

@Test("The gaze ray starts between the eyes and points at the convergence point")
func gazeRayOriginatesBetweenTheEyes() throws {
    var left = matrix_identity_float4x4
    left.columns.3 = SIMD4(-0.03, 0, 0, 1)
    var right = matrix_identity_float4x4
    right.columns.3 = SIMD4(0.03, 0, 0, 1)

    let ray = try #require(
        GazeRay.ray(
            faceInCamera: matrix_identity_float4x4,
            leftEye: left,
            rightEye: right,
            lookAtPoint: SIMD3(0, 0, 1)
        )
    )

    #expect(abs(ray.origin.x) < 1e-6)
    #expect(abs(ray.direction.z - 1) < 1e-6)
    #expect(abs(simd_length(ray.direction) - 1) < 1e-6)
}

// MARK: - Calibration

@Test("The fit recovers a known affine mapping exactly")
func calibrationRecoversKnownTransform() throws {
    // A deliberately awkward transform: mirrored in x, offset, and slightly sheared.
    func truth(_ raw: CGPoint) -> CGPoint {
        CGPoint(
            x: -8.0 * raw.x + 0.3 * raw.y + 0.5,
            y: 0.2 * raw.x + 7.0 * raw.y + 0.45
        )
    }

    let rawPoints = [-0.03, 0.0, 0.03].flatMap { x in
        [-0.05, 0.0, 0.05].map { y in CGPoint(x: x, y: y) }
    }
    let observations = rawPoints.map {
        GazeCalibrationFitter.Observation(raw: $0, target: truth($0))
    }

    let fit = try #require(
        GazeCalibrationFitter.fit(observations, screenPointSize: CGSize(width: 393, height: 852))
    )

    #expect(abs(fit.ax - -8.0) < 1e-6)
    #expect(abs(fit.bx - 0.3) < 1e-6)
    #expect(abs(fit.cx - 0.5) < 1e-6)
    #expect(abs(fit.ay - 0.2) < 1e-6)
    #expect(abs(fit.by - 7.0) < 1e-6)
    #expect(abs(fit.cy - 0.45) < 1e-6)
    #expect(fit.meanResidualPoints < 0.01)
}

@Test("Applying the fit maps raw metres onto the intended screen position")
func calibrationAppliesToNewPoints() throws {
    let observations = [-0.03, 0.0, 0.03].flatMap { x in
        [-0.05, 0.0, 0.05].map { y in
            GazeCalibrationFitter.Observation(
                raw: CGPoint(x: x, y: y),
                target: CGPoint(x: -8.0 * x + 0.5, y: 7.0 * y + 0.45)
            )
        }
    }
    let fit = try #require(
        GazeCalibrationFitter.fit(observations, screenPointSize: CGSize(width: 393, height: 852))
    )

    let mapped = fit.apply(to: CGPoint(x: 0.015, y: -0.025))
    #expect(abs(mapped.x - 0.38) < 1e-6)
    #expect(abs(mapped.y - 0.275) < 1e-6)
}

@Test("Collinear targets cannot determine a 2D mapping and are rejected")
func calibrationRejectsCollinearInput() {
    // Every raw point on one line, which happens when tracking fails for most targets.
    let observations = (0..<9).map { index -> GazeCalibrationFitter.Observation in
        let t = Double(index) * 0.01
        return GazeCalibrationFitter.Observation(
            raw: CGPoint(x: t, y: t),
            target: CGPoint(x: t, y: t)
        )
    }
    #expect(GazeCalibrationFitter.fit(observations, screenPointSize: CGSize(width: 393, height: 852)) == nil)
}

@Test("Fewer than three targets cannot be fitted")
func calibrationNeedsThreeTargets() {
    let observations = [
        GazeCalibrationFitter.Observation(raw: .zero, target: .zero),
        GazeCalibrationFitter.Observation(raw: CGPoint(x: 1, y: 1), target: CGPoint(x: 1, y: 1)),
    ]
    #expect(GazeCalibrationFitter.fit(observations, screenPointSize: CGSize(width: 393, height: 852)) == nil)
}

@Test("A single stray sample does not drag the per-target median")
func medianIgnoresOutliers() {
    let samples = [
        CGPoint(x: 0.01, y: 0.02),
        CGPoint(x: 0.011, y: 0.021),
        CGPoint(x: 0.012, y: 0.019),
        CGPoint(x: 0.0105, y: 0.0205),
        CGPoint(x: 5.0, y: -5.0), // a blink frame that slipped through
    ]
    // Sorted x: 0.01, 0.0105, 0.011, 0.012, 5.0      -> 0.011
    // Sorted y: -5.0, 0.019, 0.02, 0.0205, 0.021      -> 0.02
    let median = GazeCalibrationRun.median(of: samples)
    #expect(abs(median.x - 0.011) < 1e-9)
    #expect(abs(median.y - 0.02) < 1e-9)
}

@Test("A round trip through storage preserves the calibration")
func calibrationSurvivesStorage() throws {
    let defaults = try #require(UserDefaults(suiteName: "calibration.test.\(UUID().uuidString)"))
    let observations = [-0.03, 0.0, 0.03].flatMap { x in
        [-0.05, 0.0, 0.05].map { y in
            GazeCalibrationFitter.Observation(
                raw: CGPoint(x: x, y: y),
                target: CGPoint(x: -8.0 * x + 0.5, y: 7.0 * y + 0.45)
            )
        }
    }
    let fit = try #require(
        GazeCalibrationFitter.fit(observations, screenPointSize: CGSize(width: 393, height: 852))
    )

    GazeCalibrationStore.save(fit, to: defaults)
    #expect(GazeCalibrationStore.load(from: defaults) == fit)

    GazeCalibrationStore.clear(from: defaults)
    #expect(GazeCalibrationStore.load(from: defaults) == nil)
}

// MARK: - Screen geometry

@Test("An iPhone 15 sized display resolves to roughly its real physical size")
func screenGeometryEstimatesPhysicalSize() {
    let geometry = ScreenGeometry(pointSize: CGSize(width: 393, height: 852), displayScale: 3)
    // 6.1 inch diagonal, so about 65 mm by 141 mm of active area.
    #expect(abs(geometry.physicalSize.width - 0.0651) < 0.002)
    #expect(abs(geometry.physicalSize.height - 0.1411) < 0.002)
}

@Test("The uncalibrated fallback puts the screen centre near the middle of the display")
func screenGeometryNormalisesCentre() {
    let geometry = ScreenGeometry(pointSize: CGSize(width: 393, height: 852), displayScale: 3)
    let centreY = -geometry.cameraAboveScreenTop - Double(geometry.physicalSize.height) / 2
    let normalised = geometry.normalise(metres: CGPoint(x: 0, y: centreY))
    #expect(abs(normalised.x - 0.5) < 1e-6)
    #expect(abs(normalised.y - 0.5) < 1e-6)
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
        rawGazeX: 0.012,
        rawGazeY: -0.031,
        gazeX: 0.61,
        gazeY: 0.38,
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
        rawGazeX: nil, rawGazeY: nil,
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
    #expect(object?["gazeX"] is NSNull)
    #expect(object?["gazeY"] is NSNull)
    #expect(object?["rawGazeX"] is NSNull)
    #expect(object?["head"] is NSNull)
}
