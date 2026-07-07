import Foundation
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingCaptureService")

/// Drives live meeting capture (plan M3). It wraps `AudioRecorderService` directly and owns its
/// *own* `StreamingHandler` instance (plan D1) — it never touches the standalone Recorder's
/// view-model state, its `livePreviewEnabled` setting, or the EventBus (plan D14). Stabilized
/// transcript text is persisted incrementally as `MeetingSegment`s through `MeetingService`
/// (plan D2), and on stop the full buffer is re-transcribed to timestamped segments (plan D3).
@MainActor
final class MeetingCaptureService: ObservableObject {
    /// Capture sample rate (16 kHz mono) — used to convert the finalize buffer length to seconds
    /// for the AD8 cloud-ceiling guard.
    static let sampleRate: Double = 16_000

    enum CaptureError: LocalizedError, Equatable {
        /// The standalone Recorder (or another meeting) currently owns the capture stack.
        case recorderBusy
        /// A capture session is already in progress.
        case alreadyCapturing

        var errorDescription: String? {
            switch self {
            case .recorderBusy:
                return String(localized: "meetings.capture.error.recorderBusy")
            case .alreadyCapturing:
                return String(localized: "meetings.capture.error.alreadyCapturing")
            }
        }
    }

    // MARK: - Published capture state

    @Published private(set) var activeMeeting: Meeting?
    @Published private(set) var isCapturing = false
    /// True while `stop()` is finalizing — the multi-second span *after* `isCapturing` flips false
    /// but before teardown (`streamingHandler.finish`, `stopRecording`, full-buffer finalize) has
    /// completed. `start()` (and the window's synchronous `createAndStartAdHocCapture` guard) must
    /// still refuse during this window, because the recorder, the (re-entrant-for-`.meeting`)
    /// ownership lock, and the audio buffer are all being torn down; a new session slipping in would
    /// reset the buffer, re-install taps on the running engine, and race the finalize (finding 2).
    @Published private(set) var isFinalizing = false
    /// Whole accumulated stabilized transcript for the live-capture preview (never persisted per
    /// update; only stabilized suffixes are flushed to disk).
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    /// True when the selected engine lacks live-session support and the handler is running the
    /// windowed re-transcription fallback (plan D18) — surfaced as a reduced-quality indicator.
    @Published private(set) var isDegradedLiveMode = false
    /// True when the resolved final re-transcription policy (addendum AD8) could not be honored and
    /// degraded to a safer path (unavailable override engine, or an oversized cloud pass). Surfaced
    /// as a status, never an error dialog. Persists after `stop()` so the UI can note the last
    /// capture finalized in a degraded mode.
    @Published private(set) var finalRetranscriptionDegraded = false
    /// The default output template (opaque UUID) chosen by the matched capture-context rule for the
    /// active meeting (addendum AD7), so the generate flow can pre-select it. `nil` when no rule
    /// matched or the rule set no default.
    @Published private(set) var activeMeetingDefaultTemplateID: UUID?
    @Published private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let meetingService: MeetingService
    private let audioRecorderService: AudioRecorderService
    private let modelManager: ModelManagerService
    private let defaults: UserDefaults
    /// Interval (seconds) between durable stable-segment flushes during capture (plan D2 ≤ 5 s).
    private let flushIntervalSeconds: TimeInterval
    /// Publishes `MeetingEvent`s to plugins (addendum AD4). Defaulted no-op so v1 call sites/tests
    /// are unchanged.
    private let eventEmitter: MeetingEventEmitting
    /// Resolves an about-to-start meeting to a capture-context rule (addendum AD7). Optional so v1
    /// call sites/tests compile without rules; when nil, recorder defaults always apply.
    private let ruleMatcher: MeetingContextRuleMatching?
    /// Cloud audio duration ceiling before an `.engine` final pass on a metered engine degrades to
    /// `.sameEngine` (addendum AD8).
    private let cloudCeilingSeconds: Double
    /// Whether a final-pass override engine id is currently available (loadable/selectable).
    private let engineAvailabilityCheck: (String) -> Bool
    /// Whether a final-pass override engine id is a metered/cloud engine.
    private let engineIsCloudCheck: (String) -> Bool

    // MARK: - Session bookkeeping

    private var streamingHandler: StreamingHandler?
    private var captureStartTime: Date?
    private var elapsedTimer: AnyCancellable?

