import SwiftUI

/// Panneau de diagnostic réseau : chronométrage de chaque requête API.
/// Sert de point de mesure avant/après les optimisations (caches,
/// parallélisation) : durées par endpoint, codes HTTP, requêtes récentes.
struct PerfView: View {
    @ObservedObject private var perf = Perf.shared

    var body: some View {
        List {
            summarySection
            statsSection
            entriesSection
        }
        .navigationTitle("Mesures réseau")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Réinitialiser") {
                    perf.reset()
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Requêtes totales", value: "\(perf.totalRequests)")
            LabeledContent("Durée moyenne", value: "\(perf.averageMs) ms")
            LabeledContent("Dont miniatures", value: "\(perf.thumbnailRequests)")
        } header: {
            Text("Depuis l'ouverture")
        } footer: {
            Text("Les miniatures sont comptées dans le total mais exclues de la moyenne : elles masqueraient la latence des appels de données.")
        }
    }

    private var statsSection: some View {
        Section {
            if perf.statsByEndpoint.isEmpty {
                Text("Aucune requête enregistrée")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(perf.statsByEndpoint, id: \.name) { stat in
                    HStack {
                        Text(stat.name)
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(stat.count)×")
                            .foregroundStyle(.secondary)
                            .font(.callout.monospaced())
                        Text("\(stat.averageMs) ms moy · \(stat.maxMs) ms max")
                            .foregroundStyle(stat.averageMs > 800 ? .red : (stat.averageMs > 300 ? .orange : .green))
                            .font(.callout.monospaced())
                    }
                }
            }
        } header: {
            Text("Par endpoint")
        } footer: {
            Text("Vert < 300 ms · orange < 800 ms · rouge au-delà. Un endpoint appelé très souvent avec une moyenne élevée est le premier candidat d'optimisation.")
        }
    }

    private var entriesSection: some View {
        Section {
            ForEach(perf.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(entry.method) \(entry.endpointName)")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(entry.durationMs) ms")
                            .font(.callout.monospaced().weight(.semibold))
                            .foregroundStyle(entry.durationMs > 800 ? .red : (entry.durationMs > 300 ? .orange : .green))
                    }
                    HStack {
                        Text(entry.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(entry.status) · \(entry.bytes) o")
                            .font(.caption.monospaced())
                            .foregroundStyle(entry.status >= 400 ? .red : .secondary)
                    }
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Dernières requêtes")
        } footer: {
            Text("La liste exclut les miniatures (voir le décompte dédié). Code 304 = réponse valide depuis le cache HTTP, quasiment gratuite.")
        }
    }
}
