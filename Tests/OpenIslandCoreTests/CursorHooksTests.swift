import Foundation
import Testing
@testable import OpenIslandCore

struct CursorHooksTests {
    @Test
    func cursorHookPayloadDecodesFromJSON() throws {
        let json = """
        {
            "hook_event_name": "beforeShellExecution",
            "conversation_id": "conv-123",
            "generation_id": "gen-456",
            "workspace_roots": ["/Users/test/project"],
            "command": "npm test",
            "cwd": "/Users/test/project"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: json)
        #expect(payload.hookEventName == .beforeShellExecution)
        #expect(payload.conversationId == "conv-123")
        #expect(payload.generationId == "gen-456")
        #expect(payload.workspaceRoots == ["/Users/test/project"])
        #expect(payload.command == "npm test")
        #expect(payload.cwd == "/Users/test/project")
        #expect(payload.sessionID == "conv-123")
        #expect(payload.isBlockingHook == true)
    }

    @Test
    func cursorHookPayloadDecodesStopEvent() throws {
        let json = """
        {
            "hook_event_name": "stop",
            "conversation_id": "conv-789",
            "generation_id": "gen-012",
            "workspace_roots": ["/Users/test/project"],
            "status": "completed"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: json)
        #expect(payload.hookEventName == .stop)
        #expect(payload.status == "completed")
        #expect(payload.isBlockingHook == false)
    }

    @Test
    func cursorHookDirectiveEncodesToJSON() throws {
        let directive = CursorHookDirective(continue: true, permission: .allow)
        let data = try JSONEncoder().encode(directive)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(object["continue"] as? Bool == true)
        #expect(object["permission"] as? String == "allow")
    }

    @Test
    func cursorHookDirectiveDenyEncodesToJSON() throws {
        let directive = CursorHookDirective(
            continue: true,
            permission: .deny,
            agentMessage: "Denied by Open Island."
        )
        let data = try JSONEncoder().encode(directive)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(object["permission"] as? String == "deny")
        #expect(object["agentMessage"] as? String == "Denied by Open Island.")
    }

    @Test
    func cursorHookInstallerInstallsIntoEmptyFile() throws {
        let mutation = try CursorHookInstaller.installHooksJSON(
            existingData: nil,
            hookCommand: "/usr/local/bin/OpenIslandHooks --source cursor"
        )

        #expect(mutation.changed == true)
        #expect(mutation.managedHooksPresent == true)

        let data = try #require(mutation.contents)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = object["hooks"] as! [String: Any]

        #expect(hooks.keys.contains("sessionStart"))
        #expect(hooks.keys.contains("sessionEnd"))
        #expect(hooks.keys.contains("beforeShellExecution"))
        #expect(hooks.keys.contains("beforeMCPExecution"))
        #expect(hooks.keys.contains("stop"))

        let shellEntries = hooks["beforeShellExecution"] as! [[String: Any]]
        #expect(shellEntries.count == 1)
        #expect(shellEntries[0]["command"] as? String == "/usr/local/bin/OpenIslandHooks --source cursor")
    }

    @Test
    func cursorHookInstallerPreservesExistingHooks() throws {
        let existing = """
        {
            "version": 1,
            "hooks": {
                "beforeShellExecution": [
                    { "command": "/usr/local/bin/my-custom-hook" }
                ]
            }
        }
        """.data(using: .utf8)!

        let mutation = try CursorHookInstaller.installHooksJSON(
            existingData: existing,
            hookCommand: "/usr/local/bin/OpenIslandHooks --source cursor"
        )

        let data = try #require(mutation.contents)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = object["hooks"] as! [String: Any]
        let shellEntries = hooks["beforeShellExecution"] as! [[String: Any]]

        #expect(shellEntries.count == 2)
        #expect(shellEntries[0]["command"] as? String == "/usr/local/bin/my-custom-hook")
        #expect(shellEntries[1]["command"] as? String == "/usr/local/bin/OpenIslandHooks --source cursor")
    }

