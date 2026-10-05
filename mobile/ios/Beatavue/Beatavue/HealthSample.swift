import Foundation
import HealthKit

nonisolated enum HealthMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case heartRate, hrv
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .heartRate: "Heart rate"
        case .hrv: "HRV (SDNN)"
        }
    }

    var unit: String { self == .heartRate ? "bpm" : "ms" }
    var quantityType: HKQuantityType {
        HKQuantityType(self == .heartRate ? .heartRate : .heartRateVariabilitySDNN)
    }

    var healthUnit: HKUnit {
        self == .heartRate ? .count().unitDivided(by: .minute()) : .secondUnit(with: .milli)
    }
}

nonisolated struct HealthSample: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let metric: HealthMetric
    let value: Double
    let start: Date
    let end: Date
    let sourceName: String
    let sourceIdentifier: String
    let sourceVersion: String?
    let deviceName: String?
    let deviceModel: String?

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

nonisolated enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    func interval(containing date: Date, timeZone: TimeZone) -> DateInterval {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        return calendar.dateInterval(of: component, for: date)!
    }
}

nonisolated struct HistoryRefresh: Codable, Equatable, Sendable {
    let metric: HealthMetric
    let interval: DateInterval
    let date: Date
}

nonisolated struct HistoryCache: Codable, Sendable {
    var version = 1
    var samples: [HealthSample] = []
    var latest: [HealthSample] = []
    var refreshes: [HistoryRefresh] = []
}

// Disk access runs outside the UI actor. The cache is excluded from device backups.
actor HistoryCacheFile {
    private func location() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Beatavue", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return directory.appendingPathComponent("history-v1.json")
    }

    func read() throws -> HistoryCache {
        let url = try location()
        guard FileManager.default.fileExists(atPath: url.path) else { return HistoryCache() }
        let result = try JSONDecoder().decode(HistoryCache.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return result
    }

    func write(_ cache: HistoryCache) throws {
        try JSONEncoder().encode(cache).write(to: location(), options: [.atomic, .completeFileProtection])
    }
}
