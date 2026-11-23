import SwiftUI

/// Composer menu for switching the server endpoint and the model on it. Shown
/// as a capsule with the endpoint name; the current model's name is its help text.
struct ModelPicker: View {
    // Owns its own model list so the picker works outside a chat (the sidebar).
    @State private var viewModel = ChatViewModel()
    private let settings = AppSettings.shared

    /// The on-device model's id is "apple"; show its real name.
    private func displayName(for id: String) -> String {
        id == OnDeviceModels.appleID ? OnDeviceModels.displayName : id
    }

    var body: some View {
        Menu {
            if settings.endpoints.count > 1 {
                Section("Endpoint") {
                    ForEach(settings.endpoints) { endpoint in
                        Button {
                            // ChatView reloads the model list on the change.
                            settings.switchEndpoint(to: endpoint.id)
                        } label: {
                            if endpoint.id == settings.activeEndpointID {
                                Label(endpoint.name, systemImage: "checkmark")
                            } else {
                                Text(endpoint.name)
                            }
                        }
                    }
                }
            }
            Section("Model") {
                ForEach(viewModel.models) { model in
                    Button {
                        settings.modelID = model.id
                    } label: {
                        if model.id == settings.modelID {
                            Label(displayName(for: model.id), systemImage: "checkmark")
                        } else {
                            Text(displayName(for: model.id))
                        }
                    }
                }
            }
            Divider()
            Button("Refresh models") {
                Task { await viewModel.loadModels() }
            }
        } label: {
            let name = Text(endpointName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            #if os(macOS)
            // Same glass capsule as the plus button; a custom background here
            // would sit inside the Mac menu button's own chrome.
            name
                .padding(.horizontal, 6)
            #else
            name
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.appSecondaryBackground, in: Capsule())
            #endif
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        #endif
        // Menus tint their label with the accent color; keep it neutral.
        .tint(.primary)
        .help(currentName)
        // Load the list on appear and whenever the active endpoint changes.
        // Errors stay silent so an alert can't dismiss the Settings sheet.
        .task(id: settings.activeEndpointID) {
            await viewModel.loadModels(reportErrors: false)
        }
    }

    private var endpointName: String {
        settings.activeEndpointName.isEmpty ? "Endpoint" : settings.activeEndpointName
    }

    private var currentName: String {
        settings.modelID.isEmpty ? "Model" : displayName(for: settings.modelID)
    }
}
