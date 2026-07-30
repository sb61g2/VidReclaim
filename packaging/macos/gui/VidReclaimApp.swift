import AppKit
import SwiftUI

private enum AppColors {
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)
}

enum SidebarSection {
    case workspace
    case activity
}

enum WorkspaceOperation: String, CaseIterable, Identifiable {
    case reclaim = "Reclaim Space"
    case combine = "Combine Clips"

    var id: String { rawValue }
}

enum AppDestination: String, CaseIterable, Identifiable {
    case reclaim = "Reclaim"
    case combine = "Combine"
    case activity = "Activity"

    var id: String { rawValue }
}

struct OptionEstimate: Codable, Identifiable {
    let id: String
    let profile: String
    let encoder: String
    let preset: String
    let encoderLabel: String
    let resolution: String
    let projectedBytes: Int64
    let savingsPct: Double
    let encodeSeconds: Double
    let selected: Bool

    enum CodingKeys: String, CodingKey {
        case id, profile, encoder, preset, resolution, selected
        case encoderLabel = "encoder_label"
        case projectedBytes = "projected_bytes"
        case savingsPct = "savings_pct"
        case encodeSeconds = "encode_seconds"
    }
}

struct CombineEstimate: Codable {
    let clipCount: Int
    let sourceBytes: Int64
    let projectedOutputBytes: Int64
    let totalDurationSeconds: Double
    let projectedEncodeSeconds: Double
    let width: Int
    let height: Int
    let fps: Double

    enum CodingKeys: String, CodingKey {
        case width, height, fps
        case clipCount = "clip_count"
        case sourceBytes = "source_bytes"
        case projectedOutputBytes = "projected_output_bytes"
        case totalDurationSeconds = "total_duration_seconds"
        case projectedEncodeSeconds = "projected_encode_seconds"
    }
}

struct CombineResult: Codable {
    let outputBytes: Int64
    let outputCount: Int

    enum CodingKeys: String, CodingKey {
        case outputBytes = "output_bytes"
        case outputCount = "output_count"
    }
}

struct ReviewPair: Codable, Identifiable {
    let before: String
    let after: String
    let time: String

    var id: String { "\(before)|\(after)" }
}

struct QueueItem: Codable, Identifiable {
    let id: String
    let order: Int
    let name: String
    let path: String
    let status: String
    let progress: Double
    let transferProgress: Double?
    let speedX: Double?
    let etaSeconds: Double?
    let duration: Double?
    let sourceBytes: Int64?
    let projectedBytes: Int64?
    let projectedSavingsPct: Double?
    let projectedEncodeSeconds: Double?
    let outputBytes: Int64?
    let actualSavingsPct: Double?
    let encodeElapsedSeconds: Double?
    let relativePath: String?
    let relativeFolder: String?
    let selected: Bool?
    let processed: Bool?
    let output: String?
    let message: String
    let whatIf: [OptionEstimate]?
    let reviewPairs: [ReviewPair]?

    enum CodingKeys: String, CodingKey {
        case id, order, name, path, status, progress, duration, output, message
        case transferProgress = "transfer_progress"
        case speedX = "speed_x"
        case etaSeconds = "eta_seconds"
        case sourceBytes = "source_bytes"
        case projectedBytes = "projected_bytes"
        case projectedSavingsPct = "projected_savings_pct"
        case projectedEncodeSeconds = "projected_encode_seconds"
        case outputBytes = "output_bytes"
        case actualSavingsPct = "actual_savings_pct"
        case encodeElapsedSeconds = "encode_elapsed_seconds"
        case relativePath = "relative_path"
        case relativeFolder = "relative_folder"
        case selected, processed
        case whatIf = "what_if"
        case reviewPairs = "review_pairs"
    }

    var isActive: Bool {
        ["encoding", "verifying", "paused"].contains(status)
    }

    var isTerminal: Bool {
        ["complete", "processed", "skipped", "cancelled", "error"].contains(status)
    }

    var isProcessed: Bool {
        processed ?? ["complete", "processed"].contains(status)
    }

    var isIncluded: Bool {
        selected ?? !["processed", "skipped"].contains(status)
    }

    var canChangeInclusion: Bool {
        ["ready", "paused", "cancelled", "error"].contains(status)
    }

    var projectedSavingsBytes: Int64 {
        max(0, (sourceBytes ?? 0) - (projectedBytes ?? sourceBytes ?? 0))
    }

    var actualSavingsBytes: Int64 {
        max(0, (sourceBytes ?? 0) - (outputBytes ?? sourceBytes ?? 0))
    }
}

struct SpaceFinding: Codable, Identifiable {
    let name: String
    let path: String
    let kind: String
    let size: Int64
    let files: Int
    let errors: Int
    let children: [SpaceFinding]

    var id: String { "\(kind):\(path)" }

    var isQueueSelectable: Bool {
        kind == "directory" || kind == "video"
    }

    var videoPaths: [String] {
        if kind == "video" { return [path] }
        return children.flatMap(\.videoPaths)
    }
}

struct SpaceScanResult: Codable {
    let schema: Int
    let allocated: Bool
    let root: SpaceFinding
}

struct SpaceFindingRow: Identifiable {
    let finding: SpaceFinding
    let depth: Int

    var id: String { finding.id }
}

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case browse = "Folders"
    case largestVideos = "Largest Videos"

    var id: String { rawValue }
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case files = "File Count"
    case kind = "Type"

    var id: String { rawValue }
}

enum QueueSortOption: String, CaseIterable, Identifiable {
    case queue = "Queue order"
    case savingsBytes = "Greatest space savings"
    case savingsPercent = "Greatest percentage savings"
    case sourceSize = "Largest source"
    case encodeTime = "Longest encode"
    case name = "Name"
    case status = "Status"

    var id: String { rawValue }
}

enum QueueStatusFilter: String, CaseIterable, Identifiable {
    case all = "All statuses"
    case included = "Included"
    case active = "Active"
    case attention = "Needs attention"
    case excluded = "Excluded"
    case processed = "Processed"

    var id: String { rawValue }
}

struct QueueSession: Codable {
    let id: String
    let name: String
    let root: String
    let sessionPath: String
    let status: String
    let phase: String
    let items: [QueueItem]
    let overallFraction: Double
    let scanFraction: Double?
    let encodeFraction: Double?
    let etaSeconds: Double?
    let summary: String

    enum CodingKeys: String, CodingKey {
        case id, name, root, status, phase, items, summary
        case sessionPath = "session_path"
        case overallFraction = "overall_fraction"
        case scanFraction = "scan_fraction"
        case encodeFraction = "encode_fraction"
        case etaSeconds = "eta_seconds"
    }

    var displayPhase: String {
        guard phase == "Plan ready"
                || phase == "Plan ready; start when convenient" else {
            return phase
        }
        let hasRunnableItem = items.contains {
            $0.isIncluded
                && ["ready", "paused", "cancelled", "error"].contains($0.status)
                && $0.output != nil
        }
        return hasRunnableItem ? "Ready" : "Nothing selected"
    }
}

enum SourcePolicy: String, CaseIterable, Identifiable {
    case keep = "Keep sources"
    case archive = "Archive originals"
    case delete = "Delete after verification"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .keep:
            return "Save to VidReclaim Output. Keep sources."
        case .archive:
            return "Replace verified files. Archive originals."
        case .delete:
            return "Replace verified files. Delete originals."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarSection = .workspace
    @Published var workspaceOperation: WorkspaceOperation = .reclaim
    @Published var isRunning = false
    @Published var phase = "Ready"
    @Published var jobName = ""
    @Published var jobProgress = 0.0
    @Published var overallProgress = 0.0
    @Published var eta = "—"
    @Published var speed = ""
    @Published var log = ""
    @Published var lastSummary = "No plan has been run yet."
    @Published var lastExitSuccessful: Bool?

    @Published var compressionSource: URL?
    @Published var compressionProfile = "balanced"
    @Published var compressionEncoder = "x265"
    @Published var compressionPreset = "medium"
    @Published var remoteEnabled = false
    @Published var remoteHost = ""
    @Published var remoteUser = ""
    @Published var remotePort = 22
    @Published var remoteEncoder = "x265"
    @Published var minimumSavings = 20.0
    @Published var minimumReclaimMB = 100.0
    @Published var sampleCount = 3
    @Published var sampleSeconds = 10.0
    @Published var nice = 10
    @Published var preserveDVDExtras = false
    @Published var reviewMode = "frames"
    @Published var thoroughAnalysis = false
    @Published var deepVerify = false
    @Published var sourcePolicy: SourcePolicy = .keep
    @Published var queueSession: QueueSession?
    @Published var currentSessionURL: URL?
    @Published var workspaceSessionURL: URL?
    @Published var selectedQueueItemIDs = Set<String>()

    @Published var stitchInputs: [URL] = []
    @Published var stitchOutput: URL?
    @Published var stitchCanvas = "first"
    @Published var stitchProfile = "balanced"
    @Published var stitchEncoder = "videotoolbox"
    @Published var stitchPreset = "medium"
    @Published var stitchMixedDynamicRange = "split"
    @Published var combineEstimate: CombineEstimate?
    @Published var combineResult: CombineResult?
    @Published var combinePreflightProgress: Double?
    @Published var combineAttempted = false
    @Published var combinePartialURL: URL?
    @Published private(set) var runningCombine = false

    @Published var spacePaths: [URL] = []
    @Published var useLogicalSizes = false
    @Published var crossFilesystems = false
    @Published var spaceScan: SpaceScanResult?
    @Published var selectedSpaceFindingIDs = Set<String>()
    @Published var selectedReviewSpaceFindingIDs = Set<String>()

    private var process: Process?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    private var jobTitle = ""
    @Published private(set) var runningQueue = false
    private var pendingSpaceJSONURL: URL?
    private let logURL: URL
    private let sessionsURL: URL
    private var queueTimer: Timer?

