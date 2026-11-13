import SwiftUI

struct MetricsRow: View {
    let metrics: HealthMetrics

    var body: some View {
        HStack(alignment: .top) {
            MetricTile(title: "Vilopuls", unit: "bpm", sample: metrics.restingHeartRate, decimals: 0)
            Divider().overlay(Theme.border)
            MetricTile(title: "HRV", unit: "ms", sample: metrics.heartRateVariability, decimals: 0)
            Divider().overlay(Theme.border)
            MetricTile(title: "VO2 max", unit: "ml/kg/min", sample: metrics.vo2Max, decimals: 1)
        }
        .padding(.vertical, 4)
    }
}

private struct MetricTile: View {
    let title: String
    let unit: String
    let sample: MetricSample?
    let decimals: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(Theme.cyan)
            Text(sample.map { decimalText($0.value, decimals: decimals) } ?? "–")
                .font(Theme.metric(28))
                .foregroundStyle(.white)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
            if let date = sample?.date {
                Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
