import SwiftUI

/// Panneau de diagnostic réseau : chronométrage de chaque requête API.
/// Sert de point de mesure avant/après les optimisations (caches,
/// parallélisation) : durées par endpoint, codes HTTP, requêtes récentes.
struct PerfView: View {
    @ObservedObject private var perf = Perf.shared

    var body: some View {
        List {
            if PerfTimer.isEnabled {
                summarySection
                statsSection
                entriesSection
            } else {
                disabledSection
            }
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

    private var disabledSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Suivi désactivé", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.body.weight(.medium))
                Text("Le suivi des requêtes est désactivé dans Réglages → Diagnostic. Aucune nouvelle mesure n’est collectée ; les données ci-dessous datent d’avant la désactivation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Activez « Suivi des requêtes réseau » dans Réglages pour reprendre la mesure.")
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Requêtes totales", value: "\(perf.totalRequests)")
            LabeledContent("Durée moyenne", value: "\(perf.averageMs) ms")
            LabeledContent("Dont miniatures", value: "\(perf.thumbnailRequests)")
            LabeledContent("Servies du cache", value: "\(perf.cachedRequests)")
        } header: {
            Text("Depuis l'ouverture")
        } footer: {
            Text("Les miniatures sont comptées dans le total mais exclues de la moyenne : elles masqueraient la latence des appels de données. « Servies du cache » = réponses revalidées par 304 ou encore fraîches : aucun corps transféré.")
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
                        if entry.fromCache {
                            Text("cache")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }
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
            Text("La liste exclut les miniatures (voir le décompte dédié). Badge « cache » = réponse servie sans re-transfert (304 ou entrée fraîche).")
        }
    }
}
