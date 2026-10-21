import SwiftUI

/// Inloggning till Supabase så att passen kan synkas.
struct AccountView: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if !sync.isConfigured {
                    Section {
                        Text("Supabase är inte konfigurerat. Skapa Config/Secrets.xcconfig (se Secrets.xcconfig.example), kör xcodegen generate och bygg om.")
                            .foregroundStyle(.secondary)
                    }
                } else if let userEmail = sync.userEmail {
                    Section("Inloggad som") {
                        Text(userEmail)
                    }
                    Section {
                        Button("Logga ut", role: .destructive) {
                            Task { await sync.signOut() }
                        }
                    }
                } else {
                    Section {
                        TextField("E-post", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Lösenord", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("Kontot används för att spara dina pass i molnet så att AI-planeraren kan läsa dem.")
                    }
                    Section {
                        Button("Logga in") { run { try await sync.signIn(email: email, password: password) } }
                        Button("Skapa konto") {
                            run {
                                let needsConfirmation = try await sync.signUp(email: email, password: password)
                                if needsConfirmation {
                                    message = "Kolla din e-post och klicka på bekräftelselänken, logga sedan in här."
                                }
                            }
                        }
                    }
                    .disabled(isWorking || email.isEmpty || password.count < 6)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Konto")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") { dismiss() }
                }
            }
            .overlay {
                if isWorking { ProgressView() }
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        message = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
