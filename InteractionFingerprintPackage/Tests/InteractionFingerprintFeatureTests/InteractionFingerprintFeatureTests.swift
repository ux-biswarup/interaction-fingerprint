import Foundation
import Testing
@testable import InteractionFingerprintFeature

@Test("V0 records exactly the nine blend shapes named in the setup guide")
func trackedBlendShapesMatchTheGuide() {
    #expect(TrackedBlendShapes.all.count == 9)
    // ARKit's raw values are not the Swift case names. Pinned here so that an SDK
    // change to the exported column names fails a test instead of silently breaking
    // every analysis notebook.
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

@Test("A tracked sample survives a JSON round trip unchanged")
func faceSampleRoundTripsThroughJSON() throws {
    let sample = FaceSample(
        timestamp: 1234.5,
        isTracked: true,
        gazeX: 0.61,
        gazeY: 0.38,
        signals: ["eyeSquint_L": 0.21, "eyeBlink_R": 0.04],
        head: HeadPose(x: 0.01, y: -0.02, z: -0.35, pitch: 0.05, yaw: -0.02, roll: 0)
    )

    let data = try JSONEncoder().encode(sample)
    let decoded = try JSONDecoder().decode(FaceSample.self, from: data)

    #expect(decoded == sample)
}

@Test("Tracking loss is recorded rather than dropped, with null gaze")
func untrackedSampleKeepsNullGaze() throws {
    let sample = FaceSample(
        timestamp: 99,
        isTracked: false,
        gazeX: nil,
        gazeY: nil,
        signals: [:],
        head: nil
    )

    let data = try JSONEncoder().encode(sample)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    // Analysis reads these as a stable column set, so the keys must be present
    // as nulls rather than omitted.
    #expect(object?["isTracked"] as? Bool == false)
    #expect(object?["gazeX"] is NSNull)
    #expect(object?["gazeY"] is NSNull)
}
