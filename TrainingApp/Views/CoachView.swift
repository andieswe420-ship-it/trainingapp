import SwiftUI

/// Chatt med den löpande coachen.
struct CoachView: View {
    @Environment(SyncService.self) private var sync
    @Environment(CoachStore.self) private var store
    @Environment(PlanStore.self) private var planStore

    @State private var draft = ""
    @State private var showAccount = false
    @State private var showProfile = false

    private let suggestions = [
        "Hur går träningen?",
        "Vad har jag framför mig den här veckan?",
        "Jag sov dåligt i natt – ska jag köra dagens pass?",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if sync.isSignedIn {
                    chat
                } else {
                    ContentUnavailableView {
                        Label("Logga in för att chatta", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("Coachen följer din träning, sömn och återhämtning och hjälper dig justera planen.")
                    } actions: {
                        Button("Logga in") { showAccount = true }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.horizontal, 40)
                    }
                }
            }
            .themedScreen()
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sync.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showProfile = true } label: {
                            Image(systemName: "person.text.rectangle")
                        }
                        .accessibilityLabel("Min profil")
                    }
                }
            }
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showProfile) { ProfileView() }
        }
        .task(id: sync.userEmail) { await store.refresh() }
        .onAppear {
            store.isVisible = true
            takePrefill()
        }
        .onChange(of: store.prefill) { _, _ in takePrefill() }
        .onDisappear { store.isVisible = false }
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.messages.isEmpty {
                        intro
                    }
                    ForEach(store.messages) { message in
                        CoachMessageView(
                            message: message,
                            isDeciding: store.deciding.contains(message.id),
                            onDecide: { accept in
                                Task {
                                    if await store.decide(message, accept: accept) {
                                        await planStore.loadLatest()
                                    }
                                }
                            },
                            onShowProfile: { showProfile = true }
                        )
                        .id(message.id)
                    }
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await store.refresh() }
            .onChange(of: store.messages.last) { _, last in
                guard let last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hej! Jag följer dina pass, din sömn och din återhämtning. Fråga mig vad du vill om träningen – eller berätta hur senaste passet kändes.")
                .foregroundStyle(Theme.secondaryText)
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) {
                    Task { await store.send(suggestion) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.cyan)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.cyan.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Theme.cyan.opacity(0.35)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func takePrefill() {
        guard let prefill = store.prefill else { return }
        draft = prefill
        store.prefill = nil
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSending && !store.hasPendingReply
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Skriv till coachen…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
            Button {
                let text = draft
                draft = ""
                Task { await store.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(canSend ? Theme.cyan : Color.white.opacity(0.25))
            }
            .disabled(!canSend)
            .accessibilityLabel("Skicka")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Helt täckande, även ner under flikraden – annars lyser chatten igenom skrivfältet.
        .background(Theme.backgroundTop.ignoresSafeArea(edges: .bottom))
    }
}

/// En pratbubbla, med förslagskort om coachen föreslår en planändring.
private struct CoachMessageView: View {
    let message: CoachMessage
    let isDeciding: Bool
    let onDecide: (Bool) -> Void
    let onShowProfile: () -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            bubble
            if let proposal = message.proposal {
                ProposalCard(
                    proposal: proposal,
                    status: message.proposalStatus ?? .pending,
                    isDeciding: isDeciding,
                    onDecide: onDecide
                )
            }
            if let update = message.profileUpdate {
                Button(action: onShowProfile) {
                    Label("Profilen uppdaterad: \(update.summary)", systemImage: "person.text.rectangle")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.cyan)
                .frame(maxWidth: 320, alignment: .leading)
            }
            if let note = message.workoutNote {
                Label("Passet noterat: \(note.summary)", systemImage: "figure.run")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            Text(message.createdAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            switch message.status {
            case .pending:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Coachen skriver…")
                        .foregroundStyle(Theme.secondaryText)
                }
            case .failed:
                Label(message.error ?? "Coachen kunde inte svara. Försök igen.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .done:
                Text(Self.markdown(message.content))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(isUser ? Theme.backgroundTop : Color.white)
        .background(
            isUser ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isUser ? Color.clear : Theme.border)
        )
        .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Coachens förslag på ändrade pass, med knappar för att godkänna eller avböja.
private struct ProposalCard: View {
    let proposal: CoachProposal
    let status: CoachMessage.ProposalStatus
    let isDeciding: Bool
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Förslag på ändrad plan", systemImage: "calendar.badge.clock")
                .font(.headline)
                .foregroundStyle(Theme.cyan)
            // Motiveringen visas inte här: coachens bubbla ovanför säger redan samma sak.
            ForEach(proposal.days, id: \.self) { day in
                let workouts = proposal.workouts.filter { $0.date == day }
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayTitle(day))
                        .font(.subheadline.weight(.semibold))
                    if workouts.isEmpty {
                        Text("Vila")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.leading, 32)
                    } else {
                        ForEach(workouts) { workout in
                            HStack(spacing: 8) {
                                Image(systemName: workout.activity.symbolName)
                                    .foregroundStyle(Theme.cyan)
                                    .frame(width: 24)
                                Text("\(workout.title) · ca \(Int(workout.estimatedMinutes.rounded())) min")
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }

            switch status {
            case .pending:
                HStack(spacing: 10) {
                    Button("Godkänn") { onDecide(true) }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Avböj", role: .cancel) { onDecide(false) }
                        .buttonStyle(SecondaryButtonStyle())
                    if isDeciding { ProgressView() }
                }
                .disabled(isDeciding)
            case .accepted:
                Label("Godkänd – planen är uppdaterad", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.cyan)
            case .rejected:
                Label("Avböjd", systemImage: "xmark.circle")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.cyan.opacity(0.4)))
    }

    private func dayTitle(_ day: String) -> String {
        guard let date = PlanDate.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).capitalized
    }
}
