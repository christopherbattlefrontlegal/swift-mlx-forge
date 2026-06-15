// Forge — Claude Code headless command helper.
//
// This is a composer only. It builds a safe commented command preview and a
// separately gated ready-to-run command. Forge does not execute the command.

import AppKit
import SwiftUI

struct LauncherView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var copiedMode: String?
    @State private var pendingDangerPreset: HeadlessLauncher.Preset?
    @State private var pendingDangerPermission: HeadlessLauncher.PermissionMode?
    @State private var confirmDangerPreset = false
    @State private var confirmDangerPermission = false

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: Theme.s3)]

    var body: some View {
        @Bindable var hl = app.launcher
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    missionSection(hl)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s3) {
                        categoryPickers(hl)
                    }
                    toolsSection(hl)
                    systemPromptSection(hl)
                    mcpSection(hl)
                }
                .padding(Theme.s4)
            }
            Divider()
            outputBar(hl)
        }
        .frame(width: 900, height: 780)
        .background(Theme.backgroundGradient)
        .confirmationDialog(
            "Enable full autonomous mode?",
            isPresented: $confirmDangerPreset,
            titleVisibility: .visible
        ) {
            Button("Enable bypassPermissions", role: .destructive) {
                if let preset = pendingDangerPreset {
                    hl.applyPreset(preset)
                }
                pendingDangerPreset = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDangerPreset = nil
            }
        } message: {
            Text("This selects bypassPermissions and can run edits or shell actions without permission prompts.")
        }
        .confirmationDialog(
            "Bypass all permissions?",
            isPresented: $confirmDangerPermission,
            titleVisibility: .visible
        ) {
            Button("Use bypassPermissions", role: .destructive) {
                if let permission = pendingDangerPermission {
                    hl.permissionMode = permission
                    hl.reviewed = false
                }
                pendingDangerPermission = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDangerPermission = nil
            }
        } message: {
            Text("This is the highest-risk permission mode. Use it only for trusted local automation.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "terminal")
                .foregroundStyle(Theme.emberGradient)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Headless Mode Helper")
                    .font(.headline)
                Text("Builds a commented `claude -p` command; Forge never runs it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.launcher.refreshMCP()
            } label: {
                Label("Rescan MCP", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Re-read MCP servers from ~/.claude.json and the selected working directory's .mcp.json")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(Theme.s4)
    }

    // MARK: - Mission

    @ViewBuilder
    private func missionSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("Mission Prompt", icon: "text.alignleft") {
            TextEditor(text: $hl.prompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 106)
                .padding(Theme.s2)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
        }

        card("Working Directories", icon: "folder") {
            HStack(spacing: Theme.s2) {
                TextField("/path/to/project", text: $hl.workingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Browse") { browse($hl.workingDirectory, refreshMCP: true) }
            }
            TextEditor(text: $hl.additionalDirectories)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 54)
                .padding(Theme.s1)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                .overlay(alignment: .topLeading) {
                    if hl.additionalDirectories.isEmpty {
                        Text("optional --add-dir paths, one per line")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(Theme.s2)
                            .allowsHitTesting(false)
                    }
                }
        }

        card("Output Folder", icon: "tray.and.arrow.down") {
            HStack(spacing: Theme.s2) {
                TextField("/path/to/output", text: $hl.outputFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Browse") { browse($hl.outputFolder) }
            }
            Text("Adds this folder to --add-dir and tells Claude to write generated artifacts there.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pickers

    @ViewBuilder
    private func categoryPickers(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl

        pickerCard("Preset", icon: "slider.horizontal.3", danger: hl.selectedPreset.isDangerous) {
            Picker("", selection: Binding(
                get: { hl.selectedPreset },
                set: { newValue in
                    if newValue.isDangerous {
                        pendingDangerPreset = newValue
                        confirmDangerPreset = true
                    } else {
                        hl.applyPreset(newValue)
                    }
                }
            )) {
                ForEach(HeadlessLauncher.Preset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
        }

        pickerCard("Model", icon: "cpu") {
            Picker("", selection: $hl.model) {
                ForEach(HeadlessLauncher.models, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            if hl.model == "custom" {
                TextField("model id", text: $hl.customModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
        }

        pickerCard("Fallback Model", icon: "arrow.triangle.branch") {
            Picker("", selection: $hl.fallbackModel) {
                ForEach(HeadlessLauncher.fallbackModels, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            if hl.fallbackModel == "custom" {
                TextField("fallback model id", text: $hl.customFallbackModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
        }

        pickerCard("Output Format", icon: "curlybraces") {
            Picker("", selection: $hl.outputFormat) {
                ForEach(HeadlessLauncher.OutputFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            if hl.outputFormat == .streamJSON {
                Picker("Input", selection: $hl.inputFormat) {
                    ForEach(HeadlessLauncher.InputFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .font(.callout)
            }
        }

        pickerCard("Permission Mode", icon: "shield.lefthalf.filled", danger: hl.permissionMode.isDangerous) {
            Picker("", selection: Binding(
                get: { hl.permissionMode },
                set: { newValue in
                    if newValue.isDangerous {
                        pendingDangerPermission = newValue
                        confirmDangerPermission = true
                    } else {
                        hl.permissionMode = newValue
                        hl.reviewed = false
                    }
                }
            )) {
                ForEach(HeadlessLauncher.PermissionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }

        pickerCard("Tool Restriction", icon: "wrench.and.screwdriver") {
            Picker("", selection: $hl.toolRestriction) {
                ForEach(HeadlessLauncher.ToolRestriction.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }

        pickerCard("Session", icon: "clock.arrow.circlepath") {
            Picker("", selection: $hl.sessionMode) {
                ForEach(HeadlessLauncher.SessionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if hl.sessionMode == .resume {
                TextField("session id", text: $hl.sessionValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
        }

        pickerCard("Limits", icon: "speedometer") {
            TextField("max turns, e.g. 5", text: Binding(
                get: { hl.maxTurns },
                set: { hl.maxTurns = $0.filter(\.isNumber) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            Toggle("verbose (--verbose)", isOn: $hl.verbose)
                .font(.callout)
                .toggleStyle(.checkbox)
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private func toolsSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("Tools", icon: "hammer") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Theme.s2)], alignment: .leading, spacing: Theme.s2) {
                ForEach(HeadlessLauncher.commonTools, id: \.self) { tool in
                    Toggle(tool, isOn: Binding(
                        get: { hl.containsTool(tool) },
                        set: { hl.setTool(tool, enabled: $0) }
                    ))
                    .toggleStyle(.button)
                    .font(.callout)
                }
            }

            TextEditor(text: $hl.toolList)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 64)
                .padding(Theme.s1)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                .overlay(alignment: .topLeading) {
                    if hl.toolList.isEmpty {
                        Text("Read Edit Bash(git diff *)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(Theme.s2)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - System Prompt

    @ViewBuilder
    private func systemPromptSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("System Prompt", icon: "quote.bubble") {
            HStack(spacing: Theme.s2) {
                Picker("Mode", selection: $hl.systemPromptMode) {
                    ForEach(HeadlessLauncher.SystemPromptMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Menu {
                    if app.promptPresets.isEmpty && app.availablePrompts().isEmpty {
                        Text("No prompt library entries")
                    }
                    ForEach(app.promptPresets) { preset in
                        Button(preset.name) {
                            hl.systemPromptText = preset.text
                            if hl.systemPromptMode == .none { hl.systemPromptMode = .append }
                        }
                    }
                    ForEach(app.availablePrompts(), id: \.category) { category, items in
                        Section(category) {
                            ForEach(items, id: \.url) { name, url in
                                Button(name) {
                                    if let content = app.loadPromptContent(from: url) {
                                        hl.systemPromptText = content
                                        if hl.systemPromptMode == .none { hl.systemPromptMode = .append }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Insert From Library", systemImage: "book.closed")
                }
                .disabled(hl.systemPromptMode == .none)
            }

            TextEditor(text: $hl.systemPromptText)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 72)
                .padding(Theme.s1)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
        }
    }

    // MARK: - MCP

    @ViewBuilder
    private func mcpSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("MCP Servers", icon: "server.rack") {
            if hl.discoveredMCP.isEmpty {
                Text("No MCP servers found in ~/.claude.json or the selected project's .mcp.json.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Checked servers emit --mcp-config automatically. With allowlist mode, Forge also adds mcp__server__* tool entries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                MCPServerChecklist(servers: hl.discoveredMCP, selected: $hl.selectedMCP)
                Toggle("Strict MCP config (--strict-mcp-config)", isOn: $hl.strictMCP)
                    .font(.callout)
                    .toggleStyle(.checkbox)
                    .disabled(hl.selectedMCP.isEmpty)
            }
        }
    }

    // MARK: - Output

    @ViewBuilder
    private func outputBar(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack {
                Label("Live Preview - commented safety copy", systemImage: "terminal")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if hl.isDangerous {
                    Label("bypass permissions selected", systemImage: "exclamationmark.octagon.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }

            ScrollView(.vertical) {
                Text(hl.annotatedCommand)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(hl.validationMessages.isEmpty ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s3)
            }
            .frame(height: 148)
            .background(Theme.codeBackground)
            .clipShape(.rect(cornerRadius: Theme.radiusSmall))

            if !hl.validationMessages.isEmpty {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    ForEach(hl.validationMessages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: Theme.s3) {
                if hl.isDangerous {
                    Toggle(isOn: $hl.reviewed) {
                        Text("I reviewed this bypassPermissions command.")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Button {
                    copy(hl.annotatedCommand, mode: "safe")
                } label: {
                    Label(copiedMode == "safe" ? "Copied with #" : "Copy with #", systemImage: copiedMode == "safe" ? "checkmark" : "doc.on.doc")
                        .padding(.horizontal, Theme.s2)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(!hl.canCompose)

                Button {
                    copy(hl.commandText, mode: "ready")
                } label: {
                    Label(copiedMode == "ready" ? "Copied ready" : "Copy ready-to-run", systemImage: copiedMode == "ready" ? "checkmark" : "paperplane.fill")
                        .padding(.horizontal, Theme.s2)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(hl.isDangerous ? .red : Theme.ember)
                .disabled(!hl.canCompose || (hl.isDangerous && !hl.reviewed))
            }
        }
        .padding(Theme.s3)
        .background(.ultraThinMaterial)
        .onChange(of: hl.commandText) {
            copiedMode = nil
            hl.reviewed = false
        }
    }

    // MARK: - Building Blocks

    @ViewBuilder
    private func card(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private func pickerCard(_ title: String, icon: String, danger: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(danger ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            content()
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func browse(_ binding: Binding<String>, refreshMCP: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
            if refreshMCP {
                app.launcher.refreshMCP()
            }
        }
    }

    private func copy(_ text: String, mode: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMode = mode
    }
}

private struct MCPServerChecklist: View {
    let servers: [HeadlessLauncher.DiscoveredMCP]
    @Binding var selected: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: Theme.s2)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s2) {
            ForEach(servers) { server in
                Toggle(server.name, isOn: Binding(
                    get: { selected.contains(server.name) },
                    set: { isOn in
                        if isOn {
                            selected.insert(server.name)
                        } else {
                            selected.remove(server.name)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.callout.monospaced())
            }
        }
    }
}
