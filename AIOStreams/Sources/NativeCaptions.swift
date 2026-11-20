import AVFoundation
import AetherEngineFeatures

/// The subtitle lines of a stream AVPlayer plays itself (a remote HLS stream's renditions, on the
/// engine's bypass route), read with a legible output that holds AVPlayer's own rendering back, so
/// the app's overlay draws them in the page's style rather than iOS's caption style.
@MainActor
final class NativeCaptions: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let output = AVPlayerItemLegibleOutput()
    private weak var item: AVPlayerItem?
    private let show: ([SubtitleCue]) -> Void
    private var nextID = 0

    init(show: @escaping ([SubtitleCue]) -> Void) {
        self.show = show
        super.init()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
    }

    /// Reads the lines of `item`, the engine's current AVPlayer item, leaving the last one's.
    func attach(to next: AVPlayerItem?) {
        guard next !== item else { return }
        if let item, item.outputs.contains(output) { item.remove(output) }
        item = next
        if let next, !next.outputs.contains(output) { next.add(output) }
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                   didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any],
                                   forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        MainActor.assumeIsolated {
            // Each push is what shows from now until the next, so the cue lasts until replaced.
            nextID += 1
            show(text.isEmpty ? [] : [SubtitleCue(id: -nextID, startTime: 0, endTime: .greatestFiniteMagnitude, body: .text(text))])
        }
    }
}
