import SwiftUI

/// Premier lancement : collage du token API Infomaniak.
struct TokenSetupView: View {
    let session: SessionStore

    @State private var token = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showHelp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 60)

                AppMark()
                    .font(.system(size: 40, weight: .bold))

                VStack(spacing: 8) {
                    Text("Orvian")
                        .font(.largeTitle.bold())
                    Text("Votre kDrive, en natif.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Token API Infomaniak")
                        .font(.subheadline.weight(.semibold))
                    SecureField("Coller le token…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(connect)

                    Text("Le token est stocké dans le Keychain de l'app et n'est jamais envoyé ailleurs qu'à api.infomaniak.com.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)

                Button(action: connect) {
                    HStack {
                        if isWorking {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isWorking ? "Connexion…" : "Se connecter")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 || isWorking)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let signedOutMessage = session.signedOutMessage {
                    Label(signedOutMessage, systemImage: "key.slash.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button("Où trouver mon token ?") {
                    showHelp = true
                }
                .font(.footnote)
                .buttonStyle(.borderless)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showHelp) {
            TokenHelpSheet()
                .presentationDetents([.medium])
        }
    }

    private func connect() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await session.signIn(token: trimmed)
            } catch {
                errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct TokenHelpSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Créer un token API", systemImage: "key.fill")
                .font(.headline)
            steps
            Link("Ouvrir developer.infomaniak.com", destination: URL(string: "https://developer.infomaniak.com")!)
                .font(.footnote.weight(.semibold))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Connectez-vous au manager Infomaniak.")
            Text("2. Profil → Développeur → Tokens API (ou developer.infomaniak.com).")
            Text("3. Créez un token avec le produit kDrive et les droits de lecture.")
            Text("4. Copiez-le et collez-le ici.")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}
