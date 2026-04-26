import CarbocationLocalSpeech
import SwiftUI

@MainActor
public struct SpeechSettingsView: View {
    private let library: SpeechModelLibrary
    @Binding private var selectionStorageValue: String
    private let systemOptions: [SpeechSystemModelOption]

    public init(
        library: SpeechModelLibrary,
        selectionStorageValue: Binding<String>,
        systemOptions: [SpeechSystemModelOption] = []
    ) {
        self.library = library
        self._selectionStorageValue = selectionStorageValue
        self.systemOptions = systemOptions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicrophonePermissionStatusView(status: MicrophonePermissionHelper.authorizationStatus())
            SpeechModelLibraryPickerView(
                library: library,
                selectionStorageValue: $selectionStorageValue,
                systemOptions: systemOptions
            )
        }
    }
}
