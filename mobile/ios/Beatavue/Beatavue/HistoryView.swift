import Charts
import SwiftUI

#Preview("History") {
    HistoryView(store: HistoryStore())
}

#Preview("Sample list") {
    NavigationStack {
        SampleList(samples: [], metric: .heartRate)
    }
}

/// Displays health history for the selected metric and period.
struct HistoryView: View {
    /// Store supplying health data and authorization state.
    let store: HistoryStore
    /// App lifecycle phase used to refresh history on activation.
    @Environment(\.scenePhase) private var scenePhase
    /// Timezone supplied by the view environment.
    @Environment(\.timeZone) private var timeZone
    /// Health metric associated with these measurements.
    @AppStorage("historyMetric") private var metric = HealthMetric.heartRate
    /// Selected calendar period for browsing history.
    @AppStorage("historyPeriod") private var period = HistoryPeriod.day
    /// Selected date used to determine the displayed history period.
    @State private var date = Date()
    /// Refresh counter that restarts the history loading task.
    @State private var revision = 0

    /// Builds the interface for this view.
    var body: some View {
        // Date range represented by this history request or display.
        let interval = period.interval(containing: date, timeZone: timeZone)
        // Measurements available for the requested metric and date range.
        let samples = store.samples(metric: metric, interval: interval)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Metric", selection: $metric) {
                        ForEach(HealthMetric.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HistoryNavigation(period: $period, date: $date, interval: interval)
                    HealthAccessView(store: store)
                    if store.isLoading { ProgressView("Refreshing…") }
                    if let error = store.errors[metric] { Text(error).foregroundStyle(.orange) }
                    if let error = store.cacheError { Text(error).foregroundStyle(.orange) }
                    LatestSampleView(sample: store.cache.latest.first { $0.metric == metric }, metric: metric)
                    HistoryChart(samples: samples, metric: metric, interval: interval)
                    SampleSummary(samples: samples, unit: metric.unit)
                    if let refreshed = store.lastRefresh(metric: metric, interval: interval) {
                        Text("Updated \(refreshed, format: .dateTime.month().day().hour().minute())")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not refreshed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        SampleList(samples: samples, metric: metric)
                    } label: {
                        Label("\(samples.count) samples", systemImage: "list.bullet")
                    }
                }
                .padding()
            }
            .refreshable { await store.refresh(interval: interval) }
            .navigationTitle("Beatavue")
            .task(id: HistoryRequest(interval: interval, revision: revision)) {
                await store.refresh(interval: interval)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { revision += 1 }
            }
        }
    }
}

/// Identifies the period and revision that trigger a history refresh.
private struct HistoryRequest: Equatable {
    /// Date range represented by this history request or display.
    let interval: DateInterval
    /// Refresh counter that restarts the history loading task.
    let revision: Int
}

/// Provides period selection and date navigation.
struct HistoryNavigation: View {
    /// Selected calendar period for browsing history.
    @Binding var period: HistoryPeriod
    /// Selected date used to determine the displayed history period.
    @Binding var date: Date
    /// Date range represented by this history request or display.
    let interval: DateInterval
    /// Timezone supplied by the view environment.
    @Environment(\.timeZone) private var timeZone

    /// Builds the interface for this view.
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

    /// Moves the selected date by a calendar period without going into the future.
    private func move(_ amount: Int) {
        // Calendar used to calculate date boundaries.
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        if let moved = calendar.date(byAdding: period.component, value: amount, to: date) {
            date = min(moved, Date())
        }
    }
}

/// Displays Health availability and authorization controls.
struct HealthAccessView: View {
    /// Store supplying health data and authorization state.
    let store: HistoryStore

    /// Builds the interface for this view.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.available {
                if let error = store.authorizationError { Text(error).foregroundStyle(.orange) }
            } else {
                Label("Health unavailable", systemImage: "exclamationmark.circle")
                Text("Showing saved history.")
            }
        }
    }
}

/// Displays the latest accessible measurement and its source.
struct LatestSampleView: View {
    /// Measurement displayed by this view.
    let sample: HealthSample?
    /// Health metric associated with these measurements.
    let metric: HealthMetric

    /// Builds the interface for this view.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latest").font(.subheadline).foregroundStyle(.secondary)
            if let sample {
                Text("\(sample.value, format: .number.precision(.fractionLength(1))) \(metric.unit)")
                    .font(.largeTitle.bold())
                Text(sample.start, format: .dateTime.year().month().day().hour().minute().second())
                Text(sample.sourceName).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No data").font(.headline)
                Text("Check Health access and Watch sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Plots measured samples and supports inspecting nearby readings.
struct HistoryChart: View {
    /// Measurements available for the requested metric and date range.
    let samples: [HealthSample]
    /// Health metric associated with these measurements.
    let metric: HealthMetric
    /// Date range represented by this history request or display.
    let interval: DateInterval
    /// Chart timestamp selected for inspecting nearby measurements.
    @State private var selectedDate: Date?
    /// Timezone supplied by the view environment.
    @Environment(\.timeZone) private var timeZone

    /// Builds the interface for this view.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(metric.title).font(.headline)
            if samples.isEmpty {
                ContentUnavailableView("No data", systemImage: "heart",
                                       description: Text("Try another date or pull to refresh."))
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
                Text("Tap a point for details.")
                    .font(.caption).foregroundStyle(.secondary)
                if let selectedDate,
                   // Sample closest to the timestamp selected on the chart.
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

    /// Timezone-aware axis labels suited to the displayed interval.
    private var axisDateFormat: Date.FormatStyle {
        // Base date formatter configured for the display timezone.
        let format = Date.FormatStyle(timeZone: timeZone)
        return interval.duration <= 90000 ? format.hour().minute() : format.month().day()
    }
}

/// Displays minimum, maximum, and mean sample values.
struct SampleSummary: View {
    /// Measurements available for the requested metric and date range.
    let samples: [HealthSample]
    /// Unit label used to display measurement values.
    let unit: String

    /// Builds the interface for this view.
    var body: some View {
        if !samples.isEmpty {
            // Measurement values used to calculate summary statistics.
            let values = samples.map(\.value)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(samples.count) samples").font(.headline)
                LabeledContent("Min", value: "\(values.min()!.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                LabeledContent("Max", value: "\(values.max()!.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                LabeledContent("Average", value: "\((values.reduce(0, +) / Double(values.count)).formatted(.number.precision(.fractionLength(1)))) \(unit)")
            }
        }
    }
}

/// Lists individual measurements for the selected metric.
struct SampleList: View {
    /// Measurements available for the requested metric and date range.
    let samples: [HealthSample]
    /// Health metric associated with these measurements.
    let metric: HealthMetric
    /// Builds the interface for this view.
    var body: some View {
        List(samples) { sample in SampleDetail(sample: sample) }
            .navigationTitle(Text(metric.title))
    }
}

/// Displays a measurement, timestamp, and source metadata.
struct SampleDetail: View {
    /// Measurement displayed by this view.
    let sample: HealthSample
    /// Builds the interface for this view.
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
