import SwiftUI
import Combine
import PhotosUI
import UIKit
import UserNotifications
import ImageIO

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isUser: Bool
    var imageData: Data? = nil
    let timestamp = Date()
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isTyping = false

    func sendMessage(imageData: Data?, endpoint: String, model: String) {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || imageData != nil), !isTyping else { return }

        messages.append(ChatMessage(text: prompt, isUser: true, imageData: imageData))
        inputText = ""
        isTyping = true
        let conversation = messages
        let taskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "OllamaReply",
            expirationHandler: nil
        )

        Task {
            defer {
                isTyping = false
                if taskIdentifier != .invalid {
                    UIApplication.shared.endBackgroundTask(taskIdentifier)
                }
            }
            do {
                let reply = try await OllamaService.reply(
                    to: conversation,
                    endpoint: endpoint,
                    model: model
                )
                messages.append(ChatMessage(text: reply, isUser: false))
                await AppNotifications.deliverReply(reply)
            } catch {
                messages.append(ChatMessage(
                    text: "I couldn’t reach Ollama. \(error.localizedDescription)",
                    isUser: false
                ))
            }
        }
    }
}

private enum OllamaService {
    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
            let images: [String]?
        }

        let model: String
        let messages: [Message]
        let stream = false
    }

    private struct ResponseBody: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    static func reply(to conversation: [ChatMessage], endpoint: String, model: String) async throws -> String {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedEndpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw OllamaError.invalidEndpoint
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path != "api/chat" {
            components.path = "/" + [path, "api/chat"].filter { !$0.isEmpty }.joined(separator: "/")
        }
        guard let url = components.url else { throw OllamaError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: conversation.map { message in
                RequestBody.Message(
                    role: message.isUser ? "user" : "assistant",
                    content: message.text.isEmpty && message.imageData != nil ? "Describe this image." : message.text,
                    images: message.imageData.map { [$0.base64EncodedString()] }
                )
            }
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OllamaError.server(detail)
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OllamaError.emptyReply }
        return text
    }
}

private enum ImagePreparation {
    static func jpegData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.unreadable
        }
        guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else {
            throw ImageError.conversionFailed
        }
        return jpeg
    }

    private enum ImageError: LocalizedError {
        case unreadable
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "The selected photo couldn’t be read."
            case .conversionFailed: "The selected photo couldn’t be prepared."
            }
        }
    }
}

private enum PhotoPickerError: LocalizedError {
    case noData

    var errorDescription: String? {
        "No image data was returned for the selected photo."
    }
}

private enum AppNotifications {
    static func requestPermissionAtLaunch() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            NSLog("Could not request notification permission: %@", error.localizedDescription)
        }
    }

    static func deliverReply(_ reply: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Luma replied"
        content.body = String(reply.prefix(150))
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NSLog("Could not schedule reply notification: %@", error.localizedDescription)
        }
    }
}

private struct ChatWelcomeCard: View {
    let onPrompt: (String) -> Void

    private let prompts = ["Help me brainstorm", "Explain a concept", "Write something"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 7) {
                Circle().fill(Color.mint).frame(width: 6, height: 6)
                Text("YOUR PRIVATE AI SPACE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(Color.white.opacity(0.65))
            }

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("A little space\nto wonder.")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .tracking(-0.7)
                        .foregroundStyle(.white)
                    Text("Ask a question, explore an idea, or share a photo.")
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                OrbGraphic()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("TRY ASKING")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(Color.white.opacity(0.42))
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        onPrompt(prompt)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: icon(for: prompt))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.mint)
                                .frame(width: 17)
                            Text(prompt)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.82))
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.18, blue: 0.25).opacity(0.95),
                            Color(red: 0.11, green: 0.12, blue: 0.2).opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }
        }
    }

    private func icon(for prompt: String) -> String {
        switch prompt {
        case "Help me brainstorm": "lightbulb"
        case "Explain a concept": "sparkle.magnifyingglass"
        default: "pencil.line"
        }
    }
}