    /// Accumulated stabilized text (drives the UI preview and is the base for persistence).
    private var confirmedText = ""
    /// The portion of `confirmedText` already written to `MeetingSegment` rows.
    private var persistedText = ""
    /// End time (elapsed seconds) of the most recently persisted segment; start of the next.
    private var lastSegmentEnd: TimeInterval = 0
    /// Timeline offset (seconds) for this session's segments so a *restarted* capture on a meeting
    /// that already has persisted segments appends after them instead of overlapping (finding 1).
    /// Zero for a fresh meeting. Applied to both live-flushed and final-transcription segments.
    private var sessionTimeOffset: TimeInterval = 0
    /// Ids of `.liveCapture` segments that existed *before* this session started. They belong to an
    /// earlier finalized session and must survive `stop()`'s finalize replace (plan D3).
    private var priorLiveCaptureSegmentIDs: Set<UUID> = []
    /// The meeting's state before this session set it `.live`, restored if start fails so an
    /// interrupted/completed meeting keeps its marker on a failed restart (finding 6).
    private var previousMeetingState: MeetingState = .scheduled
    /// Elapsed seconds at the last flush attempt (throttle anchor).
    private var lastFlushElapsed: TimeInterval = 0
    /// Latest elapsed value observed from a live-transcript update.
    private var latestElapsed: TimeInterval = 0

    // MARK: - Capture-context rule session overrides (addendum AD7/AD8)

    /// Live engine override selected by the matched rule for this session (nil = recorder default).
    private var sessionLiveEngineOverride: String?
    /// Live model override selected by the matched rule for this session.
    private var sessionLiveModelOverride: String?
    /// Language override selected by the matched rule for this session (nil = `.auto`).
    private var sessionLanguageOverride: LanguageSelection?
    /// Final re-transcription policy the matched rule set for this session (nil = inherit).
    private var sessionRulePolicy: FinalRetranscriptionPolicy?

    init(
        meetingService: MeetingService,
        audioRecorderService: AudioRecorderService,
        modelManager: ModelManagerService,
        defaults: UserDefaults = .standard,
        flushIntervalSeconds: TimeInterval = 5,
        eventEmitter: MeetingEventEmitting = NoopMeetingEventEmitter(),
        ruleMatcher: MeetingContextRuleMatching? = nil,
        cloudCeilingSeconds: Double = FinalRetranscriptionPolicy.defaultCloudCeilingSeconds,
        engineAvailabilityCheck: ((String) -> Bool)? = nil,
        engineIsCloudCheck: ((String) -> Bool)? = nil
    ) {
        self.meetingService = meetingService
        self.audioRecorderService = audioRecorderService
        self.modelManager = modelManager
        self.defaults = defaults
        self.flushIntervalSeconds = flushIntervalSeconds
        self.eventEmitter = eventEmitter
        self.ruleMatcher = ruleMatcher
        self.cloudCeilingSeconds = cloudCeilingSeconds
        self.engineAvailabilityCheck = engineAvailabilityCheck ?? { id in
            PluginManager.shared.transcriptionEngine(for: id) != nil
        }
        self.engineIsCloudCheck = engineIsCloudCheck ?? { [weak modelManager] id in
            modelManager?.usesMeteredStreamingFallback(engineOverrideId: id) ?? false
        }
    }

    // MARK: - Lifecycle

