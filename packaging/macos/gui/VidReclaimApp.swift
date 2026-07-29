import AppKit
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case compress = "Compress"
    case stitch = "Stitch"
    case space = "Space Map"
    case activity = "Activity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .compress: return "film.stack"
        case .stitch: return "rectangle.3.group"
        case .space: return "square.3.layers.3d"
        case .activity: return "waveform.path.ecg"
        }
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
    @Published var visualReview = true
    @Published var deepVerify = false
    @Published var sourcePolicy: SourcePolicy = .keep

    @Published var stitchInputs: [URL] = []
    @Published var stitchOutput: URL?
    @Published var stitchCanvas = "first"
    @Published var stitchProfile = "balanced"
    @Published var stitchEncoder = "videotoolbox"
    @Published var stitchPreset = "medium"

    @Published var spacePaths: [URL] = []
    @Published var useLogicalSizes = false
    @Published var crossFilesystems = false

    private var process: Process?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    private var jobTitle = ""
    private let logURL: URL

    init() {
        let base = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        logURL = base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VidReclaim.log")
        if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
            log = String(existing.suffix(120_000))
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
        run(
            arguments: ["plan", root.path] + analysisArguments(),
            title: "Planning \(root.lastPathComponent)",
            section: .compress
        )
    }

    func runCompression() {
        guard let root = compressionSource else { return }
        var arguments = ["run", root.path] + analysisArguments()
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
            title: "Compressing \(root.lastPathComponent)",
            section: .compress
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
        return arguments
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
        var arguments = ["space"] + spacePaths.map(\.path)
        if useLogicalSizes { arguments.append("--logical-size") }
        if crossFilesystems { arguments.append("--cross-filesystems") }
        run(
            arguments: arguments,
            title: "Mapping disk usage",
            section: .space
        )
    }

    func moveStitchInput(from index: Int, by offset: Int) {
        let destination = index + offset
        guard stitchInputs.indices.contains(index),
              stitchInputs.indices.contains(destination) else { return }
        stitchInputs.swapAt(index, destination)
    }

    func cancel() {
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
                self.appendLog(
                    "\n\(succeeded ? "Completed successfully." : "Exited with status \(completed.terminationStatus).")\n"
                )
                self.process = nil
                self.outputPipe = nil
            }
        }

        do {
            try newProcess.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            outputPipe = nil
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
                                Text("Faster on M4").tag("videotoolbox")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
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

                GroupBox("Review and disc handling") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle(
                            "Open a side-by-side visual spot check before full encoding",
                            isOn: $model.visualReview
                        )
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
                    Button("Review & Start") {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(
                title: "Space Map",
                subtitle: "Find the folders and files consuming the most space before deciding what to compress."
            )
            HStack {
                Button("Add Folders or Disks…") { model.addSpacePaths() }
                Button("Clear") { model.spacePaths.removeAll() }
                    .disabled(model.spacePaths.isEmpty || model.isRunning)
                Spacer()
                Text("\(model.spacePaths.count) location\(model.spacePaths.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(model.spacePaths, id: \.self) { url in
                    HStack {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                            Text(url.path).font(.caption).foregroundStyle(.secondary)
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
                        description: Text("You can scan multiple folders, external disks, or mounted volumes together.")
                    )
                }
            }
            .frame(minHeight: 230)

            GroupBox("Scan behavior") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show logical file sizes instead of allocated disk blocks", isOn: $model.useLogicalSizes)
                    Toggle("Cross into other mounted filesystems below each root", isOn: $model.crossFilesystems)
                    Label(
                        "Hard links are counted once, symlinks are not followed, and video files are highlighted in orange.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            HStack {
                Text("The interactive treemap opens in your browser when scanning finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Scan & Open Map") { model.runSpaceMap() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.spacePaths.isEmpty || model.isRunning)
            }
        }
        .padding(28)
        .frame(maxWidth: 920, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ActivityView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeading(
                    title: "Activity",
                    subtitle: "Live output, accurate after-sampling estimates, current speed, and safe cancellation."
                )
                Spacer()
                Label(model.engineStatus, systemImage: model.cliPath == nil ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(model.cliPath == nil ? Color.red : Color.green)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.phase).font(.title3.bold())
                            Text(model.jobName.isEmpty ? "No active item" : model.jobName)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(model.eta).font(.title3.monospacedDigit())
                            Text(model.speed.isEmpty ? "ETA" : "\(model.speed) · ETA")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: model.overallProgress) {
                        Text("Whole job")
                    } currentValueLabel: {
                        Text("\(model.overallProgress * 100, specifier: "%.1f")%")
                            .monospacedDigit()
                    }
                    ProgressView(value: model.jobProgress) {
                        Text("Current item")
                    } currentValueLabel: {
                        Text("\(model.jobProgress * 100, specifier: "%.1f")%")
                            .monospacedDigit()
                    }
                }
                .padding(.top, 4)
            }
            HStack {
                Text("Persistent log").font(.headline)
                Spacer()
                Button("Reveal") { model.revealLog() }
                Button("Copy") { model.copyLog() }
                Button("Clear") { model.clearLog() }
                Button("Stop", role: .destructive) { model.cancel() }
                    .disabled(!model.isRunning)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? "Activity will appear here." : model.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .id("log-end")
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .onChange(of: model.log) {
                    proxy.scrollTo("log-end", anchor: .bottom)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 1050, maxHeight: .infinity, alignment: .topLeading)
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
