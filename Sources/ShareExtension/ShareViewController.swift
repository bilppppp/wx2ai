import Cocoa
import UniformTypeIdentifiers

// To satisfy protocol declaration requirements in Swift 6 where NSViewController
// already inherits conformance to Foundation.NSExtensionRequestHandling in AppKit.
private protocol _CustomShareExtHandling {}
private typealias NSExtensionRequestHandling = _CustomShareExtHandling

@objc(ShareViewController)
final class ShareViewController: NSViewController, NSExtensionRequestHandling {

    private var activeExtensionContext: NSExtensionContext?
    private var hasStartedHandling = false
    private var watchdogWorkItem: DispatchWorkItem?

    override func loadView() {
        self.view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startHandlingIfNeeded(source: "viewDidLoad")
    }

    override func beginRequest(with context: NSExtensionContext) {
        // Do NOT call super.beginRequest(with: context).
        // In AppKit, NSViewController.beginRequest attempts to load a nib and present a sheet,
        // which fails when there is no nib.
        self.activeExtensionContext = context
        startHandlingIfNeeded(source: "beginRequest")
    }

    private func startHandlingIfNeeded(source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.hasStartedHandling else { return }
            guard let context = self.activeExtensionContext ?? self.extensionContext else {
                self.log("Context not available yet from \(source), waiting for beginRequest...")
                return
            }
            self.activeExtensionContext = context
            self.hasStartedHandling = true
            self.log("Starting handling with context from source: \(source).")

            // 10-second watchdog timer to complete request if hanging
            let watchdog = DispatchWorkItem { [weak self, weak context] in
                guard let self = self, let context = context else { return }
                self.log("Watchdog timer triggered (10s timeout reached). Completing request.")
                self.finish(context: context, success: false)
            }
            self.watchdogWorkItem = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: watchdog)

