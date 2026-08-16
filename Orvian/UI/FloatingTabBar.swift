import SwiftUI

/// Barre d'onglets flottante translucide à coins arrondis.
struct FloatingTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                TabButton(tab: tab, isSelected: selection == tab) {
                    withAnimation(.snappy(duration: 0.25)) {
                        selection = tab
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.tabBarRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.tabBarRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
        .padding(.horizontal, DS.gridMargin + 8)
    }
}

private struct TabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .symbolEffect(.bounce, value: isSelected)
                Text(tab.title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Onglets de l'application.
enum AppTab: String, CaseIterable, Identifiable {
    case recents
    case files
    case favorites
    case media
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recents: return "Actualité"
        case .files: return "Fichiers"
        case .favorites: return "Favoris"
        case .media: return "Média"
        case .more: return "Plus"
        }
    }

    var symbol: String {
        switch self {
        case .recents: return "clock"
        case .files: return "folder"
        case .favorites: return "star"
        case .media: return "photo.on.rectangle.angled"
        case .more: return "ellipsis"
        }
    }

    var symbolFilled: String {
        switch self {
        case .recents: return "clock.fill"
        case .files: return "folder.fill"
        case .favorites: return "star.fill"
        case .media: return "photo.fill.on.rectangle.fill.angled"
        case .more: return "ellipsis.circle.fill"
        }
    }
}
