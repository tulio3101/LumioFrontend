#if os(iOS) && DEBUG
import SwiftUI
import ARKit

// MARK: - Debug panel (replaces "Asistencia aún no disponible" in Debug builds)

struct DebugSafetySection: View {
    @ObservedObject var service: SafetyService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusHeader
            recorderRow
            diagnostics
            cameraWithBoxes
        }
        .padding(.vertical, 4)
    }

    // MARK: Grabar 10 s (SCRUM-33)

    private var recorderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button {
                    service.startRecording(seconds: 10)
                } label: {
                    Label(service.recordingActive ? "Grabando…" : "Grabar 10 s",
                          systemImage: service.recordingActive ? "record.circle.fill" : "record.circle")
                }
                .font(.caption.bold())
                .disabled(service.recordingActive)
                if let name = service.lastRecordingName {
                    Text(name).font(.caption2.monospaced()).foregroundColor(.secondary).lineLimit(1)
                }
            }
            if !recordingFiles.isEmpty {
                ShareLink(items: recordingFiles) {
                    Label("Compartir grabaciones (\(recordingFiles.count))", systemImage: "square.and.arrow.up")
                }
                .font(.caption)
            }
        }
    }

    /// JSON de grabaciones en Documentos, para el botón Compartir (y Archivos con UIFileSharingEnabled).
    private var recordingFiles: [URL] {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
              ) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("lumio-safety-") && $0.pathExtension == "json" }
    }

    // MARK: Diagnóstico de desniveles + YOLO crudas

    @ViewBuilder
    private var diagnostics: some View {
        if let d = service.debugState.lastDebug {
            VStack(alignment: .leading, spacing: 3) {
                Text("YOLO crudas: \(d.rawDetections.count) · tracked: \(d.trackedCount) · prof.obj: \(d.depthObstacleCount)")
                    .font(.caption.monospacedDigit())
                if !d.rawDetections.isEmpty {
                    Text(d.rawDetections.map { "\($0.cls) \(String(format: "%.2f", $0.confidence))" }
                        .joined(separator: ", "))
                        .font(.caption2.monospaced()).foregroundColor(.secondary).lineLimit(2)
                }
                Text(floorLine(d)).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                Text("hazard crudo: \(d.rawHazard)  ·  anunciado: \(d.announcedHazards.isEmpty ? "—" : d.announcedHazards.joined(separator: ", "))")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(2)
                profileGraph(d)
            }
        }
    }

    private func floorLine(_ d: SafetyDebugFrame) -> String {
        let floor = d.floorHeight.map { String(format: "%.2f", $0) } ?? "—"
        let cam = d.cameraHeightAboveFloor.map { String(format: "%.2f", $0) } ?? "—"
        let pitch = d.pitchDegrees.map { String(format: "%.0f°", $0) } ?? "—"
        return "piso Y: \(floor)  ·  cámara sobre piso: \(cam) m  ·  pitch: \(pitch)"
    }

    /// Mini gráfica distancia vs. altura: una barra por bin (↑ verde arriba, ↓ roja abajo, hueco gris).
    private func profileGraph(_ d: SafetyDebugFrame) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(d.profileHeights.enumerated()), id: \.offset) { _, h in
                let mag = min(abs(h ?? 0) / 0.5, 1)   // normaliza a ±0.5 m
                Rectangle()
                    .fill(color(for: h))
                    .frame(width: 6, height: CGFloat(4 + mag * 24))
            }
        }
        .frame(height: 30, alignment: .center)
    }

    private func color(for height: Float?) -> Color {
        guard let h = height else { return .gray }     // hueco
        if h <= -0.08 { return .red }                   // bajada
        if h >= 0.08 { return .blue }                   // subida
        return .green                                   // ~plano
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

            // Causa real cuando la detección no está activa (modelo ausente, fallo de Core ML,
            // cámara interrumpida…). El detalle técnico va además al log (YOLORunner).
            if !service.debugState.isActive {
                Text(service.status.message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        if let source = service.debugPreviewFrameSource {
            ZStack(alignment: .topLeading) {
                ARCameraPreview(session: source.arSession)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: LumioRadius.preview))
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
