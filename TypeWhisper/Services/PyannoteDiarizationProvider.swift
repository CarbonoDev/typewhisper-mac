import Foundation
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "Diarization"
)

/// Diarization provider that shells out to a bundled Python sidecar
/// (`diarize_sidecar.py`) which runs pyannote.audio.
///
/// The sidecar reads a WAV file path and prints newline-free JSON on stdout:
/// `[{"start": 0.0, "end": 1.2, "speaker": "SPEAKER_00"}, ...]`
struct PyannoteDiarizationProvider: DiarizationProvider, Sendable {
    private let pythonPathKey = "diarization.pythonPath"
    private let hfTokenKeychainService = "diarization.huggingFaceToken"
    private let sidecarName = "diarize_sidecar.py"

    private var pythonPath: String {
        UserDefaults.standard.string(forKey: pythonPathKey) ?? "python3"
    }

    /// Locates `diarize_sidecar.py`, preferring the app bundle's resources and
    /// falling back to a sibling of the running executable (useful for CLI /
    /// debug builds where the script sits next to the binary).
    private var sidecarPath: String? {
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(sidecarName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }

        if let executableURL = Bundle.main.executableURL {
            let sibling = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(sidecarName)
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling.path
            }
        }

        return nil
    }

    /// The Hugging Face access token pyannote needs to download gated models.
    /// Prefer the Keychain, fall back to UserDefaults for convenience.
    private var hfToken: String? {
        if let token = KeychainService.load(service: hfTokenKeychainService), !token.isEmpty {
            return token
        }
        let token = UserDefaults.standard.string(forKey: "diarization.hfToken")
        return (token?.isEmpty == false) ? token : nil
    }

    var isAvailable: Bool {
        get async {
            guard sidecarPath != nil else { return false }
            return await pythonIsReachable()
        }
    }

    func diarize(wavData: Data, numSpeakers: Int?) async throws -> [SpeakerSegment] {
        guard let sidecarPath else {
            throw DiarizationError.sidecarNotFound(path: sidecarName)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try wavData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var arguments = [sidecarPath, tempURL.path]
        if let numSpeakers, numSpeakers > 0 {
            arguments.append(contentsOf: ["--speakers", "\(numSpeakers)"])
        }

        let (status, stdout, stderr) = try run(arguments: arguments)

        guard status == 0 else {
            let message = stderr.isEmpty ? "sidecar exited with status \(status)" : stderr
            logger.error("Diarization sidecar failed: \(message, privacy: .public)")
            throw DiarizationError.pythonError(message)
        }

        return try parse(stdout)
    }

    // MARK: - Process execution

    private func pythonIsReachable() async -> Bool {
        do {
            let (status, stdout, _) = try run(
                executable: "/usr/bin/which",
                arguments: [pythonPath],
                includeToken: false
            )
            return status == 0 && !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// Runs the configured Python interpreter with `arguments`.
    private func run(arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        try run(executable: pythonPath, arguments: arguments, includeToken: true)
    }

    private func run(
        executable: String,
        arguments: [String],
        includeToken: Bool
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        // Resolve bare executable names (e.g. "python3") via the login shell PATH.
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }

        if includeToken, let hfToken {
            var environment = ProcessInfo.processInfo.environment
            environment["HF_TOKEN"] = hfToken
            environment["HUGGING_FACE_HUB_TOKEN"] = hfToken
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }

    // MARK: - Parsing

    private struct RawSegment: Decodable {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
    }

    private func parse(_ stdout: String) throws -> [SpeakerSegment] {
        guard let data = stdout.data(using: .utf8), !data.isEmpty else {
            throw DiarizationError.invalidOutput
        }

        do {
            let raw = try JSONDecoder().decode([RawSegment].self, from: data)
            return raw.map { SpeakerSegment(start: $0.start, end: $0.end, speaker: $0.speaker) }
        } catch {
            logger.error("Failed to parse diarization output: \(error.localizedDescription, privacy: .public)")
            throw DiarizationError.invalidOutput
        }
    }
}
