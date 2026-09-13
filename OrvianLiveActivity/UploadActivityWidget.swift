import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity d'upload : progression en % dans la Dynamic Island
/// (compact + expanded) et sur l'écran verrouillé.
struct UploadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            lockScreenView(context.state, title: context.attributes.title)
        } dynamicIsland: { context in
            let percent = Int((context.state.progress * 100).rounded())
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(percent) %")
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.fileName)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: context.state.progress)
                            .tint(.blue)
                        if context.state.activeCount > 1 {
                            Text("\(context.state.activeCount) fichiers en cours")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.up.circle.fill")
            } compactTrailing: {
                Text("\(percent) %")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .keylineTint(.blue)
        }
    }

    /// Présentation sur l'écran verrouillé / bannière.
    private func lockScreenView(_ state: UploadActivityAttributes.ContentState, title: String) -> some View {
        let percent = Int((state.progress * 100).rounded())
        return HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.fileName)
                    .lineLimit(1)
                    .font(.headline)
                ProgressView(value: state.progress)
                    .tint(.blue)
            }
            Text("\(percent) %")
                .font(.headline.monospacedDigit())
        }
        .padding()
    }
}

@main
struct OrvianLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        UploadActivityWidget()
    }
}

#Preview("Upload en cours", as: .content, using: UploadActivityAttributes(title: "Envoi en cours")) {
    UploadActivityWidget()
} contentStates: {
    UploadActivityAttributes.ContentState(fileName: "Photo.jpg", progress: 0.42, activeCount: 1, totalCount: 3)
}
