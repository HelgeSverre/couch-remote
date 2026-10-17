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
            ForEach(RemoteAppButton.allCases) { button in
                Picker(button.title, selection: Binding(
                    get: { model.config.remaps[button.appID] },
                    set: { model.setRemap(button, to: $0) }
                )) {
                    Text("Opens \(model.name(ofApp: button.appID))").tag(String?.none)
                    Divider()
                    ForEach(apps.filter { $0.id != button.appID }) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
            }
        } header: {
            Text("Remote Buttons")
        } footer: {
            Text("While Couch Remote runs, pressing a remapped button opens the app you chose. The button's own app shows for about a second first. Samsung TV Plus must be enabled on the TV for its button to be remapped.")
                .foregroundStyle(.secondary)
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
            Text("Couch Remote finds apps by checking about 200 known app IDs. Add an ID here for an app it missed. Hidden apps are listed above with a Show button.")
                .foregroundStyle(.secondary)
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
}
