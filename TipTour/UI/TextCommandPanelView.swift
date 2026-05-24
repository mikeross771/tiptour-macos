import SwiftUI

struct TextCommandPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @FocusState private var isInputFocused: Bool
    @State private var commandText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)

                TextField("Ask TipTour...", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit {
                        submitCommand()
                    }
                    .onExitCommand {
                        commandText = ""
                        companionManager.dismissTextCommandPanel()
                    }
            }

            if let activityText = companionManager.textCommandActivityText,
               !activityText.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(DS.Colors.accent.opacity(companionManager.voiceState == .processing ? 0.95 : 0.45))
                        .frame(width: 5, height: 5)

                    Text(activityText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background)
                .shadow(color: Color.black.opacity(0.40), radius: 14, x: 0, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.borderStrong, lineWidth: 0.8)
        )
        .animation(.easeOut(duration: 0.16), value: companionManager.textCommandActivityText)
        .onAppear {
            commandText = ""
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
    }

    private func submitCommand() {
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }
        commandText = ""
        Task {
            await companionManager.submitTextCommand(trimmedCommand)
        }
    }
}
