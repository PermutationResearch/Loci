import SwiftUI

enum AppError: Identifiable, Equatable {
    var id: String { message }

    case extractionFailed(String)
    case llmNotConfigured
    case llmFailed(String)
    case importFailed(String)
    case vaultError(String)
    case networkError(String)
    case unknown(String)

    var message: String {
        switch self {
        case .extractionFailed(let detail): "Extraction failed: \(detail)"
        case .llmNotConfigured: "No LLM configured. Open Settings (Cmd+,) to add your OpenRouter API key or start Ollama."
        case .llmFailed(let detail): "LLM request failed: \(detail)"
        case .importFailed(let detail): "Import failed: \(detail)"
        case .vaultError(let detail): "Vault error: \(detail)"
        case .networkError(let detail): "Network error: \(detail)"
        case .unknown(let detail): detail
        }
    }

    var icon: String {
        switch self {
        case .extractionFailed: "doc.badge.exclamationmark"
        case .llmNotConfigured: "key"
        case .llmFailed: "brain.failing.headshot"
        case .importFailed: "arrow.down.circle"
        case .vaultError: "externaldrive.trianglebadge.exclamationmark"
        case .networkError: "wifi.exclamationmark"
        case .unknown: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .llmNotConfigured: .orange
        case .networkError: .blue
        default: .red
        }
    }
}

@MainActor
final class ErrorPresenter: ObservableObject {
    static let shared = ErrorPresenter()

    @Published var currentError: AppError?
    @Published var showToast = false

    private var dismissWorkItem: DispatchWorkItem?

    func show(_ error: AppError) {
        currentError = error
        showToast = true
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showToast = false
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    func dismiss() {
        showToast = false
        currentError = nil
        dismissWorkItem?.cancel()
    }
}

struct ErrorToast: View {
    @ObservedObject var presenter = ErrorPresenter.shared

    var body: some View {
        if presenter.showToast, let error = presenter.currentError {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: error.icon)
                        .lociFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(error.color)
                    Text(error.message)
                        .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(.black.opacity(0.78))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        presenter.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundStyle(.black.opacity(0.38))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(error.color.opacity(0.3), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: presenter.showToast)
        }
    }
}

enum AppFeedbackKind {
    case success
    case info

    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .info: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .success: Color(red: 0.04, green: 0.62, blue: 0.30)
        case .info: Color.black.opacity(0.72)
        }
    }
}

struct AppFeedback: Equatable {
    var title: String
    var detail: String?
    var kind: AppFeedbackKind
}

@MainActor
final class FeedbackPresenter: ObservableObject {
    static let shared = FeedbackPresenter()

    @Published var currentFeedback: AppFeedback?
    @Published var showToast = false

    private var dismissWorkItem: DispatchWorkItem?

    func show(_ feedback: AppFeedback, duration: TimeInterval = 2.2) {
        currentFeedback = feedback
        showToast = true
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showToast = false
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func success(_ title: String, detail: String? = nil) {
        show(AppFeedback(title: title, detail: detail, kind: .success))
    }

    func dismiss() {
        showToast = false
        currentFeedback = nil
        dismissWorkItem?.cancel()
    }
}

struct FeedbackToast: View {
    @ObservedObject var presenter = FeedbackPresenter.shared

    var body: some View {
        if presenter.showToast, let feedback = presenter.currentFeedback {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: feedback.kind.icon)
                        .lociFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(feedback.kind.tint)
                        .symbolEffect(.bounce, value: presenter.showToast)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(feedback.title)
                            .lociFont(size: 11.5, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(.black.opacity(0.82))
                        if let detail = feedback.detail, !detail.isEmpty {
                            Text(detail)
                                .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                                .foregroundStyle(.black.opacity(0.48))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 340)
                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(feedback.kind.tint.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                .padding(.bottom, 25)
                .transition(AppMotion.bottomToastTransition)
            }
            .animation(AppMotion.toast, value: presenter.showToast)
            .allowsHitTesting(false)
        }
    }
}