    /// Begin capturing into `meeting`. Acquires exclusive ownership of the capture stack, starts
    /// the recorder, and wires an owned `StreamingHandler` for the live preview + incremental
    /// persistence. Throws `CaptureError.recorderBusy` if the Recorder currently owns capture.
    func start(
        meeting: Meeting,
        micEnabled: Bool = true,
        systemAudioEnabled: Bool = true
    ) async throws {
        guard !isCapturing, !isFinalizing else { throw CaptureError.alreadyCapturing }

        // Claim `isCapturing` synchronously — before the first `await` — so a second `start()`
        // slipping in during `startRecording`'s suspension (double-click on "New Meeting" or the
        // detail Start button, both gated only by `isCapturing`) is rejected by the guard above
        // instead of overwriting `activeMeeting` and racing a concurrent recording start
        // (finding 2). Mirrors `AudioRecorderViewModel`'s `state = .recording` placement.
        isCapturing = true

        guard audioRecorderService.acquireCaptureOwnership(.meeting) else {
            isCapturing = false
            throw CaptureError.recorderBusy
        }

        resetSessionState()
        errorMessage = nil
        activeMeeting = meeting

        // AD7: resolve any matching capture-context rule *before* streaming starts so its live
        // engine/model/language overrides feed `startStreaming()` and its final-pass policy +
        // default template are stashed for this session. No-op when no matcher/rule applies.
        applyContextRule(for: meeting)

        // Watermark the pre-existing content so finalize (stop) touches only this session's
        // segments and its timestamps sit after the prior session's (finding 1).
        previousMeetingState = meeting.state
        priorLiveCaptureSegmentIDs = Set(
            meeting.segments.filter { $0.source == .liveCapture }.map(\.id)
        )
        sessionTimeOffset = meeting.segments.map(\.end).max() ?? 0
        lastSegmentEnd = sessionTimeOffset

        meeting.state = .live
        meetingService.update(meeting)

        do {
            _ = try await audioRecorderService.startRecording(
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled,
                format: .wav
            )
        } catch {
            audioRecorderService.releaseCaptureOwnership(.meeting)
            meeting.state = previousMeetingState
            meetingService.update(meeting)
            activeMeeting = nil
            isCapturing = false
            errorMessage = error.localizedDescription
            throw error
        }

        captureStartTime = Date()
        startElapsedTimer()
        startStreaming()

        // AD4 emission point 1/5: capture session started.
        eventEmitter.emit(.started(MeetingStartedPayload(
            meetingID: meeting.id,
            title: meeting.title,
            startedAt: captureStartTime ?? Date(),
            isCalendarMeeting: meeting.source == .calendar,
            attendeeCount: meeting.attendees.count
        )))
    }

    /// Stop capturing: finalize the live session, persist any pending stable tail, move the audio
    /// file into the meetings library, re-transcribe the full buffer to timestamped segments
    /// (falling back to the live-stabilized segments on failure), and mark the meeting completed.
    func stop() async {
        // Re-entrancy guard (finding 3): a double-click on Stop (the VM's `isCapturing` mirror
        // lags by a main-queue hop) must not run the finalize pipeline twice concurrently.
        guard isCapturing, let meeting = activeMeeting else { return }

        isCapturing = false
        // Keep `start()`'s guard closed across the multi-`await` finalize below: `isCapturing` is
        // already false (so the UI stops showing "recording"), but a new session must not begin
        // until teardown finishes (finding 2). A double-click on Stop is still handled by the
        // `guard isCapturing` above — this only gates a concurrent *start*.
        isFinalizing = true
        defer { isFinalizing = false }
        stopElapsedTimer()

        meeting.state = .processing
        meetingService.update(meeting)

        // Grab the full 16 kHz buffer before tearing down (it survives stopRecording).
        let fullBuffer = audioRecorderService.getCurrentBuffer()

        let liveSessionResult = await streamingHandler?.finish()
        streamingHandler = nil

        // Persist any stabilized tail that has not yet been flushed.
        flushPendingSegments(elapsed: latestElapsed)

        let audioURL = await audioRecorderService.stopRecording()
        audioRecorderService.releaseCaptureOwnership(.meeting)

        if let audioURL {
            meetingService.adoptAudioFile(audioURL, for: meeting)
        }

        // Final timestamped transcript (plan D3). Prefer a segmented live-session result; else
        // re-transcribe the full buffer; if neither yields segments, keep the live segments.
        let finalSegments = await finalizeSegments(liveSessionResult: liveSessionResult, buffer: fullBuffer)
        if let finalSegments, !finalSegments.isEmpty {
            // Final segments are timed relative to *this* session's buffer (0-based); shift them
            // onto the meeting timeline and replace only this session's live segments, preserving
            // any from an earlier finalized session (finding 1 / plan D3).
            let offsetSegments = finalSegments.map { segment in
                TranscriptionSegment(
                    text: segment.text,
                    start: segment.start + sessionTimeOffset,
                    end: segment.end + sessionTimeOffset,
                    speakerLabel: segment.speakerLabel,
                    speakerConfidence: segment.speakerConfidence
                )
            }
            meetingService.replaceSegments(
                of: meeting,
                source: .liveCapture,
                with: offsetSegments,
                preservingSegmentIDs: priorLiveCaptureSegmentIDs
            )
        }

        // AD4 emission point 3/5: final transcript is ready (after live segments were replaced).
        let readyText = transcriptText(for: meeting)
        let durationSeconds = meeting.segments.map(\.end).max() ?? latestElapsed
        let segmentCount = meeting.segments.count
        eventEmitter.emit(.transcriptReady(MeetingTranscriptReadyPayload(
            meetingID: meeting.id,
            fullText: readyText,
            segmentCount: segmentCount,
            durationSeconds: durationSeconds
        )))

        meeting.state = .completed
        meetingService.update(meeting)

        // AD4 emission point 4/5: capture session ended.
        eventEmitter.emit(.ended(MeetingEndedPayload(
            meetingID: meeting.id,
            endedAt: Date(),
            durationSeconds: durationSeconds,
            stateRaw: meeting.state.rawValue,
            segmentCount: segmentCount
        )))

        activeMeeting = nil
        liveTranscript = ""
        elapsedSeconds = 0
        isDegradedLiveMode = false
    }

