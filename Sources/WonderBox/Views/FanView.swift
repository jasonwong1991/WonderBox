import SwiftUI

struct FanView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedMode: FanMode = .automatic
    @State private var customRPM = 2_400.0
    @State private var isApplying = false

    private var temperaturePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Core Temperatures", systemImage: "thermometer.medium").font(.headline)
            Text("Each available CPU/GPU sensor is shown separately. Sensor coverage and physical-core mapping depend on this Mac; missing cores are not estimated.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.temperatures.isEmpty {
                Text(model.hasReadFans ? "No temperature sensors exposed on this Mac" : "Reading temperature sensors…")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(model.temperatures) { reading in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(reading.title).font(.caption).foregroundStyle(.secondary)
                            Text(reading.formatted).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                            Text(reading.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color.subtleBackground).clipShape(RoundedRectangle(cornerRadius: 7))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }.appPanel()
    }

    private func temperatureSummary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "thermometer.medium").font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).appPanel()
        .help("Highest available sensor reading; unavailable sensors show a dash")
    }

    private var rpmRange: ClosedRange<Double> {
        let minimum = model.fans.map(\.minimumRPM).filter { $0 > 0 }.max() ?? 1_200
        let maximum = model.fans.map(\.maximumRPM).filter { $0 > minimum }.min() ?? 6_000
        return minimum...maximum
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: String(localized: "Fan"), subtitle: String(localized: "Apple SMC · On-demand control"))

                HStack {
                    StatusPill(
                        text: !model.hasReadFans ? String(localized: "Reading fan sensors…") : model.fans.isEmpty ? String(localized: "Not supported on this Mac") : String(localized: "\(model.fans.count) fans connected"),
                        color: model.fans.isEmpty ? .secondary : .healthy,
                        symbol: model.fans.isEmpty ? "fan.slash" : "fan.fill"
                    )
                    Spacer()
                    StatusPill(text: String(localized: "Direct build module"), color: Color(hex: 0x7A67D8), symbol: "lock.shield")
                }

                HStack(spacing: 14) {
                    temperatureSummary(String(localized: "CPU Temperature"), value: TemperatureReading.summary(model.temperatures))
                    temperatureSummary(String(localized: "GPU Temperature"), value: TemperatureReading.summary(model.temperatures, gpu: true))
                }

                if !model.hasReadFans {
                    ProgressView("Reading fan sensors…")
                        .frame(maxWidth: .infinity, minHeight: 210)
                        .appPanel()
                } else if model.fans.isEmpty {
                    EmptyContentView(
                        symbol: "fan.slash",
                        title: String(localized: "No Fan Sensors Found"),
                        detail: String(localized: "Fanless Mac, or AppleSMC is not exposed on this system")
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
                        Text("Control Mode")
                            .font(.headline)
                        Spacer()
                        Text("Authorize once on first use")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Fan Mode", selection: $selectedMode) {
                        ForEach(FanMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.fans.isEmpty || isApplying)

                    if selectedMode == .custom {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Target Speed")
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
                            Label(isApplying ? "Applying…" : "Apply Mode", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.fans.isEmpty || isApplying)
                    }
                }
                .appPanel()

                temperaturePanel
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .onAppear {
            // Refreshing only samples sensors; it never reapplies the selected fan mode.
            if let first = model.fans.first {
                customRPM = min(rpmRange.upperBound, max(rpmRange.lowerBound, first.currentRPM))
            }
        }
        .sectionRefresh(.fan, busy: model.isRefreshingFans || isApplying) { await model.refreshFans() }
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
        0...max(1, fan.maximumRPM)
    }

    var body: some View {
        HStack(spacing: 18) {
            Gauge(value: min(range.upperBound, max(0, fan.currentRPM)), in: range) {
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
                if fan.currentRPM == 0 {
                    Text("Stopped · normal when the Mac is cool")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .appPanel()
    }
}
