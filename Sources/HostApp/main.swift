import Cocoa
import CryptoKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var targetAppName: String = "转发到 Antigravity"
    private(set) var targetAppBundleID: String = "com.google.antigravity"
    private(set) var targetAppFallbackPath: String = "/Applications/Antigravity.app"
    private(set) var autoPasteMode: String = "keystroke"

    private var hasReceivedFiles = false
    private var processedFilePaths = Set<String>()

    override init() {
        super.init()
        loadConfiguration()
    }

    private func loadConfiguration() {
        if let info = Bundle.main.infoDictionary {
            if let name = info["TargetAppName"] as? String, !name.isEmpty {
                targetAppName = name
            }
            if let bundleID = info["TargetAppBundleID"] as? String {
                targetAppBundleID = bundleID
            }
            if let path = info["TargetAppFallbackPath"] as? String {
                targetAppFallbackPath = path
            }
            if let mode = info["AutoPasteMode"] as? String, !mode.isEmpty {
                autoPasteMode = mode.lowercased()
            }
        }
        NSLog("[HostApp] TargetApp: %@, BundleID: %@, FallbackPath: %@, AutoPasteMode: %@",
              targetAppName, targetAppBundleID, targetAppFallbackPath, autoPasteMode)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register embedded Share Extension with pluginkit
        registerEmbeddedExtension()

        // Check if any zip files were passed via command line arguments
        var cliZipUrls: [URL] = []
        for arg in CommandLine.arguments.dropFirst() {
            if arg.hasPrefix("-") { continue }
            let url = URL(fileURLWithPath: arg)
            if url.pathExtension.lowercased() == "zip" && FileManager.default.fileExists(atPath: url.path) {
                cliZipUrls.append(url)
            }
        }

        if !cliZipUrls.isEmpty {
            hasReceivedFiles = true
            for url in cliZipUrls {
                processZipFile(at: url)
            }
        }

        // Watchdog: If launched directly by user without files after 1.5s, notify/alert ready and quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if !self.hasReceivedFiles {
                self.showReadyAlertAndTerminate()
            }
        }
    }

    private func registerEmbeddedExtension() {
        let appexURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/WechatShare.appex")
        let appexPath = appexURL.path

        guard FileManager.default.fileExists(atPath: appexPath) else {
            NSLog("[HostApp] Embedded extension not found at %@", appexPath)
            return
        }

        let appexBundleId = (Bundle.main.bundleIdentifier ?? "io.github.bilppppp.wx2ai") + ".WechatShare"
        NSLog("[HostApp] Registering Share Extension with pluginkit: %@ (%@)", appexPath, appexBundleId)

        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        addProcess.arguments = ["-a", appexPath]
        try? addProcess.run()
        addProcess.waitUntilExit()

        let enableProcess = Process()
        enableProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        enableProcess.arguments = ["-e", "use", "-i", appexBundleId]
        try? enableProcess.run()
        enableProcess.waitUntilExit()
    }

    private func showReadyAlertAndTerminate() {
        NSLog("[HostApp] Launched directly without files. Showing ready status.")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if autoPasteMode == "clipboard" || targetAppBundleID == "clipboard" {
            let alert = NSAlert()
            alert.messageText = "微信「转发到剪贴板」扩展已就绪"
            alert.informativeText = """
            微信「转发到剪贴板」扩展已成功注册并启用！

            无需额外配置辅助功能权限。

            使用方式：
            1. 在微信中选择聊天记录，点击「转发」
            2. 在分享列表中选择「转发到剪贴板」
            3. 系统将自动解压、提取记录生成 Prompt 存入剪贴板，并在右上角通知提示。
            4. 您可以在任意 AI 客户端（Antigravity、ChatGPT/Codex、Claude 等）中按 ⌘V 直接粘贴！
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好的")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let a11yOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(a11yOptions)
        let a11yStatus = isTrusted ? "✅ 已授权（转发后自动完成 ⌘V 粘贴）" : "⚠️ 未授权（已弹出授权提示；授权后可免按 ⌘V，当前仍可手动 ⌘V 粘贴）"

        let alertTitle = targetAppName.hasPrefix("转发到") ? "微信「\(targetAppName)」扩展已就绪" : "\(targetAppName) 微信转发扩展已就绪"
        let alert = NSAlert()
        alert.messageText = alertTitle
        alert.informativeText = """
        微信转发扩展已成功注册并启用！

        辅助功能自动粘贴权限：\(a11yStatus)

        使用方式：
        1. 在微信中选择聊天记录，点击「转发」
        2. 在分享列表中选择「\(targetAppName)」
        3. 系统将自动解压、提取记录生成 Prompt，并在 \(targetAppName) 中自动粘贴！

        系统设置管理入口：
        • 分享菜单：「系统设置 -> 隐私与安全性 -> 扩展 -> 分享菜单」
        • 辅助功能：「系统设置 -> 隐私与安全性 -> 辅助功能」
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()

        NSApp.terminate(nil)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        let zipUrls = urls.filter { $0.pathExtension.lowercased() == "zip" }
        guard !zipUrls.isEmpty else { return }
        hasReceivedFiles = true
        for url in zipUrls {
            processZipFile(at: url)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let zipUrls = filenames.map { URL(fileURLWithPath: $0) }.filter { $0.pathExtension.lowercased() == "zip" }
        guard !zipUrls.isEmpty else { return }
        hasReceivedFiles = true
        for url in zipUrls {
            processZipFile(at: url)
        }
    }

    private func processZipFile(at zipURL: URL) {
        let canonicalPath = zipURL.standardizedFileURL.path
        if processedFilePaths.contains(canonicalPath) {
            NSLog("[HostApp] Skipping already processed zip: %@", canonicalPath)
            return
        }
        processedFilePaths.insert(canonicalPath)
        NSLog("[HostApp] Processing incoming zip file: %@", canonicalPath)

        // a. WeChat DistributedNotification Ack
        sendWeChatNotificationAck(for: canonicalPath)

        // b. Extract ZIP to Fixed Directory
        guard let destDir = extractZip(at: zipURL) else {
            NSLog("[HostApp] Failed to extract zip: %@", canonicalPath)
            return
        }

        // c. Parse & Build Prompt to Clipboard
        let prompt = buildAndCopyPrompt(from: destDir)

        // d. Activate Target App & Perform Auto-Paste / Notify
        activateTargetAppAndNotify(prompt: prompt, destDir: destDir)
    }

    // MARK: - Step a: WeChat DistributedNotification Ack
    private func sendWeChatNotificationAck(for filePath: String) {
        let pathData = Data(filePath.utf8)
        let md5Digest = Insecure.MD5.hash(data: pathData)
        let md5Hex = md5Digest.map { String(format: "%02X", $0) }.joined()
        let md5Bytes = Array(md5Hex.utf8)

        // Protobuf: field 1 varint = 3 (0x08, 0x03), field 5 length-delimited string (0x2A, count) + md5Bytes
        let protoBytes: [UInt8] = [0x08, 0x03, 0x2A, UInt8(md5Bytes.count)] + md5Bytes
        let base64String = Data(protoBytes).base64EncodedString()

        let hostBundleID = Bundle.main.bundleIdentifier ?? "io.github.bilppppp.wx2ai"
        let channelName = "\(hostBundleID).wechatchannel"

        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name(channelName),
            object: base64String,
            userInfo: ["data": base64String],
            deliverImmediately: true
        )
        NSLog("[HostApp] Sent WeChat DistributedNotification ack (MD5: %@, channel: %@)", md5Hex, channelName)
    }

    // MARK: - Step b: Extract ZIP to Fixed Directory
    private func extractZip(at zipURL: URL) -> URL? {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let baseDir = homeDir.appendingPathComponent("WeChatForwards", isDirectory: true)

        do {
            try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[HostApp] Error creating WeChatForwards base directory: %@", error.localizedDescription)
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let randomHex = String(format: "%04x", Int.random(in: 0...0xFFFF))
        let folderName = "\(timestamp)_\(randomHex)"
        let destDir = baseDir.appendingPathComponent(folderName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[HostApp] Error creating destination directory: %@", error.localizedDescription)
            return nil
        }

        // Extract using ditto -x -k <zipPath> <destDir>
        var extractedSuccessfully = false
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, destDir.path]
        try? ditto.run()
        ditto.waitUntilExit()

        if ditto.terminationStatus == 0 {
            extractedSuccessfully = true
        } else {
            NSLog("[HostApp] ditto failed with code %d. Falling back to unzip...", ditto.terminationStatus)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-q", zipURL.path, "-d", destDir.path]
            try? unzip.run()
            unzip.waitUntilExit()
            if unzip.terminationStatus == 0 {
                extractedSuccessfully = true
            } else {
                NSLog("[HostApp] unzip failed with code %d.", unzip.terminationStatus)
            }
        }

        guard extractedSuccessfully else {
            return nil
        }

        // Update ~/WeChatForwards/latest symlink -> destDir
        let latestSymlink = baseDir.appendingPathComponent("latest")
        try? fileManager.removeItem(at: latestSymlink)
        do {
            try fileManager.createSymbolicLink(at: latestSymlink, withDestinationURL: destDir)
            NSLog("[HostApp] Created latest symlink: %@ -> %@", latestSymlink.path, destDir.path)
        } catch {
            NSLog("[HostApp] Failed to create symlink: %@", error.localizedDescription)
        }

        return destDir
    }

    // MARK: - Step c: Parse & Build Prompt to Clipboard
    @discardableResult
    private func buildAndCopyPrompt(from destDir: URL) -> String {
        let fileManager = FileManager.default
        var allFiles: [URL] = []

        if let enumerator = fileManager.enumerator(
            at: destDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isRegularFile {
                    // Ignore common macOS metadata
                    if fileURL.lastPathComponent == ".DS_Store" || fileURL.path.contains("__MACOSX") {
                        continue
                    }
                    allFiles.append(fileURL)
                }
            }
        }

        // Find transcript file: 聊天记录.txt, 聊天記錄.txt, Chat History.txt, or any root .txt file
        let candidateNames = ["聊天记录.txt", "聊天記錄.txt", "Chat History.txt", "chat_history.txt"]
        var transcriptURL: URL? = nil

        for candidate in candidateNames {
            if let match = allFiles.first(where: { $0.lastPathComponent.caseInsensitiveCompare(candidate) == .orderedSame }) {
                transcriptURL = match
                break
            }
        }

        if transcriptURL == nil {
            // Any .txt directly in destDir root
            if let rootTxt = allFiles.first(where: {
                $0.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL &&
                $0.pathExtension.lowercased() == "txt"
            }) {
                transcriptURL = rootTxt
            }
        }

        if transcriptURL == nil {
            // Any .txt anywhere in the extraction
            transcriptURL = allFiles.first(where: { $0.pathExtension.lowercased() == "txt" })
        }

        // Other files are attachments
        let attachments = allFiles.filter { $0 != transcriptURL }.sorted { $0.path < $1.path }

        // Read transcript text (UTF-8, fallback to GB18030 / CP936)
        var rawContent = ""
        if let tURL = transcriptURL {
            if let utf8String = try? String(contentsOf: tURL, encoding: .utf8) {
                rawContent = utf8String
            } else {
                let cfGB18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                if let gb18030String = try? String(contentsOf: tURL, encoding: String.Encoding(rawValue: cfGB18030)) {
                    rawContent = gb18030String
                } else {
                    let cfGBK = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue))
                    if let gbkString = try? String(contentsOf: tURL, encoding: String.Encoding(rawValue: cfGBK)) {
                        rawContent = gbkString
                    } else if let latin1 = try? String(contentsOf: tURL, encoding: .isoLatin1) {
                        rawContent = latin1
                    }
                }
            }
        }

        let maxCharacters = 15000
        let displayContent: String
        if rawContent.count > maxCharacters {
            let prefix = String(rawContent.prefix(maxCharacters))
            displayContent = "\(prefix)\n\n[注：聊天记录文本过长，已截取前 15,000 字符。完整记录请查看文件：\(transcriptURL?.path ?? "未知")]"
        } else {
            displayContent = rawContent
        }

        // Assemble Chinese Markdown Prompt
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        let latestSymlinkPath = "\(homeDir)/WeChatForwards/latest"

        var prompt = """
        # 微信转发聊天记录

        - **解压目录**: `\(destDir.path)`
        - **最新记录软链接**: `\(latestSymlinkPath)`
        - **聊天记录文本文件**: `\(transcriptURL?.path ?? "（未找到单独文本文件）")`
        """

        if !attachments.isEmpty {
            prompt += "\n- **附件列表** (\(attachments.count) 个):\n"
            for attachment in attachments {
                prompt += "  - `\(attachment.path)`\n"
            }
        } else {
            prompt += "\n- **附件列表**: （无其他附件）\n"
        }

        prompt += "\n\n## 聊天记录内容\n\n```text\n\(displayContent)\n```\n\n请根据以上微信转发的聊天记录及附件进行分析和处理。"

        // Copy to general pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        NSLog("[HostApp] Copied prompt to pasteboard (%d characters)", prompt.count)
        return prompt
    }

    private var actionNotificationTitle: String {
        targetAppName.hasPrefix("转发到") ? "微信聊天记录已\(targetAppName)" : "微信聊天记录已转发至 \(targetAppName)"
    }

    // MARK: - Step d: Activate Target App & Perform Auto-Paste / Notify
    private func activateTargetAppAndNotify(prompt: String, destDir: URL) {
        // Mode 0: Clipboard-only mode (No window switching, instant copy & notify)
        if autoPasteMode == "clipboard" || targetAppBundleID == "clipboard" || targetAppBundleID.isEmpty {
            NSLog("[HostApp] Clipboard-only mode. Playing sound and notifying.")
            NSSound(named: "Glass")?.play()
            showNotification(
                title: "微信聊天记录已复制到剪贴板",
                message: "已解压至 ~/WeChatForwards/latest，可在任意应用中按 ⌘V 粘贴"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSLog("[HostApp] Terminating host app after clipboard copy.")
                NSApp.terminate(nil)
            }
            return
        }

        // Mode 1: deeplink mode for Codex (optional mode)
        if autoPasteMode == "deeplink" && targetAppBundleID == "com.openai.codex" {
            var urlComponents = URLComponents(string: "codex://threads/new")
            urlComponents?.queryItems = [
                URLQueryItem(name: "prompt", value: prompt),
                URLQueryItem(name: "path", value: destDir.path)
            ]
            if let deeplinkURL = urlComponents?.url {
                NSLog("[HostApp] Opening Codex deeplink: %@", deeplinkURL.absoluteString)
                NSWorkspace.shared.open(deeplinkURL)
                NSSound(named: "Glass")?.play()
                showNotification(title: actionNotificationTitle, message: "已解压至 ~/WeChatForwards/latest 并创建新会话")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApp.terminate(nil)
                }
                return
            }
        }

        // Mode 2: Activate application window without arguments
        var targetAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetAppBundleID)
        if targetAppURL == nil || !FileManager.default.fileExists(atPath: targetAppURL!.path) {
            if FileManager.default.fileExists(atPath: targetAppFallbackPath) {
                targetAppURL = URL(fileURLWithPath: targetAppFallbackPath)
            } else if (targetAppBundleID == "com.openai.codex" || targetAppName.localizedCaseInsensitiveContains("Codex")) && FileManager.default.fileExists(atPath: "/Applications/Codex.app") {
                targetAppURL = URL(fileURLWithPath: "/Applications/Codex.app")
            }
        }

        if let targetURL = targetAppURL {
            NSLog("[HostApp] Activating target app at %@", targetURL.path)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            // Do NOT pass file arguments so Codex/Antigravity stays on its active thread/session window!
            NSWorkspace.shared.openApplication(at: targetURL, configuration: config) { app, error in
                if let error = error {
                    NSLog("[HostApp] Error activating target app: %@", error.localizedDescription)
                } else {
                    NSLog("[HostApp] Successfully activated target app (PID: %d)", app?.processIdentifier ?? 0)
                }
            }
        } else {
            NSLog("[HostApp] Warning: Target app not found for %@ (%@)", targetAppName, targetAppBundleID)
        }

        // Play feedback sound
        NSSound(named: "Glass")?.play()

        if autoPasteMode == "none" {
            showNotification(title: actionNotificationTitle, message: "已解压至 ~/WeChatForwards/latest 并复制 Prompt，按 ⌘V 即可粘贴")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
            return
        }

        // Default mode: Keystroke auto-paste (⌘V)
        // Poll every 0.15s (up to 2.5s max) until target app is frontmost, then wait 0.25s for focus and paste
        let startTime = Date()
        func pollFrontmostApp() {
            let elapsed = Date().timeIntervalSince(startTime)
            let currentFrontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

            if currentFrontBundle == self.targetAppBundleID {
                NSLog("[HostApp] %@ is frontmost (elapsed: %.2fs). Waiting 0.25s for input focus...", self.targetAppName, elapsed)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.performAutoPaste()
                }
            } else if elapsed >= 2.5 {
                NSLog("[HostApp] Timed out waiting for %@ to become frontmost (frontmost is %@). Attempting paste anyway...",
                      self.targetAppName, currentFrontBundle ?? "none")
                self.performAutoPaste()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    pollFrontmostApp()
                }
            }
        }

        pollFrontmostApp()
    }

    private func performAutoPaste() {
        let a11yOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(a11yOptions)

        if isTrusted {
            // Synthesize Cmd+V using CGEvent (virtual key 0x09 is 'v')
            if let src = CGEventSource(stateID: .hidSystemState),
               let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                NSLog("[HostApp] Synthesized Cmd+V auto-paste via CGEvent into %@", targetAppName)
            }
            showNotification(title: actionNotificationTitle, message: "已解压并自动粘贴聊天记录 Prompt")
        } else {
            // Fallback to System Events keystroke
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
            try? osa.run()
            osa.waitUntilExit()

            if osa.terminationStatus == 0 {
                NSLog("[HostApp] Synthesized Cmd+V via System Events fallback into %@", targetAppName)
                showNotification(title: actionNotificationTitle, message: "已解压并自动粘贴聊天记录 Prompt")
            } else {
                NSLog("[HostApp] Accessibility permission not granted. User must paste with Cmd+V.")
                showNotification(
                    title: actionNotificationTitle,
                    message: "已解压并复制 Prompt，按 ⌘V 即可粘贴 (可在系统设置->辅助功能中开启自动粘贴)"
                )
            }
        }

        // Terminate host app cleanly after auto-paste step completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSLog("[HostApp] Terminating host app after task completion.")
            NSApp.terminate(nil)
        }
    }

    private func showNotification(title: String, message: String) {
        let safeTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let safeMsg = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(safeMsg)\" with title \"\(safeTitle)\""

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        try? osa.run()
    }
}

// Application Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
