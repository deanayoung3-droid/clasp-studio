import Foundation
import Speech
import CoreMedia

struct ScriptVoicePosition: Equatable {
    var section: Int
    var word: Int
    var finished: Bool
}

// Recognition results are cumulative and may revise their last few words. Align a
// short suffix near the current cue; require multiple matches before jumping.
struct SpeechScriptMatcher {
    private var tokens: [String] = []
    private var locations: [(section: Int, word: Int)] = []
    private var previousTranscript: [String] = []
    private var lastSection = 0
    private var lastWordCount = 0
    private(set) var cursor = 0

    init(sections: [ScriptSection], section: Int = 0, word: Int = 0) {
        for (sectionIndex, item) in sections.enumerated() {
            for (wordIndex, raw) in item.words.enumerated() {
                for token in Self.normalize(raw) {
                    tokens.append(token); locations.append((sectionIndex, wordIndex))
                }
            }
        }
        lastSection = max(0, sections.count - 1)
        lastWordCount = sections.last?.words.count ?? 0
        cursor = locations.firstIndex { $0.section > section || ($0.section == section && $0.word >= word) } ?? tokens.count
    }
    static func normalize(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.flatMap { word -> [String] in
            guard word.allSatisfy({ $0.isNumber }), let number = Int(word), number >= 0, number < 1_000_000 else { return [word] }
            let formatter = NumberFormatter(); formatter.numberStyle = .spellOut; formatter.locale = Locale(identifier: "en_US")
            return (formatter.string(from: NSNumber(value: number)) ?? word).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
    }
    mutating func resetTranscript() { previousTranscript = [] }
    var position: ScriptVoicePosition {
        guard cursor < locations.count else { return ScriptVoicePosition(section: lastSection, word: lastWordCount, finished: true) }
        let point = locations[cursor]
        return ScriptVoicePosition(section: point.section, word: point.word, finished: false)
    }
    mutating func update(_ transcript: String) -> ScriptVoicePosition? {
        let all = Self.normalize(transcript)
        guard !all.isEmpty, all != previousTranscript, cursor < tokens.count else { return nil }
        var common = 0
        while common < min(all.count, previousTranscript.count), all[common] == previousTranscript[common] { common += 1 }
        previousTranscript = all
        // A shortened revision supplies no new evidence to move ahead.
        guard common < all.count else { return nil }
        let spoken = Array(all[max(0, max(common - 3, all.count - 12))...])
        let lower = max(0, cursor - 12), upper = min(tokens.count, cursor + 40)
        var bestEnd = cursor, bestScore = -Double.infinity
        for start in lower..<upper {
            // Local sequence alignment permits a missed script word or a filler.
            var scores = Array(repeating: -Double.infinity, count: spoken.count + 1)
            var matches = Array(repeating: 0, count: spoken.count + 1)
            scores[0] = 0
            for end in start..<min(upper, start + spoken.count + 6) {
                var nextScores = Array(repeating: -Double.infinity, count: spoken.count + 1)
                var nextMatches = Array(repeating: 0, count: spoken.count + 1)
                nextScores[0] = scores[0] - 1.5
                for j in 1...spoken.count {
                    let equal = tokens[end] == spoken[j - 1]
                    let choices: [(Double, Int)] = [
                        (scores[j - 1] + (equal ? 3 : -2.5), matches[j - 1] + (equal ? 1 : 0)),
                        (scores[j] - 1.5, matches[j]),
                        (nextScores[j - 1] - 1.8, nextMatches[j - 1])
                    ]
                    let choice = choices.max { $0.0 < $1.0 }!
                    nextScores[j] = choice.0; nextMatches[j] = choice.1
                }
                scores = nextScores; matches = nextMatches
                let count = matches[spoken.count]
                let advance = end + 1 - cursor
                let required = advance > 8 ? 4 : (tokens.count - cursor == 1 ? 1 : 2)
                guard advance > 0, count >= required, tokens[end] == spoken.last,
                      scores[spoken.count] >= Double(required) * 2, count * 2 >= spoken.count else { continue }
                let ranked = scores[spoken.count] - Double(max(0, start - cursor)) * 0.45 - Double(advance) * 0.025
                if ranked > bestScore { bestScore = ranked; bestEnd = end + 1 }
            }
        }
        guard bestEnd > cursor else { return nil }
        cursor = bestEnd
        return position
    }
}

// Shares the capture session's selected microphone. All Speech objects live on
// this queue so append, cancellation and recognition restarts never race.
final class SpeechFollower: @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.speech", qos: .userInitiated)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: DispatchSourceTimer?
    private var generation = UUID()
    private var active = false
    private var runID = UUID()
    private var receivedText = false
    private var hints: [String] = []
    private let stateLock = NSLock()
    private var acceptingAudio = false
    private let pendingAudio = DispatchSemaphore(value: 8)
    private var lastTranscriptTime = 0.0
    private var lastTranscript = ""
    private var retryCount = 0
    private var pendingTranscript: String?
    private var transcriptDelivery: DispatchWorkItem?
    var onTranscript: ((UUID, String) -> Void)?
    var onSessionReset: ((UUID) -> Void)?
    var onFailure: ((UUID, String) -> Void)?

    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
    func start(id: UUID, hints: [String] = []) {
        queue.async { [self] in
            self.stopOnQueue(); self.runID = id; self.hints = hints; self.retryCount = 0
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")), recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition else {
                self.onFailure?(id, "On-device English speech recognition is unavailable on this Mac. Use Reading pace, or enable English Dictation in System Settings → Keyboard and try again.")
                return
            }
            self.recognizer = recognizer; self.active = true; self.beginSession()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 50, repeating: 50)
            timer.setEventHandler { [weak self] in self?.beginSession() }
            self.restartTimer = timer; timer.resume()
        }
    }
    func append(_ sample: CMSampleBuffer) {
        stateLock.lock(); let enabled = acceptingAudio; stateLock.unlock()
        // No queued microphone work while paused; cap outstanding samples when
        // Speech is busy instead of retaining an unbounded audio backlog.
        guard enabled, pendingAudio.wait(timeout: .now()) == .success else { return }
        queue.async { self.request?.appendAudioSampleBuffer(sample); self.pendingAudio.signal() }
    }
    func stop() {
        stateLock.lock(); acceptingAudio = false; stateLock.unlock()
        queue.async { self.stopOnQueue() }
    }
    private func stopOnQueue() {
        stateLock.lock(); acceptingAudio = false; stateLock.unlock()
        transcriptDelivery?.cancel(); transcriptDelivery = nil; pendingTranscript = nil
        active = false; generation = UUID(); restartTimer?.cancel(); restartTimer = nil
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil
    }
    private func deliverTranscript(_ text: String, final: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if final || now - lastTranscriptTime >= 0.15 {
            transcriptDelivery?.cancel(); transcriptDelivery = nil; pendingTranscript = nil
            lastTranscript = text; lastTranscriptTime = now; onTranscript?(runID, text)
        } else {
            pendingTranscript = text
            guard transcriptDelivery == nil else { return }
            let id = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.active, self.generation == id else { return }
                self.transcriptDelivery = nil
                guard let latest = self.pendingTranscript else { return }
                self.pendingTranscript = nil; self.lastTranscript = latest
                self.lastTranscriptTime = ProcessInfo.processInfo.systemUptime
                self.onTranscript?(self.runID, latest)
            }
            transcriptDelivery = work; queue.asyncAfter(deadline: .now() + max(0, 0.15 - (now - lastTranscriptTime)), execute: work)
        }
    }
    private func scheduleRestart() {
        if let latest = pendingTranscript { deliverTranscript(latest, final: true) }
        stateLock.lock(); acceptingAudio = false; stateLock.unlock()
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        generation = UUID(); let id = generation
        retryCount += 1
        // Idle/no-speech failures sometimes arrive immediately. Back off so they
        // cannot create a rapid task-restart loop and consume the capture budget.
        queue.asyncAfter(deadline: .now() + min(3, Double(retryCount) * 0.5)) { [weak self] in
            guard let self, self.active, self.generation == id else { return }; self.beginSession()
        }
    }
    private func beginSession() {
        guard active, let recognizer else { return }
        transcriptDelivery?.cancel(); transcriptDelivery = nil; pendingTranscript = nil
        generation = UUID(); let id = generation
        request?.endAudio(); task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = hints.map { String($0.prefix(200)) }
        self.request = request; receivedText = false; lastTranscript = ""; lastTranscriptTime = 0
        stateLock.lock(); acceptingAudio = true; stateLock.unlock()
        onSessionReset?(runID)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard self.active, self.generation == id else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        self.receivedText = true; self.retryCount = 0
                        if text != self.lastTranscript { self.deliverTranscript(text, final: result.isFinal) }
                    }
                    if result.isFinal { self.scheduleRestart(); return }
                }
                if let error {
                    // A recognizer may close an idle dictation session. Keep listening
                    // after a normal no-speech timeout, but surface other failures.
                    let ns = error as NSError
                    if ns.code == 1110 || self.receivedText { self.scheduleRestart() }
                    else {
                        self.stopOnQueue()
                        self.onFailure?(self.runID, "Voice following stopped: \(error.localizedDescription). You can try again or switch to Reading pace.")
                    }
                }
            }
        }
    }
}
