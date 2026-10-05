import Foundation
import HealthKit
import Observation

/// Loads, refreshes, and persists the iPhone health history.
@MainActor @Observable
final class HistoryStore {
    /// In-memory health samples and refresh metadata.
    private(set) var cache = HistoryCache()
    /// Whether the current history refresh is in progress.
    private(set) var isLoading = false
    /// Whether the Health authorization prompt is in progress.
    private(set) var isAuthorizing = false
    /// Whether the Health authorization prompt has completed before.
    private(set) var authorizationRequested = UserDefaults.standard.bool(forKey: "healthAuthorizationRequested")
    /// Most recent error from requesting Health authorization.
    private(set) var authorizationError: String?
    /// Refresh errors indexed by health metric.
    private(set) var errors: [HealthMetric: String] = [:]
    /// Most recent local cache read or write error.
    private(set) var cacheError: String?
    /// Whether HealthKit data is available on this device.
    let available = HKHealthStore.isHealthDataAvailable()
    /// HealthKit store used for history authorization and queries.
    @ObservationIgnored private let healthStore = HKHealthStore()
    /// Actor responsible for reading and writing the protected history cache.
    @ObservationIgnored private let file = HistoryCacheFile()
    /// Whether the persisted cache has been installed in memory.
    @ObservationIgnored private var loadedCache = false
    /// Shared in-flight task that reads the cache once.
    @ObservationIgnored private var cacheLoadTask: Task<HistoryCache, Error>?
    /// Identifier of the latest refresh, used to reject superseded results.
    @ObservationIgnored private var requestID = UUID()

    /// Loads the persisted cache once, sharing any in-flight read.
    func loadCache() async {
        guard !loadedCache else { return }
        if cacheLoadTask == nil {
            cacheLoadTask = Task { try await file.read() }
        }
        do {
            // Loaded cache awaiting validation or installation in memory.
            let result = try await cacheLoadTask!.value
            guard !loadedCache else { return }
            cache = result
            loadedCache = true
            cacheLoadTask = nil
        } catch {
            cacheLoadTask = nil
            cacheError = "Could not read the local cache: \(error.localizedDescription)"
        }
    }

    /// Requests read access to the supported Health metrics.
    func authorize() async {
        guard available, !isAuthorizing else { return }
        isAuthorizing = true
        authorizationError = nil
        defer { isAuthorizing = false }
        do {
            // Completion indicates the prompt finished, never whether read access was granted.
            try await healthStore.requestAuthorization(toShare: [], read: Set(HealthMetric.allCases.map(\.quantityType)))
            authorizationRequested = true
            UserDefaults.standard.set(true, forKey: "healthAuthorizationRequested")
        } catch {
            authorizationError = error.localizedDescription
        }
    }

    /// Returns cached samples starting within the requested interval.
    func samples(metric: HealthMetric, interval: DateInterval) -> [HealthSample] {
        cache.samples.filter { $0.metric == metric && $0.start >= interval.start && $0.start < interval.end }
    }

    /// Returns the latest refresh timestamp covering this metric and interval.
    func lastRefresh(metric: HealthMetric, interval: DateInterval) -> Date? {
        cache.refreshes.last {
            $0.metric == metric && $0.interval.start <= interval.start && $0.interval.end >= interval.end
        }?.date
    }

    /// Refreshes recent and selected history, then reconciles and persists the cache.
    func refresh(interval: DateInterval) async {
        await loadCache()
        guard available, authorizationRequested, !Task.isCancelled else { return }
        // Identifier used to discard results from superseded refresh requests.
        let id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }

        // Calendar used to calculate date boundaries.
        let calendar = Calendar.autoupdatingCurrent
        // Start of today in the current calendar.
        let today = calendar.startOfDay(for: Date())
        // Rolling 30-day interval refreshed alongside the selected period.
        let recent = DateInterval(start: calendar.date(byAdding: .day, value: -29, to: today)!,
                                  end: calendar.date(byAdding: .day, value: 1, to: today)!)
        // Date ranges to query without duplicating a covered selection.
        let ranges = recent.start <= interval.start && recent.end >= interval.end ? [recent] : [recent, interval]

        for metric in HealthMetric.allCases {
            do {
                // Queried ranges and samples awaiting cache reconciliation.
                var replacements: [(DateInterval, [HealthSample])] = []
                for range in ranges {
                    // Restricts the HealthKit query to samples starting in this range.
                    let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: .strictStartDate)
                    // Query that reads the metric’s samples in chronological order.
                    let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: metric.quantityType, predicate: predicate)],
                                                             sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)])
                    // Measurements available for the requested metric and date range.
                    let samples = try await descriptor.result(for: healthStore)
                    replacements.append((range, samples.filter { $0.startDate < range.end }.map { HealthSample($0, metric: metric) }))
                }
                // Query that retrieves the most recent sample for this metric.
                let latestQuery = HKSampleQueryDescriptor(predicates: [.quantitySample(type: metric.quantityType)],
                                                          sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate, order: .reverse)], limit: 1)
                // Most recent accessible measurements for each metric.
                let latest = try await latestQuery.result(for: healthStore)
                try Task.checkCancellation()
                guard requestID == id else { return }
                // Replace queried ranges so deletions and permission changes reconcile too.
                for (range, samples) in replacements {
                    cache.samples.removeAll { $0.metric == metric && $0.start >= range.start && $0.start < range.end }
                    cache.samples.append(contentsOf: samples)
                    cache.refreshes.removeAll { $0.metric == metric && $0.interval == range }
                    cache.refreshes.append(HistoryRefresh(metric: metric, interval: range, date: Date()))
                }
                cache.samples = Array(Dictionary(cache.samples.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values)
                    .sorted { $0.start < $1.start }
                cache.latest.removeAll { $0.metric == metric }
                cache.latest.append(contentsOf: latest.map { HealthSample($0, metric: metric) })
                errors[metric] = nil
                do {
                    try await file.write(cache)
                    cacheError = nil
                } catch {
                    cacheError = "History is available in memory, but could not be cached: \(error.localizedDescription)"
                }
            } catch is CancellationError {
                return
            } catch {
                guard requestID == id, !Task.isCancelled else { return }
                errors[metric] = "Could not refresh \(String(localized: metric.title)): \(error.localizedDescription). Cached history remains available. Try again after unlocking your iPhone."
            }
        }
    }
}
