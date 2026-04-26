import CarbocationLocalSpeech
import SwiftUI

public struct MicrophonePermissionStatusView: View {
    public var status: MicrophonePermissionStatus

    public init(status: MicrophonePermissionStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(status == .authorized ? .green : .orange)
            Text(title)
            Spacer()
        }
        .font(.callout)
    }

    private var iconName: String {
        switch status {
        case .authorized:
            return "mic"
        case .denied, .restricted:
            return "mic.slash"
        case .notDetermined, .unknown:
            return "mic.badge.plus"
        }
    }

    private var title: String {
        switch status {
        case .authorized:
            return "Microphone Available"
        case .denied:
            return "Microphone Denied"
        case .restricted:
            return "Microphone Restricted"
        case .notDetermined:
            return "Microphone Not Requested"
        case .unknown:
            return "Microphone Unknown"
        }
    }
}
