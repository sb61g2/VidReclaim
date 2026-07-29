import AppKit
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case compress = "Compress"
    case stitch = "Stitch"
    case space = "Space Map"
    case activity = "Queue"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .compress: return "film.stack"
        case .stitch: return "rectangle.3.group"
        case .space: return "square.3.layers.3d"
        case .activity: return "list.bullet.rectangle"
        }
    }
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

struct QueueItem: Codable, Identifiable {
    let id: String
    let order: Int
    let name: String
    let path: String
    let status: String
    let progress: Double
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

    enum CodingKeys: String, CodingKey {
        case id, order, name, path, status, progress, duration, output, message
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
    let etaSeconds: Double?
    let summary: String

    enum CodingKeys: String, CodingKey {
        case id, name, root, status, phase, items, summary
        case sessionPath = "session_path"
        case overallFraction = "overall_fraction"
        case etaSeconds = "eta_seconds"
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
            return "Write verified results to .vidreclaim/output and leave every source untouched."
        case .archive:
            return "Replace files only after verification and move originals to .reclaim-originals."
        case .delete:
            return "Low-disk-space mode. Permanently delete each source only after its result verifies."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarSection = .compress
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
    @Published var minimumSavings = 20.0
    @Published var minimumReclaimMB = 100.0
    @Published var sampleCount = 3
    @Published var sampleSeconds = 10.0
    @Published var nice = 10
    @Published var preserveDVDExtras = false
    @Published var visualReview = false
    @Published var thoroughAnalysis = false
    @Published var deepVerify = false
    @Published var sourcePolicy: SourcePolicy = .keep
    @Published var queueSession: QueueSession?
    @Published var currentSessionURL: URL?
    @Published var selectedQueueItemIDs = Set<String>()

    @Published var stitchInputs: [URL] = []
    @Published var stitchOutput: URL?
    @Published var stitchCanvas = "first"
    @Published var stitchProfile = "balanced"
    @Published var stitchEncoder = "videotoolbox"
    @Published var stitchPreset = "medium"

    @Published var spacePaths: [URL] = []
    @Published var useLogicalSizes = false
    @Published var crossFilesystems = false
    @Published var spaceScan: SpaceScanResult?
    @Published var selectedSpaceFindingIDs = Set<String>()

    private var process: Process?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    private var jobTitle = ""
    private var runningQueue = false
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

    var engineStatus: String {
        cliPath == nil ? "Engine not found" : "Engine ready"
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
            for url in panel.urls where !stitchInputs.contains(url) {
                stitchInputs.append(url)
            }
        }
    }

    func chooseStitchOutput() {
        let panel = NSSavePanel()
        panel.title = "Save stitched video"
        panel.prompt = "Choose"
        panel.nameFieldStringValue = stitchOutput?.lastPathComponent ?? "stitched-video.mkv"
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.isEmpty {
                url.appendPathExtension("mkv")
            }
            stitchOutput = url
        }
    }

