import SwiftUI

/// Toolbar menu for switching the server endpoint and the model on it.
struct ModelPicker: View {
    let viewModel: ChatViewModel
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
            Text(settings.modelID.isEmpty ? "Model" : displayName(for: settings.modelID))
                .lineLimit(1)
        }
    }
}
