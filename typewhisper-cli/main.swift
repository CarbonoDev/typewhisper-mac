import Foundation

let args = CommandLine.arguments.dropFirst()

var portOverride: UInt16?
var apiTokenOverride = ProcessInfo.processInfo.environment["TYPEWHISPER_API_TOKEN"]
var jsonOutput = false
var devMode = false
var command: String?
var positionalArgs = [String]()

// Transcribe options
var languageOptions = CLITranscribeLanguageOptions()
var task: String?
var translateTo: String?
var engineOverride: String?
var modelOverride: String?
var awaitDownload = false
var applyCorrections = true

// Meeting options
var meetingTitle: String?
var meetingDate: String?
var meetingFolder: String?
var meetingTags = [String]()
var listTag: String?
var listFrom: String?
var listTo: String?
var matchCalendar = false

var argIterator = args.makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--help", "-h":
        printUsage()
        exit(0)
    case "--version":
        printVersion()
        exit(0)
    case "--port":
        guard let next = argIterator.next(), let p = UInt16(next) else {
            printError("Error: --port requires a number.")
            exit(1)
        }
        portOverride = p
    case "--api-token":
        guard let next = argIterator.next(), !next.isEmpty else {
            printError("Error: --api-token requires a value.")
            exit(1)
        }
        apiTokenOverride = next
    case "--json":
        jsonOutput = true
    case "--dev":
        devMode = true
    case "--language":
        guard let next = argIterator.next() else {
            printError("Error: --language requires a value.")
            exit(1)
        }
        languageOptions.language = next
    case "--language-hint":
        guard let next = argIterator.next() else {
            printError("Error: --language-hint requires a value.")
            exit(1)
        }
        languageOptions.languageHints.append(next)
    case "--task":
        guard let next = argIterator.next() else {
            printError("Error: --task requires a value.")
            exit(1)
        }
        task = next
    case "--translate-to":
        guard let next = argIterator.next() else {
            printError("Error: --translate-to requires a value.")
            exit(1)
        }
        translateTo = next
    case "--engine":
        guard let next = argIterator.next() else {
            printError("Error: --engine requires a value.")
            exit(1)
        }
        engineOverride = next
    case "--model":
        guard let next = argIterator.next() else {
            printError("Error: --model requires a value.")
            exit(1)
        }
        modelOverride = next
    case "--await-download":
        awaitDownload = true
    case "--no-corrections":
        applyCorrections = false
    case "--title":
        guard let next = argIterator.next() else {
            printError("Error: --title requires a value.")
            exit(1)
        }
        meetingTitle = next
    case "--date":
        guard let next = argIterator.next() else {
            printError("Error: --date requires a value.")
            exit(1)
        }
        meetingDate = next
    case "--folder":
        guard let next = argIterator.next() else {
            printError("Error: --folder requires a value.")
            exit(1)
        }
        meetingFolder = next
    case "--tags":
        guard let next = argIterator.next() else {
            printError("Error: --tags requires a value.")
            exit(1)
        }
        meetingTags = next
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    case "--tag":
        guard let next = argIterator.next() else {
            printError("Error: --tag requires a value.")
            exit(1)
        }
        listTag = next
    case "--from":
        guard let next = argIterator.next() else {
            printError("Error: --from requires a value.")
            exit(1)
        }
        listFrom = next
    case "--to":
        guard let next = argIterator.next() else {
            printError("Error: --to requires a value.")
            exit(1)
        }
        listTo = next
    case "--match-calendar":
        matchCalendar = true
    default:
        // Ignore Apple/Xcode internal flags (e.g. -NSDocumentRevisionsDebugMode)
        if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
            _ = argIterator.next() // skip value if present
            continue
        }
        if arg.hasPrefix("-") && command != nil {
            printError("Error: Unknown option '\(arg)'.")
            exit(1)
        }
        if command == nil {
            command = arg
        } else {
            positionalArgs.append(arg)
        }
    }
}

if let validationError = languageOptions.validationError() {
    printError(validationError)
    exit(1)
}

guard let command else {
    printUsage()
    exit(1)
}

let discovery = PortDiscovery.discover(dev: devMode)
let port = portOverride ?? discovery.port
let apiToken = apiTokenOverride?.isEmpty == false ? apiTokenOverride : discovery.token
let client = CLIClient(port: port, apiToken: apiToken)

