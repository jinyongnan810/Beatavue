import Foundation
import HealthKit
import Observation

@MainActor @Observable
final class HistoryStore {
    private(set) var cache = HistoryCache()
    private(set) var isLoading = false
    private(set) var isAuthorizing = false
    private(set) var authorizationRequested = UserDefaults.standard.bool(forKey: "healthAuthorizationRequested")
    private(set) var authorizationError: String?
    private(set) var errors: [HealthMetric: String] = [:]
    private(set) var cacheError: String?
    let available = HKHealthStore.isHealthDataAvailable()
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private let file = HistoryCacheFile()
    @ObservationIgnored private var loadedCache = false
    @ObservationIgnored private var cacheLoadTask: Task<HistoryCache, Error>?
    @ObservationIgnored private var requestID = UUID()

    func loadCache() async {
        guard !loadedCache else { return }
        if cacheLoadTask == nil {
            cacheLoadTask = Task { try await file.read() }
        }
        do {
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

    func samples(metric: HealthMetric, interval: DateInterval) -> [HealthSample] {
        cache.samples.filter { $0.metric == metric && $0.start >= interval.start && $0.start < interval.end }
    }

    func lastRefresh(metric: HealthMetric, interval: DateInterval) -> Date? {
        cache.refreshes.last {
            $0.metric == metric && $0.interval.start <= interval.start && $0.interval.end >= interval.end
        }?.date
    }

    func refresh(interval: DateInterval) async {
        await loadCache()
        guard available, authorizationRequested, !Task.isCancelled else { return }
        let id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let recent = DateInterval(start: calendar.date(byAdding: .day, value: -29, to: today)!,
                                  end: calendar.date(byAdding: .day, value: 1, to: today)!)
        let ranges = recent.start <= interval.start && recent.end >= interval.end ? [recent] : [recent, interval]

        for metric in HealthMetric.allCases {
            do {
                var replacements: [(DateInterval, [HealthSample])] = []
                for range in ranges {
                    let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: .strictStartDate)
                    let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: metric.quantityType, predicate: predicate)],
                                                             sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)])
                    let samples = try await descriptor.result(for: healthStore)
                    replacements.append((range, samples.filter { $0.startDate < range.end }.map { HealthSample($0, metric: metric) }))
                }
                let latestQuery = HKSampleQueryDescriptor(predicates: [.quantitySample(type: metric.quantityType)],
                                                          sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate, order: .reverse)], limit: 1)
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
