import Services
import SwiftUI

extension SettingsSheet {
    var apiStylePicker: some View {
        Picker("API", selection: $store.apiStyle) {
            Text("Responses").tag(LLMAPIStyle.responses)
            Text("Chat Completions").tag(LLMAPIStyle.chatCompletions)
        }
    }
}
