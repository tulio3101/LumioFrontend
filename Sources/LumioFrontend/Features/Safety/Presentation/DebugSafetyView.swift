#if os(iOS) && DEBUG
import SwiftUI
import ARKit

// MARK: - Debug panel (replaces "Asistencia aún no disponible" in Debug builds)

struct DebugSafetySection: View {
    @ObservedObject var service: SafetyService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusHeader
            cameraWithBoxes
        }
        .padding(.vertical, 4)
    }

    // MARK: Status rows

    private var statusHeader: some View {
        Group {
            Label(
                service.debugState.isActive ? "Detección activa" : "Detección inactiva",
                systemImage: service.debugState.isActive ? "eye.fill" : "eye.slash.fill"
            )
            .foregroundColor(service.debugState.isActive ? .green : .red)
            .font(.subheadline.bold())

            Text("Modo: \(service.debugState.isFullMode ? "completo (LiDAR)" : "reducido (sin LiDAR)")")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("FPS: \(String(format: "%.0f", service.debugState.fps))")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)

            if let date = service.debugState.lastDetectionDate {
                Text("Última det: \(date, style: .time) — \(service.debugState.lastDetections.count) objeto(s)")
                    .font(.caption.monospacedDigit())
            } else {
                Text("Sin detecciones aún")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Camera preview + bounding boxes

    @ViewBuilder
    private var cameraWithBoxes: some View {
        if let source = service.debugPipeline.frameSource as? ARKitFrameSource {
            ZStack(alignment: .topLeading) {
                ARCameraPreview(session: source.arSession)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                DetectionBoxesOverlay(detections: service.debugState.lastDetections)
                    .frame(height: 280)
            }
        } else {
            Text("Preview no disponible (ARKitFrameSource no encontrada)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Camera preview (shares the existing ARSession — no second session opened)

struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session          // attach to existing session, not a new one
        view.automaticallyUpdatesLighting = false
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Detection bounding box overlay

struct DetectionBoxesOverlay: View {
    let detections: [Detection]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(detections.enumerated()), id: \.offset) { _, det in
                let r = boxRect(det.boundingBox, in: geo.size)
                Rectangle()
                    .stroke(Color(uiColor: .systemGreen), lineWidth: 2)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                Text(label(for: det))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(uiColor: .systemGreen))
                    .shadow(color: .black, radius: 1)
                    .position(x: r.midX, y: max(r.minY - 8, 8))
            }
        }
    }

    private func boxRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: box.minX * size.width,
            y: box.minY * size.height,
            width: box.width * size.width,
            height: box.height * size.height
        )
    }

    private func label(for det: Detection) -> String {
        var s = det.obstacleClass.rawValue
        if let dist = det.distanceMeters {
            s += " \(String(format: "%.1f", dist))m"
        }
        return s
    }
}
#endif