private struct OrbGraphic: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.mint.opacity(0.12))
                .frame(width: 94, height: 94)
                .blur(radius: 4)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.62, green: 1, blue: 0.84), Color(red: 0.22, green: 0.75, blue: 0.7), Color(red: 0.24, green: 0.48, blue: 0.66)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 58, height: 58)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(.white.opacity(0.75))
                        .frame(width: 15, height: 9)
                        .blur(radius: 4)
                        .offset(x: 12, y: 10)
                }
                .shadow(color: .mint.opacity(0.32), radius: 16, y: 6)
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                .frame(width: 82, height: 82)
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .offset(x: 38, y: -31)
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: 4, height: 4)
                .offset(x: -38, y: 27)
        }
    }
}

private enum OllamaError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case emptyReply
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Check the Ollama URL in settings."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .emptyReply:
            return "Ollama returned an empty reply."
        case .server(let detail):
            return "Ollama returned an error: \(detail)"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @AppStorage("ollamaEndpoint") private var endpoint = "http://localhost:11434"
    @AppStorage("ollamaModel") private var model = "llama3.2"
    @State private var username = ""
    @State private var isSignedIn = false

    var body: some View {
        Group {
            if isSignedIn {
                ChatScreen(
                    viewModel: viewModel,
                    username: username,
                    endpoint: $endpoint,
                    model: $model,
                    onSignOut: { isSignedIn = false }
                )
                .transition(.opacity)
            } else {
                LoginScreen { name in
                    username = name
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isSignedIn = true
                    }
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await AppNotifications.requestPermissionAtLaunch()
        }
    }
}

private struct LoginScreen: View {
    let onContinue: (String) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var passwordVisible = false

    private var canContinue: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                BrandMark()
                    .padding(.bottom, 34)

                Text("Your own space\nfor big ideas.")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(-1.3)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text("A thoughtful AI conversation, powered locally.")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.top, 12)
                    .padding(.bottom, 34)

                VStack(spacing: 14) {
                    LoginField(title: "USERNAME", icon: "person", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 12) {
                        Image(systemName: "lock")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.52))
                            .frame(width: 20)
                        Group {
                            if passwordVisible {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        Button {
                            passwordVisible.toggle()
                        } label: {
                            Image(systemName: passwordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(Color.white.opacity(0.48))
                        }
                    }
                    .font(.system(size: 16))
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.09)))
                }

                Button {
                    onContinue(username.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    HStack {
                        Text("Continue")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.04, green: 0.12, blue: 0.13))
                    .padding(.horizontal, 20)
                    .frame(height: 58)
                    .background(canContinue ? Color.mint : Color.mint.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!canContinue)
                .padding(.top, 20)

                Text("Local demo sign-in · credentials aren’t verified or sent")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                Spacer()
                Text("PRIVATE BY DESIGN")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 28)
        }
    }
}

private struct LoginField: View {
    let title: String
    let icon: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.52))
                .frame(width: 20)
            TextField(title.capitalized, text: $text)
                .font(.system(size: 16))
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.09)))
    }
}

private struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let username: String
    @Binding var endpoint: String
    @Binding var model: String
    let onSignOut: () -> Void
    @State private var showingSettings = false
    @State private var showingBackgroundHelp = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var photoError = ""
    @State private var showingPhotoError = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 22) {
                            if viewModel.messages.isEmpty {
                                ChatWelcomeCard { prompt in
                                    viewModel.inputText = prompt
                                }
                            }
                            ForEach(viewModel.messages) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                            if viewModel.isTyping {
                                TypingIndicator()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: viewModel.messages.count) {
                        guard let lastID = viewModel.messages.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                composer
            }
        }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            Task {
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else {
                        throw PhotoPickerError.noData
                    }
                    selectedImageData = try ImagePreparation.jpegData(from: data)
                } catch {
                    photoError = error.localizedDescription
                    showingPhotoError = true
                    selectedPhoto = nil
                }
            }
        }
        .alert("Couldn’t add photo", isPresented: $showingPhotoError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoError)
        }
        .confirmationDialog("Background or close Luma", isPresented: $showingBackgroundHelp, titleVisibility: .visible) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Press Home or swipe up to leave the app running in the background. iOS gives an active reply limited time to finish and may suspend it. To fully quit, swipe up on Luma in the app switcher; iOS apps can’t quit themselves.")
        }
        .sheet(isPresented: $showingSettings) {
            OllamaSettings(endpoint: $endpoint, model: $model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            BrandMark(size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("Luma")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    Circle().fill(Color.mint).frame(width: 6, height: 6)
                    Text(model.isEmpty ? "Ollama · local" : model)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }
            Menu {
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", action: onSignOut)
                Button("Background or close", systemImage: "rectangle.stack") {
                    showingBackgroundHelp = true
                }
            } label: {
                Text(String(username.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color(red: 0.31, green: 0.36, blue: 0.58))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let selectedImageData, let image = UIImage(data: selectedImageData) {
                HStack(spacing: 10) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Photo attached")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    Spacer()
                    Button {
                        self.selectedImageData = nil
                        selectedPhoto = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .accessibilityLabel("Remove attached photo")
                }
                .padding(9)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .disabled(viewModel.isTyping)
                .accessibilityLabel("Attach photo")

                TextField("Message Luma...", text: $viewModel.inputText, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .tint(.mint)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .disabled(viewModel.isTyping)
                Button(action: send) {
                    Image(systemName: viewModel.isTyping ? "ellipsis" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(red: 0.04, green: 0.12, blue: 0.13))
                        .frame(width: 42, height: 42)
                        .background(canSend ? Color.mint : Color.mint.opacity(0.35))
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .padding(7)
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.1)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(red: 0.055, green: 0.07, blue: 0.12))
    }

    private var canSend: Bool {
        (!viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImageData != nil)
            && !viewModel.isTyping
    }

    private func send() {
        guard canSend else { return }
        viewModel.sendMessage(imageData: selectedImageData, endpoint: endpoint, model: model)
        selectedImageData = nil
        selectedPhoto = nil
    }
}

private struct OllamaSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var endpoint: String
    @Binding var model: String

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(alignment: .leading, spacing: 20) {
                    SettingsInput(title: "OLLAMA SERVER", placeholder: "http://localhost:11434", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SettingsInput(title: "MODEL", placeholder: "llama3.2", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Use localhost in the iOS Simulator. On a physical iPhone, enter your Mac’s local network IP. For photo questions, choose an Ollama vision model such as llava or qwen2.5vl.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(22)
                .padding(.top, 12)
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.mint)
                }
            }
        }
    }
}

private struct SettingsInput: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(Color.white.opacity(0.48))
            TextField(placeholder, text: $text)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(.white)
                .padding(15)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.09)))
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isUser { Spacer(minLength: 44) }
            if !message.isUser { BrandMark(size: 30) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                Text(message.isUser ? "YOU" : "LUMA")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(Color.white.opacity(0.4))
                VStack(alignment: .leading, spacing: 9) {
                    if let imageData = message.imageData, let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 250, maxHeight: 250)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 16))
                            .lineSpacing(4)
                    }
                }
                .foregroundStyle(message.isUser ? Color(red: 0.05, green: 0.12, blue: 0.13) : .white.opacity(0.9))
                .padding(message.imageData == nil ? 15 : 9)
                .background(message.isUser ? Color.mint : Color.white.opacity(0.075))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay {
                    if !message.isUser {
                        RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.07))
                    }
                }
            }
            if message.isUser { EmptyView() } else { Spacer(minLength: 34) }
        }
    }
}

private struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            ProgressView()
                .tint(.mint)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.075))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
    }
}

private struct BrandMark: View {
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32)
                .fill(
                    LinearGradient(
                        colors: [Color.mint, Color(red: 0.25, green: 0.76, blue: 0.71)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Color(red: 0.04, green: 0.12, blue: 0.13))
        }
        .frame(width: size, height: size)
    }
}

private struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.07, blue: 0.12)
            RadialGradient(
                colors: [Color(red: 0.17, green: 0.27, blue: 0.3).opacity(0.55), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 480
            )
            RadialGradient(
                colors: [Color(red: 0.23, green: 0.2, blue: 0.4).opacity(0.28), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 390
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
