import SwiftUI

struct LoginView: View {
    @Environment(Session.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "play.rectangle.fill").font(.system(size: 56)).foregroundStyle(.purple)
            Text("Streamio").font(.largeTitle.bold())
            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button {
                Task { await submit() }
            } label: {
                Group { if busy { ProgressView() } else { Text("Sign in").bold() } }
                    .frame(maxWidth: .infinity).padding()
            }
            .background(.purple, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            .disabled(busy || email.isEmpty || password.isEmpty)
            Spacer()
        }
        .padding(24)
        .background(Color.black.ignoresSafeArea())
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await session.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password) }
        catch { self.error = error.localizedDescription }
    }
}
