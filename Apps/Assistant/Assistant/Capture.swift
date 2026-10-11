import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(iOS)
import UIKit
#endif

/// Turns an attachment into text on this device. Nothing is uploaded; the text goes into the message.
enum AttachmentReader {
    static let fileTypes: [UTType] = [.plainText, .utf8PlainText, .text, .json, .commaSeparatedText, .pdf, .image]

    static func text(fromImage data: Data) async -> String {
        (try? await VisionDocuments().recognize(data: data)) ?? ""
    }

    static func text(fromFile url: URL) async -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        #if canImport(PDFKit)
        if type?.conforms(to: .pdf) == true, let document = PDFDocument(url: url) {
            return document.string ?? ""
        }
        #endif
        if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: url) {
            return await text(fromImage: data)
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// Dictation that streams partial text until `stop()`. Recognition stays on device when supported.
@MainActor
@Observable
final class Dictation {
    var isListening = false
    var text = ""

    #if canImport(Speech) && canImport(AVFoundation)
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    #endif

    func start() async -> Bool {
        #if canImport(Speech) && canImport(AVFoundation)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer, recognizer.isAvailable else { return false }
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        self.request = request
        text = ""
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let partial = result?.bestTranscription.formattedString
            let finished = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self else { return }
                if let partial { self.text = partial }
                if finished { self.stop() }
            }
        }
        return true
        #else
        return false
        #endif
    }

    func stop() {
        #if canImport(Speech) && canImport(AVFoundation)
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
    }
}

#if os(iOS)
/// The system camera. Returns JPEG data for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, @MainActor UIImagePickerControllerDelegate, @MainActor UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
