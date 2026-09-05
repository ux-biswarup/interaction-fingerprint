import ARKit
import SceneKit
import SwiftUI

/// What the system sees: the camera image with the tracked face mesh, the head's forward
/// direction and each eye's line of sight drawn over it.
///
/// This exists so the two components of the gaze model can be judged by eye. The corrected
/// gaze is the head direction plus a scaled eye-in-head term, and when the dot is wrong it
/// matters which of the two was wrong. The head line and the eye lines make that visible.
///
/// Display only. Nothing here is recorded, and the ARKit session is the tracker's own.
struct FaceMirrorView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.rendersCameraGrain = false
        view.scene = SCNScene()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session { uiView.session = session }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// SceneKit calls these on its render thread, so nothing here touches main-actor state.
    final class Coordinator: NSObject, ARSCNViewDelegate {
        private var faceGeometry: ARSCNFaceGeometry?
        private let eyeLines = SCNNode()
        private let headLine = SCNNode()

        func renderer(_ renderer: any SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard anchor is ARFaceAnchor, let device = renderer.device else { return nil }
            let node = SCNNode()

            if let geometry = ARSCNFaceGeometry(device: device, fillMesh: false) {
                let material = geometry.firstMaterial
                material?.fillMode = .lines
                material?.diffuse.contents = UIColor(white: 1, alpha: 0.55)
                material?.lightingModel = .constant
                faceGeometry = geometry
                node.geometry = geometry
            }

            node.addChildNode(eyeLines)
            node.addChildNode(headLine)
            return node
        }

        func renderer(_ renderer: any SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let face = anchor as? ARFaceAnchor else { return }
            faceGeometry?.update(from: face.geometry)

            // Each eye to the point ARKit says they converge on. Yellow, like the dot.
            let left = position(face.leftEyeTransform)
            let right = position(face.rightEyeTransform)
            eyeLines.geometry = Self.lines(
                [(left, face.lookAtPoint), (right, face.lookAtPoint)],
                colour: UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)
            )

            // The head's own forward axis, from between the eyes. Cyan. When this and the
            // yellow lines disagree, the difference is the eye-in-head term the model scales.
            let between = (left + right) / 2
            let ahead = between + SIMD3<Float>(0, 0, simd_length(face.lookAtPoint - between))
            headLine.geometry = Self.lines(
                [(between, ahead)],
                colour: UIColor(red: 0.3, green: 0.85, blue: 1.0, alpha: 1)
            )
        }

        private func position(_ transform: simd_float4x4) -> SIMD3<Float> {
            SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }

        private static func lines(_ segments: [(SIMD3<Float>, SIMD3<Float>)], colour: UIColor) -> SCNGeometry {
            var vertices: [SCNVector3] = []
            var indices: [Int32] = []
            for (a, b) in segments {
                indices.append(Int32(vertices.count))
                vertices.append(SCNVector3(a.x, a.y, a.z))
                indices.append(Int32(vertices.count))
                vertices.append(SCNVector3(b.x, b.y, b.z))
            }
            let source = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = colour
            material.lightingModel = .constant
            geometry.materials = [material]
            return geometry
        }
    }
}
