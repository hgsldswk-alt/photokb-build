import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SystemPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let receive: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(receive: receive) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.preferredAssetRepresentationMode = .current
        config.selectionLimit = limit
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let receive: ([PHPickerResult]) -> Void

        init(receive: @escaping ([PHPickerResult]) -> Void) { self.receive = receive }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            receive(results)
        }
    }
}

enum PhotoAccess {
    static func load(_ results: [PHPickerResult], folder: URL) async throws -> [PhotoInput] {
        var inputs: [PhotoInput] = []
        for (index, result) in results.enumerated() {
            try Task.checkCancellation()
            let provider = result.itemProvider
            let name = provider.suggestedName ?? L.f("photo.number", L.integer(index + 1))
            guard let identifier = provider.registeredTypeIdentifiers.first(where: {
                candidate in PhotoFormat.allCases.contains { $0.type.identifier == candidate }
            }) else {
                inputs.append(PhotoInput(name: name, url: nil, info: nil, issue: .unsupported))
                continue
            }
            do {
                let item = try await withThrowingTaskGroup(of: PhotoInput.self) { group in
                    group.addTask { try await transfer(provider, identifier: identifier, folder: folder, name: name) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(20))
                        throw Issue.cloud
                    }
                    defer { group.cancelAll() }
                    guard let item = try await group.next() else { throw Issue.unreadable }
                    return item
                }
                inputs.append(item)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                inputs.append(PhotoInput(name: name, url: nil, info: nil, issue: error as? Issue ?? .unreadable))
            }
        }
        return inputs
    }

    private static func transfer(_ provider: NSItemProvider, identifier: String,
                                 folder: URL, name: String) async throws -> PhotoInput {
        let stream = AsyncThrowingStream<PhotoInput, Error> { continuation in
            let progress = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else {
                    continuation.finish(throwing: Issue.cloud)
                    return
                }
                do {
                    let input = try PhotoStore.stage(url, in: folder, name: name)
                    if case .terminated = continuation.yield(input), let file = input.url {
                        try? FileManager.default.removeItem(at: file)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in progress.cancel() }
        }
        for try await input in stream { return input }
        try Task.checkCancellation()
        throw Issue.unreadable
    }

    static func save(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Issue.permission }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: url, options: nil)
                }
            }
        } catch {
            throw Issue.saveFailed
        }
    }
}

struct ShareRequest: Identifiable {
    let id: UUID
    let items: [Any]
    var group: UUID?
    var resultIDs: [UUID] = []
}

struct SystemShare: UIViewControllerRepresentable {
    let request: ShareRequest
    let finished: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: request.items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, failure in
            Task { @MainActor in finished(completed && failure == nil) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
