import PhotosUI
import SwiftUI
#if os(iOS)
import UIKit
#endif

#if canImport(VisionKit) && os(iOS)
import VisionKit
#endif

struct VoiceButton: View {
    var model: AgentModel

    var body: some View {
        Button {
            Task { await capture() }
        } label: {
            Image(systemName: "mic")
        }
        .accessibilityLabel(String(localized: "Dictate"))
    }

    private func capture() async {
        #if canImport(Speech) && canImport(AVFoundation)
        let text = (try? await SpeechCapture().transcribeOnce()) ?? ""
        if !text.isEmpty {
            await model.send(text)
        }
        #endif
    }
}

struct DocumentButton: View {
    var model: AgentModel
    @State private var photo: PhotosPickerItem?
    @State private var showScanner = false

    var body: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Image(systemName: "doc.viewfinder")
        }
        .accessibilityLabel(String(localized: "Scan a document"))
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let text = (try? await VisionDocuments().recognize(data: data)) ?? ""
                    if !text.isEmpty {
                        await model.ingest(text: text)
                    }
                }
            }
        }
        #if os(iOS)
        .background {
            Button(String(localized: "Camera scan")) { showScanner = true }
                .opacity(0)
                .accessibilityLabel(String(localized: "Camera scan"))
        }
        .sheet(isPresented: $showScanner) {
            DocumentCamera { text in
                Task { await model.ingest(text: text) }
            }
        }
        #endif
    }
}

#if os(iOS) && canImport(VisionKit)
struct DocumentCamera: UIViewControllerRepresentable {
    var onText: (String) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    @MainActor
    final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        let onText: (String) -> Void
        init(onText: @escaping (String) -> Void) { self.onText = onText }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            controller.dismiss(animated: true)
            guard scan.pageCount > 0 else { return }
            let image = scan.imageOfPage(at: 0)
            guard let data = image.jpegData(compressionQuality: 0.8) else { return }
            Task {
                let text = (try? await VisionDocuments().recognize(data: data)) ?? ""
                onText(text)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }
    }
}
#endif
