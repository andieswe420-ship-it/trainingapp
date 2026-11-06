import SwiftUI

struct MetricsRow: View {
    let metrics: HealthMetrics

    var body: some View {
        HStack(alignment: .top) {
            MetricTile(title: "Vilopuls", unit: "bpm", sample: metrics.restingHeartRate, format: "%.0f")
            Divider().overlay(Theme.border)
            MetricTile(title: "HRV", unit: "ms", sample: metrics.heartRateVariability, format: "%.0f")
            Divider().overlay(Theme.border)
            MetricTile(title: "VO2 max", unit: "ml/kg/min", sample: metrics.vo2Max, format: "%.1f")
        }
        .padding(.vertical, 4)
    }
}

private struct MetricTile: View {
    let title: String
    let unit: String
    let sample: MetricSample?
    let format: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(Theme.cyan)
            Text(sample.map { String(format: format, $0.value) } ?? "–")
                .font(Theme.metric(28))
                .foregroundStyle(.white)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
            if let date = sample?.date {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
