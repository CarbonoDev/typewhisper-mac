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
    /// The meeting whose final re-transcription just finalized in a degraded mode, so the UI can
    /// scope the degraded status to the correct completed meeting (and not show it on unrelated
    /// meetings the user browses before the next capture). `nil` when the last finalize was not
    /// degraded. Set at `stop()`; reset by `resetSessionState()` on the next `start()`.
    @Published private(set) var finalRetranscriptionDegradedMeetingID: UUID?
    /// The default output template (opaque UUID) chosen by the matched capture-context rule for the
    /// active meeting (addendum AD7), so the generate flow can pre-select it. `nil` when no rule
    /// matched or the rule set no default. Persists after `stop()` (generation happens post-stop);
    /// reset by `resetSessionState()` on the next `start()`.
    @Published private(set) var activeMeetingDefaultTemplateID: UUID?
    /// The meeting `activeMeetingDefaultTemplateID` was chosen for, so the generate flow applies the
    /// rule-selected template only to that meeting and not to unrelated meetings browsed afterward.
    @Published private(set) var defaultTemplateMeetingID: UUID?
    @Published private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let meetingService: MeetingService
    private let audioRecorderService: AudioRecorderService
    private let modelManager: ModelManagerService
    /// [Track J] The final re-transcription runs as a cancellable `.finalTranscription` job on this
    /// queue (plan J2) instead of being awaited inline in `stop()`, so the transcription lane serializes
    /// it against imports/diarization and it can be cancelled without leaving the meeting `.processing`.
    private let jobQueue: JobQueueService
    private let defaults: UserDefaults
    /// Test seam (plan J2): overrides the full-buffer final re-transcription so the success /
    /// keep-live / cancellation paths can be exercised without a loaded transcription plugin. Nil in
    /// production (uses `modelManager.transcribe`). Mirrors `AudioRecorderService`'s override hooks.
    var finalizeTranscribeOverrideForTesting: (@MainActor (_ samples: [Float], _ languageSelection: LanguageSelection) async throws -> TranscriptionResult)?
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
    /// [M2] Invoked once the final transcript is ready (after the final pass replaces live segments and
    /// the meeting is marked `.completed`). ServiceContainer wires this to enqueue a `.background`
    /// language-detection job so an unset meeting language fills itself in (plan D5). Optional so the
    /// capture service has no hard dependency on the language service (constructed later) and tests are
    /// unaffected when left nil.
    var onTranscriptReady: (@MainActor (Meeting) -> Void)?
    /// [Speaker-recognition amendment, M9-SPK-A] Invoked at the end of finalization to run the
    /// automatic speaker-labeling pass (cloud adoption, else the two-person channel fast path — D-A2/
    /// D-A4). ServiceContainer wires this to the diarization enricher's `autoAssignSpeakers`; the
    /// common 1:1 call is labeled with zero user action. Optional so the capture service has no hard
    /// dependency on the enricher and tests are unaffected when left nil. Runs *after* the meeting is
    /// marked `.completed` (so it labels the final segments, and `isCapturing` is already false so the
    /// live-render suppression never hides the freshly-written labels).
    var onFinalizeSpeakerLabeling: (@MainActor (Meeting) async -> Void)?

    // MARK: - Session bookkeeping

    private var streamingHandler: StreamingHandler?
    private var captureStartTime: Date?
    private var elapsedTimer: AnyCancellable?
    /// The in-flight `stop()` teardown (buffer snapshot → live-session finish → recorder stop → audio
    /// adopt → enqueue final pass). It runs off the MainActor so `stop()` returns instantly and the
    /// window never freezes while a long meeting finalizes. Retained so it is not cancelled mid-way;
    /// nil when no teardown is running.
    private var finalizeTask: Task<Void, Never>?

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
        jobQueue: JobQueueService,
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
        self.jobQueue = jobQueue
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
        systemAudioEnabled: Bool = true,
        calendarName: String? = nil
    ) async throws {
        guard !isCapturing, !isFinalizing else { throw CaptureError.alreadyCapturing }

        // [Track J] The synchronous `isFinalizing` window ends when `stop()`'s teardown completes, but
        // this meeting's final re-transcription may still be queued/running as a `.finalTranscription`
        // job. Restarting the *same* meeting before its final pass finishes would let `resetSessionState`
        // clobber the session offsets that pass relies on and race its `replaceSegments`, so refuse
        // until it settles (plan §CC2). Different meetings are unaffected — the transcription lane just
        // serializes their final passes.
        if jobQueue.hasActiveJob(kind: .finalTranscription, meetingID: meeting.id) {
            throw CaptureError.alreadyCapturing
        }

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
        // The calendar (source list) name — only known at capture start from the originating
        // `CalendarEventDTO` (it is not persisted on `Meeting`) — feeds the calendar-name trigger
        // tier (addendum AD7); nil for ad-hoc captures.
        applyContextRule(for: meeting, calendarName: calendarName)

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

        // Speaker-recognition amendment, Fix B: restarting capture on a non-empty (previously-labeled)
        // meeting stitches a second recording onto the timeline, making the whole meeting a
        // `.timelineMismatch` for labeling — the pre-restart labels can never be honestly completed or
        // extended across the stitched timeline, so clear stale segment labels + the speaker map
        // rather than let them persist as a permanent partial attribution. Idempotent (no-op for a
        // fresh meeting with no labels).
        //
        // Cleared only *after* `startRecording` succeeds (M2 carried finding): a failed restart throws
        // above and returns with the meeting's valid labels intact — clearing them before the throwable
        // start would destroy honest attribution on a session that never actually began.
        if !meeting.segments.isEmpty {
            meetingService.clearSpeakerLabels(for: meeting)
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

    /// Stop capturing. Returns to the caller almost immediately: only the cheap, main-actor state
    /// flip runs inline (mark `.processing`, close the finalize gate, stop the timer, flush the
    /// pending tail). The *heavy* teardown — snapshotting the capture buffer (up to hundreds of MB
    /// for a long meeting), finishing the live session, mixing/finalizing the recording file, and
    /// adopting the audio — runs off the MainActor in `finalizeTask` so the window never freezes; it
    /// then hands the full-buffer re-transcription to the job queue as a cancellable
    /// `.finalTranscription` job (plan J2). See `performTeardownAndEnqueueFinalPass`.
    func stop() async {
        // Re-entrancy guard (finding 3): a double-click on Stop (the VM's `isCapturing` mirror
        // lags by a main-queue hop) must not run the finalize pipeline twice concurrently.
        guard isCapturing, let meeting = activeMeeting else { return }

        isCapturing = false
        // Keep `start()`'s guard closed across the *entire* off-main teardown below: `isCapturing` is
        // already false (so the UI stops showing "recording" and can flip to "finalizing"), but a new
        // session must not begin until teardown finishes (finding 2). `isFinalizing` stays true until
        // `performTeardownAndEnqueueFinalPass` releases the recorder/ownership and has snapshotted the
        // buffer. A double-click on Stop is still handled by the `guard isCapturing` above — this only
        // gates a concurrent *start*.
        isFinalizing = true
        stopElapsedTimer()

        meeting.state = .processing
        meetingService.update(meeting)

        // Persist any stabilized tail that has not yet been flushed. Cheap and main-actor bound (it
        // reads the in-memory confirmed/persisted text), and done inline so a crash during the async
        // teardown still leaves the last live words on disk (segments persist incrementally).
        flushPendingSegments(elapsed: latestElapsed)

        // Snapshot the session state the teardown + final pass depend on *before* returning: once
        // teardown releases the finalize gate a new capture (of another meeting) may `start()` and
        // reset these live-session vars, so both the off-main teardown and the queued finalization
        // read snapshots, never mutable `self` (plan §CC2).
        let sessionTimeOffsetSnapshot = sessionTimeOffset
        let priorLiveCaptureSnapshot = priorLiveCaptureSegmentIDs
        let sessionRulePolicySnapshot = sessionRulePolicy
        let latestElapsedSnapshot = latestElapsed

        // Hand the live-session handle to the teardown and drop our reference now (the local retains
        // it across the hop); a subsequent `start()` installs a fresh handler.
        let handler = streamingHandler
        streamingHandler = nil

        // Return to the caller *now*; run the heavy teardown off the MainActor. `Task` inherits the
        // MainActor, but every expensive step inside suspends onto a background executor (the detached
        // buffer snapshot and the nonisolated `stopRecording` file mixdown), so the main run loop
        // stays free and the window never freezes while a long meeting finalizes.
        finalizeTask = Task { [weak self] in
            await self?.performTeardownAndEnqueueFinalPass(
                for: meeting,
                handler: handler,
                sessionTimeOffset: sessionTimeOffsetSnapshot,
                priorLiveCaptureSegmentIDs: priorLiveCaptureSnapshot,
                sessionRulePolicy: sessionRulePolicySnapshot,
                latestElapsed: latestElapsedSnapshot
            )
        }
    }

    /// The heavy `stop()` teardown, run off the MainActor as `finalizeTask` (freeze fix + plan J2).
    /// Snapshots the capture buffer without blocking the main thread, finishes the live session,
    /// finalizes/mixes the recording file, adopts the audio, releases the recorder, then enqueues the
    /// cancellable `.finalTranscription` job. The `isFinalizing` gate stays closed for the whole span
    /// so no new capture slips in while the recorder/buffer are being torn down (finding 2); it is
    /// released only after the buffer is snapshotted and ownership handed back (plan §CC2).
    private func performTeardownAndEnqueueFinalPass(
        for meeting: Meeting,
        handler: StreamingHandler?,
        sessionTimeOffset: TimeInterval,
        priorLiveCaptureSegmentIDs: Set<UUID>,
        sessionRulePolicy: FinalRetranscriptionPolicy?,
        latestElapsed: TimeInterval
    ) async {
        // Snapshot the full 16 kHz buffer OFF the MainActor: for a 1 h meeting this is ~57 M samples
        // (~230 MB) plus a per-sample mic/system mix — running it inline on the main thread is the
        // dominant Stop freeze. The buffer survives `stopRecording` (only `startRecording` resets it),
        // and the `isFinalizing` gate blocks any capture that could reset it while we read (plan §CC2).
        // `getCurrentBuffer()` is a thread-safe (`OSAllocatedUnfairLock`) nonisolated read, already
        // called off-main by the streaming providers, so this hop introduces no new hazard.
        let recorder = audioRecorderService
        let fullBuffer = await Task.detached(priority: .userInitiated) {
            recorder.getCurrentBuffer()
        }.value

        // Finish the live session (main-isolated bookkeeping; its model/network calls suspend off-main).
        let liveSessionResult = await handler?.finish()

        // Stop the recorder: file finalization/mixdown/encode. `stopRecording` is nonisolated `async`,
        // so its multi-second I/O for a long meeting runs off the MainActor and never blocks the window.
        let audioURL = await audioRecorderService.stopRecording()
        audioRecorderService.releaseCaptureOwnership(.meeting)

        if let audioURL {
            // A same-volume file move (rename) plus a small SwiftData save; main-actor bound but cheap.
            meetingService.adoptAudioFile(audioURL, for: meeting)
        }

        // Teardown done: the recorder and ownership are released, so a *different* meeting may start.
        // A restart of *this* meeting is still refused by `start()`'s `.finalTranscription` guard until
        // the job below settles (plan §CC2).
        isFinalizing = false

        // The final re-transcription runs as a cancellable transcription-lane job (cap 1).
        // `runFinalization` never throws: on transcription success it replaces the live segments; on
        // failure *or* cancellation it keeps the live segments; in every case it marks the meeting
        // `.completed`, so a stopped meeting is never stuck in `.processing` (plan J2).
        //
        // QUEUED-CANCEL INVARIANT (J2 review finding 1): the J3 activity popover exposes Cancel. A
        // *running* final pass is safe to cancel — the awaited transcribe throws, `runFinalization`
        // keeps the live segments and still marks the meeting `.completed`. But a *queued* final pass
        // that were cancelled would be marked `.cancelled` by the generic queue *without ever running
        // `runFinalization`*, permanently stranding this meeting in `.processing`. Resolved at the UI
        // layer (`MeetingJobPresentation.canCancel`), which withholds Cancel for a queued
        // `.finalTranscription` (with a localized hint) so no code path ever cancels it while queued.
        // The transcription lane is cap-1 and this job is `.userInitiated`, so the un-cancellable
        // queued window is short (it only ever waits behind another transcription job). Chosen over
        // the "run the keep-live path on queued-cancel" option because that would violate the queue's
        // generic `testCancelQueuedNeverRunsOperation` contract (a queued cancel must never run the
        // operation) — the UI-guard keeps `JobQueueService` free of any kind-specific cancel semantics.
        jobQueue.enqueue(
            kind: .finalTranscription,
            meetingID: meeting.id,
            progressLabel: String(localized: "meetings.jobs.progress.transcribing")
        ) { [weak self] in
            await self?.runFinalization(
                for: meeting,
                buffer: fullBuffer,
                liveSessionResult: liveSessionResult,
                sessionTimeOffset: sessionTimeOffset,
                priorLiveCaptureSegmentIDs: priorLiveCaptureSegmentIDs,
                sessionRulePolicy: sessionRulePolicy,
                latestElapsed: latestElapsed
            )
        }
    }

    /// Test hook (plan J2 + freeze fix): await the off-MainActor `stop()` teardown through the point
    /// where the `.finalTranscription` job has been enqueued and the finalize gate reopened. Lets
    /// tests keep their `await stop(); await jobQueue.drain()` shape now that teardown is asynchronous.
    func awaitFinalizeTeardownForTesting() async {
        await finalizeTask?.value
    }

    /// The final (post-stop) re-transcription pass, run as the `.finalTranscription` job body (plan
    /// J2). All session state is passed in as snapshots (never read off `self`) so a concurrent new
    /// capture cannot corrupt it. Emits `transcriptReady`/`ended` exactly once and always marks the
    /// meeting `.completed` — whether the transcription succeeds (segments replaced), fails, or is
    /// cancelled (live segments kept) — so the meeting is never left stuck in `.processing`.
    private func runFinalization(
        for meeting: Meeting,
        buffer: [Float],
        liveSessionResult: TranscriptionResult?,
        sessionTimeOffset: TimeInterval,
        priorLiveCaptureSegmentIDs: Set<UUID>,
        sessionRulePolicy: FinalRetranscriptionPolicy?,
        latestElapsed: TimeInterval
    ) async {
        // Final timestamped transcript (plan D3). Prefer a segmented live-session result; else
        // re-transcribe the full buffer; if neither yields segments (or the pass is cancelled/fails),
        // keep the live segments.
        let (finalSegments, degraded) = await finalizeSegments(
            for: meeting,
            liveSessionResult: liveSessionResult,
            buffer: buffer,
            sessionRulePolicy: sessionRulePolicy
        )
        // Scope the degraded status to this meeting so it surfaces only on the meeting that finalized
        // in a reduced mode (AD8), never on unrelated meetings browsed afterward.
        finalRetranscriptionDegraded = degraded
        finalRetranscriptionDegradedMeetingID = degraded ? meeting.id : nil

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
            // A genuine final re-transcription refined the per-segment timings (D-A6): mark it so
            // Identify does not later pay for the M9-SPK-B timing re-pass on already-accurate times.
            meetingService.setTimestampsRefined(true, for: meeting)
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

        // [Speaker-recognition amendment, M9-SPK-A] Automatic speaker labeling with zero user action
        // (D-A2/D-A4): adopt provider labels when present, else label a two-person call by audio
        // channel. Runs now that the meeting is `.completed` and `isCapturing` is false, so the
        // freshly-written labels are not hidden by the live-render suppression. No-op when nil (tests).
        await onFinalizeSpeakerLabeling?(meeting)

        // [M2] Transcript-ready choke point: auto-enqueue background language detection for an unset
        // meeting (plan D5). Idempotent by the job queue's `(languageDetection, meetingID)` dedupe and
        // guarded again inside the detector (`languageCode == nil`); a no-op when the language is set.
        onTranscriptReady?(meeting)

        // AD4 emission point 4/5: capture session ended.
        eventEmitter.emit(.ended(MeetingEndedPayload(
            meetingID: meeting.id,
            endedAt: Date(),
            durationSeconds: durationSeconds,
            stateRaw: meeting.state.rawValue,
            segmentCount: segmentCount
        )))

        // Clear the live UI state only if this meeting is still the active one — a new capture may have
        // begun for a *different* meeting while this pass was queued (plan §CC2).
        if activeMeeting?.id == meeting.id {
            activeMeeting = nil
            liveTranscript = ""
            elapsedSeconds = 0
            isDegradedLiveMode = false
        }
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
            languageSelection: liveLanguageSelection(),
            task: .transcribe,
            cloudModelOverride: cloudModelOverride,
            allowLiveTranscription: true,
            stateCheck: { [weak self] in self?.isCapturing == true }
        )
    }

    /// Resolve the live-capture engine language for the active meeting (plan D2/D3): the meeting's
    /// persisted language wins (manual > rule > detected, all folded into the one column), else the
    /// session rule override (which survives only for non-`.exact` rule values, e.g. `.hints`), else
    /// `.auto`.
    private func liveLanguageSelection() -> LanguageSelection {
        if let meeting = activeMeeting, meeting.languageCode != nil {
            return meetingService.transcriptionLanguageSelection(for: meeting)
        }
        return sessionLanguageOverride ?? .auto
    }

    /// Ingest a stabilized transcript snapshot from the streaming handler: update the preview and,
    /// when the flush interval has elapsed, persist the newly-stable suffix as a segment.
    ///
    /// Internal (not private) so unit tests can script a stabilized-text sequence without a live
    /// engine.
    func ingestLiveTranscript(_ raw: String, elapsed: TimeInterval) {
        latestElapsed = elapsed
        // Bounded stabilization: text already persisted to segments can no longer change, so freeze
        // it and only run the (potentially O(n*m)) stabilization heuristics on the still-active tail.
        // Without this the whole meeting transcript is re-stabilized on the main actor every ~350 ms,
        // pegging a core and freezing the UI as the meeting grows.
        let stabilized = StreamingHandler.stabilizeText(
            confirmed: confirmedText,
            new: raw,
            frozenPrefix: persistedText
        )
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

    /// Resolve the final re-transcription plan and run it, returning the resulting segments (nil ⇒
    /// keep live) and whether the pass ran in a degraded mode. Parameterized by snapshotted session
    /// state (plan §CC2) so it never reads mutable `self` session vars a concurrent capture could
    /// clobber.
    private func finalizeSegments(
        for meeting: Meeting,
        liveSessionResult: TranscriptionResult?,
        buffer: [Float],
        sessionRulePolicy: FinalRetranscriptionPolicy?
    ) async -> (segments: [TranscriptionSegment]?, degraded: Bool) {
        // AD8: resolve the final re-transcription policy (per-meeting → rule → global → sameEngine)
        // and apply the availability + cloud-ceiling guards.
        let policy = resolveFinalRetranscriptionPolicy(for: meeting, sessionRulePolicy: sessionRulePolicy)
        // Both final-pass paths honor the meeting's persisted language (plan D3, table rows 2/3):
        // `.exact(code)` when set, else `.auto`.
        let languageSelection = meetingService.transcriptionLanguageSelection(for: meeting)
        let durationSeconds = Double(buffer.count) / MeetingCaptureService.sampleRate
        let plan = FinalRetranscriptionPolicy.plan(
            for: policy,
            durationSeconds: durationSeconds,
            cloudCeilingSeconds: cloudCeilingSeconds,
            isEngineAvailable: engineAvailabilityCheck,
            isCloudEngine: engineIsCloudCheck
        )

        switch plan.execution {
        case .keepLiveSegments:
            // `.off`: skip re-transcription entirely; the persisted `.liveCapture` segments stand.
            return (nil, plan.degraded)
        case .sameEngine:
            let segments = await runSameEngineFinalize(
                liveSessionResult: liveSessionResult, buffer: buffer, languageSelection: languageSelection
            )
            return (segments, plan.degraded)
        case .engine(let id, let model):
            let outcome = await runOverrideEngineFinalize(
                liveSessionResult: liveSessionResult,
                buffer: buffer,
                engineId: id,
                model: model,
                languageSelection: languageSelection
            )
            return (outcome.segments, plan.degraded || outcome.degraded)
        }
    }

    /// Resolve the effective final re-transcription policy for `meeting` from the AD8 layers.
    private func resolveFinalRetranscriptionPolicy(
        for meeting: Meeting?,
        sessionRulePolicy: FinalRetranscriptionPolicy?
    ) -> FinalRetranscriptionPolicy {
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
        buffer: [Float],
        languageSelection: LanguageSelection
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
            // The test seam (when set) stands in for the real engine so the success / keep-live /
            // cancellation paths are exercisable without a loaded transcription plugin (plan J2).
            let result: TranscriptionResult
            if let finalizeTranscribeOverrideForTesting {
                result = try await finalizeTranscribeOverrideForTesting(buffer, languageSelection)
            } else {
                result = try await modelManager.transcribe(
                    audioSamples: buffer,
                    languageSelection: languageSelection,
                    task: .transcribe,
                    engineOverrideId: providerId,
                    cloudModelOverride: cloudModelOverride,
                    onProgress: { _ in true }
                )
            }
            return result.segments.isEmpty ? nil : result.segments
        } catch {
            // A thrown `CancellationError` (job cancelled) is handled identically to a transcription
            // failure: keep the live segments (plan J2 finalTranscription cancel semantics).
            logger.warning("Final meeting transcription failed/cancelled; keeping live segments: \(error.localizedDescription)")
            return nil
        }
    }

    /// `.engine(id, model)`: run the full-buffer pass on a specific override engine (AD8). On
    /// failure/empty, degrade to the `.sameEngine` path — forwarding the already-computed
    /// `liveSessionResult` so the degrade prefers the segmented live-session segments (which
    /// `.sameEngine` would normally use) instead of forcing a redundant full-buffer re-transcription
    /// (finding: avoid a second full pass on degrade). The override pass itself never uses the
    /// live-session result — the point is a fresh override transcription.
    private func runOverrideEngineFinalize(
        liveSessionResult: TranscriptionResult?,
        buffer: [Float],
        engineId: String,
        model: String?,
        languageSelection: LanguageSelection
    ) async -> (segments: [TranscriptionSegment]?, degraded: Bool) {
        guard buffer.count > 8_000 else { return (nil, false) }
        do {
            let result = try await modelManager.transcribe(
                audioSamples: buffer,
                languageSelection: languageSelection,
                task: .transcribe,
                engineOverrideId: engineId,
                cloudModelOverride: model,
                onProgress: { _ in true }
            )
            if !result.segments.isEmpty {
                return (result.segments, false)
            }
        } catch {
            logger.warning("Override-engine final transcription failed; degrading to same-engine: \(error.localizedDescription)")
        }
        // Override produced nothing usable — degrade one step (never lose content). Prefer the
        // already-computed live-session segments before paying for a second full-buffer pass.
        let segments = await runSameEngineFinalize(
            liveSessionResult: liveSessionResult, buffer: buffer, languageSelection: languageSelection
        )
        return (segments, true)
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
        finalRetranscriptionDegradedMeetingID = nil
        activeMeetingDefaultTemplateID = nil
        defaultTemplateMeetingID = nil
        sessionLiveEngineOverride = nil
        sessionLiveModelOverride = nil
        sessionLanguageOverride = nil
        sessionRulePolicy = nil
    }

    // MARK: - Capture-context rule resolution (addendum AD7)

    /// Match `meeting` against the capture-context rules and stash the winning rule's overrides on
    /// the session. Pure w.r.t. persistence — only sets in-memory session state consumed by
    /// `startStreaming()` and `finalizeSegments()`.
    private func applyContextRule(for meeting: Meeting, calendarName: String?) {
        guard let ruleMatcher else { return }
        let context = MeetingContext(
            title: meeting.title,
            attendeeEmails: meeting.attendees.compactMap(\.email),
            calendarName: calendarName,
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
            let resolved = LanguageSelection(storedValue: language, nilBehavior: .auto)
            sessionLanguageOverride = resolved
            // Plan D2: a rule whose language resolves to a single exact code *seeds* the meeting
            // language (`.rule`, ladder-checked so it never clobbers a manual pick). Non-`.exact`
            // rule values (`.hints`, auto) persist nothing — they stay session-only overrides.
            if case .exact(let code) = resolved {
                meetingService.seedRuleLanguage(code, for: meeting)
            }
        }
        sessionRulePolicy = actions.finalRetranscription
        activeMeetingDefaultTemplateID = actions.defaultOutputTemplateID
        defaultTemplateMeetingID = actions.defaultOutputTemplateID != nil ? meeting.id : nil
    }
}
