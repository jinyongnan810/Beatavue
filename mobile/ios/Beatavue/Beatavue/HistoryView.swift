import Charts
import SwiftUI

struct HistoryView: View {
    let store: HistoryStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.timeZone) private var timeZone
    @AppStorage("historyMetric") private var metric = HealthMetric.heartRate
    @AppStorage("historyPeriod") private var period = HistoryPeriod.day
    @State private var date = Date()
    @State private var revision = 0

    var body: some View {
        let interval = period.interval(containing: date, timeZone: timeZone)
        let samples = store.samples(metric: metric, interval: interval)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Metric", selection: $metric) {
                        ForEach(HealthMetric.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HistoryNavigation(period: $period, date: $date, interval: interval)
                    HealthAccessView(store: store, refresh: { revision += 1 })
                    if store.isLoading { ProgressView("Refreshing Apple Health") }
                    if let error = store.errors[metric] { Text(error).foregroundStyle(.orange) }
                    if let error = store.cacheError { Text(error).foregroundStyle(.orange) }
                    LatestSampleView(sample: store.cache.latest.first { $0.metric == metric }, metric: metric)
                    HistoryChart(samples: samples, metric: metric, interval: interval)
                    SampleSummary(samples: samples, unit: metric.unit)
                    if let refreshed = store.lastRefresh(metric: metric, interval: interval) {
                        Text("This period refreshed \(refreshed, format: .dateTime.month().day().hour().minute())")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("This period has not been refreshed. Cached samples may be incomplete.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Points are measured samples from all accessible sources. Gaps mean no accessible readings; samples are not continuous or time weighted.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        SampleList(samples: samples, metric: metric)
                    } label: {
                        Label("Inspect all \(samples.count) samples", systemImage: "list.bullet")
                    }
                }
                .padding()
            }
            .navigationTitle("Beatavue")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { revision += 1 }
            }
            .refreshable { await store.refresh(interval: interval) }
            .task(id: HistoryRequest(interval: interval, revision: revision)) {
                await store.refresh(interval: interval)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { revision += 1 }
            }
        }
    }
}

private struct HistoryRequest: Equatable {
    let interval: DateInterval
    let revision: Int
}

struct HistoryNavigation: View {
    @Binding var period: HistoryPeriod
    @Binding var date: Date
    let interval: DateInterval
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack {
            Picker("Period", selection: $period) {
                ForEach(HistoryPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Previous period", systemImage: "chevron.left") { move(-1) }
                    .labelStyle(.iconOnly)
                Spacer()
                DatePicker("Selected date", selection: $date, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                Spacer()
                Button("Next period", systemImage: "chevron.right") { move(1) }
                    .labelStyle(.iconOnly)
                    .disabled(interval.end > Date())
            }.padding()
            if period != .day {
                Text("\(interval.start, format: .dateTime.month().day()) – \(interval.end.addingTimeInterval(-1), format: .dateTime.month().day().year())")
                    .font(.caption)
            }
        }
    }

    private func move(_ amount: Int) {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        if let moved = calendar.date(byAdding: period.component, value: amount, to: date) {
            date = min(moved, Date())
        }
    }
}

struct HealthAccessView: View {
    let store: HistoryStore
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.available {
                Text("Read heart rate and HRV (SDNN) from Apple Health to view your measurements.")
                    .font(.subheadline)
                Button("Review Health permissions") {
                    Task {
                        await store.authorize()
                        refresh()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isAuthorizing)
                if let error = store.authorizationError { Text(error).foregroundStyle(.orange) }
                Text("Manage existing access in the Health app’s privacy settings for Beatavue.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Apple Health is unavailable on this device", systemImage: "exclamationmark.circle")
                Text("Previously cached history remains available.")
            }
        }
    }
}

struct LatestSampleView: View {
    let sample: HealthSample?
    let metric: HealthMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latest available").font(.subheadline).foregroundStyle(.secondary)
            if let sample {
                Text("\(sample.value, format: .number.precision(.fractionLength(1))) \(metric.unit)")
                    .font(.largeTitle.bold())
                Text(sample.start, format: .dateTime.year().month().day().hour().minute().second())
                Text(sample.sourceName).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No accessible data").font(.headline)
                Text("Check Health permissions and allow time for Apple Watch to sync. Read authorization cannot be inferred from an empty result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct HistoryChart: View {
    let samples: [HealthSample]
    let metric: HealthMetric
    let interval: DateInterval
    @State private var selectedDate: Date?
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(metric.title).font(.headline)
            if samples.isEmpty {
                ContentUnavailableView("No accessible data", systemImage: "heart",
                                       description: Text("Try another date, review Health permissions, or refresh after Watch synchronization."))
            } else {
                Chart(samples) { sample in
                    PointMark(x: .value("Measurement time", sample.start),
                              y: .value(metric.unit, sample.value))
                        .foregroundStyle(by: .value("Source", sample.sourceName))
                        .symbolSize(18)
                }
                .chartXScale(domain: interval.start ... interval.end)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: axisDateFormat)
                            }
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXSelection(value: $selectedDate)
                .chartLegend(.hidden)
                .frame(height: 240)
                .accessibilityLabel(Text(metric.title))
                Text("Touch the graph to inspect the nearest measured sample. All points are raw measurements.")
                    .font(.caption).foregroundStyle(.secondary)
                if let selectedDate,
                   let nearest = samples.min(by: { abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate)) })
                {
                    // Retain overlapping measurements from different sources at the same timestamp.
                    ForEach(samples.filter { $0.start == nearest.start }) { sample in
                        SampleDetail(sample: sample)
                    }
                }
            }
        }
    }

    private var axisDateFormat: Date.FormatStyle {
        let format = Date.FormatStyle(timeZone: timeZone)
        return interval.duration <= 90000 ? format.hour().minute() : format.month().day()
    }
}

struct SampleSummary: View {
    let samples: [HealthSample]
    let unit: String

    var body: some View {
        if !samples.isEmpty {
            let values = samples.map(\.value)
            VStack(alignment: .leading, spacing: 8) {
                Text("Selected period · \(samples.count) samples").font(.headline)
                LabeledContent("Minimum", value: "\(values.min()!.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                LabeledContent("Maximum", value: "\(values.max()!.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                LabeledContent("Average of available samples", value: "\((values.reduce(0, +) / Double(values.count)).formatted(.number.precision(.fractionLength(1)))) \(unit)")
            }
        }
    }
}

struct SampleList: View {
    let samples: [HealthSample]
    let metric: HealthMetric
    var body: some View {
        List(samples) { sample in SampleDetail(sample: sample) }
            .navigationTitle(Text(metric.title))
    }
}

struct SampleDetail: View {
    let sample: HealthSample
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(sample.value, format: .number.precision(.fractionLength(1))) \(sample.metric.unit)").font(.headline)
            Text(sample.start, format: .dateTime.year().month().day().hour().minute().second())
            if sample.end != sample.start {
                Text("Ends \(sample.end, format: .dateTime.year().month().day().hour().minute().second())")
            }
            Text(sample.sourceName)
            Text(sample.sourceIdentifier).font(.caption).foregroundStyle(.secondary)
            if let device = sample.deviceName { Text(device).font(.caption) }
        }
        .font(.subheadline)
    }
}
