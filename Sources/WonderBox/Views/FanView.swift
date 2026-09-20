import SwiftUI

struct FanView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedMode: FanMode = .automatic
    @State private var customRPM = 2_400.0
    @State private var isApplying = false

    private var rpmRange: ClosedRange<Double> {
        let minimum = model.fans.map(\.minimumRPM).filter { $0 > 0 }.max() ?? 1_200
        let maximum = model.fans.map(\.maximumRPM).filter { $0 > minimum }.min() ?? 6_000
        return minimum...maximum
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "风扇", subtitle: "Apple SMC · 按需控制")

                HStack {
                    StatusPill(
                        text: model.fans.isEmpty ? "当前机型不支持" : "已连接 \(model.fans.count) 个风扇",
                        color: model.fans.isEmpty ? .secondary : .healthy,
                        symbol: model.fans.isEmpty ? "fan.slash" : "fan.fill"
                    )
                    Spacer()
                    StatusPill(text: "Direct 增强模块", color: Color(hex: 0x7A67D8), symbol: "lock.shield")
                }

                if model.fans.isEmpty {
                    EmptyContentView(
                        symbol: "fan.slash",
                        title: "未读取到风扇传感器",
                        detail: "无风扇机型或当前系统未开放 AppleSMC 通道"
                    )
                    .frame(minHeight: 210)
                    .appPanel()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                        ForEach(model.fans) { fan in
                            FanGaugeCard(fan: fan)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("控制模式")
                            .font(.headline)
                        Spacer()
                        Text("首次启用时授权一次")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("风扇模式", selection: $selectedMode) {
                        ForEach(FanMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.fans.isEmpty || isApplying)

                    if selectedMode == .custom {
                        VStack(spacing: 8) {
                            HStack {
                                Text("目标转速")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(customRPM.rounded())) RPM")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .monospacedDigit()
                            }
                            Slider(value: $customRPM, in: rpmRange, step: 50)
                        }
                    }

                    HStack {
                        if let message = model.fanMessage {
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            isApplying = true
                            Task {
                                await model.applyFan(mode: selectedMode, customRPM: customRPM)
                                isApplying = false
                            }
                        } label: {
                            Label(isApplying ? "正在应用" : "应用模式", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.fans.isEmpty || isApplying)
                    }
                }
                .appPanel()
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .onAppear {
            if let first = model.fans.first {
                customRPM = min(rpmRange.upperBound, max(rpmRange.lowerBound, first.currentRPM))
            }
        }
        .task {
            await model.refreshFans()
            if let first = model.fans.first {
                customRPM = min(rpmRange.upperBound, max(rpmRange.lowerBound, first.currentRPM))
            }
        }
    }
}

private struct FanGaugeCard: View {
    let fan: FanReading

    private var range: ClosedRange<Double> {
        let minimum = max(0, fan.minimumRPM)
        return minimum...max(minimum + 1, fan.maximumRPM)
    }

    var body: some View {
        HStack(spacing: 18) {
            Gauge(value: fan.currentRPM, in: range) {
                Image(systemName: "fan.fill")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Color.healthy)
            .scaleEffect(1.35)
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 5) {
                Text(fan.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(Int(fan.currentRPM.rounded()))")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("RPM · \(Int(fan.minimumRPM))–\(Int(fan.maximumRPM))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .appPanel()
    }
}