    init() {
        let base = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        logURL = base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VidReclaim.log")
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? base.appendingPathComponent("Application Support", isDirectory: true)
        sessionsURL = support
            .appendingPathComponent("VidReclaim", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        remoteEnabled = UserDefaults.standard.bool(
            forKey: "VidReclaimRemoteEnabled"
        )
        remoteHost = UserDefaults.standard.string(
            forKey: "VidReclaimRemoteHost"
        ) ?? ""
        remoteUser = UserDefaults.standard.string(
            forKey: "VidReclaimRemoteUser"
        ) ?? ""
        let savedRemotePort = UserDefaults.standard.integer(
            forKey: "VidReclaimRemotePort"
        )
        remotePort = savedRemotePort == 0 ? 22 : savedRemotePort
        remoteEncoder = UserDefaults.standard.string(
            forKey: "VidReclaimRemoteEncoder"
        ) ?? "x265"
        if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
            log = String(existing.suffix(120_000))
        }
        loadLatestQueueSession()
        queueTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.loadQueueSession() }
        }
    }

    var cliPath: String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["VIDRECLAIM_CLI"],
            "/usr/local/libexec/vidreclaim/vidreclaim",
            "/usr/local/bin/vidreclaim",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var destination: AppDestination {
        get {
            if selection == .activity { return .activity }
            return workspaceOperation == .combine ? .combine : .reclaim
        }
        set {
            switch newValue {
            case .reclaim:
                selection = .workspace
                workspaceOperation = .reclaim
            case .combine:
                selection = .workspace
                workspaceOperation = .combine
            case .activity:
                selection = .activity
            }
        }
    }

    func chooseCompressionSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video, folder, disc rip, or volume"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            compressionSource = panel.url
        }
    }

    func addStitchInputs() {
        let panel = NSOpenPanel()
        panel.title = "Add clips or folders"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            resetCombineEstimate()
            for url in panel.urls where !stitchInputs.contains(url) {
                stitchInputs.append(url)
            }
            if stitchOutput == nil {
                stitchOutput = availableSuggestedStitchOutput()
            }
        }
    }

    func chooseStitchOutput() {
        let panel = NSSavePanel()
        panel.title = "Save stitched video"
        panel.prompt = "Choose"
        panel.nameFieldStringValue = (
            stitchOutput?.lastPathComponent ?? suggestedStitchFilename
        )
        if stitchOutput == nil, let first = stitchInputs.first {
            panel.directoryURL = first.hasDirectoryPath
                ? first.deletingLastPathComponent()
                : first.deletingLastPathComponent()
        }
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.isEmpty {
                url.appendPathExtension("mkv")
            }
            stitchOutput = url
        }
    }

    var suggestedStitchFilename: String {
        guard let first = stitchInputs.first else {
            return "combined-video.mkv"
        }
        if stitchInputs.count == 1, first.hasDirectoryPath {
            return "\(first.lastPathComponent)-combined.mkv"
        }
        let stems = stitchInputs
            .filter { !$0.hasDirectoryPath }
            .map { $0.deletingPathExtension().lastPathComponent }
        if let firstStem = stems.first {
            var prefix = firstStem
            for stem in stems.dropFirst() {
                while !stem.localizedCaseInsensitiveContains(prefix),
                      !prefix.isEmpty {
                    prefix.removeLast()
                }
            }
            prefix = prefix.trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted
            )
            prefix = prefix.replacingOccurrences(
                of: #"[\s._-]*\d+$"#,
                with: "",
                options: .regularExpression
            )
            if prefix.count >= 3 {
                return "\(prefix)-combined.mkv"
            }
        }
        let parents = Set(stitchInputs.map {
            ($0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent()).path
        })
        if parents.count == 1, let parent = parents.first {
            let name = URL(fileURLWithPath: parent).lastPathComponent
            if !name.isEmpty {
                return "\(name)-combined.mkv"
            }
        }
        return "combined-video.mkv"
    }

    var canStitchSelection: Bool {
        stitchInputs.count >= 2
            || stitchInputs.contains(where: \.hasDirectoryPath)
    }

    func resetCombineEstimate() {
        guard !runningCombine else { return }
        combineEstimate = nil
        combineResult = nil
        combinePreflightProgress = nil
        combineAttempted = false
        combinePartialURL = nil
    }

    private func combinePartialURL(for output: URL) -> URL {
        let extensionPart = output.pathExtension.isEmpty
            ? "" : ".\(output.pathExtension)"
        return output.deletingLastPathComponent().appendingPathComponent(
            ".\(output.deletingPathExtension().lastPathComponent).part\(extensionPart)"
        )
    }

    private func availableSuggestedStitchOutput() -> URL? {
        guard let first = stitchInputs.first else { return nil }
        let directory = first.deletingLastPathComponent()
        let suggestion = URL(
            fileURLWithPath: suggestedStitchFilename,
            relativeTo: directory
        ).standardizedFileURL
        if !FileManager.default.fileExists(atPath: suggestion.path) {
            return suggestion
        }
        let stem = suggestion.deletingPathExtension().lastPathComponent
        let ext = suggestion.pathExtension
        for suffix in 2...999 {
            let name = "\(stem)-\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func addSpacePaths() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders, disks, or volumes to map"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            var changed = false
            for url in panel.urls where !spacePaths.contains(url) {
                spacePaths.append(url)
                changed = true
            }
            if changed {
                spaceScan = nil
                selectedSpaceFindingIDs.removeAll()
                selectedReviewSpaceFindingIDs.removeAll()
            }
        }
    }

    func runPlan() {
        guard let root = compressionSource else { return }
        try? FileManager.default.createDirectory(
            at: sessionsURL, withIntermediateDirectories: true
        )
        let session = sessionsURL.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        )
        currentSessionURL = session
        workspaceSessionURL = session
        UserDefaults.standard.set(session.path, forKey: "VidReclaimCurrentSession")
        var arguments = [
            "queue-start", root.path, "--session", session.path, "--plan-only",
        ] + analysisArguments()
        if deepVerify { arguments.append("--deep-verify") }
        switch sourcePolicy {
        case .keep:
            break
        case .archive:
            arguments.append("--replace")
        case .delete:
            arguments += ["--delete-source-as-you-go", "--yes"]
        }
        run(
            arguments: arguments,
            title: "Planning \(root.lastPathComponent)",
            section: .workspace
        )
    }

    func runCompression() {
        guard let root = compressionSource else { return }
        try? FileManager.default.createDirectory(
            at: sessionsURL, withIntermediateDirectories: true
        )
        let session = sessionsURL.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        )
        currentSessionURL = session
        workspaceSessionURL = session
        UserDefaults.standard.set(session.path, forKey: "VidReclaimCurrentSession")
        var arguments = [
            "queue-start", root.path, "--session", session.path,
        ] + analysisArguments()
        if deepVerify { arguments.append("--deep-verify") }
        switch sourcePolicy {
        case .keep:
            break
        case .archive:
            arguments.append("--replace")
        case .delete:
            arguments += ["--delete-source-as-you-go", "--yes"]
        }
        run(
            arguments: arguments,
            title: "Queueing \(root.lastPathComponent)",
            section: .workspace
        )
    }

    private func analysisArguments() -> [String] {
        let planningEncoder = (
            remoteEnabled && remoteEncoder == "nvenc"
        ) ? "videotoolbox" : compressionEncoder
        var arguments = [
            "--profile", compressionProfile,
            "--encoder", planningEncoder,
            "--preset", compressionPreset,
            "--min-savings", String(format: "%.1f", minimumSavings),
            "--min-reclaim-mb", String(format: "%.0f", minimumReclaimMB),
            "--samples", String(sampleCount),
            "--sample-seconds", String(format: "%.1f", sampleSeconds),
            "--review-mode", reviewMode,
            "--nice", String(nice),
        ]
        if preserveDVDExtras { arguments.append("--keep-dvd-extras") }
        if thoroughAnalysis {
            arguments.append("--thorough-analysis")
        }
        if remoteEnabled {
            UserDefaults.standard.set(
                true, forKey: "VidReclaimRemoteEnabled"
            )
            UserDefaults.standard.set(
                remoteHost, forKey: "VidReclaimRemoteHost"
            )
            UserDefaults.standard.set(
                remoteUser, forKey: "VidReclaimRemoteUser"
            )
            UserDefaults.standard.set(
                remotePort, forKey: "VidReclaimRemotePort"
            )
            UserDefaults.standard.set(
                remoteEncoder, forKey: "VidReclaimRemoteEncoder"
            )
            arguments += [
                "--remote-host", remoteHost,
                "--remote-user", remoteUser,
                "--remote-port", String(remotePort),
                "--remote-encoder", remoteEncoder,
            ]
        } else {
            UserDefaults.standard.set(
                false, forKey: "VidReclaimRemoteEnabled"
            )
        }
        return arguments
    }

    func testRemote() {
        guard !remoteHost.isEmpty, !remoteUser.isEmpty else {
            phase = "Enter a Windows host and user"
            return
        }
        run(
            arguments: [
                "remote-doctor", remoteHost,
                "--user", remoteUser,
                "--port", String(remotePort),
                "--encoder", remoteEncoder,
            ],
            title: "Checking \(remoteHost)",
            section: .workspace
        )
    }

    func resumeQueue() {
        guard let session = currentSessionURL else { return }
        let runnable = queueSession?.items.contains {
            $0.isIncluded
                && ["ready", "paused", "cancelled", "error"].contains($0.status)
                && $0.output != nil
        } ?? false
        let canContinuePreparation = queueSession.map {
            ["new", "scanning", "analyzing", "reviewing"].contains($0.status)
        } ?? false
        guard runnable || canContinuePreparation else {
            phase = "No selected items are ready to encode"
            lastSummary = "0 items ready to encode"
            return
        }
        run(
            arguments: ["queue-resume", session.path],
            title: "Resuming \(queueSession?.name ?? "queue")",
            section: .workspace
        )
    }

    func queueControl(
        _ action: String,
        itemID: String? = nil,
        itemIDs: [String] = [],
        folder: String? = nil
    ) {
        guard let executable = cliPath, let session = currentSessionURL else { return }
        let control = Process()
        control.executableURL = URL(fileURLWithPath: executable)
        var arguments = ["queue-control", session.path, action]
        var ids = itemIDs
        if let itemID { ids.append(itemID) }
        for id in Set(ids) {
            arguments += ["--item", id]
        }
        if let folder { arguments += ["--folder", folder] }
        control.arguments = arguments
        let pipe = Pipe()
        control.standardOutput = pipe
        control.standardError = pipe
        control.terminationHandler = { [weak self] completed in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.loadQueueSession()
                if completed.terminationStatus != 0 {
                    self?.phase = "Queue command failed"
                    self?.lastExitSuccessful = false
                    if !message.isEmpty {
                        self?.appendLog(message)
                    }
                }
                if action == "resume",
                   completed.terminationStatus == 0,
                   self?.isRunning == false {
                    self?.resumeQueue()
                }
            }
        }
        do {
            try control.run()
        } catch {
            appendLog("Could not send queue command: \(error.localizedDescription)\n")
        }
    }

    func moveQueueItem(_ id: String, by offset: Int) {
        queueControl(offset < 0 ? "move-up" : "move-down", itemID: id)
    }

    func openQueueSession() {
        let panel = NSOpenPanel()
        panel.title = "Open a saved queue"
        panel.prompt = "Open Queue"
        panel.directoryURL = sessionsURL
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              url.pathExtension.lowercased() == "json" else { return }
        currentSessionURL = url
        UserDefaults.standard.set(url.path, forKey: "VidReclaimCurrentSession")
        selectedQueueItemIDs.removeAll()
        selection = .activity
        loadQueueSession()
    }

    private func loadLatestQueueSession() {
        if let saved = UserDefaults.standard.string(forKey: "VidReclaimCurrentSession") {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.path) {
                currentSessionURL = url
                loadQueueSession()
                return
            }
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let latest = urls
            .filter { $0.pathExtension == "json" }
            .max {
                let left = (try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return left < right
            }
        if let latest {
            currentSessionURL = latest
            UserDefaults.standard.set(latest.path, forKey: "VidReclaimCurrentSession")
            loadQueueSession()
        }
    }

    private func loadQueueSession() {
        guard let url = currentSessionURL,
              let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(QueueSession.self, from: data)
        else { return }
        queueSession = session
        selectedQueueItemIDs.formIntersection(
            Set(session.items.map(\.id))
        )
        let shouldPublishQueueProgress = runningQueue
            || selection == .activity
            || (
                selection == .workspace
                && workspaceOperation == .reclaim
                && !runningCombine
            )
        guard shouldPublishQueueProgress else { return }
        overallProgress = session.encodeFraction ?? session.overallFraction
        phase = session.displayPhase
        eta = durationLabel(session.etaSeconds)
        if let active = session.items.first(where: { $0.isActive }) {
            jobName = active.name
            jobProgress = active.transferProgress ?? active.progress
            if active.transferProgress != nil {
                phase = active.message
            }
            speed = active.speedX.map { String(format: "%.2f×", $0) } ?? ""
        } else {
            jobName = session.summary
            jobProgress = 0
            speed = ""
        }
        lastSummary = session.summary
    }

    func durationLabel(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let total = max(0, Int(seconds.rounded()))
        return String(
            format: "%d:%02d:%02d",
            total / 3600, (total % 3600) / 60, total % 60
        )
    }

    func bytesLabel(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func runStitch() {
        guard canStitchSelection else {
            phase = "Choose at least two clips or a folder"
            lastSummary = "Combine needs at least two clips. A folder may contain both."
            lastExitSuccessful = false
            return
        }
        guard let output = stitchOutput else {
            phase = "Choose an output file"
            lastSummary = "Choose where to save the combined video."
            lastExitSuccessful = false
            return
        }
        combineEstimate = nil
        combineResult = nil
        combinePreflightProgress = 0
        combineAttempted = true
        combinePartialURL = nil
        let partial = combinePartialURL(for: output)
        if FileManager.default.fileExists(atPath: partial.path) {
            combinePartialURL = partial
            phase = "Incomplete output found"
            jobName = partial.lastPathComponent
            lastSummary = "Move the incomplete output to Trash before retrying."
            lastExitSuccessful = false
            return
        }
        let arguments = [
            "stitch", output.path,
        ] + stitchInputs.map(\.path) + [
            "--canvas", stitchCanvas,
            "--profile", stitchProfile,
            "--encoder", stitchEncoder,
            "--preset", stitchPreset,
            "--mixed-dynamic-range", stitchMixedDynamicRange,
            "--nice", String(nice),
        ]
        run(
            arguments: arguments,
            title: "Preparing clips",
            section: .workspace
        )
    }

    func revealCombinePartial() {
        guard let combinePartialURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([combinePartialURL])
    }

    func discardCombinePartialAndRetry() {
        guard !isRunning, let partial = combinePartialURL else { return }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(
                at: partial,
                resultingItemURL: &trashed
            )
            combinePartialURL = nil
            runStitch()
        } catch {
            phase = "Could not move partial output to Trash"
            lastSummary = error.localizedDescription
            lastExitSuccessful = false
            appendLog(
                "Could not move \(partial.path) to Trash: "
                    + "\(error.localizedDescription)\n"
            )
        }
    }

    func runSpaceMap(section: SidebarSection = .workspace) {
        guard !spacePaths.isEmpty else { return }
        let reportDirectory = sessionsURL.deletingLastPathComponent()
            .appendingPathComponent("Space Scans", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: reportDirectory, withIntermediateDirectories: true
        )
        let jsonURL = reportDirectory.appendingPathComponent(
            "space-\(Int(Date().timeIntervalSince1970)).json"
        )
        pendingSpaceJSONURL = jsonURL
        var arguments = ["space"] + spacePaths.map(\.path) + [
            "--json-output", jsonURL.path, "--no-open",
        ]
        if useLogicalSizes { arguments.append("--logical-size") }
        if crossFilesystems { arguments.append("--cross-filesystems") }
        run(
            arguments: arguments,
            title: "Mapping disk usage",
            section: section
        )
    }

    private func finding(
        withID id: String,
        in node: SpaceFinding
    ) -> SpaceFinding? {
        if node.id == id { return node }
        for child in node.children {
            if let match = finding(withID: id, in: child) { return match }
        }
        return nil
    }

    private func videoPaths(
        selectedBy ids: Set<String>,
        in scan: SpaceScanResult
    ) -> [String] {
        func queueSourcePath(_ path: String) -> String {
            let components = URL(fileURLWithPath: path).pathComponents
            if let index = components.firstIndex(
                where: { $0.caseInsensitiveCompare("VIDEO_TS") == .orderedSame }
            ) {
                return NSString.path(
                    withComponents: Array(components.prefix(through: index))
                )
            }
            return path
        }
        return Array(
            Set(
                ids.compactMap { finding(withID: $0, in: scan.root) }
                    .flatMap(\.videoPaths)
                    .map(queueSourcePath)
            )
        ).sorted()
    }

    var selectedSpaceVideoPaths: [String] {
        guard let scan = spaceScan else { return [] }
        return videoPaths(selectedBy: selectedSpaceFindingIDs, in: scan)
    }

    var selectedReviewSpaceVideoPaths: [String] {
        guard let scan = spaceScan else { return [] }
        let included = Set(selectedSpaceVideoPaths)
        return videoPaths(
            selectedBy: selectedReviewSpaceFindingIDs,
            in: scan
        ).filter(included.contains)
    }

    private var selectedQueueRoot: URL? {
        let videoURLs = selectedSpaceVideoPaths.map(URL.init(fileURLWithPath:))
        guard !videoURLs.isEmpty else { return nil }
        if let scannedRoot = spacePaths.first(where: { candidate in
            let root = candidate.standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return videoURLs.allSatisfy {
                let path = $0.standardizedFileURL.path
                return path == root || path.hasPrefix(prefix)
            }
        }) {
            return scannedRoot
        }
        let components = videoURLs.map {
            $0.standardizedFileURL.pathComponents
        }
        guard var common = components.first else { return nil }
        for pathComponents in components.dropFirst() {
            var length = 0
            while length < min(common.count, pathComponents.count),
                  common[length] == pathComponents[length] {
                length += 1
            }
            common = Array(common.prefix(length))
        }
        let commonPath = NSString.path(withComponents: common)
        guard commonPath != "/",
              commonPath != "/Volumes",
              !commonPath.isEmpty else { return nil }
        return URL(fileURLWithPath: commonPath, isDirectory: true)
    }

    var canPrepareSelectedVideos: Bool {
        !selectedSpaceVideoPaths.isEmpty
            && selectedQueueRoot != nil
            && (!remoteEnabled || (!remoteHost.isEmpty && !remoteUser.isEmpty))
    }

    var queueSelectionIssue: String? {
        guard !selectedSpaceVideoPaths.isEmpty,
              selectedQueueRoot == nil else { return nil }
        return "Selections on different disks must be prepared as separate jobs."
    }

    func queueSelectedSpaceFindings() {
        guard spaceScan != nil else { return }
        let videoPaths = selectedSpaceVideoPaths
        let reviewPaths = selectedReviewSpaceVideoPaths
        guard !videoPaths.isEmpty else {
            appendLog("Choose at least one video or a folder containing videos.\n")
            return
        }
        guard let root = selectedQueueRoot else {
            appendLog(
                "Selections on different disks must be prepared as separate jobs.\n"
            )
            return
        }
        compressionSource = root
        try? FileManager.default.createDirectory(
            at: sessionsURL, withIntermediateDirectories: true
        )
        let session = sessionsURL.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        )
        currentSessionURL = session
        workspaceSessionURL = session
        UserDefaults.standard.set(session.path, forKey: "VidReclaimCurrentSession")
        var arguments = [
            "queue-start", root.path, "--session", session.path, "--plan-only",
        ] + videoPaths.flatMap { ["--include-path", $0] } + analysisArguments()
        if !reviewPaths.isEmpty {
            arguments += ["--review", "--review-interface", "native"]
            arguments += reviewPaths.flatMap { ["--review-path", $0] }
        }
        if deepVerify { arguments.append("--deep-verify") }
        switch sourcePolicy {
        case .keep:
            break
        case .archive:
            arguments.append("--replace")
        case .delete:
            arguments += ["--delete-source-as-you-go", "--yes"]
        }
        run(
            arguments: arguments,
            title: "Preparing \(videoPaths.count) selected video\(videoPaths.count == 1 ? "" : "s")",
            section: .workspace
        )
    }

    private func loadSpaceScan(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let scan = try? JSONDecoder().decode(
                SpaceScanResult.self, from: data
              ) else {
            appendLog("The disk scan finished, but its structured results could not be read.\n")
            return
        }
        spaceScan = scan
        selectedSpaceFindingIDs.removeAll()
        selectedReviewSpaceFindingIDs.removeAll()
    }

    func moveStitchInput(from index: Int, by offset: Int) {
        let destination = index + offset
        guard stitchInputs.indices.contains(index),
              stitchInputs.indices.contains(destination) else { return }
        resetCombineEstimate()
        stitchInputs.swapAt(index, destination)
    }

    func cancel() {
        if runningQueue, currentSessionURL != nil {
            queueControl("cancel")
            phase = "Cancelling queue"
            return
        }
        guard let process, process.isRunning else { return }
        appendLog("\nCancellation requested. Finishing the current safe interruption point…\n")
        phase = "Cancelling"
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            self?.appendLog("The worker did not stop after interrupt; termination was requested.\n")
        }
    }

    func stopForApplicationTermination() {
        queueTimer?.invalidate()
        queueTimer = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.interrupt()
        }
    }

    func clearLog() {
        log = ""
        try? FileManager.default.removeItem(at: logURL)
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log, forType: .string)
    }

    func revealLog() {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    func revealQueueOutput(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path)
        ])
    }

    private func run(arguments: [String], title: String, section: SidebarSection) {
        guard !isRunning else { return }
        guard let executable = cliPath else {
            lastExitSuccessful = false
            phase = "Engine not found"
            appendLog("VidReclaim's installed engine could not be found. Reinstall the package.\n")
            selection = .activity
            return
        }

        let newProcess = Process()
        let pipe = Pipe()
        newProcess.executableURL = URL(fileURLWithPath: executable)
        newProcess.arguments = arguments
        newProcess.standardOutput = pipe
        newProcess.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        newProcess.environment = environment

        process = newProcess
        outputPipe = pipe
        pendingOutput = ""
        jobTitle = title
        runningQueue = arguments.first?.hasPrefix("queue-") == true
        runningCombine = arguments.first == "stitch"
        isRunning = true
        phase = title
        jobName = ""
        jobProgress = 0
        overallProgress = 0
        eta = "Estimating…"
        speed = ""
        lastExitSuccessful = nil
        selection = section
        appendLog("\n\(String(repeating: "─", count: 64))\n\(title)\n")
        appendLog("$ vidreclaim \(arguments.map(shellDisplay).joined(separator: " "))\n\n")

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.consume(chunk)
            }
        }
        newProcess.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                if !self.pendingOutput.isEmpty {
                    self.handleLine(self.pendingOutput)
                    self.pendingOutput = ""
                }
                let succeeded = completed.terminationStatus == 0
                self.lastExitSuccessful = succeeded
                self.isRunning = false
                if self.runningQueue {
                    self.loadQueueSession()
                } else {
                    if succeeded {
                        self.phase = "Complete"
                    } else if self.combinePartialURL != nil {
                        self.phase = "Incomplete output found"
                    } else {
                        self.phase = completed.terminationStatus == 130
                            ? "Cancelled" : "Needs attention"
                    }
                    if succeeded {
                        self.overallProgress = 1
                        self.jobProgress = 1
                        self.eta = "Done"
                    } else {
                        self.eta = "—"
                    }
                }
                if succeeded, let report = self.pendingSpaceJSONURL {
                    self.loadSpaceScan(report)
                }
                self.pendingSpaceJSONURL = nil
                self.appendLog(
                    "\n\(succeeded ? "Completed successfully." : "Exited with status \(completed.terminationStatus).")\n"
                )
                self.process = nil
                self.outputPipe = nil
                self.runningQueue = false
                self.runningCombine = false
            }
        }

        do {
            try newProcess.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            outputPipe = nil
            runningQueue = false
            runningCombine = false
            isRunning = false
            phase = "Could not start"
            lastExitSuccessful = false
            appendLog("Could not launch the engine: \(error.localizedDescription)\n")
            selection = .activity
        }
    }

    private func consume(_ chunk: String) {
        appendLog(chunk)
        let normalized = chunk.replacingOccurrences(of: "\r", with: "\n")
        pendingOutput += normalized
        let lines = pendingOutput.components(separatedBy: "\n")
        pendingOutput = lines.last ?? ""
        for line in lines.dropLast() where !line.isEmpty {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("REMOTE_DOCTOR ") {
            phase = "Windows PC ready"
            lastSummary = "\(remoteHost) is ready for \(remoteEncoder == "x265" ? "CPU x265" : "RTX 4090") encoding."
            eta = "Ready"
            return
        }
        let stalePartialPrefix = "Stitch ERROR: Stale partial stitch exists: "
        if line.hasPrefix(stalePartialPrefix) {
            let path = String(line.dropFirst(stalePartialPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            combinePartialURL = URL(fileURLWithPath: path)
            combineAttempted = true
            phase = "Incomplete output found"
            jobName = URL(fileURLWithPath: path).lastPathComponent
            lastSummary = "Move the incomplete output to Trash before retrying."
            lastExitSuccessful = false
            return
        }
        if line.hasPrefix("Combine preflight:") {
            phase = "Preparing clips"
            jobName = String(line.dropFirst("Combine preflight:".count))
                .trimmingCharacters(in: .whitespaces)
            if line.contains("reading metadata") {
                combinePreflightProgress = 0
            }
            eta = "Estimating…"
            return
        }
        if line.hasPrefix("Combine metadata:") {
            phase = "Reading clip metadata"
            let detail = String(line.dropFirst("Combine metadata:".count))
                .trimmingCharacters(in: .whitespaces)
            jobName = detail
            if let marker = detail.split(separator: " ").first {
                let values = marker.split(separator: "/")
                if values.count == 2,
                   let current = Double(values[0]),
                   let total = Double(values[1]), total > 0 {
                    combinePreflightProgress = max(0, min(1, current / total))
                }
            }
            return
        }
        if line.hasPrefix("COMBINE_ESTIMATE ") {
            let json = String(line.dropFirst("COMBINE_ESTIMATE ".count))
            if let data = json.data(using: .utf8),
               let estimate = try? JSONDecoder().decode(
                   CombineEstimate.self, from: data
               ) {
                combineEstimate = estimate
                combinePreflightProgress = 1
                phase = "Encoding combined video"
                jobName = "\(estimate.clipCount) clips · \(estimate.width)×\(estimate.height)"
                eta = durationLabel(estimate.projectedEncodeSeconds)
            }
            return
        }
        if line.hasPrefix("COMBINE_RESULT ") {
            let json = String(line.dropFirst("COMBINE_RESULT ".count))
            if let data = json.data(using: .utf8),
               let result = try? JSONDecoder().decode(
                   CombineResult.self, from: data
               ) {
                combineResult = result
            }
            return
        }
        if line.hasPrefix("Plan:") {
            lastSummary = line
            phase = "Ready"
            eta = extractEstimate(from: line) ?? "See plan"
            return
        }
        if line.hasPrefix("Finished:") || line.hasPrefix("Stitched ") {
            lastSummary = line
            return
        }
        if line.hasPrefix("Scanned ") {
            phase = "Scanning"
            jobName = line
            return
        }
        if line.contains("Preparing side-by-side review") {
            phase = "Waiting for visual review"
            eta = "Review in browser"
            return
        }
        if line.hasPrefix("DVD ") {
            phase = "Selecting main DVD content"
            jobName = line
            return
        }
        if line.contains("] analyzing ") {
            phase = "Analyzing samples"
            jobName = String(line.split(separator: "]", maxSplits: 1).last ?? "")
                .trimmingCharacters(in: .whitespaces)
            if let range = line.range(
                of: #"^\[(\d+)/(\d+)\]"#,
                options: .regularExpression
            ) {
                let marker = String(line[range])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: "/")
                if marker.count == 2,
                   let current = Double(marker[0]),
                   let total = Double(marker[1]), total > 0 {
                    overallProgress = max(0, min(0.98, (current - 1) / total))
                }
            }
            return
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("sample ") {
            phase = "Testing quality and size"
            return
        }
        parseProgressLine(line)
    }

    private func parseProgressLine(_ line: String) {
        let parts = line.components(separatedBy: " · ")
        guard parts.count >= 3,
              let firstPercentRange = parts[0].range(
                of: #"[0-9]+(?:\.[0-9]+)?% overall"#,
                options: .regularExpression
              ),
              let overall = Double(
                parts[0][firstPercentRange]
                    .replacingOccurrences(of: "% overall", with: "")
              ) else { return }
        overallProgress = max(0, min(1, overall / 100))

        if let jobPercentRange = parts[1].range(
            of: #"[0-9]+(?:\.[0-9]+)?%"#,
            options: .regularExpression
        ), let current = Double(
            parts[1][jobPercentRange].replacingOccurrences(of: "%", with: "")
        ) {
            jobProgress = max(0, min(1, current / 100))
            phase = String(parts[1][jobPercentRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .capitalized
        }
        if let etaPart = parts.first(where: { $0.hasPrefix("ETA ") }) {
            eta = String(etaPart.dropFirst(4))
        }
        if let speedPart = parts.first(where: { $0.hasSuffix("×") }) {
            speed = speedPart
        }
        jobName = parts.last ?? jobTitle
    }

    private func extractEstimate(from line: String) -> String? {
        guard let range = line.range(
            of: #"~[^,]+ total encode time"#,
            options: .regularExpression
        ) else { return nil }
        return String(line[range])
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: " total encode time", with: "")
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 200_000 {
            log = String(log.suffix(160_000))
        }
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            // The on-screen log remains available if the persistent log cannot be written.
        }
    }

    private func shellDisplay(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

struct PathChooser: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.title2)
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(2)
            }
            Spacer()
            Button("Choose…", action: action)
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(AppColors.secondaryText)
        }
    }
}