            self.handleSharedItems(context: context)
        }
    }

    private func handleSharedItems(context: NSExtensionContext) {
        log("Inspecting input items. Count: \(context.inputItems.count)")

        guard let inputItems = context.inputItems as? [NSExtensionItem], !inputItems.isEmpty else {
            log("No input items present in extension context.")
            finish(context: context, success: false)
            return
        }

        let candidateTypes = [
            "public.zip-archive",
            "com.pkware.zip-archive",
            "public.file-url",
            "public.data"
        ]

        var targetProvider: NSItemProvider?
        var matchedType: String?

        outerLoop: for type in candidateTypes {
            for item in inputItems {
                guard let attachments = item.attachments else { continue }
                for provider in attachments {
                    if provider.hasItemConformingToTypeIdentifier(type) {
                        targetProvider = provider
                        matchedType = type
                        break outerLoop
                    }
                }
            }
        }

        guard let provider = targetProvider, let typeIdentifier = matchedType else {
            log("No attachment conforming to zip/file-url/data found.")
            finish(context: context, success: false)
            return
        }

        log("Found candidate attachment conforming to: \(typeIdentifier)")

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] (secureCodingItem, error) in
            guard let self = self else { return }
            if let error = error {
                self.log("Error loading item with identifier \(typeIdentifier): \(error.localizedDescription)")
                self.finish(context: context, success: false)
                return
            }

            self.resolveAndForward(item: secureCodingItem, context: context)
        }
    }

    private func resolveAndForward(item: NSSecureCoding?, context: NSExtensionContext) {
        guard let item = item else {
            log("Loaded secureCodingItem is nil.")
            finish(context: context, success: false)
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-share", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            log("Failed to create tempDir at \(tempDir.path): \(error.localizedDescription)")
        }

        let destinationZipURL = tempDir.appendingPathComponent("\(UUID().uuidString)-wechat-chat-history.zip")
        var copiedSuccessfully = false

        if let url = item as? URL ?? (item as? NSURL as URL?) {
            log("Item resolved as URL: \(url.path)")
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                if FileManager.default.fileExists(atPath: destinationZipURL.path) {
                    try FileManager.default.removeItem(at: destinationZipURL)
                }
                if url.isFileURL {
                    try FileManager.default.copyItem(at: url, to: destinationZipURL)
                    copiedSuccessfully = true
                    log("Copied shared file URL to \(destinationZipURL.path)")
                } else if let data = try? Data(contentsOf: url) {
                    try data.write(to: destinationZipURL, options: .atomic)
                    copiedSuccessfully = true
                    log("Wrote URL data (\(data.count) bytes) to \(destinationZipURL.path)")
                }
            } catch {
                log("Failed copying URL: \(error.localizedDescription)")
            }
        } else if let data = item as? Data ?? (item as? NSData as Data?) {
            log("Item resolved as Data (\(data.count) bytes)")
            let isZipMagic = data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B // "PK"

            if isZipMagic {
                // Direct ZIP archive binary payload
                do {
                    if FileManager.default.fileExists(atPath: destinationZipURL.path) {
                        try FileManager.default.removeItem(at: destinationZipURL)
                    }
                    try data.write(to: destinationZipURL, options: .atomic)
                    copiedSuccessfully = true
                    log("Wrote raw ZIP Data to \(destinationZipURL.path)")
                } catch {
                    log("Failed writing ZIP Data: \(error.localizedDescription)")
                }
            } else if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                // AppKit often passes file URLs encoded as UTF-8 Data rather than a URL object
                log("Data does not have PK magic; decoded as UTF-8 string: \(str)")
                let fileURL: URL
                if str.hasPrefix("file://") {
                    fileURL = URL(string: str) ?? URL(fileURLWithPath: str)
                } else {
                    fileURL = URL(fileURLWithPath: str)
                }

                if fileURL.isFileURL || FileManager.default.fileExists(atPath: fileURL.path) {
                    let isScoped = fileURL.startAccessingSecurityScopedResource()
                    defer {
                        if isScoped {
                            fileURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    do {
                        if FileManager.default.fileExists(atPath: destinationZipURL.path) {
                            try FileManager.default.removeItem(at: destinationZipURL)
                        }
                        try FileManager.default.copyItem(at: fileURL, to: destinationZipURL)
                        copiedSuccessfully = true
                        log("Copied file from decoded URL string \(fileURL.path) to \(destinationZipURL.path)")
                    } catch {
                        log("Failed copying from decoded file URL: \(error.localizedDescription)")
                    }
                } else {
                    log("Decoded string path does not exist: \(str)")
                }
            } else {
                log("Data does not match ZIP magic and cannot be decoded as UTF-8 string.")
            }
        } else if let str = item as? String ?? (item as? NSString as String?) {
            log("Item resolved as String: \(str)")
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceURL: URL
            if trimmed.hasPrefix("file://") {
                sourceURL = URL(string: trimmed) ?? URL(fileURLWithPath: trimmed)
            } else {
                sourceURL = URL(fileURLWithPath: trimmed)
            }
            let isScoped = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if isScoped {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            do {
                if FileManager.default.fileExists(atPath: destinationZipURL.path) {
                    try FileManager.default.removeItem(at: destinationZipURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationZipURL)
                copiedSuccessfully = true
                log("Copied from string path to \(destinationZipURL.path)")
            } catch {
                log("Failed copying from string path: \(error.localizedDescription)")
            }
        } else {
            log("Item type not supported: \(type(of: item))")
        }

        guard copiedSuccessfully, FileManager.default.fileExists(atPath: destinationZipURL.path) else {
            log("Failed to resolve item into valid zip file at \(destinationZipURL.path)")
            finish(context: context, success: false)
            return
        }

        // Derive Host App bundle identifier by stripping the last .WechatShare component
        guard let bundleId = Bundle.main.bundleIdentifier else {
            log("Extension bundle identifier is nil")
            finish(context: context, success: false)
            return
        }

        let hostBundleId: String
        if bundleId.hasSuffix(".WechatShare") {
            hostBundleId = String(bundleId.dropLast(".WechatShare".count))
        } else if let dotRange = bundleId.range(of: ".WechatShare", options: .backwards) {
            hostBundleId = String(bundleId[..<dotRange.lowerBound])
        } else {
            let comps = bundleId.split(separator: ".")
            hostBundleId = comps.count > 1 ? comps.dropLast().joined(separator: ".") : bundleId
        }
        log("Derived Host App bundle identifier: \(hostBundleId)")

        var hostAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostBundleId)
        if hostAppURL == nil {
            // Fallback: 3 levels up (Contents/PlugIns/WechatShare.appex -> HostApp.app)
            let fallbackURL = Bundle.main.bundleURL
                .deletingLastPathComponent() // PlugIns
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // App
            if FileManager.default.fileExists(atPath: fallbackURL.path) && fallbackURL.pathExtension == "app" {
                hostAppURL = fallbackURL
                log("Found Host App via relative bundle hierarchy: \(fallbackURL.path)")
            }
        }

        guard let targetHostURL = hostAppURL else {
            log("Could not locate Host App URL for \(hostBundleId)")
            finish(context: context, success: false)
            return
        }

        log("Opening \(destinationZipURL.path) with Host App at \(targetHostURL.path)")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        NSWorkspace.shared.open([destinationZipURL], withApplicationAt: targetHostURL, configuration: config) { [weak self] (runningApp, error) in
            guard let self = self else { return }
            if let error = error {
                self.log("Failed to open Host App: \(error.localizedDescription)")
                self.finish(context: context, success: false)
            } else {
                self.log("Successfully opened Host App (PID: \(runningApp?.processIdentifier ?? 0))")
                self.finish(context: context, success: true)
            }
        }
    }

    private func finish(context: NSExtensionContext, success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogWorkItem?.cancel()
            self?.watchdogWorkItem = nil

            // Always completeRequest with returningItems: [] so WeChat does not show an error dialog
            self?.log("Calling context.completeRequest (success=\(success)).")
            context.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func log(_ message: String) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let logFile = tempDir.appendingPathComponent("wechat-share.log")

        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [ShareExt] \(message)\n"
        NSLog("%@", line)

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile, options: .atomic)
            }
        }
    }
}