do {
    switch command {
    case "status":
        let data = try await client.status()
        print(OutputFormatter.formatStatus(data, json: jsonOutput))

    case "models":
        let data = try await client.models()
        print(OutputFormatter.formatModels(data, json: jsonOutput))

    case "transcribe":
        let fileURL: URL?
        if let path = positionalArgs.first, path != "-" {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = nil // stdin
        }
        let data = try await client.transcribe(
            fileURL: fileURL,
            language: languageOptions.language,
            languageHints: languageOptions.languageHints,
            task: task,
            targetLanguage: translateTo,
            engine: engineOverride,
            model: modelOverride,
            awaitDownload: awaitDownload,
            applyCorrections: applyCorrections
        )
        print(OutputFormatter.formatTranscription(data, json: jsonOutput))

    case "meetings":
        guard let subcommand = positionalArgs.first else {
            printError("Error: 'meetings' requires a subcommand (import-transcript, list).")
            exit(1)
        }
        switch subcommand {
        case "import-transcript":
            guard positionalArgs.count >= 2 else {
                printError("Error: 'meetings import-transcript' requires a transcript file path.")
                exit(1)
            }
            let fileURL = URL(fileURLWithPath: positionalArgs[1])
            let data = try await client.importMeetingTranscript(
                fileURL: fileURL,
                title: meetingTitle,
                date: meetingDate,
                folder: meetingFolder,
                tags: meetingTags,
                language: languageOptions.language,
                matchCalendar: matchCalendar
            )
            print(OutputFormatter.formatMeetingImport(data, json: jsonOutput))

        case "list":
            let data = try await client.listMeetings(
                folder: meetingFolder,
                tag: listTag,
                from: listFrom,
                to: listTo
            )
            print(OutputFormatter.formatMeetingsList(data, json: jsonOutput))

        default:
            printError("Error: Unknown meetings subcommand '\(subcommand)'.")
            printUsage()
            exit(1)
        }

    default:
        printError("Error: Unknown command '\(command)'.")
        printUsage()
        exit(1)
    }
} catch let error as CLIError {
    printError(error.message)
    exit(error.exitCode)
} catch {
    printError("Error: \(error.localizedDescription)")
    exit(1)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage() {
    let usage = """
        Usage: typewhisper <command> [options]

        Commands:
          transcribe <file>    Transcribe an audio file (or - for stdin)
          status               Show server status
          models               List available models
          meetings import-transcript <file>  Import a transcript file as a meeting
          meetings list        List meetings

        Global options:
          --port <N>           Server port (default: auto-detect)
          --api-token <TOKEN>   API bearer token (default: auto-detect)
          --dev                Connect to TypeWhisper Dev instance
          --json               Output as JSON
          --help, -h           Show help
          --version            Show version

        Transcribe options:
          --language <code>    Source language (e.g. en, de)
          --language-hint <code>  Repeatable ordered language hint; non-hint engines use the first
          --task <task>        transcribe (default) or translate
          --translate-to <code>  Target language for translation
          --engine <id>        Override the engine for this request (e.g. groq, qwen3)
          --model <id>         Override the model for this request (e.g. whisper-large-v3-turbo)
          --await-download     Wait for an engine to restore/download its model instead of failing with 409
          --no-corrections     Return raw transcription text without Dictionary Corrections

        Meeting import options (meetings import-transcript):
          --title <text>       Meeting title (defaults to the file name)
          --date <iso8601>     Meeting date (e.g. 2026-01-05 or 2026-01-05T10:00:00Z)
          --folder <path>      Assign to a /-separated folder
          --tags <a,b,c>       Comma-separated tags
          --language <code>    Meeting language (e.g. en, de)
          --match-calendar     Auto-link a matching historical calendar event (needs --date)

        Meeting list options (meetings list):
          --folder <path>      Filter by folder (and its subfolders)
          --tag <tag>          Filter by tag
          --from <iso8601>     Only meetings on/after this date
          --to <iso8601>       Only meetings on/before this date

        Examples:
          typewhisper status
          typewhisper transcribe recording.wav
          typewhisper transcribe recording.wav --language de --json
          typewhisper transcribe recording.wav --language-hint de --language-hint en
          typewhisper transcribe recording.wav --model whisper-large-v3-turbo
          typewhisper transcribe recording.wav --engine groq
          typewhisper transcribe recording.wav --engine groq --model whisper-large-v3-turbo
          typewhisper transcribe - < audio.wav
          cat audio.wav | typewhisper transcribe -
          typewhisper meetings import-transcript notes.txt --date 2026-01-05 --match-calendar
          typewhisper meetings import-transcript call.txt --folder Clients/Acme --tags sales,q1
          typewhisper meetings list --folder Clients/Acme --json
        """
    print(usage)
}

func printVersion() {
    print("typewhisper 0.9.2")
}
