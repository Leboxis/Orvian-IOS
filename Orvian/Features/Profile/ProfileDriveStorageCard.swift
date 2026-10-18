import SwiftUI

/// Le quota du drive, avec une jauge courte et deux valeurs lisibles.
struct ProfileDriveStorageCard: View {
    let session: SessionStore
    let drive: Drive
    var refreshFailed = false

    var body: some View {
        let used = drive.usedSize.flatMap { $0 >= 0 ? $0 : nil }
        let total = drive.size.flatMap { $0 > 0 ? $0 : nil }
        let free = total.flatMap { total in used.map { max(total - $0, 0) } }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(drive.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if session.drives.count > 1 {
                    Menu {
                        ForEach(session.drives) { candidate in
                            Button {
                                session.selectDrive(candidate)
                            } label: {
                                if candidate.id == drive.id {
                                    Label(candidate.name, systemImage: "checkmark")
                                } else {
                                    Text(candidate.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Changer de drive")
                }
            }

            if let used, let total {
                ProgressView(value: min(Double(used) / Double(total), 1))
                    .tint(Double(used) / Double(total) >= 0.9 ? .orange : .accentColor)
                    .accessibilityLabel("Stockage utilisé")
            }

            HStack(alignment: .firstTextBaseline) {
                storageValue(used, label: "utilisés", tint: .accentColor)
                Spacer(minLength: 12)
                storageValue(free, label: "libres", tint: .secondary)
            }
            .font(.caption)
            .monospacedDigit()

            if refreshFailed {
                Text("Dernière mesure connue · actualisation indisponible")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func storageValue(_ bytes: Int?, label: String, tint: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ByteFormatter.string(fromBytes: bytes)).fontWeight(.semibold).foregroundStyle(tint)
                Text(label).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteFormatter.string(fromBytes: bytes)).fontWeight(.semibold).foregroundStyle(tint)
                Text(label).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