    /// The meeting's full transcript rendered as newline-separated segment text, ordered by
    /// `order`, for the `.transcriptReady` payload (addendum AD4).
    private func transcriptText(for meeting: Meeting) -> String {
        meeting.segments
            .sorted { $0.order < $1.order }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Notes

    /// Add an in-meeting note, stamped with elapsed seconds from the start of capture when live.
    @discardableResult
    func addNote(_ text: String) -> MeetingNote? {
        guard let meeting = activeMeeting else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Stamp on the meeting timeline (shifted by `sessionTimeOffset`), matching persisted
        // segment starts, so notes taken during a *restarted* session don't collide with session 1's
        // timeline in outputs/export (finding 5).
        let offset = isCapturing ? meetingTimelineElapsed : nil
        return meetingService.addNote(to: meeting, text: trimmed, timestampOffset: offset)
    }

    // MARK: - Streaming wiring

    private func startStreaming() {
        let handler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: { [weak audioRecorderService] in
                audioRecorderService?.getCurrentBuffer() ?? []
            },
            recentBufferProvider: { [weak audioRecorderService] maxDuration in
                audioRecorderService?.getRecentBuffer(maxDuration: maxDuration) ?? []
            },
            bufferDeltaProvider: { [weak audioRecorderService] offset in
                audioRecorderService?.getBufferDelta(since: offset) ?? ([], offset)
            },
            bufferedDurationProvider: { [weak audioRecorderService] in
                audioRecorderService?.totalBufferDuration ?? 0
            }
        )
        handler.onPartialTextUpdate = { [weak self] text in
            guard let self else { return }
            self.ingestLiveTranscript(text, elapsed: self.currentElapsed())
        }
        streamingHandler = handler

        // Read the Recorder's engine/model selection read-only; never mutate its settings (D1). A
        // matched capture-context rule (AD7) overrides the engine/model for this session only.
        let providerId = sessionLiveEngineOverride
            ?? defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        let cloudModelOverride = modelManager.resolvedModelId(
            engineOverrideId: providerId,
            cloudModelOverride: sessionLiveModelOverride
                ?? defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel)
        )
        let selectedProviderId = modelManager.selectedProviderId
        let effectiveProviderId = providerId ?? selectedProviderId

        // Reduced-quality indicator when no live-session engine is available (D18).
        isDegradedLiveMode = effectiveProviderId != nil
            && !modelManager.supportsLiveTranscriptionSession(engineOverrideId: providerId)

