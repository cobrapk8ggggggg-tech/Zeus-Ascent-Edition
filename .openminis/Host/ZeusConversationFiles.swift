import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import ZEUSBrowser

extension AIChatViewModel {
    /// Files providers may download or coordinate a large selection. Keep that
    /// work off the UI actor, use the original attachment cache and placeholders,
    /// and never attach the result to a different/new conversation after a move.
    func zeusAddPickedFiles(_ urls: [URL]) {
        for source in urls {
            let id = UUID(), owner = sessionId
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("InputAttachments")
            let target = directory.appendingPathComponent(UUID().uuidString + "_" + source.lastPathComponent)
            attachments.append(InputAttachment(id: id, fileName: source.lastPathComponent, cacheURL: target, kind: .document, loadState: .loading))
            Task { @MainActor [weak self] in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let accessed = source.startAccessingSecurityScopedResource()
                        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        var readError: Error?, coordinationError: NSError?
                        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                            do { try FileManager.default.copyItem(at: readable, to: target) } catch { readError = error }
                        }
                        if let coordinationError { throw coordinationError }
                        if let readError { throw readError }
                    }.value
                    guard let self, self.sessionId == owner, let index = self.attachments.firstIndex(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: target); return }
                    let type = UTType(filenameExtension: source.pathExtension)
                    self.attachments[index].kind = type?.conforms(to: .image) == true || Self.detectImageType(atFileURL: target) != nil ? .image : (type?.conforms(to: .movie) == true ? .video : .document)
                    self.attachments[index].loadState = .ready
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    self?.markPlaceholderFailed(id: id)
                }
            }
        }
    }

}
