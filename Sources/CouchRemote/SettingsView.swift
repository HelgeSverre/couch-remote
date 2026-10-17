import ServiceManagement
import SwiftUI
import TVKit

struct SettingsView: View {
    @Environment(RemoteModel.self) private var model
    @State private var hostDraft = ""
    @State private var macDraft = ""
    @State private var appIDDraft = ""
    @State private var addError: String?
    @State private var searching = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            tvSection
            remapSection
            appsSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            hostDraft = model.config.host ?? ""
            macDraft = model.config.wifiMAC ?? ""
        }
    }

    private var tvSection: some View {
        Section("Television") {
            LabeledContent("Name", value: model.displayName)
            if let modelName = model.device?.modelName ?? model.config.modelName {
                LabeledContent("Model", value: modelName)
            }
            HStack {
                TextField("Address", text: $hostDraft, prompt: Text("192.168.1.20"))
                Button("Connect") { model.useTV(host: hostDraft) }
                    .disabled(hostDraft.isEmpty || hostDraft == model.config.host)
            }
            HStack {
                Button(searching ? "Searching…" : "Find TVs on This Network") {
                    searching = true
                    Task {
                        await model.discover(autoSelect: false)
                        searching = false
                    }
                }
                .disabled(searching)
                Spacer()
                Button("Pair Again", action: model.pairAgain)
            }
            ForEach(model.discovered) { tv in
                HStack {
                    VStack(alignment: .leading) {
                        Text(tv.name)
                        Text("\(tv.modelName) · \(tv.host)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tv.host == model.config.host {
                        Text("In use").foregroundStyle(.secondary)
                    } else {
                        Button("Use") {
                            hostDraft = tv.host
                            model.useTV(host: tv.host)
                        }
                    }
                }
            }
            TextField("Wi-Fi MAC", text: $macDraft, prompt: Text("Read from the TV"))
                .onSubmit { model.setWifiMAC(macDraft) }
                .help("Used to wake the TV from standby with Wake-on-LAN.")
        }
    }

    private var remapSection: some View {
        let apps = model.config.knownApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Section {
            ForEach(model.config.remaps) { rule in
                HStack(spacing: 8) {
                    Picker("When", selection: Binding(
                        get: { rule.fromAppID },
                        set: { model.updateRemap(rule.id, from: $0) }
                    )) {
                        ForEach(apps) { Text($0.name).tag($0.id) }
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("Open instead", selection: Binding(
                        get: { rule.toAppID },
                        set: { model.updateRemap(rule.id, to: $0) }
                    )) {
                        ForEach(apps.filter { $0.id != rule.fromAppID }) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    Button {
                        model.removeRemap(rule.id)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this rule")
                }
            }
            Button("Add Rule", action: model.addRemap)
                .disabled(apps.count < 2)
        } header: {
            Text("Remote Buttons")
        } footer: {
            footer("Repurpose an app button on your TV remote: when the left app opens, the right one opens instead. Works while Couch Remote is running.")
        }
    }

    private var appsSection: some View {
        Section {
            HStack {
                TextField("App ID", text: $appIDDraft, prompt: Text("3201907018807"))
                Button("Add") {
                    Task {
                        addError = await model.addApp(id: appIDDraft)
                        if addError == nil { appIDDraft = "" }
                    }
                }
                .disabled(appIDDraft.isEmpty)
            }
            if let addError {
                Text(addError).foregroundStyle(.red).font(.callout)
            }
            ForEach(model.hiddenApps) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    Button("Show") { model.unhide(app) }
                }
            }
            HStack {
                Button(model.scanningApps ? "Scanning…" : "Scan for Apps Again") {
                    Task { await model.rescanApps() }
                }
                .disabled(model.scanningApps)
                Spacer()
                Button("Reset Order", action: model.resetOrder)
                    .disabled(model.config.appOrder.isEmpty)
            }
        } header: {
            Text("Apps")
        } footer: {
            footer("Add an app the scan missed by its ID. Hidden apps are listed here.")
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError {
                Text(loginError).foregroundStyle(.red).font(.callout)
            }
            LabeledContent("Settings file") {
                Button(ConfigStore.fileURL.lastPathComponent) {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
                }
                .buttonStyle(.link)
            }
        }
    }

    /// Section footer: secondary, left-aligned (grouped forms otherwise right-align wrapped footer text).
    private func footer(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