struct RunningBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.phase).fontWeight(.semibold)
                    if !model.jobName.isEmpty {
                        Text(model.jobName)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !model.speed.isEmpty {
                    Text(model.speed).monospacedDigit().foregroundStyle(AppColors.secondaryText)
                }
                Label(model.eta, systemImage: "clock")
                    .monospacedDigit()
                    .foregroundStyle(AppColors.secondaryText)
                Button("Stop", role: .destructive) { model.cancel() }
            }
            if model.runningQueue, let session = model.queueSession {
                let scanProgress = session.scanFraction ?? 0
                let encodeProgress = session.encodeFraction
                    ?? session.overallFraction
                HStack(spacing: 14) {
                    Text("Scan \(scanProgress * 100, specifier: "%.0f")%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 72, alignment: .leading)
                    ProgressView(value: scanProgress)
                        .progressViewStyle(.linear)
                    Text(
                        "Encode \(encodeProgress * 100, specifier: "%.0f")%"
                    )
                    .font(.caption.monospacedDigit())
                    .frame(width: 86, alignment: .leading)
                    ProgressView(value: encodeProgress)
                        .progressViewStyle(.linear)
                }
            } else {
                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

struct CompressionSourcePicker: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var viewMode: LibraryViewMode = .browse
    @State private var sortOption: LibrarySortOption = .size
    @State private var ascending = false
    @State private var expandedFindingIDs = Set<String>()

    private var roots: [SpaceFinding] {
        model.spaceScan?.root.children ?? []
    }

    private var scanIdentity: String {
        guard let root = model.spaceScan?.root else { return "" }
        return "\(root.size):\(root.files):"
            + root.children.map(\.id).joined(separator: "|")
    }

    private func compare(
        _ left: SpaceFinding,
        _ right: SpaceFinding
    ) -> Bool {
        let order: ComparisonResult
        switch sortOption {
        case .size:
            if left.size == right.size {
                order = left.name.localizedStandardCompare(right.name)
            } else {
                order = left.size < right.size
                    ? .orderedAscending : .orderedDescending
            }
        case .name:
            order = left.name.localizedStandardCompare(right.name)
        case .files:
            if left.files == right.files {
                order = left.name.localizedStandardCompare(right.name)
            } else {
                order = left.files < right.files
                    ? .orderedAscending : .orderedDescending
            }
        case .kind:
            if left.kind == right.kind {
                order = left.name.localizedStandardCompare(right.name)
            } else {
                order = left.kind.localizedStandardCompare(right.kind)
            }
        }
        return ascending
            ? order == .orderedAscending
            : order == .orderedDescending
    }

    private func flatten(_ findings: [SpaceFinding]) -> [SpaceFinding] {
        findings.flatMap { [$0] + flatten($0.children) }
    }

    private var allFindings: [SpaceFinding] {
        flatten(roots)
    }

    private var allVideoIDs: Set<String> {
        Set(allFindings.filter { $0.kind == "video" }.map(\.id))
    }

    private var allDirectoryIDs: Set<String> {
        Set(
            allFindings
                .filter { !$0.children.isEmpty }
                .map(\.id)
        )
    }

    private func matchesSearch(_ finding: SpaceFinding) -> Bool {
        guard !searchText.isEmpty else { return true }
        return finding.name.localizedCaseInsensitiveContains(searchText)
            || finding.path.localizedCaseInsensitiveContains(searchText)
    }

    private func branchMatchesSearch(_ finding: SpaceFinding) -> Bool {
        matchesSearch(finding)
            || finding.children.contains(where: branchMatchesSearch)
    }

    private var browseRows: [SpaceFindingRow] {
        var rows: [SpaceFindingRow] = []
        func append(_ finding: SpaceFinding, depth: Int) {
            if !searchText.isEmpty && !branchMatchesSearch(finding) {
                return
            }
            rows.append(SpaceFindingRow(finding: finding, depth: depth))
            let showChildren = !searchText.isEmpty
                || expandedFindingIDs.contains(finding.id)
            guard showChildren else { return }
            for child in finding.children.sorted(by: compare) {
                append(child, depth: depth + 1)
            }
        }
        for root in roots.sorted(by: compare) {
            append(root, depth: 0)
        }
        return rows
    }

    private var largestVideoRows: [SpaceFindingRow] {
        allFindings
            .filter { $0.kind == "video" && matchesSearch($0) }
            .sorted(by: compare)
            .map { SpaceFindingRow(finding: $0, depth: 0) }
    }

    private var findings: [SpaceFindingRow] {
        viewMode == .browse ? browseRows : largestVideoRows
    }

    private var visibleVideoIDs: Set<String> {
        Set(findings.filter { $0.finding.kind == "video" }.map(\.finding.id))
    }

    private var selectedVideoBytes: Int64 {
        allFindings
            .filter {
                $0.kind == "video"
                    && model.selectedSpaceFindingIDs.contains($0.id)
            }
            .reduce(0) { $0 + $1.size }
    }

    private func descendantVideoIDs(_ item: SpaceFinding) -> Set<String> {
        if item.kind == "video" { return [item.id] }
        return Set(item.children.flatMap {
            Array(descendantVideoIDs($0))
        })
    }

    private func selectionIcon(
        for item: SpaceFinding,
        in selected: Set<String>
    ) -> String {
        let descendants = descendantVideoIDs(item)
        guard !descendants.isEmpty else { return "square" }
        let selectedCount = descendants.intersection(selected).count
        if selectedCount == 0 { return "square" }
        return selectedCount == descendants.count
            ? "checkmark.square.fill" : "minus.square.fill"
    }

    private func toggleAnalysis(_ item: SpaceFinding) {
        let descendants = descendantVideoIDs(item)
        guard !descendants.isEmpty else { return }
        if descendants.isSubset(of: model.selectedSpaceFindingIDs) {
            model.selectedSpaceFindingIDs.subtract(descendants)
            model.selectedReviewSpaceFindingIDs.subtract(descendants)
        } else {
            model.selectedSpaceFindingIDs.formUnion(descendants)
        }
    }

    private func toggleReview(_ item: SpaceFinding) {
        let descendants = descendantVideoIDs(item)
        guard !descendants.isEmpty else { return }
        if descendants.isSubset(of: model.selectedReviewSpaceFindingIDs) {
            model.selectedReviewSpaceFindingIDs.subtract(descendants)
        } else {
            model.selectedReviewSpaceFindingIDs.formUnion(descendants)
            model.selectedSpaceFindingIDs.formUnion(descendants)
        }
    }

    var body: some View {
        GroupBox("Choose Videos") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Locations")
                        .font(.headline)
                    Button("Add Folders, Files, or Disks…") {
                        model.addSpacePaths()
                    }
                    Button("Clear Locations") {
                        model.spacePaths.removeAll()
                        model.spaceScan = nil
                        model.selectedSpaceFindingIDs.removeAll()
                        model.selectedReviewSpaceFindingIDs.removeAll()
                    }
                    .disabled(model.spacePaths.isEmpty || model.isRunning)
                    Spacer()
                    Button(
                        model.spaceScan == nil
                            ? "Scan Disk Usage" : "Rescan"
                    ) {
                        model.runSpaceMap(section: .workspace)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.spacePaths.isEmpty || model.isRunning)
                }

                if model.spaceScan == nil {
                    List {
                        ForEach(model.spacePaths, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(AppColors.secondaryText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        url.lastPathComponent.isEmpty
                                            ? url.path : url.lastPathComponent
                                    )
                                    Text(url.path)
                                        .font(.caption2)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    model.spacePaths.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .overlay {
                        if model.spacePaths.isEmpty {
                            ContentUnavailableView(
                                "Choose library locations",
                                systemImage: "folder.badge.plus",
                                description: Text("Add folders, files, or disks.")
                            )
                        }
                    }
                    .frame(minHeight: 135, maxHeight: 190)
                } else {
                    Divider()

                    HStack {
                        Text("Contents")
                            .font(.headline)
                        if let scan = model.spaceScan {
                            Label(
                                "\(model.bytesLabel(scan.root.size)) "
                                    + (scan.allocated ? "on disk" : "logical"),
                                systemImage: "internaldrive"
                            )
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            Text("\(scan.root.files.formatted()) files")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                            if scan.root.errors > 0 {
                                Label(
                                    "\(scan.root.errors) unreadable",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(AppColors.warning)
                            }
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Picker("View", selection: $viewMode) {
                            ForEach(LibraryViewMode.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 230)

                        TextField("Filter scanned contents", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180, maxWidth: 300)

                        Spacer()

                        Picker("Sort", selection: $sortOption) {
                            ForEach(LibrarySortOption.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)

                        Button {
                            ascending.toggle()
                        } label: {
                            Image(
                                systemName: ascending
                                    ? "arrow.up" : "arrow.down"
                            )
                        }
                        .help(ascending ? "Ascending" : "Descending")

                        if viewMode == .browse {
                            Button("Expand All") {
                                expandedFindingIDs = allDirectoryIDs
                            }
                            Button("Collapse All") {
                                expandedFindingIDs.removeAll()
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Text("Name")
                            .font(.caption.bold())
                        Spacer()
                        Text("Files")
                            .font(.caption.bold())
                            .frame(width: 64, alignment: .trailing)
                        Text("Size")
                            .font(.caption.bold())
                            .frame(width: 95, alignment: .trailing)
                        Text("Analyze")
                            .font(.caption.bold())
                            .frame(width: 64)
                        Text("Review")
                            .font(.caption.bold())
                            .frame(width: 52)
                    }
                    .padding(.horizontal, 8)

                    List {
                        ForEach(findings) { row in
                            let item = row.finding
                            HStack(spacing: 8) {
                                Color.clear
                                    .frame(width: CGFloat(row.depth * 16))
                                if viewMode == .browse,
                                   !item.children.isEmpty {
                                    Button {
                                        if expandedFindingIDs.contains(item.id) {
                                            expandedFindingIDs.remove(item.id)
                                        } else {
                                            expandedFindingIDs.insert(item.id)
                                        }
                                    } label: {
                                        Image(
                                            systemName: expandedFindingIDs
                                                .contains(item.id)
                                                ? "chevron.down"
                                                : "chevron.right"
                                        )
                                        .font(.caption.bold())
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 14)
                                } else {
                                    Color.clear.frame(width: 14)
                                }
                                Image(
                                    systemName: item.kind == "directory"
                                        ? "folder.fill"
                                        : (item.kind == "video"
                                            ? "film.fill" : "doc.fill")
                                )
                                .foregroundStyle(
                                    item.kind == "video"
                                        ? AppColors.warning : AppColors.secondaryText
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).lineLimit(1)
                                    if viewMode == .largestVideos
                                        || !searchText.isEmpty {
                                        Text(
                                            URL(fileURLWithPath: item.path)
                                                .deletingLastPathComponent().path
                                        )
                                            .font(.caption2)
                                            .foregroundStyle(
                                                AppColors.tertiaryText
                                            )
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(
                                    item.kind == "directory"
                                        ? item.files.formatted() : "—"
                                )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(width: 64, alignment: .trailing)
                                Text(model.bytesLabel(item.size))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(width: 95, alignment: .trailing)
                                Button {
                                    toggleAnalysis(item)
                                } label: {
                                    Image(
                                        systemName: selectionIcon(
                                            for: item,
                                            in: model.selectedSpaceFindingIDs
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(width: 64)
                                .disabled(descendantVideoIDs(item).isEmpty)
                                Button {
                                    toggleReview(item)
                                } label: {
                                    Image(
                                        systemName: selectionIcon(
                                            for: item,
                                            in: model.selectedReviewSpaceFindingIDs
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(width: 52)
                                .disabled(descendantVideoIDs(item).isEmpty)
                                .help("Generate side-by-side samples")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .overlay {
                        if findings.isEmpty {
                            ContentUnavailableView(
                                "No matching items",
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        }
                    }
                    .frame(minHeight: 260, idealHeight: 340, maxHeight: 430)

                    HStack {
                        Text(
                            "\(model.selectedSpaceVideoPaths.count.formatted()) selected"
                        )
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                        if selectedVideoBytes > 0 {
                            Text("· \(model.bytesLabel(selectedVideoBytes))")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        if !model.selectedReviewSpaceVideoPaths.isEmpty {
                            Text(
                                "· \(model.selectedReviewSpaceVideoPaths.count.formatted()) for review"
                            )
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        }
                        Spacer()
                        Button("Select Visible") {
                            model.selectedSpaceFindingIDs.formUnion(
                                visibleVideoIDs
                            )
                        }
                        .disabled(visibleVideoIDs.isEmpty)
                        Button("Select All") {
                            model.selectedSpaceFindingIDs.formUnion(allVideoIDs)
                        }
                        .disabled(allVideoIDs.isEmpty)
                        Button("Clear Selection") {
                            model.selectedSpaceFindingIDs.removeAll()
                            model.selectedReviewSpaceFindingIDs.removeAll()
                        }
                        .disabled(model.selectedSpaceFindingIDs.isEmpty)
                    }
                }

                if let issue = model.queueSelectionIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppColors.warning)
                }
            }
            .padding(.top, 6)
        }
        .onAppear {
            if expandedFindingIDs.isEmpty {
                expandedFindingIDs = Set(
                    roots.filter { !$0.children.isEmpty }.map(\.id)
                )
            }
        }
        .onChange(of: scanIdentity) { _, _ in
            expandedFindingIDs = Set(
                roots.filter { !$0.children.isEmpty }.map(\.id)
            )
        }
        .onChange(of: viewMode) { _, mode in
            if mode == .largestVideos {
                sortOption = .size
                ascending = false
            }
        }
        .onChange(of: sortOption) { _, option in
            ascending = option == .name
        }
    }
}

struct ReviewFrameView: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(AppColors.secondaryText)
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 160)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                ContentUnavailableView(
                    "Frame unavailable",
                    systemImage: "photo.badge.exclamationmark"
                )
                .frame(width: 220, height: 130)
            }
        }
    }
}

struct NativeSBSReviewView: View {
    @ObservedObject var model: AppModel
    let item: QueueItem
    @State private var isExpanded: Bool

    init(
        model: AppModel,
        item: QueueItem,
        initiallyExpanded: Bool
    ) {
        self.model = model
        self.item = item
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                    Text(item.path)
                        .font(.caption2)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if let savings = item.projectedSavingsPct {
                    Text(
                        "\(savings, specifier: "%.1f")% projected savings"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppColors.secondaryText)
                }
                Button(isExpanded ? "Hide Frames" : "Compare Frames") {
                    withAnimation { isExpanded.toggle() }
                }
                Button {
                    model.queueControl(
                        item.isIncluded ? "exclude" : "include",
                        itemID: item.id
                    )
                } label: {
                    Label(
                        item.isIncluded
                            ? "Included" : "Excluded",
                        systemImage: item.isIncluded
                            ? "checkmark.circle.fill" : "circle"
                    )
                }
                .buttonStyle(.bordered)
                .tint(item.isIncluded ? Color.accentColor : AppColors.secondaryText)
            }

            if isExpanded {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(item.reviewPairs ?? []) { pair in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(pair.time)
                                    .font(.caption.monospacedDigit())
                                HStack(spacing: 8) {
                                    ReviewFrameView(
                                        title: "Source",
                                        path: pair.before
                                    )
                                    ReviewFrameView(
                                        title: "Planned",
                                        path: pair.after
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}

struct PreparedQueueView: View {
    @ObservedObject var model: AppModel
    let session: QueueSession

    private var reviewItems: [QueueItem] {
        session.items.filter { !($0.reviewPairs ?? []).isEmpty }
    }

    private var includedCount: Int {
        session.items.filter {
            $0.isIncluded && !$0.isProcessed && $0.status != "skipped"
        }.count
    }

    private var runnableCount: Int {
        session.items.filter {
            $0.isIncluded
                && ["ready", "paused", "cancelled", "error"].contains($0.status)
                && $0.output != nil
        }.count
    }

    var body: some View {
        GroupBox("Ready to Encode") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(session.summary, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(includedCount) included")
                        .foregroundStyle(AppColors.secondaryText)
                }

                if !reviewItems.isEmpty {
                    Text("Exclude anything you do not want.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    ForEach(
                        Array(reviewItems.enumerated()),
                        id: \.element.id
                    ) { index, item in
                        NativeSBSReviewView(
                            model: model,
                            item: item,
                            initiallyExpanded: index == 0
                        )
                    }
                }

                HStack {
                    Spacer()
                    Button("Start \(runnableCount) Encode\(runnableCount == 1 ? "" : "s")") {
                        model.resumeQueue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        runnableCount == 0
                        || model.isRunning
                        || !["paused", "queued"].contains(session.status)
                    )
                }
            }
            .padding(.top, 6)
        }
    }
}

struct CompressView: View {
    @ObservedObject var model: AppModel
    @State private var confirmDeletion = false

    private var preparedSession: QueueSession? {
        guard model.workspaceSessionURL == model.currentSessionURL,
              let session = model.queueSession,
              ["paused", "queued", "complete", "attention"].contains(
                session.status
              ) else { return nil }
        return session
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(
                    title: "Reclaim Space",
                    subtitle: "Choose videos and prepare a queue."
                )
                CompressionSourcePicker(model: model)

                GroupBox {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 18,
                        verticalSpacing: 13
                    ) {
                        GridRow {
                            Text("Quality")
                            Picker(
                                "Quality",
                                selection: $model.compressionProfile
                            ) {
                                Text("More detail").tag("conservative")
                                Text("Balanced").tag("balanced")
                                Text("Smaller").tag("compact")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        GridRow {
                            Text("Computer")
                            Toggle("Use Windows PC", isOn: $model.remoteEnabled)
                            .toggleStyle(.switch)
                        }
                        if model.remoteEnabled {
                            GridRow {
                                Text("Windows PC")
                                HStack {
                                    TextField(
                                        "Host or IP",
                                        text: $model.remoteHost
                                    )
                                    TextField(
                                        "User",
                                        text: $model.remoteUser
                                    )
                                    .frame(width: 120)
                                    Button("Test") {
                                        model.testRemote()
                                    }
                                    .disabled(
                                        model.isRunning
                                        || model.remoteHost.isEmpty
                                        || model.remoteUser.isEmpty
                                    )
                                }
                            }
                            GridRow {
                                Text("Mode")
                                Picker(
                                    "Mode",
                                    selection: $model.remoteEncoder
                                ) {
                                    Text("Smaller").tag("x265")
                                    Text("Faster").tag("nvenc")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                        } else {
                            GridRow {
                                Text("Mode")
                                Picker(
                                    "Mode",
                                    selection: $model.compressionEncoder
                                ) {
                                    Text("Smaller").tag("x265")
                                    Text("Faster").tag("videotoolbox")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                        }
                        GridRow {
                            Text("Minimum savings")
                            HStack {
                                Slider(
                                    value: $model.minimumSavings,
                                    in: 5...50,
                                    step: 1
                                )
                                Text(
                                    "\(model.minimumSavings, specifier: "%.0f")%"
                                )
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                            }
                        }
                        GridRow {
                            Text("Sources")
                            Picker(
                                "Sources",
                                selection: $model.sourcePolicy
                            ) {
                                ForEach(SourcePolicy.allCases) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.sourcePolicy.detail)
                                Label(
                                    "Output: VidReclaim Output",
                                    systemImage: "folder"
                                )
                            }
                            .font(.caption)
                            .foregroundStyle(
                                model.sourcePolicy == .delete
                                    ? AppColors.warning
                                    : AppColors.secondaryText
                            )
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Options")
                        .font(.headline)
                }

                HStack {
                    Spacer()
                    Button(
                        !model.selectedReviewSpaceVideoPaths.isEmpty
                            ? "Prepare and Review"
                            : "Prepare"
                    ) {
                        if model.sourcePolicy == .delete {
                            confirmDeletion = true
                        } else {
                            model.queueSelectedSpaceFindings()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !model.canPrepareSelectedVideos
                        || model.isRunning
                    )
                }

                if let preparedSession {
                    PreparedQueueView(
                        model: model,
                        session: preparedSession
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .alert("Permanently delete verified sources?", isPresented: $confirmDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Prepare Queue", role: .destructive) {
                model.queueSelectedSpaceFindings()
            }
        } message: {
            Text("Sources are deleted only after verification.")
        }
    }
}

struct StitchView: View {
    @ObservedObject var model: AppModel

    private var outputSizeTitle: String {
        model.combineResult == nil ? "Estimated output" : "Actual output"
    }

    private var outputSize: Int64? {
        model.combineResult?.outputBytes
            ?? model.combineEstimate?.projectedOutputBytes
    }

    private var sizeDifference: Int64? {
        guard let source = model.combineEstimate?.sourceBytes,
              let output = outputSize else { return nil }
        return source - output
    }

    private var differenceTitle: String {
        guard let difference = sizeDifference else { return "Estimated change" }
        let prefix = model.combineResult == nil ? "Estimated" : "Actual"
        return "\(prefix) \(difference >= 0 ? "savings" : "increase")"
    }

    private var differenceValue: String {
        guard let difference = sizeDifference,
              let source = model.combineEstimate?.sourceBytes,
              source > 0 else { return "—" }
        let percent = abs(Double(difference) / Double(source) * 100)
        return "\(model.bytesLabel(abs(difference))) (\(percent.formatted(.number.precision(.fractionLength(1))))%)"
    }

    private var partialSize: Int64? {
        guard let partial = model.combinePartialURL,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: partial.path
              ),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            SectionHeading(
                title: "Combine Clips",
                subtitle: "Join clips in the listed order."
            )
            HStack {
                Button("Add Clips or Folders…") { model.addStitchInputs() }
                    .disabled(model.isRunning)
                Button("Clear") {
                    model.resetCombineEstimate()
                    model.stitchInputs.removeAll()
                    model.stitchOutput = nil
                }
                    .disabled(model.stitchInputs.isEmpty || model.isRunning)
                Spacer()
                Text("\(model.stitchInputs.count) selected")
                    .foregroundStyle(AppColors.secondaryText)
            }
            List {
                ForEach(Array(model.stitchInputs.enumerated()), id: \.element) { index, url in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(AppColors.secondaryText)
                            .frame(width: 25, alignment: .trailing)
                        Image(systemName: url.hasDirectoryPath ? "folder" : "film")
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                        }
                        Spacer()
                        Button { model.moveStitchInput(from: index, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0 || model.isRunning)
                        Button { model.moveStitchInput(from: index, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            index == model.stitchInputs.count - 1
                                || model.isRunning
                        )
                        Button(role: .destructive) {
                            model.resetCombineEstimate()
                            model.stitchInputs.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRunning)
                    }
                }
            }
            .overlay {
                if model.stitchInputs.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add at least two clips.")
                    )
                }
            }
            .frame(minHeight: 190, idealHeight: 280, maxHeight: 360)

            if model.combineAttempted {
                GroupBox("Combine status") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            if model.runningCombine
                                && model.combineEstimate == nil {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(
                                    systemName: model.combineResult != nil
                                        ? "checkmark.circle.fill"
                                        : (
                                            model.lastExitSuccessful == false
                                                ? "exclamationmark.triangle.fill"
                                                : "clock"
                                        )
                                )
                                .foregroundStyle(
                                    model.combineResult != nil
                                        ? AppColors.success
                                        : (
                                            model.lastExitSuccessful == false
                                                ? AppColors.error : Color.accentColor
                                        )
                                )
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.phase).fontWeight(.semibold)
                                if !model.jobName.isEmpty {
                                    Text(model.jobName)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if model.runningCombine {
                                Text(
                                    model.combineEstimate == nil
                                        ? "Calculating estimates"
                                        : "ETA \(model.eta)"
                                )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                            }
                        }

                        if model.runningCombine {
                            if model.combineEstimate == nil {
                                if let progress = model.combinePreflightProgress {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                } else {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                }
                            } else {
                                ProgressView(value: model.jobProgress)
                                    .progressViewStyle(.linear)
                            }
                        }

                        if let partial = model.combinePartialURL {
                            Divider()
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("An earlier combine left an incomplete file.")
                                        .font(.callout)
                                    Text(
                                        partial.lastPathComponent
                                            + (partialSize.map {
                                                " · \(model.bytesLabel($0))"
                                            } ?? "")
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppColors.secondaryText)
                                    .lineLimit(1)
                                }
                                Spacer()
                                Button("Show in Finder") {
                                    model.revealCombinePartial()
                                }
                                Button("Move to Trash and Retry", role: .destructive) {
                                    model.discardCombinePartialAndRetry()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        if let estimate = model.combineEstimate {
                            Grid(
                                alignment: .leading,
                                horizontalSpacing: 24,
                                verticalSpacing: 7
                            ) {
                                GridRow {
                                    Text("Clips").foregroundStyle(AppColors.secondaryText)
                                    Text(estimate.clipCount.formatted())
                                        .monospacedDigit()
                                    Text("Total runtime")
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text(
                                        model.durationLabel(
                                            estimate.totalDurationSeconds
                                        )
                                    )
                                    .monospacedDigit()
                                    Text("Resolution")
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text("\(estimate.width)×\(estimate.height)")
                                        .monospacedDigit()
                                }
                                GridRow {
                                    Text("Source size")
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text(model.bytesLabel(estimate.sourceBytes))
                                        .monospacedDigit()
                                    Text(outputSizeTitle)
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text(model.bytesLabel(outputSize))
                                        .monospacedDigit()
                                    Text(differenceTitle)
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text(differenceValue)
                                        .monospacedDigit()
                                }
                                GridRow {
                                    Text("Estimated encode")
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text(
                                        model.durationLabel(
                                            estimate.projectedEncodeSeconds
                                        )
                                    )
                                    .monospacedDigit()
                                    Text("Output files")
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text(
                                        model.combineResult?.outputCount
                                            .formatted() ?? (
                                                model.stitchMixedDynamicRange
                                                    == "split"
                                                ? "1 or 2" : "1"
                                            )
                                    )
                                    Text("")
                                    Text("")
                                }
                            }
                            .font(.caption)
                            Text(
                                "Estimates update during encoding."
                            )
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .padding(.top, 5)
                }
            }

            PathChooser(
                title: model.stitchOutput?.lastPathComponent
                    ?? model.suggestedStitchFilename,
                detail: model.stitchOutput?.path
                    ?? "Suggested name; choose where to save it.",
                action: model.chooseStitchOutput
            )
            .disabled(model.isRunning)

            GroupBox("Output") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 13) {
                    GridRow {
                        Text("Canvas")
                        Picker("Canvas", selection: $model.stitchCanvas) {
                            Text("First clip").tag("first")
                            Text("Largest clip").tag("largest")
                            Text("1080p").tag("1080p")
                            Text("4K").tag("4k")
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Quality")
                        Picker("Quality", selection: $model.stitchProfile) {
                            Text("Conservative").tag("conservative")
                            Text("Balanced").tag("balanced")
                            Text("Compact").tag("compact")
                        }
                        .labelsHidden().pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Encoder")
                        Picker("Encoder", selection: $model.stitchEncoder) {
                            Text("Fast M4 hardware").tag("videotoolbox")
                            Text("Smaller x265").tag("x265")
                        }
                        .labelsHidden().pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Mixed SDR/HDR")
                        Picker(
                            "Mixed SDR/HDR",
                            selection: $model.stitchMixedDynamicRange
                        ) {
                            Text("Separate outputs").tag("split")
                            Text("Tone-map to SDR").tag("sdr")
                        }
                        .labelsHidden().pickerStyle(.segmented)
                    }
                }
                .padding(.top, 6)
            }
            .disabled(model.isRunning)

            HStack {
                Label(
                    model.stitchMixedDynamicRange == "split"
                        ? "Mixed inputs create “-sdr” and “-hdr” files so neither color range is compromised."
                        : "HDR clips are converted to BT.709 SDR when color-aware tone mapping is available; otherwise two outputs are created.",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(AppColors.secondaryText)
                Spacer()
                Button {
                    model.runStitch()
                } label: {
                    HStack(spacing: 7) {
                        if model.runningCombine {
                            ProgressView().controlSize(.small)
                        }
                        Text(
                            model.runningCombine
                                ? "Combining…" : "Combine Videos"
                        )
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !model.canStitchSelection
                        || model.stitchOutput == nil
                        || model.isRunning
                    )
            }
            }
            .onChange(of: model.stitchCanvas) { _, _ in
                model.resetCombineEstimate()
            }
            .onChange(of: model.stitchProfile) { _, _ in
                model.resetCombineEstimate()
            }
            .onChange(of: model.stitchEncoder) { _, _ in
                model.resetCombineEstimate()
            }
            .onChange(of: model.stitchPreset) { _, _ in
                model.resetCombineEstimate()
            }
            .onChange(of: model.stitchMixedDynamicRange) { _, _ in
                model.resetCombineEstimate()
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .topLeading)
        }
    }
}

struct SpaceMapView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var flatSizeRanking = false
    @State private var queueCandidatesOnly = true

    private func flatten(
        _ findings: [SpaceFinding],
        depth: Int = 0
    ) -> [SpaceFindingRow] {
        findings.flatMap { finding in
            [SpaceFindingRow(finding: finding, depth: depth)]
                + flatten(
                    finding.children.sorted { $0.size > $1.size },
                    depth: depth + 1
                )
        }
    }

    private var findings: [SpaceFindingRow] {
        guard let root = model.spaceScan?.root else { return [] }
        let rows = flatten(root.children.sorted { $0.size > $1.size })
        let filtered = rows.filter { row in
            let finding = row.finding
            if queueCandidatesOnly
                && finding.kind != "directory"
                && finding.kind != "video" {
                return false
            }
            guard !searchText.isEmpty else { return true }
            return finding.name.localizedCaseInsensitiveContains(searchText)
                || finding.path.localizedCaseInsensitiveContains(searchText)
        }
        return flatSizeRanking
            ? filtered.sorted { $0.finding.size > $1.finding.size }
            : filtered
    }

    private var selectedVideoPaths: Set<String> {
        guard let root = model.spaceScan?.root else { return [] }
        func selectedPaths(_ node: SpaceFinding) -> [String] {
            let own = model.selectedSpaceFindingIDs.contains(node.id)
                ? node.videoPaths : []
            return own + node.children.flatMap(selectedPaths)
        }
        return Set(selectedPaths(root))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(
                title: "Space Map",
                subtitle: "Scan disk usage and select files or folders."
            )
            HStack {
                Button("Add Folders or Disks…") { model.addSpacePaths() }
                Button("Clear") {
                    model.spacePaths.removeAll()
                    model.spaceScan = nil
                    model.selectedSpaceFindingIDs.removeAll()
                }
                    .disabled(model.spacePaths.isEmpty || model.isRunning)
                Spacer()
                Text("\(model.spacePaths.count) location\(model.spacePaths.count == 1 ? "" : "s")")
                    .foregroundStyle(AppColors.secondaryText)
            }

            if let scan = model.spaceScan {
                HStack(spacing: 16) {
                    Label(
                        model.bytesLabel(scan.root.size),
                        systemImage: "internaldrive"
                    )
                    Text("\(scan.root.files.formatted()) files")
                    if scan.root.errors > 0 {
                        Label(
                            "\(scan.root.errors) unreadable",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(AppColors.warning)
                    }
                    Spacer()
                    TextField("Filter findings", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Toggle("Videos and folders", isOn: $queueCandidatesOnly)
                        .toggleStyle(.checkbox)
                    Toggle("Flat size ranking", isOn: $flatSizeRanking)
                        .toggleStyle(.checkbox)
                }

                List {
                    ForEach(findings) { row in
                        let item = row.finding
                        HStack(spacing: 10) {
                            Button {
                                if model.selectedSpaceFindingIDs.contains(item.id) {
                                    model.selectedSpaceFindingIDs.remove(item.id)
                                } else {
                                    model.selectedSpaceFindingIDs.insert(item.id)
                                }
                            } label: {
                                Image(
                                    systemName: model.selectedSpaceFindingIDs.contains(item.id)
                                        ? "checkmark.square.fill" : "square"
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!item.isQueueSelectable)
                            Image(
                                systemName: item.kind == "directory"
                                    ? "folder.fill"
                                    : (item.kind == "video" ? "film.fill" : "doc.fill")
                            )
                            .foregroundStyle(
                                item.kind == "video"
                                    ? AppColors.warning
                                    : AppColors.secondaryText
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.path)
                                    .font(.caption2)
                                    .foregroundStyle(AppColors.tertiaryText)
                                    .lineLimit(1)
                            }
                            .padding(
                                .leading,
                                flatSizeRanking ? 0 : CGFloat(row.depth * 16)
                            )
                            Spacer()
                            if item.kind == "directory" {
                                Text("\(item.files.formatted()) files")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Text(model.bytesLabel(item.size))
                                .monospacedDigit()
                                .frame(width: 100, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(minHeight: 320)

                HStack {
                    Text(
                        "\(selectedVideoPaths.count.formatted()) unique video\(selectedVideoPaths.count == 1 ? "" : "s") selected"
                    )
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    Button("Clear Selection") {
                        model.selectedSpaceFindingIDs.removeAll()
                    }
                    .disabled(model.selectedSpaceFindingIDs.isEmpty)
                    Spacer()
                    Button("Queue Selection") {
                        model.queueSelectedSpaceFindings()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedVideoPaths.isEmpty || model.isRunning)
                }
            } else {
                List {
                    ForEach(model.spacePaths, id: \.self) { url in
                        HStack {
                            Image(systemName: "externaldrive")
                            VStack(alignment: .leading) {
                                Text(
                                    url.lastPathComponent.isEmpty
                                        ? url.path : url.lastPathComponent
                                )
                                Text(url.path)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.spacePaths.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .overlay {
                    if model.spacePaths.isEmpty {
                        ContentUnavailableView(
                            "Choose what to map",
                            systemImage: "square.3.layers.3d",
                            description: Text("Choose folders or disks.")
                        )
                    }
                }
                .frame(minHeight: 230)
            }

            DisclosureGroup("Scan behavior") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Show logical file sizes instead of allocated disk blocks",
                        isOn: $model.useLogicalSizes
                    )
                    Toggle(
                        "Cross into other mounted filesystems below each root",
                        isOn: $model.crossFilesystems
                    )
                    Label(
                        "Hard links are counted once and symlinks are not followed.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                }
                .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button(model.spaceScan == nil ? "Scan" : "Scan Again") {
                    model.runSpaceMap()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.spacePaths.isEmpty || model.isRunning)
            }
        }
        .padding(28)
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WhatIfView: View {
    @ObservedObject var model: AppModel
    let item: QueueItem
    @Environment(\.dismiss) private var dismiss

    private let profileOrder = ["conservative", "balanced", "compact"]

    private var estimates: [OptionEstimate] {
        (item.whatIf ?? []).sorted {
            let leftProfile = profileOrder.firstIndex(of: $0.profile) ?? 99
            let rightProfile = profileOrder.firstIndex(of: $1.profile) ?? 99
            if leftProfile != rightProfile { return leftProfile < rightProfile }
            let encoderOrder = [
                "x265-veryfast": 0,
                "x265-medium": 1,
                "x265-slow": 2,
                "videotoolbox-medium": 3,
            ]
            return encoderOrder["\($0.encoder)-\($0.preset)", default: 99]
                < encoderOrder["\($1.encoder)-\($1.preset)", default: 99]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare encode options").font(.title2.bold())
                    Text(item.name).font(.headline)
                    Text(
                        "Uses existing scan data."
                    )
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if estimates.isEmpty {
                ContentUnavailableView(
                    "Estimates unavailable",
                    systemImage: "chart.bar.xaxis",
                    description: Text(
                        "Re-plan this queue."
                    )
                )
            } else {
                ScrollView {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 20,
                        verticalSpacing: 8
                    ) {
                        GridRow {
                            Text("Quality").fontWeight(.semibold)
                            Text("Encoder").fontWeight(.semibold)
                            Text("Resolution").fontWeight(.semibold)
                            Text("Output size").fontWeight(.semibold)
                            Text("Savings").fontWeight(.semibold)
                            Text("Total time").fontWeight(.semibold)
                        }
                        Divider().gridCellColumns(6)
                        ForEach(estimates) { estimate in
                            GridRow {
                                HStack(spacing: 5) {
                                    Text(estimate.profile.capitalized)
                                    if estimate.selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AppColors.success)
                                            .help("Current job setting")
                                    }
                                }
                                Text(estimate.encoderLabel)
                                Text(estimate.resolution).monospacedDigit()
                                Text(model.bytesLabel(estimate.projectedBytes))
                                    .monospacedDigit()
                                Text("\(estimate.savingsPct, specifier: "%.1f")%")
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        estimate.savingsPct >= 0 ? AppColors.primaryText : AppColors.warning
                                    )
                                Text(model.durationLabel(estimate.encodeSeconds))
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(14)
                }
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))

                Label(
                    "Actual results may vary.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(24)
        .frame(minWidth: 800, minHeight: 480)
    }
}

struct QueueSummaryCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppColors.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }
}

struct QueueFolderSummary: Identifiable {
    let path: String
    let total: Int
    let selectable: Int
    let included: Int

    var id: String { path }

    var selectionIcon: String {
        if selectable == 0 || included == 0 { return "square" }
        return included == selectable
            ? "checkmark.square.fill" : "minus.square.fill"
    }
}

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var showLog = false
    @State private var whatIfItem: QueueItem?
    @State private var searchText = ""
    @State private var sortOption: QueueSortOption = .savingsBytes
    @State private var statusFilter: QueueStatusFilter = .included
    @State private var showProcessed = false
    @State private var selectedFolder = ""

    private var orderedItems: [QueueItem] {
        (model.queueSession?.items ?? []).sorted { $0.order < $1.order }
    }

    private var selectedItem: QueueItem? {
        guard model.selectedQueueItemIDs.count == 1,
              let id = model.selectedQueueItemIDs.first else { return nil }
        return orderedItems.first { $0.id == id }
    }

    private var selectedItems: [QueueItem] {
        orderedItems.filter { model.selectedQueueItemIDs.contains($0.id) }
    }

    private var pausableItems: [QueueItem] {
        includedItems.filter { ["ready", "encoding"].contains($0.status) }
    }

    private var resumableItems: [QueueItem] {
        includedItems.filter {
            ["paused", "cancelled", "error"].contains($0.status)
                && $0.output != nil
        }
    }

    private var cancellableItems: [QueueItem] {
        includedItems.filter { !$0.isTerminal }
    }

    private var completedItems: [QueueItem] {
        orderedItems.filter { ["complete", "processed"].contains($0.status) }
    }

    private var cancelledItems: [QueueItem] {
        orderedItems.filter { $0.status == "cancelled" }
    }

    private var finishedItems: [QueueItem] {
        orderedItems.filter(\.isTerminal)
    }

    private var currentProgressItem: QueueItem? {
        orderedItems.first { $0.isActive }
            ?? orderedItems.first {
                ["probing", "analyzing"].contains($0.status)
            }
    }

    private func isInFolder(_ item: QueueItem, folder: String) -> Bool {
        guard !folder.isEmpty else { return true }
        let candidate = item.relativeFolder ?? ""
        return candidate == folder || candidate.hasPrefix(folder + "/")
    }

    private var folderSummaries: [QueueFolderSummary] {
        var counts: [String: (total: Int, selectable: Int, included: Int)] = [:]
        for item in orderedItems {
            let components = (item.relativeFolder ?? "")
                .split(separator: "/").map(String.init)
            var ancestors = [""]
            if !components.isEmpty {
                for count in 1...components.count {
                    ancestors.append(
                        components.prefix(count).joined(separator: "/")
                    )
                }
            }
            for folder in ancestors {
                var current = counts[folder] ?? (0, 0, 0)
                current.total += 1
                if item.canChangeInclusion {
                    current.selectable += 1
                    if item.isIncluded { current.included += 1 }
                }
                counts[folder] = current
            }
        }
        return counts.map { path, count in
            QueueFolderSummary(
                path: path,
                total: count.total,
                selectable: count.selectable,
                included: count.included
            )
        }.sorted {
            if $0.path.isEmpty { return true }
            if $1.path.isEmpty { return false }
            return $0.path.localizedStandardCompare($1.path)
                == .orderedAscending
        }
    }

    private var filteredItems: [QueueItem] {
        let filtered = orderedItems.filter { item in
            if !showProcessed
                && statusFilter != .processed
                && item.isProcessed {
                return false
            }
            if !isInFolder(item, folder: selectedFolder) { return false }
            if !searchText.isEmpty
                && !item.name.localizedCaseInsensitiveContains(searchText)
                && !item.path.localizedCaseInsensitiveContains(searchText)
                && !(item.relativePath ?? "").localizedCaseInsensitiveContains(searchText) {
                return false
            }
            switch statusFilter {
            case .all:
                return true
            case .included:
                return item.isIncluded && !item.isProcessed
            case .active:
                return item.isActive
            case .attention:
                return ["error", "cancelled"].contains(item.status)
            case .excluded:
                return !item.isIncluded && !item.isProcessed
            case .processed:
                return item.isProcessed
            }
        }
        return filtered.sorted { left, right in
            switch sortOption {
            case .queue:
                return left.order < right.order
            case .savingsBytes:
                return left.projectedSavingsBytes > right.projectedSavingsBytes
            case .savingsPercent:
                return (left.projectedSavingsPct ?? -1)
                    > (right.projectedSavingsPct ?? -1)
            case .sourceSize:
                return (left.sourceBytes ?? 0) > (right.sourceBytes ?? 0)
            case .encodeTime:
                return (left.projectedEncodeSeconds ?? 0)
                    > (right.projectedEncodeSeconds ?? 0)
            case .name:
                return left.name.localizedStandardCompare(right.name)
                    == .orderedAscending
            case .status:
                return left.status.localizedStandardCompare(right.status)
                    == .orderedAscending
            }
        }
    }

    private var includedItems: [QueueItem] {
        orderedItems.filter { $0.isIncluded && !$0.isProcessed }
    }

    private var processedItems: [QueueItem] {
        orderedItems.filter(\.isProcessed)
    }

    private var projectedSavings: Int64 {
        includedItems.reduce(0) { $0 + $1.projectedSavingsBytes }
    }

    private var actualSavings: Int64 {
        processedItems.reduce(0) { $0 + $1.actualSavingsBytes }
    }

    private var elapsedEncodeTime: Double {
        orderedItems
            .filter { $0.status != "processed" }
            .reduce(0) { $0 + ($1.encodeElapsedSeconds ?? 0) }
    }

    private var projectedEncodeTime: Double {
        includedItems.reduce(0) { $0 + ($1.projectedEncodeSeconds ?? 0) }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "complete": return "checkmark.circle.fill"
        case "processed": return "checkmark.seal.fill"
        case "encoding": return "arrow.up.circle.fill"
        case "verifying": return "checkmark.shield.fill"
        case "paused": return "pause.circle.fill"
        case "skipped": return "forward.end.circle"
        case "cancelled": return "xmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        case "probing", "analyzing": return "magnifyingglass.circle"
        default: return "clock"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "complete", "processed": return AppColors.success
        case "encoding", "verifying": return .accentColor
        case "paused": return AppColors.warning
        case "cancelled", "error": return AppColors.error
        default: return AppColors.secondaryText
        }
    }

    private func itemDetail(_ item: QueueItem) -> String {
        if !item.isIncluded || item.status == "skipped" { return "" }
        guard item.isActive else { return item.message }
        if item.transferProgress != nil { return item.message }
        return String(format: "%.1f%%", item.progress * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Queue").font(.largeTitle.bold())
                Spacer()
                Button("Open Saved Queue…") { model.openQueueSession() }
            }

            if let session = model.queueSession {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name).font(.title3.bold())
                                Text(session.root)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(model.eta).font(.title3.monospacedDigit())
                                Text(model.speed.isEmpty ? "remaining" : "\(model.speed) · remaining")
                                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        let scanProgress = session.scanFraction ?? (
                            ["new", "scanning", "analyzing"].contains(
                                session.status
                            ) ? 0.0 : 1.0
                        )
                        let encodeProgress = session.encodeFraction
                            ?? session.overallFraction
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Scan & analysis")
                                    .font(.caption.bold())
                                Text(
                                    scanProgress >= 1
                                        ? "Complete" : session.displayPhase
                                )
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(1)
                                Spacer()
                                Text(
                                    "\(scanProgress * 100, specifier: "%.1f")%"
                                )
                                .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: scanProgress)
                                .progressViewStyle(.linear)

                            HStack {
                                Text("Batch encoding")
                                    .font(.caption.bold())
                                Text(
                                    scanProgress < 1
                                        ? "Waiting for scan" : session.displayPhase
                                )
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(1)
                                Spacer()
                                Text(
                                    "\(encodeProgress * 100, specifier: "%.1f")%"
                                )
                                .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: encodeProgress)
                                .progressViewStyle(.linear)

                            if let current = currentProgressItem {
                                Divider()
                                HStack {
                                    Text("Current file")
                                        .font(.caption.bold())
                                    Text(current.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(current.status.capitalized)
                                        .font(.caption2.bold())
                                        .foregroundStyle(
                                            statusColor(current.status)
                                        )
                                    Spacer()
                                    if let eta = current.etaSeconds,
                                       current.isActive {
                                        Text(
                                            "ETA \(model.durationLabel(eta))"
                                        )
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(AppColors.secondaryText)
                                    }
                                    Text(
                                        "\(current.progress * 100, specifier: "%.1f")%"
                                    )
                                    .font(.caption.monospacedDigit())
                                }
                                ProgressView(value: current.progress)
                                    .progressViewStyle(.linear)
                            }
                        }
                        HStack {
                            Text(session.summary)
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                            Spacer()
                            Button {
                                model.queueControl("pause")
                            } label: {
                                Label("Pause All", systemImage: "pause.fill")
                            }
                            .disabled(pausableItems.isEmpty)
                            Button {
                                model.queueControl("resume")
                            } label: {
                                Label("Resume All", systemImage: "play.fill")
                            }
                            .disabled(resumableItems.isEmpty)
                            Button(role: .destructive) {
                                model.queueControl("cancel")
                            } label: {
                                Label("Cancel All", systemImage: "xmark")
                            }
                            .disabled(cancellableItems.isEmpty)
                            if !model.isRunning
                                && !["complete", "attention", "running"].contains(session.status)
                                && (
                                    ["new", "scanning", "analyzing", "reviewing"]
                                        .contains(session.status)
                                    || includedItems.contains(where: {
                                        ["ready", "paused", "cancelled", "error"]
                                            .contains($0.status)
                                            && $0.output != nil
                                    })
                                ) {
                                Button(
                                    ["new", "scanning", "analyzing", "reviewing"]
                                        .contains(session.status)
                                        ? "Resume Analysis" : "Resume Queue"
                                ) {
                                    model.resumeQueue()
                                }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                HStack(spacing: 10) {
                    QueueSummaryCard(
                        title: "Included",
                        value: "\(includedItems.count.formatted()) videos",
                        detail: model.bytesLabel(
                            includedItems.reduce(0) { $0 + ($1.sourceBytes ?? 0) }
                        ),
                        systemImage: "checklist"
                    )
                    QueueSummaryCard(
                        title: "Projected savings",
                        value: model.bytesLabel(projectedSavings),
                        detail: "Current selection",
                        systemImage: "internaldrive"
                    )
                    QueueSummaryCard(
                        title: "Saved so far",
                        value: model.bytesLabel(actualSavings),
                        detail: "\(processedItems.count.formatted()) processed",
                        systemImage: "arrow.down.circle"
                    )
                    QueueSummaryCard(
                        title: "Encode time",
                        value: model.durationLabel(elapsedEncodeTime),
                        detail: "~\(model.durationLabel(projectedEncodeTime)) selected",
                        systemImage: "clock"
                    )
                }

                HStack(spacing: 8) {
                    Text(
                        "\(filteredItems.count.formatted()) of \(orderedItems.count.formatted()) videos"
                    )
                    .font(.headline)
                    TextField("Search name or path", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180, maxWidth: 260)
                    Picker("Status", selection: $statusFilter) {
                        ForEach(QueueStatusFilter.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Picker("Sort", selection: $sortOption) {
                        ForEach(QueueSortOption.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    Toggle("Show processed", isOn: $showProcessed)
                        .toggleStyle(.checkbox)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Menu {
                        Button("Include Selected Rows") {
                            model.queueControl(
                                "include", itemIDs: selectedItems.map(\.id)
                            )
                        }
                        .disabled(selectedItems.isEmpty)
                        Button("Exclude Selected Rows") {
                            model.queueControl(
                                "exclude", itemIDs: selectedItems.map(\.id)
                            )
                        }
                        .disabled(selectedItems.isEmpty)
                        Divider()
                        Button("Include All Visible") {
                            model.queueControl(
                                "include", itemIDs: filteredItems.map(\.id)
                            )
                        }
                        .disabled(filteredItems.isEmpty)
                        Button("Exclude All Visible") {
                            model.queueControl(
                                "exclude", itemIDs: filteredItems.map(\.id)
                            )
                        }
                        .disabled(filteredItems.isEmpty)
                        Divider()
                        Button("Include Only Selected Rows") {
                            model.queueControl(
                                "only", itemIDs: selectedItems.map(\.id)
                            )
                        }
                        .disabled(selectedItems.isEmpty)
                    } label: {
                        Label("Selection", systemImage: "checkmark.square")
                    }

                    Button {
                        model.queueControl(
                            "pause", itemIDs: selectedItems.map(\.id)
                        )
                    } label: {
                        Label("Pause", systemImage: "pause")
                    }
                    .disabled(
                        !selectedItems.contains {
                            ["ready", "encoding"].contains($0.status)
                        }
                    )
                    Button {
                        model.queueControl(
                            "resume", itemIDs: selectedItems.map(\.id)
                        )
                    } label: {
                        Label("Resume", systemImage: "play")
                    }
                    .disabled(
                        !selectedItems.contains {
                            ["paused", "cancelled", "error"]
                                .contains($0.status)
                                && $0.output != nil
                        }
                    )
                    Button {
                        model.queueControl(
                            "skip", itemIDs: selectedItems.map(\.id)
                        )
                    } label: {
                        Label("Skip", systemImage: "forward.end")
                    }
                    .disabled(!selectedItems.contains { !$0.isTerminal })
                    Button(role: .destructive) {
                        model.queueControl(
                            "cancel", itemIDs: selectedItems.map(\.id)
                        )
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .disabled(!selectedItems.contains { !$0.isTerminal })

                    if let item = selectedItem {
                        Divider().frame(height: 18)
                        Button {
                            model.moveQueueItem(item.id, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .help("Move earlier")
                        .disabled(
                            sortOption != .queue
                            || item.order == orderedItems.first?.order
                        )
                        Button {
                            model.moveQueueItem(item.id, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .help("Move later")
                        .disabled(
                            sortOption != .queue
                            || item.order == orderedItems.last?.order
                        )
                        Button {
                            whatIfItem = item
                        } label: {
                            Label(
                                "Compare Options",
                                systemImage: "chart.bar.xaxis"
                            )
                        }
                        .disabled((item.whatIf ?? []).isEmpty)
                        if let output = item.output {
                            Button {
                                model.revealQueueOutput(output)
                            } label: {
                                Label("Show Output", systemImage: "folder")
                            }
                        }
                    }
                    Spacer()
                    Button {
                        model.queueControl("clear-completed")
                        model.selectedQueueItemIDs.removeAll()
                    } label: {
                        Label("Clear Completed", systemImage: "trash")
                    }
                    .disabled(
                        completedItems.isEmpty
                            || model.isRunning
                            || session.status == "running"
                    )
                    Menu {
                        Button("Clear Cancelled") {
                            model.queueControl("clear-cancelled")
                            model.selectedQueueItemIDs.removeAll()
                        }
                        .disabled(cancelledItems.isEmpty)
                        Button("Clear Finished") {
                            model.queueControl("clear-finished")
                            model.selectedQueueItemIDs.removeAll()
                        }
                        .disabled(finishedItems.isEmpty)
                        Divider()
                        Button("Clear All", role: .destructive) {
                            model.queueControl("clear-all")
                            model.selectedQueueItemIDs.removeAll()
                        }
                        .disabled(
                            model.isRunning || session.status == "running"
                        )
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                HSplitView {
                    List {
                        ForEach(folderSummaries) { summary in
                            let folder = summary.path
                            let depth = folder.split(separator: "/").count
                            HStack(spacing: 7) {
                                Button {
                                    let action = (
                                        summary.selectable > 0
                                        && summary.included == summary.selectable
                                    ) ? "exclude" : "include"
                                    model.queueControl(
                                        action, folder: folder
                                    )
                                } label: {
                                    Image(
                                        systemName: summary.selectionIcon
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(summary.selectable == 0)
                                Button {
                                    selectedFolder = folder
                                } label: {
                                    HStack {
                                        Image(
                                            systemName: folder.isEmpty
                                                ? "externaldrive.fill"
                                                : "folder.fill"
                                        )
                                        Text(
                                            folder.isEmpty
                                                ? session.name
                                                : URL(
                                                    fileURLWithPath: folder
                                                ).lastPathComponent
                                        )
                                        .lineLimit(1)
                                        Spacer()
                                        Text(summary.total.formatted())
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(
                                .leading,
                                CGFloat(depth * 16)
                            )
                            .listRowBackground(
                                selectedFolder == folder
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear
                            )
                        }
                    }
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)

                    List(selection: $model.selectedQueueItemIDs) {
                        ForEach(filteredItems) { item in
                            HStack(spacing: 10) {
                                Button {
                                    model.queueControl(
                                        item.isIncluded ? "exclude" : "include",
                                        itemID: item.id
                                    )
                                } label: {
                                    Image(
                                        systemName: item.isIncluded
                                            ? "checkmark.square.fill" : "square"
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!item.canChangeInclusion)
                                Image(systemName: statusIcon(item.status))
                                    .font(.title3)
                                    .foregroundStyle(statusColor(item.status))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(item.name)
                                            .fontWeight(.semibold)
                                            .lineLimit(1)
                                        if item.isProcessed {
                                            Text("Processed")
                                                .font(.caption2.bold())
                                                .foregroundStyle(AppColors.success)
                                        } else if !item.isIncluded {
                                            Text("Excluded")
                                                .font(.caption2.bold())
                                                .foregroundStyle(AppColors.secondaryText)
                                        } else {
                                            Text(item.status.capitalized)
                                                .font(.caption2.bold())
                                                .foregroundStyle(
                                                    statusColor(item.status)
                                                )
                                        }
                                    }
                                    Text(item.relativePath ?? item.path)
                                        .font(.caption2)
                                        .foregroundStyle(AppColors.tertiaryText)
                                        .lineLimit(1)
                                    let detail = itemDetail(item)
                                    if !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(AppColors.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let savings = item.projectedSavingsPct {
                                        Text(
                                            "Save ~\(model.bytesLabel(item.projectedSavingsBytes)) · \(savings, specifier: "%.0f")%"
                                        )
                                        .monospacedDigit()
                                    } else if item.isProcessed {
                                        Text(
                                            "Saved \(model.bytesLabel(item.actualSavingsBytes))"
                                        )
                                        .monospacedDigit()
                                    }
                                    Text(
                                        "\(model.bytesLabel(item.sourceBytes)) → \(model.bytesLabel(item.projectedBytes ?? item.outputBytes))"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                                    if !item.isTerminal {
                                        Text(
                                            "~\(model.durationLabel(item.projectedEncodeSeconds ?? item.etaSeconds))"
                                        )
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(AppColors.secondaryText)
                                    }
                                }
                                .frame(width: 215, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            .tag(item.id)
                        }
                    }
                    .overlay {
                        if filteredItems.isEmpty {
                            ContentUnavailableView(
                                orderedItems.isEmpty
                                    && session.status == "scanning"
                                    ? "Scanning…" : "No matching videos",
                                systemImage: "line.3.horizontal.decrease.circle",
                                description: Text(
                                    showProcessed
                                        ? "Change the filters."
                                        : "Processed items are hidden."
                                )
                            )
                        }
                    }
                }
                .frame(minHeight: 310)
            } else {
                ContentUnavailableView(
                    "No queue session yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Prepare a queue in Reclaim.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            DisclosureGroup("Worker log", isExpanded: $showLog) {
                VStack(spacing: 8) {
                    HStack {
                        Spacer()
                        Button("Reveal") { model.revealLog() }
                        Button("Copy") { model.copyLog() }
                        Button("Clear") { model.clearLog() }
                    }
                    ScrollView {
                        Text(model.log.isEmpty ? "Activity will appear here." : model.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(height: 130)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 1150, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $whatIfItem) { item in
            WhatIfView(model: model, item: item)
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.workspaceOperation {
        case .reclaim:
            CompressView(model: model)
        case .combine:
            StitchView(model: model)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(
                    "View",
                    selection: Binding(
                        get: { model.destination },
                        set: { model.destination = $0 }
                    )
                ) {
                    ForEach(AppDestination.allCases) { destination in
                        Text(destination.rawValue).tag(destination)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()

            VStack(spacing: 0) {
                Group {
                    switch model.selection {
                    case .workspace: WorkspaceView(model: model)
                    case .activity: ActivityView(model: model)
                    }
                }
                let hasInlineProgress = model.selection == .activity
                    || (
                        model.selection == .workspace
                        && model.workspaceOperation == .combine
                        && model.combineAttempted
                    )
                if model.isRunning && !hasInlineProgress {
                    RunningBanner(model: model)
                }
            }
        }
        .foregroundStyle(AppColors.primaryText)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            model.stopForApplicationTermination()
        }
    }
}

final class VidReclaimAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}

@main
struct VidReclaimApp: App {
    @NSApplicationDelegateAdaptor(VidReclaimAppDelegate.self)
    private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Show Activity") {
                    model.selection = .activity
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