    func addSpacePaths() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders, disks, or volumes to map"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !spacePaths.contains(url) {
                spacePaths.append(url)
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
        UserDefaults.standard.set(session.path, forKey: "VidReclaimCurrentSession")
        var arguments = [
            "queue-start", root.path, "--session", session.path, "--plan-only",
        ] + analysisArguments()
        if visualReview { arguments.append("--review") }
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
            section: .activity
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
        UserDefaults.standard.set(session.path, forKey: "VidReclaimCurrentSession")
        var arguments = [
            "queue-start", root.path, "--session", session.path,
        ] + analysisArguments()
        if visualReview { arguments.append("--review") }
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
            section: .activity
        )
    }

    private func analysisArguments() -> [String] {
        var arguments = [
            "--profile", compressionProfile,
            "--encoder", compressionEncoder,
            "--preset", compressionPreset,
            "--min-savings", String(format: "%.1f", minimumSavings),
            "--min-reclaim-mb", String(format: "%.0f", minimumReclaimMB),
            "--samples", String(sampleCount),
            "--sample-seconds", String(format: "%.1f", sampleSeconds),
            "--nice", String(nice),
        ]
        if preserveDVDExtras { arguments.append("--keep-dvd-extras") }
        if thoroughAnalysis || visualReview {
            arguments.append("--thorough-analysis")
        }
        return arguments
    }

    func resumeQueue() {
        guard let session = currentSessionURL else { return }
        run(
            arguments: ["queue-resume", session.path],
            title: "Resuming \(queueSession?.name ?? "queue")",
            section: .activity
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
        control.standardOutput = FileHandle.nullDevice
        control.standardError = FileHandle.nullDevice
        control.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.loadQueueSession()
                if action == "resume", self?.isRunning == false {
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
        loadQueueSession()
        selection = .activity
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
        overallProgress = session.overallFraction
        phase = session.phase
        eta = durationLabel(session.etaSeconds)
        if let active = session.items.first(where: { $0.isActive }) {
            jobName = active.name
            jobProgress = active.progress
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
        guard stitchInputs.count >= 2, let output = stitchOutput else { return }
        let arguments = [
            "stitch", output.path,
        ] + stitchInputs.map(\.path) + [
            "--canvas", stitchCanvas,
            "--profile", stitchProfile,
            "--encoder", stitchEncoder,
            "--preset", stitchPreset,
            "--nice", String(nice),
        ]
        run(
            arguments: arguments,
            title: "Stitching \(stitchInputs.count) clips",
            section: .stitch
        )
    }

    func runSpaceMap() {
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
            section: .space
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

    func queueSelectedSpaceFindings() {
        guard let scan = spaceScan else { return }
        let findings = selectedSpaceFindingIDs.compactMap {
            finding(withID: $0, in: scan.root)
        }
        let videoPaths = Array(
            Set(findings.flatMap(\.videoPaths))
        ).sorted()
        guard !videoPaths.isEmpty else {
            appendLog("Choose at least one video or a folder containing videos.\n")
            return
        }
        let videoURLs = videoPaths.map(URL.init(fileURLWithPath:))
        let root = spacePaths.first { candidate in
            let prefix = candidate.standardizedFileURL.path.hasSuffix("/")
                ? candidate.standardizedFileURL.path
                : candidate.standardizedFileURL.path + "/"
            return videoURLs.allSatisfy {
                $0.standardizedFileURL.path == candidate.standardizedFileURL.path
                || $0.standardizedFileURL.path.hasPrefix(prefix)
            }
        }
        guard let root else {
            appendLog(
                "Queue selections must be inside one scanned location so folder structure remains unambiguous.\n"
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
        UserDefaults.standard.set(session.path, forKey: "VidReclaimCurrentSession")
        var arguments = [
            "queue-start", root.path, "--session", session.path, "--plan-only",
        ] + videoPaths.flatMap { ["--include-path", $0] } + analysisArguments()
        if visualReview { arguments.append("--review") }
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
            section: .activity
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
    }

    func moveStitchInput(from index: Int, by offset: Int) {
        let destination = index + offset
        guard stitchInputs.indices.contains(index),
              stitchInputs.indices.contains(destination) else { return }
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
                    self.phase = succeeded ? "Complete" : (
                        completed.terminationStatus == 130 ? "Cancelled" : "Needs attention"
                    )
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
            }
        }

        do {
            try newProcess.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            outputPipe = nil
            runningQueue = false
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
        if line.hasPrefix("Plan:") {
            lastSummary = line
            phase = "Plan ready"
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
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
            Text(subtitle).foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !model.speed.isEmpty {
                    Text(model.speed).monospacedDigit().foregroundStyle(.secondary)
                }
                Label(model.eta, systemImage: "clock")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Stop", role: .destructive) { model.cancel() }
            }
            ProgressView(value: model.overallProgress)
                .progressViewStyle(.linear)
        }
        .padding(12)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

struct CompressView: View {
    @ObservedObject var model: AppModel
    @State private var confirmDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(
                    title: "Compress",
                    subtitle: "Find wasteful encodes, preserve worthwhile detail, and skip files that will not reclaim enough space."
                )
                PathChooser(
                    title: model.compressionSource?.lastPathComponent ?? "Choose your media",
                    detail: model.compressionSource?.path
                        ?? "A file, folder, VIDEO_TS rip, mounted disk, or volume.",
                    action: model.chooseCompressionSource
                )

                GroupBox("Quality and speed") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 13) {
                        GridRow {
                            Text("Quality profile")
                            Picker("Quality profile", selection: $model.compressionProfile) {
                                Text("Conservative").tag("conservative")
                                Text("Balanced").tag("balanced")
                                Text("Compact").tag("compact")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        GridRow {
                            Text("Encoder")
                            Picker("Encoder", selection: $model.compressionEncoder) {
                                Text("Smaller files (x265)").tag("x265")
                                Text("Faster on M4 (hardware)").tag("videotoolbox")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            Text(
                                model.compressionEncoder == "videotoolbox"
                                ? "Usually finishes about 4–8× sooner than x265 Medium on an M4, while often using 15–35% more space at similar casual-viewing quality."
                                : "Usually takes about 4–8× longer than the M4 hardware encoder, but often produces files 15–35% smaller at similar casual-viewing quality."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        if model.compressionEncoder == "x265" {
                            GridRow {
                                Text("x265 preset")
                                Picker("x265 preset", selection: $model.compressionPreset) {
                                    ForEach(
                                        ["veryfast", "faster", "fast", "medium", "slow"],
                                        id: \.self
                                    ) { Text($0.capitalized).tag($0) }
                                }
                                .labelsHidden()
                            }
                        }
                        GridRow {
                            Text("Keep Mac responsive")
                            Stepper(
                                "Niceness \(model.nice) \(model.nice == 0 ? "(full speed)" : "")",
                                value: $model.nice, in: 0...20
                            )
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Worthwhile-work threshold") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 13) {
                        GridRow {
                            Text("Minimum savings")
                            HStack {
                                Slider(value: $model.minimumSavings, in: 5...50, step: 1)
                                Text("\(model.minimumSavings, specifier: "%.0f")%")
                                    .monospacedDigit().frame(width: 42, alignment: .trailing)
                            }
                        }
                        GridRow {
                            Text("Minimum reclaim")
                            HStack {
                                Slider(value: $model.minimumReclaimMB, in: 25...2000, step: 25)
                                Text("\(model.minimumReclaimMB, specifier: "%.0f") MiB")
                                    .monospacedDigit().frame(width: 74, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Fast scan, optional review, and disc handling") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle(
                            "Thorough visual analysis (trial encodes and XPSNR)",
                            isOn: $model.thoroughAnalysis
                        )
                        Toggle(
                            "Generate an optional side-by-side visual spot check",
                            isOn: $model.visualReview
                        )
                        Text(
                            model.visualReview
                            ? "SBS review enables thorough analysis automatically and takes longer."
                            : "Fast mode trusts VidReclaim’s metadata intelligence, parallelizes probes, and reuses cached results. No trial clips or screenshots are made."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Toggle("Decode every output frame during verification", isOn: $model.deepVerify)
                        Toggle(
                            "Preserve DVD trailers, menus, and extras",
                            isOn: $model.preserveDVDExtras
                        )
                        if !model.preserveDVDExtras {
                            Label(
                                "Main-content-only mode is on. Movie features and episode-length title groups are retained.",
                                systemImage: "checkmark.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if model.thoroughAnalysis || model.visualReview {
                            DisclosureGroup("Sampling details") {
                                HStack {
                                    Stepper(
                                        "\(model.sampleCount) samples per title",
                                        value: $model.sampleCount, in: 1...3
                                    )
                                    Spacer()
                                    Stepper(
                                        "\(model.sampleSeconds, specifier: "%.0f") seconds each",
                                        value: $model.sampleSeconds, in: 4...30, step: 1
                                    )
                                }
                                .padding(.top, 6)
                            }
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("After each verified encode") {
                    VStack(alignment: .leading, spacing: 9) {
                        Picker("Source handling", selection: $model.sourcePolicy) {
                            ForEach(SourcePolicy.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        Text(model.sourcePolicy.detail)
                            .font(.caption)
                            .foregroundStyle(
                                model.sourcePolicy == .delete ? Color.orange : Color.secondary
                            )
                    }
                    .padding(.top, 6)
                }

                HStack {
                    Button("Plan Only") { model.runPlan() }
                        .disabled(model.compressionSource == nil || model.isRunning)
                    Spacer()
                    if model.lastSummary != "No plan has been run yet." {
                        Text(model.lastSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Button(model.visualReview ? "Review & Start Queue" : "Start Queue") {
                        if model.sourcePolicy == .delete {
                            confirmDeletion = true
                        } else {
                            model.runCompression()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.compressionSource == nil || model.isRunning)
                }
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .alert("Permanently delete verified sources?", isPresented: $confirmDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Start and Delete", role: .destructive) { model.runCompression() }
        } message: {
            Text(
                "Each source will be deleted only after its replacement passes verification and the actual savings threshold. This cannot be undone; keep a backup if the media matters."
            )
        }
    }
}

struct StitchView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(
                title: "Stitch",
                subtitle: "Join mixed clips in order. VidReclaim normalizes their size, frame rate, and audio, then adds chapter markers."
            )
            HStack {
                Button("Add Clips or Folders…") { model.addStitchInputs() }
                Button("Clear") { model.stitchInputs.removeAll() }
                    .disabled(model.stitchInputs.isEmpty || model.isRunning)
                Spacer()
                Text("\(model.stitchInputs.count) selected")
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(model.stitchInputs.enumerated()), id: \.element) { index, url in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 25, alignment: .trailing)
                        Image(systemName: url.hasDirectoryPath ? "folder" : "film")
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { model.moveStitchInput(from: index, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain).disabled(index == 0)
                        Button { model.moveStitchInput(from: index, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain).disabled(index == model.stitchInputs.count - 1)
                        Button(role: .destructive) {
                            model.stitchInputs.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if model.stitchInputs.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add at least two files or folders. Folder contents use natural filename order.")
                    )
                }
            }
            .frame(minHeight: 190)

            PathChooser(
                title: model.stitchOutput?.lastPathComponent ?? "Choose an output file",
                detail: model.stitchOutput?.path ?? "MKV, MP4, M4V, or MOV.",
                action: model.chooseStitchOutput
            )

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
                }
                .padding(.top, 6)
            }

            HStack {
                Label(
                    "Mixed HDR and SDR clips are intentionally refused to avoid incorrect color conversion.",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stitch Video") { model.runStitch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.stitchInputs.count < 2
                        || model.stitchOutput == nil
                        || model.isRunning
                    )
            }
        }
        .padding(28)
        .frame(maxWidth: 920, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SpaceMapView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var largestFirst = true
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
        return largestFirst
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
                subtitle: "Find large media, select files or folders, and prepare a queue without scanning the whole library again."
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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.orange)
                    }
                    Spacer()
                    TextField("Filter findings", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Toggle("Videos and folders", isOn: $queueCandidatesOnly)
                        .toggleStyle(.checkbox)
                    Toggle("Largest first", isOn: $largestFirst)
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
                                item.kind == "video" ? .orange : .secondary
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(
                                .leading,
                                largestFirst ? 0 : CGFloat(row.depth * 12)
                            )
                            Spacer()
                            if item.kind == "directory" {
                                Text("\(item.files.formatted()) files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                                    .foregroundStyle(.secondary)
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
                            description: Text(
                                "Scan folders, external disks, or mounted volumes."
                            )
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
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            HStack {
                Text("Results stay in the app and can feed a queue directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        "Instant metadata estimates—no additional probing, samples, or test encodes."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        "This session predates the what-if estimator. Re-plan it to compare options."
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
                                            .foregroundStyle(.green)
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
                                        estimate.savingsPct >= 0 ? Color.primary : Color.orange
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
                    "These are planning estimates, not guarantees. Grain, motion, HDR, and source complexity can change actual size and speed; live ETA corrects itself during encoding.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
    @State private var statusFilter: QueueStatusFilter = .all
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
        case "complete", "processed": return .green
        case "encoding", "verifying": return .accentColor
        case "paused": return .orange
        case "cancelled", "error": return .red
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeading(
                    title: "Queue",
                    subtitle: "Persistent per-video controls with reboot-resumable sessions."
                )
                Spacer()
                Button("Open Saved Queue…") { model.openQueueSession() }
                Label(model.engineStatus, systemImage: model.cliPath == nil ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(model.cliPath == nil ? Color.red : Color.green)
            }

            if let session = model.queueSession {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name).font(.title3.bold())
                                Text(session.root)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(model.eta).font(.title3.monospacedDigit())
                                Text(model.speed.isEmpty ? "remaining" : "\(model.speed) · remaining")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: session.overallFraction) {
                            Text(session.phase)
                        } currentValueLabel: {
                            Text("\(session.overallFraction * 100, specifier: "%.1f")%")
                                .monospacedDigit()
                        }
                        HStack {
                            Text(session.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                model.queueControl("pause")
                            } label: {
                                Label("Pause All", systemImage: "pause.fill")
                            }
                            Button {
                                model.queueControl("resume")
                            } label: {
                                Label("Resume All", systemImage: "play.fill")
                            }
                            Button(role: .destructive) {
                                model.queueControl("cancel")
                            } label: {
                                Label("Cancel All", systemImage: "xmark")
                            }
                            if !model.isRunning
                                && !["complete", "attention", "running"].contains(session.status) {
                                Button("Resume Session") { model.resumeQueue() }
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
                    .disabled(selectedItems.isEmpty)
                    Button {
                        model.queueControl(
                            "resume", itemIDs: selectedItems.map(\.id)
                        )
                    } label: {
                        Label("Resume", systemImage: "play")
                    }
                    .disabled(selectedItems.isEmpty)
                    Button {
                        model.queueControl(
                            "skip", itemIDs: selectedItems.map(\.id)
                        )
                    } label: {
                        Label("Skip", systemImage: "forward.end")
                    }
                    .disabled(selectedItems.isEmpty)
                    Button(role: .destructive) {
                        model.queueControl(
                            "cancel", itemIDs: selectedItems.map(\.id)
                        )
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .disabled(selectedItems.isEmpty)

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
                    }
                    Spacer()
                    Menu {
                        Button("Clear Completed") {
                            model.queueControl("clear-completed")
                            model.selectedQueueItemIDs.removeAll()
                        }
                        Button("Clear Cancelled") {
                            model.queueControl("clear-cancelled")
                            model.selectedQueueItemIDs.removeAll()
                        }
                        Button("Clear All Finished") {
                            model.queueControl("clear-finished")
                            model.selectedQueueItemIDs.removeAll()
                        }
                        Divider()
                        Button("Clear Queue", role: .destructive) {
                            model.queueControl("clear-all")
                            model.selectedQueueItemIDs.removeAll()
                        }
                        .disabled(
                            model.isRunning || session.status == "running"
                        )
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }

                HSplitView {
                    List {
                        ForEach(folderSummaries) { summary in
                            let folder = summary.path
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
                                        Image(systemName: "folder")
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
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(
                                .leading,
                                CGFloat(
                                    max(
                                        0,
                                        folder.split(separator: "/").count - 1
                                    ) * 12
                                )
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
                                                .foregroundStyle(.green)
                                        } else if !item.isIncluded {
                                            Text("Excluded")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    if item.isActive {
                                        ProgressView(value: item.progress)
                                            .progressViewStyle(.linear)
                                    } else {
                                        Text(item.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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
                                    .foregroundStyle(.secondary)
                                    if !item.isTerminal {
                                        Text(
                                            "~\(model.durationLabel(item.projectedEncodeSeconds ?? item.etaSeconds))"
                                        )
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
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
                                    ? "Scanning quickly…" : "No matching videos",
                                systemImage: "line.3.horizontal.decrease.circle",
                                description: Text(
                                    showProcessed
                                        ? "Adjust the folder, search, or status filter."
                                        : "Processed items are hidden by default."
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
                    description: Text("Choose media in Compress, then start a queue.")
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

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("VidReclaim")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(model.engineStatus, systemImage: model.cliPath == nil ? "xmark.circle" : "checkmark.circle")
                    Text("Personal media toolkit")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch model.selection {
                    case .compress: CompressView(model: model)
                    case .stitch: StitchView(model: model)
                    case .space: SpaceMapView(model: model)
                    case .activity: ActivityView(model: model)
                    }
                }
                if model.isRunning {
                    RunningBanner(model: model)
                }
            }
        }
    }
}

@main
struct VidReclaimApp: App {
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
