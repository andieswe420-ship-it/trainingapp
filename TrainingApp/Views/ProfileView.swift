import SwiftUI

/// Visa och ändra träningsprofilen (mål, veckoschema, skador, övrigt).
struct ProfileView: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var profile = AthleteProfile.empty
    @State private var saved = AthleteProfile.empty
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mål") {
                    TextField("T.ex. 10 km under 45 min i vår", text: $profile.goals, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    ForEach(AthleteProfile.Weekday.allCases) { day in
                        HStack {
                            Text(day.swedishName)
                                .frame(width: 80, alignment: .leading)
                            TextField("Flexibel", text: binding(for: day))
                        }
                    }
                } header: {
                    Text("Veckoschema")
                } footer: {
                    Text("Skriv vad dagen ska innehålla, t.ex. \"Vila\" eller \"Intervaller inomhus\". Tom dag = flexibel.")
                }

                Section("Skador och begränsningar") {
                    TextField("T.ex. känning i vänster hälsena", text: $profile.limitations, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    TextField("Andra preferenser", text: $profile.notes, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("Övrigt")
                } footer: {
                    Text("Coachen uppdaterar profilen när du berättar något bestående i chatten. Profilen används också när nya veckoplaner skapas.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isLoading)
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle("Min profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stäng") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Spara") { Task { await save() } }
                            .disabled(isLoading || profile == saved)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func binding(for day: AthleteProfile.Weekday) -> Binding<String> {
        Binding(
            get: { profile.weeklySchedule[day.rawValue] ?? "" },
            set: { profile.weeklySchedule[day.rawValue] = $0 }
        )
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try await sync.fetchProfile()
            saved = profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await sync.saveProfile(profile)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
