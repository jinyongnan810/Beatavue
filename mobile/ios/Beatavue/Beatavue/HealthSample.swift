import Foundation
import HealthKit

/// Defines the supported HealthKit measurements and display units.
nonisolated enum HealthMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case heartRate, hrv
    /// Raw value used to identify this picker option.
    var id: String { rawValue }
    /// Localized label for this option or workout state.
    var title: LocalizedStringResource {
        switch self {
        case .heartRate: "Heart rate"
        case .hrv: "HRV (SDNN)"
        }
    }

    /// Unit label used to display measurement values.
    var unit: String { self == .heartRate ? "bpm" : "ms" }
    /// HealthKit quantity type corresponding to this metric.
    var quantityType: HKQuantityType {
        HKQuantityType(self == .heartRate ? .heartRate : .heartRateVariabilitySDNN)
    }

    /// HealthKit unit used to convert this metric into display values.
    var healthUnit: HKUnit {
        self == .heartRate ? .count().unitDivided(by: .minute()) : .secondUnit(with: .milli)
    }
}

/// Stores a measurement and its HealthKit source metadata.
nonisolated struct HealthSample: Codable, Identifiable, Equatable, Sendable {
    /// UUID of the original HealthKit measurement.
    let id: UUID
    /// Health metric associated with these measurements.
    let metric: HealthMetric
    /// Measurement expressed in the metric’s display unit.
    let value: Double
    /// Start timestamp of the HealthKit measurement.
    let start: Date
    /// End timestamp of the HealthKit measurement.
    let end: Date
    /// Display name of the app that recorded the measurement.
    let sourceName: String
    /// Bundle identifier of the app that recorded the measurement.
    let sourceIdentifier: String
    /// Version of the recording app, when available.
    let sourceVersion: String?
    /// Name of the recording device, when available.
    let deviceName: String?
    /// Model of the recording device, when available.
    let deviceModel: String?

    /// Copies a HealthKit sample into the cache’s portable measurement format.
    init(_ sample: HKQuantitySample, metric: HealthMetric) {
        id = sample.uuid
        self.metric = metric
        value = sample.quantity.doubleValue(for: metric.healthUnit)
        start = sample.startDate
        end = sample.endDate
        sourceName = sample.sourceRevision.source.name
        sourceIdentifier = sample.sourceRevision.source.bundleIdentifier
        sourceVersion = sample.sourceRevision.version
        deviceName = sample.device?.name
        deviceModel = sample.device?.model
    }
}

/// Defines the calendar periods available for browsing history.
nonisolated enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    /// Raw value used to identify this picker option.
    var id: String { rawValue }
    /// Localized label for this option or workout state.
    var title: LocalizedStringResource {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    /// Calendar component used to calculate and navigate this period.
    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// Returns the calendar interval containing the date in the supplied timezone.
    func interval(containing date: Date, timeZone: TimeZone) -> DateInterval {
        // Calendar used to calculate date boundaries.
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        return calendar.dateInterval(of: component, for: date)!
    }
}

/// Records when a metric and date interval were refreshed.
nonisolated struct HistoryRefresh: Codable, Equatable, Sendable {
    /// Health metric associated with these measurements.
    let metric: HealthMetric
    /// Date range represented by this history request or display.
    let interval: DateInterval
    /// Timestamp when this metric and interval were refreshed.
    let date: Date
}

/// Stores versioned samples and refresh metadata for local persistence.
nonisolated struct HistoryCache: Codable, Sendable {
    /// Cache schema version used to validate persisted data.
    var version = 1
    /// Measurements available for the requested metric and date range.
    var samples: [HealthSample] = []
    /// Most recent accessible measurements for each metric.
    var latest: [HealthSample] = []
    /// Refresh timestamps for cached metric and interval pairs.
    var refreshes: [HistoryRefresh] = []
}

// Disk access runs outside the UI actor. The cache is excluded from device backups.
actor HistoryCacheFile {
    /// Creates the cache directory and returns its file URL.
    private func location() throws -> URL {
        // Application support directory containing the local history cache.
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Beatavue", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // URL used for cache file access or directory metadata.
        var url = directory
        // Resource metadata used to exclude the cache directory from backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return directory.appendingPathComponent("history-v1.json")
    }

    /// Reads and validates the persisted cache, or returns an empty cache.
    func read() throws -> HistoryCache {
        // URL used for cache file access or directory metadata.
        let url = try location()
        guard FileManager.default.fileExists(atPath: url.path) else { return HistoryCache() }
        // Loaded cache awaiting validation or installation in memory.
        let result = try JSONDecoder().decode(HistoryCache.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return result
    }

    /// Atomically saves the cache with complete file protection.
    func write(_ cache: HistoryCache) throws {
        try JSONEncoder().encode(cache).write(to: location(), options: [.atomic, .completeFileProtection])
    }
}