        handler.start(
            streamPrompt: "",
            engineOverrideId: providerId,
            selectedProviderId: selectedProviderId,
            languageSelection: sessionLanguageOverride ?? .auto,
            task: .transcribe,
            cloudModelOverride: cloudModelOverride,
            allowLiveTranscription: true,
            stateCheck: { [weak self] in self?.isCapturing == true }
        )
    }

    /// Ingest a stabilized transcript snapshot from the streaming handler: update the preview and,
    /// when the flush interval has elapsed, persist the newly-stable suffix as a segment.
    ///
    /// Internal (not private) so unit tests can script a stabilized-text sequence without a live
    /// engine.
    func ingestLiveTranscript(_ raw: String, elapsed: TimeInterval) {
        latestElapsed = elapsed
        let stabilized = StreamingHandler.stabilizeText(confirmed: confirmedText, new: raw)
        confirmedText = stabilized
        liveTranscript = stabilized

        if elapsed - lastFlushElapsed >= flushIntervalSeconds {
            flushPendingSegments(elapsed: elapsed)
        }
    }

    /// Persist the portion of the stabilized transcript not yet written to disk as a single
    /// `.liveCapture` segment. A no-op when nothing new has stabilized (so repeated identical
    /// snapshots upsert rather than duplicate). Internal for testing.
    func flushPendingSegments(elapsed: TimeInterval) {
        guard let meeting = activeMeeting else { return }
        lastFlushElapsed = elapsed

        let previous = persistedText
        let current = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, current != previous else { return }

        let suffix: String
        let newBaseline: String
        if previous.isEmpty {
            suffix = current
            newBaseline = current
        } else if current.hasPrefix(previous) {
            suffix = String(current.dropFirst(previous.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            newBaseline = current
        } else {
            // Rare provider correction that diverged from the persisted prefix: re-stabilize.
            let stable = StreamingHandler.stabilizeText(confirmed: previous, new: current)
            guard stable.hasPrefix(previous), stable != previous else { return }
            suffix = String(stable.dropFirst(previous.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            newBaseline = stable
        }

        guard !suffix.isEmpty else {
            persistedText = newBaseline
            return
        }

        let start = lastSegmentEnd
        // `elapsed` is session-relative (0-based); shift onto the meeting timeline so a restarted
        // session's live segments sit after the prior session's (finding 1).
        let end = max(elapsed + sessionTimeOffset, start)
        meetingService.appendStableSegments(
            [TranscriptionSegment(text: suffix, start: start, end: end)],
            source: .liveCapture,
            to: meeting
        )
        persistedText = newBaseline
        lastSegmentEnd = end

        // AD4 emission point 2/5: batched stable-segment flush (never per 350 ms partial).
        eventEmitter.emit(.transcriptSegment(MeetingTranscriptSegmentPayload(
            meetingID: meeting.id,
            segments: [MeetingEventSegment(text: suffix, startSeconds: start, endSeconds: end)]
        )))
    }

    // MARK: - Finalization

    private func finalizeSegments(
        liveSessionResult: TranscriptionResult?,
        buffer: [Float]
    ) async -> [TranscriptionSegment]? {
        // AD8: resolve the final re-transcription policy (per-meeting → rule → global → sameEngine)
        // and apply the availability + cloud-ceiling guards.
        let policy = resolveFinalRetranscriptionPolicy(for: activeMeeting)
        let durationSeconds = Double(buffer.count) / MeetingCaptureService.sampleRate
        let plan = FinalRetranscriptionPolicy.plan(
            for: policy,
            durationSeconds: durationSeconds,
            cloudCeilingSeconds: cloudCeilingSeconds,
            isEngineAvailable: engineAvailabilityCheck,
            isCloudEngine: engineIsCloudCheck
        )
        finalRetranscriptionDegraded = plan.degraded

        switch plan.execution {
        case .keepLiveSegments:
            // `.off`: skip re-transcription entirely; the persisted `.liveCapture` segments stand.
            return nil
        case .sameEngine:
            return await runSameEngineFinalize(liveSessionResult: liveSessionResult, buffer: buffer)
        case .engine(let id, let model):
            return await runOverrideEngineFinalize(buffer: buffer, engineId: id, model: model)
        }
    }

    /// Resolve the effective final re-transcription policy for `meeting` from the AD8 layers.
    private func resolveFinalRetranscriptionPolicy(for meeting: Meeting?) -> FinalRetranscriptionPolicy {
        let global = FinalRetranscriptionPolicy(
            mode: defaults.string(forKey: UserDefaultsKeys.meetingsFinalPassDefaultMode),
            engineId: defaults.string(forKey: UserDefaultsKeys.meetingsFinalPassEngineId),
            model: defaults.string(forKey: UserDefaultsKeys.meetingsFinalPassModel)
        )
        return FinalRetranscriptionPolicy.resolve(
            perMeeting: meeting?.finalRetranscriptionPolicy,
            rule: sessionRulePolicy,
            global: global
        )
    }

    /// `.sameEngine`: today's behavior — prefer a segmented live-session result, else re-transcribe
    /// the full buffer with the Recorder's engine defaults; keep live segments on failure.
    private func runSameEngineFinalize(
        liveSessionResult: TranscriptionResult?,
        buffer: [Float]
    ) async -> [TranscriptionSegment]? {
        if let liveSessionResult, !liveSessionResult.segments.isEmpty {
            return liveSessionResult.segments
        }

        // At least ~0.5 s of audio before re-transcribing (mirrors the Recorder's guard).
        guard buffer.count > 8_000 else { return nil }

        let providerId = defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        let cloudModelOverride = modelManager.resolvedModelId(
            engineOverrideId: providerId,
            cloudModelOverride: defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel)
        )
        do {
            let result = try await modelManager.transcribe(
                audioSamples: buffer,
                languageSelection: .auto,
                task: .transcribe,
                engineOverrideId: providerId,
                cloudModelOverride: cloudModelOverride,
                onProgress: { _ in true }
            )
            return result.segments.isEmpty ? nil : result.segments
        } catch {
            logger.warning("Final meeting transcription failed; keeping live segments: \(error.localizedDescription)")
            return nil
        }
    }

    /// `.engine(id, model)`: run the full-buffer pass on a specific override engine (AD8). On
    /// failure/empty, degrade to the `.sameEngine` path (which itself keeps live segments if that
    /// too fails). Never uses the live-session result — the point is a fresh override pass.
    private func runOverrideEngineFinalize(
        buffer: [Float],
        engineId: String,
        model: String?
    ) async -> [TranscriptionSegment]? {
        guard buffer.count > 8_000 else { return nil }
        do {
            let result = try await modelManager.transcribe(
                audioSamples: buffer,
                languageSelection: .auto,
                task: .transcribe,
                engineOverrideId: engineId,
                cloudModelOverride: model,
                onProgress: { _ in true }
            )
            if !result.segments.isEmpty {
                return result.segments
            }
        } catch {
            logger.warning("Override-engine final transcription failed; degrading to same-engine: \(error.localizedDescription)")
        }
        // Override produced nothing usable — degrade one step (never lose content).
        finalRetranscriptionDegraded = true
        return await runSameEngineFinalize(liveSessionResult: nil, buffer: buffer)
    }

    // MARK: - Elapsed time

    private func currentElapsed() -> TimeInterval {
        guard let captureStartTime else { return latestElapsed }
        return Date().timeIntervalSince(captureStartTime)
    }

    /// Elapsed seconds on the *meeting timeline*: the session-relative `currentElapsed()` shifted by
    /// `sessionTimeOffset`, matching the shift `flushPendingSegments` applies to persisted segment
    /// starts. Q&A `asOfOffset` scoping and note timestamps must use this (not the session-relative
    /// `elapsedSeconds`), so a restarted session's offsets line up with persisted `segment.start`
    /// values instead of dropping/colliding with the prior session's transcript (findings 1 & 5).
    var meetingTimelineElapsed: TimeInterval {
        currentElapsed() + sessionTimeOffset
    }

    private func startElapsedTimer() {
        elapsedTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let start = self.captureStartTime else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    private func resetSessionState() {
        confirmedText = ""
        persistedText = ""
        lastSegmentEnd = 0
        lastFlushElapsed = 0
        latestElapsed = 0
        liveTranscript = ""
        elapsedSeconds = 0
        isDegradedLiveMode = false
        finalRetranscriptionDegraded = false
        activeMeetingDefaultTemplateID = nil
        sessionLiveEngineOverride = nil
        sessionLiveModelOverride = nil
        sessionLanguageOverride = nil
        sessionRulePolicy = nil
    }

    // MARK: - Capture-context rule resolution (addendum AD7)

    /// Match `meeting` against the capture-context rules and stash the winning rule's overrides on
    /// the session. Pure w.r.t. persistence — only sets in-memory session state consumed by
    /// `startStreaming()` and `finalizeSegments()`.
    private func applyContextRule(for meeting: Meeting) {
        guard let ruleMatcher else { return }
        let context = MeetingContext(
            title: meeting.title,
            attendeeEmails: meeting.attendees.compactMap(\.email),
            calendarName: nil,
            seriesID: meeting.seriesID,
            isRecurringSeries: meeting.seriesID != nil
        )
        guard let match = ruleMatcher.match(context) else { return }
        let actions = match.actions
        if let engine = actions.liveEngineId, !engine.isEmpty {
            sessionLiveEngineOverride = engine
        }
        if let model = actions.liveModelId, !model.isEmpty {
            sessionLiveModelOverride = model
        }
        if let language = actions.languageSelection {
            sessionLanguageOverride = LanguageSelection(storedValue: language, nilBehavior: .auto)
        }
        sessionRulePolicy = actions.finalRetranscription
        activeMeetingDefaultTemplateID = actions.defaultOutputTemplateID
    }
}
