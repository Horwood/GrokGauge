import Foundation

/// Watches the shared settings folder and file. Sync clients (Google Drive, Insync, Dropbox, iCloud)
/// often replace a file rather than write it in place, so this watches the folder (renames/creates),
/// the file itself (in-place writes), and also polls as a fallback.
final class FolderWatcher {
    private let directory: URL
    private let file: URL
    private let onChange: () -> Void
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var lastSeen: (Date?, Int?) = (nil, nil)
    private var pending: DispatchWorkItem?

    init(directory: URL, file: URL, pollInterval: TimeInterval = 30, onChange: @escaping () -> Void) {
        self.directory = directory
        self.file = file
        self.onChange = onChange
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.poll() }
        pollTimer = timer
    }

    func start() {
        lastSeen = stamp()
        arm()
        pollTimer?.resume()
    }

    func stop() {
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
        pollTimer?.cancel(); pollTimer = nil
        pending?.cancel()
    }

    deinit { stop() }

    private func arm() {
        if dirSource == nil { dirSource = source(for: directory) }
        if fileSource == nil { fileSource = source(for: file) }
    }

    private func source(for url: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                // The watched node went away (atomic replace); re-open on the next event or poll.
                src.cancel()
                if src === self.dirSource { self.dirSource = nil }
                if src === self.fileSource { self.fileSource = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.arm() }
            }
            self.changed()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    private func stamp() -> (Date?, Int?) {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate, values?.fileSize)
    }

    private func poll() {
        arm()
        let now = stamp()
        if now.0 != lastSeen.0 || now.1 != lastSeen.1 { changed() }
    }

    /// Coalesces bursts of events (a sync client may touch the file several times).
    private func changed() {
        lastSeen = stamp()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
