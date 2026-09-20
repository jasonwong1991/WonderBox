import Charts
import SwiftUI

struct PageHeader: View {
    let title: String
    let subtitle: String
    var actionTitle: String?
    var actionSymbol: String = "arrow.clockwise"
    var isWorking = false
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSymbol)
                }
                .disabled(isWorking)
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    var progress: Double? = nil
    var history: [Double] = []
    var actionSymbol: String? = nil
    var actionHelp: String? = nil
    var actionIsWorking = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let actionSymbol, let action {
                    Button(action: action) {
                        if actionIsWorking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: actionSymbol)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(actionHelp ?? title)
                    .accessibilityLabel(actionHelp ?? title)
                    .disabled(actionIsWorking)
                }
            }

            HStack(alignment: .lastTextBaseline) {
                Text(value)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 8)
                if history.count > 1 {
                    Chart(Array(history.enumerated()), id: \.offset) { point in
                        LineMark(
                            x: .value("时间", point.offset),
                            y: .value("数值", point.element)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 0...1)
                    .frame(width: 72, height: 28)
                    .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if let progress {
                    ProgressView(value: min(1, max(0, progress)))
                        .tint(tint)
                        .controlSize(.small)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 112, alignment: .topLeading)
        .appPanel()
    }
}

struct EmptyContentView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
                .background(Color.subtleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct InlineMessage: View {
    let text: String
    var isError = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.warning : Color.healthy)
            Text(text)
                .font(.subheadline)
            Spacer()
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
                .accessibilityLabel("关闭消息")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background((isError ? Color.warning : Color.healthy).opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