    @Test
    func cursorHookInstallerUninstallsCleanly() throws {
        let installed = try CursorHookInstaller.installHooksJSON(
            existingData: nil,
            hookCommand: "/usr/local/bin/OpenIslandHooks --source cursor"
        )

        let uninstalled = try CursorHookInstaller.uninstallHooksJSON(
            existingData: installed.contents,
            managedCommand: "/usr/local/bin/OpenIslandHooks --source cursor"
        )

        #expect(uninstalled.changed == true)
        #expect(uninstalled.managedHooksPresent == true)
        #expect(uninstalled.contents == nil)
    }

    @Test
    func cursorHookInstallationManagerRoundTripsInstallAndUninstall() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-cursor-hooks-\(UUID().uuidString)", isDirectory: true)
        let cursorDirectory = rootURL.appendingPathComponent(".cursor", isDirectory: true)
        let managedHooksBinaryURL = rootURL
            .appendingPathComponent("managed", isDirectory: true)
            .appendingPathComponent("OpenIslandHooks")
        let manager = CursorHookInstallationManager(
            cursorDirectory: cursorDirectory,
            managedHooksBinaryURL: managedHooksBinaryURL
        )
        let hooksBinaryURL = rootURL
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("OpenIslandHooks")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: hooksBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cursor-hook".utf8).write(to: hooksBinaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooksBinaryURL.path)

        let installStatus = try manager.install(hooksBinaryURL: hooksBinaryURL)
        #expect(installStatus.managedHooksPresent == true)
        #expect(FileManager.default.fileExists(atPath: cursorDirectory.appendingPathComponent("hooks.json").path))
        #expect(FileManager.default.fileExists(atPath: cursorDirectory.appendingPathComponent(CursorHookInstallerManifest.fileName).path))

        let hooksData = try Data(contentsOf: cursorDirectory.appendingPathComponent("hooks.json"))
        let hooksObject = try JSONSerialization.jsonObject(with: hooksData) as! [String: Any]
        let hooks = hooksObject["hooks"] as! [String: Any]
        #expect(hooks.keys.count == 8)

        let uninstallStatus = try manager.uninstall()
        #expect(uninstallStatus.managedHooksPresent == false)
        #expect(!FileManager.default.fileExists(atPath: cursorDirectory.appendingPathComponent(CursorHookInstallerManifest.fileName).path))
    }

    @Test
    func cursorHookPayloadDecodesSessionStartEvent() throws {
        let json = """
        {
            "hook_event_name": "sessionStart",
            "conversation_id": "conv-new",
            "generation_id": "gen-new",
            "workspace_roots": ["/Users/test/project"],
            "composer_mode": "agent",
            "is_background_agent": false,
            "loop_count": 0
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: json)
        #expect(payload.hookEventName == .sessionStart)
        #expect(payload.composerMode == "agent")
        #expect(payload.isBackgroundAgent == false)
        #expect(payload.loopCount == 0)
        #expect(payload.isBlockingHook == false)
    }

    @Test
    func cursorHookPayloadDecodesSessionEndEvent() throws {
        let json = """
        {
            "hook_event_name": "sessionEnd",
            "conversation_id": "conv-end",
            "generation_id": "gen-end",
            "workspace_roots": ["/Users/test/project"],
            "reason": "completed",
            "duration_ms": 45000
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: json)
        #expect(payload.hookEventName == .sessionEnd)
        #expect(payload.reason == "completed")
        #expect(payload.durationMs == 45000)
    }

    @Test
    func cursorPayloadConvenienceProperties() {
        let payload = CursorHookPayload(
            hookEventName: .beforeShellExecution,
            conversationId: "conv-test",
            generationId: "gen-test",
            workspaceRoots: ["/Users/test/my-project"],
            command: "npm run build",
            cwd: "/Users/test/my-project"
        )

        #expect(payload.workspaceName == "my-project")
        #expect(payload.sessionTitle == "Cursor \u{00B7} my-project")
        #expect(payload.primaryWorkspaceRoot == "/Users/test/my-project")
        #expect(payload.permissionRequestTitle == "Allow shell command")
        #expect(payload.permissionRequestSummary == "npm run build")
        #expect(payload.defaultJumpTarget.terminalApp == "Cursor")
        #expect(payload.defaultJumpTarget.workingDirectory == "/Users/test/my-project")
        #expect(payload.defaultCursorMetadata.initialUserPrompt == nil)
        #expect(payload.defaultCursorMetadata.lastUserPrompt == nil)
    }
}
