import SwiftUI

struct MetricsRow: View {
    let metrics: HealthMetrics

    var body: some View {
        HStack(alignment: .top) {
            MetricTile(title: "Vilopuls", unit: "bpm", sample: metrics.restingHeartRate, format: "%.0f")
            Divider()
            MetricTile(title: "HRV", unit: "ms", sample: metrics.heartRateVariability, format: "%.0f")
            Divider()
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
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(sample.map { String(format: format, $0.value) } ?? "–")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let date = sample?.date {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
