import Foundation

public enum QuotaForecastError: Error, Equatable, Sendable {
    case emptyObservedSeries
    case nonFiniteValue(index: Int)
    case negativeValue(index: Int, value: Double)
    case decreasingValue(index: Int, previous: Double, current: Double)
    case totalCountSmallerThanObserved(totalCount: Int, observedCount: Int)
    case invalidConfiguration(String)
}

extension QuotaForecastError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyObservedSeries:
            return "The observed cumulative series is empty."
        case let .nonFiniteValue(index):
            return "Observed value at index \(index) is not finite."
        case let .negativeValue(index, value):
            return "Observed value at index \(index) is negative (\(value))."
        case let .decreasingValue(index, previous, current):
            return "The cumulative series decreases at index \(index): \(previous) -> \(current)."
        case let .totalCountSmallerThanObserved(totalCount, observedCount):
            return "totalCount (\(totalCount)) is smaller than observed.count (\(observedCount))."
        case let .invalidConfiguration(message):
            return "Invalid forecast configuration: \(message)"
        }
    }
}

public struct ForecastInterval: Codable, Equatable, Sendable {
    public let lower: Double
    public let median: Double
    public let upper: Double

    public init(lower: Double, median: Double, upper: Double) {
        self.lower = lower
        self.median = median
        self.upper = upper
    }
}

public struct ScenarioForecast: Codable, Equatable, Sendable {
    public let fullSeries: [Double]
    public let futureValues: [Double]
    public let endpoint: Double
    public let endpointInterval: ForecastInterval
    public let quotaExhaustionIndex: Int?

    public init(
        fullSeries: [Double],
        futureValues: [Double],
        endpoint: Double,
        endpointInterval: ForecastInterval,
        quotaExhaustionIndex: Int?
    ) {
        self.fullSeries = fullSeries
        self.futureValues = futureValues
        self.endpoint = endpoint
        self.endpointInterval = endpointInterval
        self.quotaExhaustionIndex = quotaExhaustionIndex
    }
}

public struct ForecastDiagnostics: Codable, Equatable, Sendable {
    public let observedCount: Int
    public let totalCount: Int
    public let finalObservedValue: Double
    public let inputWasRepaired: Bool
    public let historicalMeanIncrement: Double
    public let positiveIncrementProbability: Double
    public let meanPositiveIncrement: Double
    public let tsbOccurrenceProbability: Double
    public let tsbPositiveIncrementSize: Double
    public let burstThreshold: Double
    public let patternBlockCount: Int

    public init(
        observedCount: Int,
        totalCount: Int,
        finalObservedValue: Double,
        inputWasRepaired: Bool,
        historicalMeanIncrement: Double,
        positiveIncrementProbability: Double,
        meanPositiveIncrement: Double,
        tsbOccurrenceProbability: Double,
        tsbPositiveIncrementSize: Double,
        burstThreshold: Double,
        patternBlockCount: Int
    ) {
        self.observedCount = observedCount
        self.totalCount = totalCount
        self.finalObservedValue = finalObservedValue
        self.inputWasRepaired = inputWasRepaired
        self.historicalMeanIncrement = historicalMeanIncrement
        self.positiveIncrementProbability = positiveIncrementProbability
        self.meanPositiveIncrement = meanPositiveIncrement
        self.tsbOccurrenceProbability = tsbOccurrenceProbability
        self.tsbPositiveIncrementSize = tsbPositiveIncrementSize
        self.burstThreshold = burstThreshold
        self.patternBlockCount = patternBlockCount
    }
}

public struct QuotaForecast: Codable, Equatable, Sendable {
    public let optimistic: ScenarioForecast
    public let pessimistic: ScenarioForecast
    public let diagnostics: ForecastDiagnostics

    public init(
        optimistic: ScenarioForecast,
        pessimistic: ScenarioForecast,
        diagnostics: ForecastDiagnostics
    ) {
        self.optimistic = optimistic
        self.pessimistic = pessimistic
        self.diagnostics = diagnostics
    }
}

public struct QuotaForecastConfiguration: Sendable {
    public var softQuota: Double = 100
    public var alpha: Double = 0.25
    public var beta: Double = 0.20
    public var minBlockLength: Int = 3
    public var maxBlockLength: Int = 8
    public var contextLength: Int = 6
    public var ensembleSize: Int = 384
    public var randomSeed: UInt64 = 0x5155_4F54_4146_4B54
    public var zeroTolerance: Double = 1e-9
    public var recentWindow: Int = 12
    public var regimeWindow: Int = 3
    public var burstQuantile: Double = 0.78
    public var optimisticPatternQuantile: Double = 0.32
    public var pessimisticPatternQuantile: Double = 0.84
    public var patternQuantileBandwidth: Double = 0.24
    public var optimisticMagnitudeMultiplier: Double = 0.94
    public var pessimisticMagnitudeMultiplier: Double = 1.10
    public var optimisticConservationStrength: Double = 0.72
    public var optimisticTargetQuotaFraction: Double = 0.96
    public var minimumConservationMultiplier: Double = 0.18
    public var baselineScaleBlend: Double = 0.35
    public var magnitudeJitter: Double = 0.07
    public var recencyWeight: Double = 0.30
    public var contextWeight: Double = 1.45
    public var intensityWeight: Double = 0.85
    public var transitionWeight: Double = 0.95
    public var scenarioWeight: Double = 1.25
    public var maxCandidateBlocks: Int = 192
    public var optimisticRepresentativeQuantile: Double = 0.45
    public var pessimisticRepresentativeQuantile: Double = 0.55
    public var intervalLowerQuantile: Double = 0.10
    public var intervalUpperQuantile: Double = 0.90
    public var allowOverrun: Bool = true
    public var repairNonMonotonicInput: Bool = true
    public var enforceScenarioOrdering: Bool = true
    public var quantizationStep: Double? = nil

    public init() {}

    fileprivate func validate() throws {
        guard softQuota > 0, softQuota.isFinite else {
            throw QuotaForecastError.invalidConfiguration("softQuota must be finite and greater than zero")
        }
        guard alpha > 0, alpha <= 1, beta > 0, beta <= 1 else {
            throw QuotaForecastError.invalidConfiguration("alpha and beta must be in (0, 1]")
        }
        guard minBlockLength > 0, maxBlockLength >= minBlockLength else {
            throw QuotaForecastError.invalidConfiguration("block lengths are invalid")
        }
        guard contextLength >= 0, ensembleSize > 0, zeroTolerance >= 0 else {
            throw QuotaForecastError.invalidConfiguration("contextLength, ensembleSize, or zeroTolerance is invalid")
        }
        guard recentWindow > 0, regimeWindow > 0, maxCandidateBlocks > 0 else {
            throw QuotaForecastError.invalidConfiguration("window and candidate counts must be positive")
        }
        let quantiles = [burstQuantile, optimisticPatternQuantile, pessimisticPatternQuantile,
                         optimisticRepresentativeQuantile, pessimisticRepresentativeQuantile,
                         intervalLowerQuantile, intervalUpperQuantile]
        guard quantiles.allSatisfy({ $0 >= 0 && $0 <= 1 }) else {
            throw QuotaForecastError.invalidConfiguration("quantiles must be in [0, 1]")
        }
        guard intervalLowerQuantile <= intervalUpperQuantile, patternQuantileBandwidth > 0 else {
            throw QuotaForecastError.invalidConfiguration("interval or quantile bandwidth is invalid")
        }
        guard optimisticMagnitudeMultiplier >= 0, pessimisticMagnitudeMultiplier >= 0,
              optimisticConservationStrength >= 0, optimisticConservationStrength <= 1,
              optimisticTargetQuotaFraction > 0,
              minimumConservationMultiplier >= 0, minimumConservationMultiplier <= 1,
              baselineScaleBlend >= 0, baselineScaleBlend <= 1,
              magnitudeJitter >= 0 else {
            throw QuotaForecastError.invalidConfiguration("scenario scaling values are invalid")
        }
        if let quantizationStep, !(quantizationStep > 0 && quantizationStep.isFinite) {
            throw QuotaForecastError.invalidConfiguration("quantizationStep must be finite and positive")
        }
    }
}

private enum Stats {
    static func mean<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        var total = 0.0
        var count = 0
        for value in values { total += value; count += 1 }
        return count == 0 ? 0 : total / Double(count)
    }

    static func quantile(_ values: [Double], _ probability: Double) -> Double {
        quantileSorted(values.sorted(), probability)
    }

    static func quantileSorted(_ sorted: [Double], _ probability: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let p = clamp(probability, 0, 1)
        let position = p * Double(sorted.count - 1)
        let lo = Int(position.rounded(.down))
        let hi = Int(position.rounded(.up))
        if lo == hi { return sorted[lo] }
        let fraction = position - Double(lo)
        return sorted[lo] * (1 - fraction) + sorted[hi] * fraction
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    static func smoothStep(_ value: Double) -> Double {
        let x = clamp(value, 0, 1)
        return x * x * (3 - 2 * x)
    }

    static func suffixMean(_ values: [Double], count: Int) -> Double {
        guard !values.isEmpty, count > 0 else { return 0 }
        return mean(values[max(0, values.count - count)...])
    }

    static func suffixPositiveFraction(_ values: [Double], count: Int, tolerance: Double) -> Double {
        guard !values.isEmpty, count > 0 else { return 0 }
        let suffix = values[max(0, values.count - count)...]
        let positives = suffix.reduce(into: 0) { if $1 > tolerance { $0 += 1 } }
        return Double(positives) / Double(suffix.count)
    }

    static func meanAbsoluteDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        var total = 0.0
        for index in 0 ..< count { total += abs(lhs[index] - rhs[index]) }
        return total / Double(count)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) { state = seed; spare = nil }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func integer(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func normal() -> Double {
        if let spare { self.spare = nil; return spare }
        let u1 = max(unit(), Double.leastNonzeroMagnitude)
        let u2 = unit()
        let radius = sqrt(-2 * log(u1))
        let angle = 2 * Double.pi * u2
        spare = radius * sin(angle)
        return radius * cos(angle)
    }

    mutating func sample(logWeights: [Double]) -> Int {
        guard let maximum = logWeights.max(), maximum.isFinite else { return integer(logWeights.count) }
        let weights = logWeights.map { $0.isFinite ? exp($0 - maximum) : 0 }
        let total = weights.reduce(0, +)
        guard total > 0, total.isFinite else { return integer(logWeights.count) }
        let target = unit() * total
        var running = 0.0
        for (index, weight) in weights.enumerated() {
            running += weight
            if running >= target { return index }
        }
        return weights.count - 1
    }
}

private enum ScenarioKind {
    case optimistic, pessimistic

    var salt: UInt64 {
        switch self {
        case .optimistic: return 0x4F50_5449_4D49_5354
        case .pessimistic: return 0x5045_5353_494D_4953
        }
    }
}

private enum Regime: Int, CaseIterable { case idle, normal, burst }

private struct TSBState {
    var probability: Double
    var positiveSize: Double
    var rate: Double { probability * positiveSize }

    mutating func update(_ increment: Double, _ configuration: QuotaForecastConfiguration) {
        let active = increment > configuration.zeroTolerance ? 1.0 : 0.0
        probability = Stats.clamp(probability + configuration.beta * (active - probability), 0, 1)
        if active > 0 {
            positiveSize = max(0, positiveSize + configuration.alpha * (increment - positiveSize))
        }
    }
}

private struct PatternBlock {
    let start: Int
    let values: [Double]
    let rate: Double
    let positiveFraction: Double
    let firstRegime: Regime
    let lastRegime: Regime
    let recency: Double
    var rank: Double
}

private struct PreparedInput {
    let values: [Double]
    let wasRepaired: Bool
}

private struct HistoryModel {
    let observed: [Double]
    let wasRepaired: Bool
    let increments: [Double]
    let historicalRate: Double
    let positiveProbability: Double
    let meanPositive: Double
    let positiveScale: Double
    let fittedTSB: TSBState
    let burstThreshold: Double
    let regimes: [Regime]
    let transitions: [[Double]]
    let blocks: [PatternBlock]
    let recentBlockIndices: [Int]

    init(_ prepared: PreparedInput, _ configuration: QuotaForecastConfiguration) {
        observed = prepared.values
        wasRepaired = prepared.wasRepaired
        increments = prepared.values.count > 1
            ? (1 ..< prepared.values.count).map { max(0, prepared.values[$0] - prepared.values[$0 - 1]) }
            : []
        historicalRate = Stats.mean(increments)
        let positive = increments.filter { $0 > configuration.zeroTolerance }
        positiveProbability = increments.isEmpty ? 0 : Double(positive.count) / Double(increments.count)
        meanPositive = Stats.mean(positive)
        let medianPositive = Stats.quantile(positive, 0.5)
        positiveScale = max(medianPositive, meanPositive * 0.25,
                            configuration.zeroTolerance * 10, Double.leastNonzeroMagnitude)

        var tsb = TSBState(probability: positiveProbability,
                           positiveSize: positive.isEmpty ? 0 : medianPositive)
        for increment in increments { tsb.update(increment, configuration) }
        fittedTSB = tsb

        var rollingScores = [Double]()
        rollingScores.reserveCapacity(increments.count)
        var rolling = 0.0
        for index in increments.indices {
            rolling += increments[index]
            if index >= configuration.regimeWindow { rolling -= increments[index - configuration.regimeWindow] }
            rollingScores.append(max(0, rolling))
        }
        let positiveScores = rollingScores.filter { $0 > configuration.zeroTolerance }
        let threshold = positiveScores.isEmpty
            ? 0
            : max(Stats.quantile(positiveScores, configuration.burstQuantile), positiveScale * 1.5)
        burstThreshold = threshold
        let classified = rollingScores.map {
            HistoryModel.classify($0, threshold: threshold, tolerance: configuration.zeroTolerance)
        }
        regimes = classified

        var counts = Array(repeating: Array(repeating: 0.35, count: 3), count: 3)
        if classified.count > 1 {
            for index in 1 ..< classified.count {
                let recency = 0.55 + 0.45 * Double(index) / Double(classified.count - 1)
                counts[classified[index - 1].rawValue][classified[index].rawValue] += recency
            }
        }
        transitions = counts.map { row in
            let total = row.reduce(0, +)
            return row.map { $0 / total }
        }

        var built = [PatternBlock]()
        if !increments.isEmpty {
            let maximum = min(configuration.maxBlockLength, increments.count)
            let minimum = min(configuration.minBlockLength, maximum)
            for length in minimum ... maximum {
                for start in 0 ... (increments.count - length) {
                    let values = Array(increments[start ..< start + length])
                    let rate = values.reduce(0, +) / Double(length)
                    let positives = values.reduce(into: 0) { if $1 > configuration.zeroTolerance { $0 += 1 } }
                    built.append(PatternBlock(
                        start: start,
                        values: values,
                        rate: rate,
                        positiveFraction: Double(positives) / Double(length),
                        firstRegime: classified[start],
                        lastRegime: classified[start + length - 1],
                        recency: Double(start + length) / Double(increments.count),
                        rank: 0.5
                    ))
                }
            }
        }

        if built.count > 1 {
            let sorted = built.indices.sorted { built[$0].rate < built[$1].rate }
            var groupStart = 0
            while groupStart < sorted.count {
                var groupEnd = groupStart + 1
                let value = built[sorted[groupStart]].rate
                while groupEnd < sorted.count,
                      abs(built[sorted[groupEnd]].rate - value) <= configuration.zeroTolerance {
                    groupEnd += 1
                }
                let rank = 0.5 * Double(groupStart + groupEnd - 1) / Double(sorted.count - 1)
                for position in groupStart ..< groupEnd { built[sorted[position]].rank = rank }
                groupStart = groupEnd
            }
        }
        blocks = built
        recentBlockIndices = built.indices.sorted {
            if built[$0].start == built[$1].start { return built[$0].values.count > built[$1].values.count }
            return built[$0].start > built[$1].start
        }
    }

    static func classify(_ rolling: Double, threshold: Double, tolerance: Double) -> Regime {
        if rolling <= tolerance { return .idle }
        if threshold > tolerance, rolling >= threshold { return .burst }
        return .normal
    }
}

public struct QuotaForecaster: Sendable {
    public let configuration: QuotaForecastConfiguration

    public init(configuration: QuotaForecastConfiguration = QuotaForecastConfiguration()) {
        self.configuration = configuration
    }

    public func forecast(observed: [Double], totalCount: Int) throws -> QuotaForecast {
        try configuration.validate()
        let prepared = try prepare(observed, totalCount: totalCount)
        let model = HistoryModel(prepared, configuration)
        let diagnostics = ForecastDiagnostics(
            observedCount: model.observed.count,
            totalCount: totalCount,
            finalObservedValue: model.observed.last ?? 0,
            inputWasRepaired: model.wasRepaired,
            historicalMeanIncrement: model.historicalRate,
            positiveIncrementProbability: model.positiveProbability,
            meanPositiveIncrement: model.meanPositive,
            tsbOccurrenceProbability: model.fittedTSB.probability,
            tsbPositiveIncrementSize: model.fittedTSB.positiveSize,
            burstThreshold: model.burstThreshold,
            patternBlockCount: model.blocks.count
        )

        if totalCount == prepared.values.count {
            let scenario = completed(prepared.values, observedCount: prepared.values.count)
            return QuotaForecast(optimistic: scenario, pessimistic: scenario, diagnostics: diagnostics)
        }

        guard model.increments.contains(where: { $0 > configuration.zeroTolerance }) else {
            let values = prepared.values + Array(repeating: prepared.values.last ?? 0,
                                                 count: totalCount - prepared.values.count)
            let scenario = completed(values, observedCount: prepared.values.count)
            return QuotaForecast(optimistic: scenario, pessimistic: scenario, diagnostics: diagnostics)
        }

        let optimisticPaths = ensemble(model, totalCount: totalCount, scenario: .optimistic)
        let pessimisticPaths = ensemble(model, totalCount: totalCount, scenario: .pessimistic)
        let optimistic = select(optimisticPaths, observed: prepared.values,
                                quantile: configuration.optimisticRepresentativeQuantile)
        var pessimistic = select(pessimisticPaths, observed: prepared.values,
                                 quantile: configuration.pessimisticRepresentativeQuantile)
        if configuration.enforceScenarioOrdering {
            var ordered = pessimistic.fullSeries
            for index in ordered.indices { ordered[index] = max(ordered[index], optimistic.fullSeries[index]) }
            let observedCount = optimistic.fullSeries.count - optimistic.futureValues.count
            pessimistic = ScenarioForecast(
                fullSeries: ordered,
                futureValues: Array(ordered.dropFirst(observedCount)),
                endpoint: ordered.last ?? pessimistic.endpoint,
                endpointInterval: pessimistic.endpointInterval,
                quotaExhaustionIndex: exhaustionIndex(ordered)
            )
        }
        return QuotaForecast(optimistic: optimistic, pessimistic: pessimistic, diagnostics: diagnostics)
    }

    private func prepare(_ observed: [Double], totalCount: Int) throws -> PreparedInput {
        guard !observed.isEmpty else { throw QuotaForecastError.emptyObservedSeries }
        guard totalCount >= observed.count else {
            throw QuotaForecastError.totalCountSmallerThanObserved(totalCount: totalCount,
                                                                    observedCount: observed.count)
        }
        var values = [Double]()
        var repaired = false
        for (index, original) in observed.enumerated() {
            guard original.isFinite else { throw QuotaForecastError.nonFiniteValue(index: index) }
            guard original >= 0 else { throw QuotaForecastError.negativeValue(index: index, value: original) }
            var value = original
            if let previous = values.last, value < previous {
                guard configuration.repairNonMonotonicInput else {
                    throw QuotaForecastError.decreasingValue(index: index, previous: previous, current: original)
                }
                value = previous
                repaired = true
            }
            values.append(value)
        }
        return PreparedInput(values: values, wasRepaired: repaired)
    }

    private struct Path { let future: [Double]; var endpoint: Double { future.last ?? 0 } }
    private struct Adaptive {
        let targetRate: Double
        let momentum: Double
        let pressure: Double
        let conservation: Double
        let desiredQuantile: Double
    }

    private func ensemble(_ model: HistoryModel, totalCount: Int, scenario: ScenarioKind) -> [Path] {
        (0 ..< configuration.ensembleSize).map { index in
            let seed = configuration.randomSeed ^ scenario.salt
                ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            return simulate(model, totalCount: totalCount, scenario: scenario, seed: seed)
        }
    }

    private func simulate(_ model: HistoryModel, totalCount: Int,
                          scenario: ScenarioKind, seed: UInt64) -> Path {
        let futureCount = totalCount - model.observed.count
        var rng = SplitMix64(seed: seed)
        var cumulative = model.observed.last ?? 0
        var future = [Double]()
        future.reserveCapacity(futureCount)
        let retained = max(configuration.contextLength, configuration.recentWindow,
                           configuration.regimeWindow, configuration.maxBlockLength) + 2
        var recent = Array(model.increments.suffix(retained))
        var tsb = model.fittedTSB
        var regime = model.regimes.last ?? .idle

        while future.count < futureCount {
            let adaptive = adaptiveState(model, tsb: tsb, recent: recent, cumulative: cumulative,
                                         generated: future.count, totalCount: totalCount, scenario: scenario)
            let block = chooseBlock(model, recent: recent, regime: regime,
                                    adaptive: adaptive, scenario: scenario, rng: &rng)
            let floor = max(model.positiveScale * 0.05, configuration.zeroTolerance)
            let ratio = block.rate <= configuration.zeroTolerance
                ? 1
                : (adaptive.targetRate + floor) / (block.rate + floor)
            var scale = pow(max(ratio, Double.leastNonzeroMagnitude), configuration.baselineScaleBlend)
            scale = Stats.clamp(scale, 0.45, 2.25)
            scale *= scenario == .optimistic
                ? configuration.optimisticMagnitudeMultiplier
                : configuration.pessimisticMagnitudeMultiplier
            if configuration.magnitudeJitter > 0 {
                scale *= Stats.clamp(exp(rng.normal() * configuration.magnitudeJitter), 0.72, 1.38)
            }
            if scenario == .optimistic {
                scale *= pow(adaptive.conservation, 0.72)
            } else if regime == .burst || block.firstRegime == .burst {
                scale *= 1 + 0.10 * adaptive.momentum
            }

            let usable = min(block.values.count, futureCount - future.count)
            for raw in block.values.prefix(usable) {
                var increment = raw <= configuration.zeroTolerance ? 0 : max(0, raw * scale)
                if let step = configuration.quantizationStep, increment > 0 {
                    increment = max(step, (increment / step).rounded() * step)
                }
                if !configuration.allowOverrun {
                    increment = min(increment, max(0, configuration.softQuota - cumulative))
                }
                cumulative += increment
                future.append(cumulative)
                recent.append(increment)
                if recent.count > retained { recent.removeFirst(recent.count - retained) }
                tsb.update(increment, configuration)
                let count = min(configuration.regimeWindow, recent.count)
                regime = HistoryModel.classify(recent.suffix(count).reduce(0, +),
                                               threshold: model.burstThreshold,
                                               tolerance: configuration.zeroTolerance)
            }
        }
        return Path(future: future)
    }

    private func adaptiveState(_ model: HistoryModel, tsb: TSBState, recent: [Double],
                               cumulative: Double, generated: Int, totalCount: Int,
                               scenario: ScenarioKind) -> Adaptive {
        let recentRate = Stats.suffixMean(recent, count: configuration.recentWindow)
        let positiveFraction = Stats.suffixPositiveFraction(recent, count: configuration.recentWindow,
                                                            tolerance: configuration.zeroTolerance)
        let rateMomentum = Stats.clamp(
            recentRate / max(model.historicalRate * 2, model.positiveScale * 0.25), 0, 1)
        let momentum = Stats.clamp(0.52 * positiveFraction + 0.48 * rateMomentum, 0, 1)
        let baseRate = max(0,
            0.28 * model.historicalRate + 0.34 * model.fittedTSB.rate
                + 0.23 * tsb.rate + 0.15 * recentRate)

        if scenario == .optimistic {
            let pressure = quotaPressure(cumulative: cumulative,
                                         uncontrolledRate: max(baseRate, recentRate * 0.80),
                                         generated: generated, observedCount: model.observed.count,
                                         totalCount: totalCount)
            let conservation = max(configuration.minimumConservationMultiplier,
                                   1 - configuration.optimisticConservationStrength * pressure)
            return Adaptive(
                targetRate: baseRate * conservation,
                momentum: momentum,
                pressure: pressure,
                conservation: conservation,
                desiredQuantile: Stats.clamp(configuration.optimisticPatternQuantile - 0.22 * pressure,
                                             0.02, 0.90)
            )
        }
        return Adaptive(
            targetRate: baseRate * (1 + 0.24 * momentum),
            momentum: momentum,
            pressure: 0,
            conservation: 1,
            desiredQuantile: Stats.clamp(configuration.pessimisticPatternQuantile + 0.10 * momentum,
                                         0.10, 0.98)
        )
    }

    private func quotaPressure(cumulative: Double, uncontrolledRate: Double, generated: Int,
                               observedCount: Int, totalCount: Int) -> Double {
        let currentIndex = observedCount + generated - 1
        let elapsed = Stats.clamp(Double(max(0, currentIndex)) / Double(max(1, totalCount - 1)), 0, 1)
        let remaining = max(1, totalCount - observedCount - generated)
        let target = configuration.softQuota * configuration.optimisticTargetQuotaFraction
        let projected = cumulative + uncontrolledRate * Double(remaining)
        let projectionPressure = max(0, projected - target)
            / max(configuration.softQuota * 0.18, uncontrolledRate, 1e-9)
        let pacePressure = max(0, cumulative - target * elapsed)
            / max(configuration.softQuota * 0.16, 1e-9)
        let sustainable = max(0, target - cumulative) / Double(remaining)
        let ratePressure = sustainable <= configuration.zeroTolerance
            ? (uncontrolledRate > configuration.zeroTolerance ? 1 : 0)
            : max(0, uncontrolledRate / sustainable - 1) / 2
        return Stats.smoothStep(Stats.clamp(max(projectionPressure, pacePressure, ratePressure), 0, 1))
    }

    private func chooseBlock(_ model: HistoryModel, recent: [Double], regime: Regime,
                             adaptive: Adaptive, scenario: ScenarioKind,
                             rng: inout SplitMix64) -> PatternBlock {
        let candidates = candidateIndices(model, rng: &rng)
        var weights = [Double]()
        weights.reserveCapacity(candidates.count)
        for index in candidates {
            let block = model.blocks[index]
            var weight = configuration.transitionWeight
                * log(max(model.transitions[regime.rawValue][block.firstRegime.rawValue], 1e-12))
            weight -= configuration.contextWeight * contextDistance(block, recent: recent, model: model)
            let floor = max(model.positiveScale * 0.05, configuration.zeroTolerance)
            let intensity = block.rate <= configuration.zeroTolerance
                && adaptive.targetRate <= configuration.zeroTolerance
                ? 0
                : abs(log((block.rate + floor) / (adaptive.targetRate + floor)))
            weight -= configuration.intensityWeight * intensity
            weight -= configuration.scenarioWeight
                * abs(block.rank - adaptive.desiredQuantile)
                / configuration.patternQuantileBandwidth
            weight += configuration.recencyWeight * (2 * block.recency - 1)

            if scenario == .optimistic {
                if block.firstRegime == .idle { weight += log(1 + 2.2 * adaptive.pressure) }
                if block.firstRegime == .burst || block.lastRegime == .burst {
                    weight -= 1.25 * adaptive.pressure
                }
                if block.positiveFraction < 0.34 { weight += 0.30 * adaptive.pressure }
            } else {
                if block.firstRegime == .burst || block.lastRegime == .burst {
                    weight += log(1 + 1.45 * (0.25 + adaptive.momentum))
                }
                if regime == .burst, block.firstRegime == .burst { weight += log(1.65) }
                if block.firstRegime == .idle { weight -= 0.20 * adaptive.momentum }
            }
            weights.append(weight)
        }
        return model.blocks[candidates[rng.sample(logWeights: weights)]]
    }

    private func candidateIndices(_ model: HistoryModel, rng: inout SplitMix64) -> [Int] {
        if model.blocks.count <= configuration.maxCandidateBlocks { return Array(model.blocks.indices) }
        let maximum = configuration.maxCandidateBlocks
        var indices = [Int]()
        let recentCount = min(maximum / 5, model.recentBlockIndices.count)
        indices.append(contentsOf: model.recentBlockIndices.prefix(recentCount))

        let strata = max(1, maximum / 3)
        let offset = rng.integer(max(1, model.blocks.count / strata))
        for position in 0 ..< strata where indices.count < maximum {
            let index = min(model.blocks.count - 1,
                            position * model.blocks.count / strata + offset)
            if !indices.contains(index) { indices.append(index) }
        }
        while indices.count < maximum {
            let index = rng.integer(model.blocks.count)
            if !indices.contains(index) { indices.append(index) }
        }
        return indices
    }

    private func contextDistance(_ block: PatternBlock, recent: [Double], model: HistoryModel) -> Double {
        let count = min(configuration.contextLength, recent.count, block.start)
        guard count > 0 else { return 0.35 }
        let currentStart = recent.count - count
        let historicalStart = block.start - count
        let scale = max(model.positiveScale, configuration.zeroTolerance, 1e-12)
        var distance = 0.0
        for offset in 0 ..< count {
            let current = recent[currentStart + offset]
            let historical = model.increments[historicalStart + offset]
            distance += abs(log(1 + current / scale) - log(1 + historical / scale))
            if (current <= configuration.zeroTolerance) != (historical <= configuration.zeroTolerance) {
                distance += 0.42
            }
        }
        return distance / Double(count)
    }

    private func select(_ paths: [Path], observed: [Double], quantile: Double) -> ScenarioForecast {
        let sortedEndpoints = paths.map(\.endpoint).sorted()
        let target = Stats.quantileSorted(sortedEndpoints, quantile)
        let lower = Stats.quantileSorted(sortedEndpoints, configuration.intervalLowerQuantile)
        let median = Stats.quantileSorted(sortedEndpoints, 0.5)
        let upper = Stats.quantileSorted(sortedEndpoints, configuration.intervalUpperQuantile)
        let futureCount = paths[0].future.count
        var pointwiseMedian = [Double]()
        for index in 0 ..< futureCount {
            pointwiseMedian.append(Stats.quantileSorted(paths.map { $0.future[index] }.sorted(), 0.5))
        }
        let spread = max(upper - lower, abs(median) * 0.05, 1e-9)
        var best = 0
        var bestScore = Double.infinity
        for index in paths.indices {
            let score = abs(paths[index].endpoint - target) / spread
                + 0.18 * Stats.meanAbsoluteDifference(paths[index].future, pointwiseMedian) / spread
            if score < bestScore { best = index; bestScore = score }
        }
        let future = paths[best].future
        let full = observed + future
        return ScenarioForecast(
            fullSeries: full,
            futureValues: future,
            endpoint: full.last ?? observed.last ?? 0,
            endpointInterval: ForecastInterval(lower: lower, median: median, upper: upper),
            quotaExhaustionIndex: exhaustionIndex(full)
        )
    }

    private func completed(_ values: [Double], observedCount: Int) -> ScenarioForecast {
        let endpoint = values.last ?? 0
        return ScenarioForecast(
            fullSeries: values,
            futureValues: Array(values.dropFirst(observedCount)),
            endpoint: endpoint,
            endpointInterval: ForecastInterval(lower: endpoint, median: endpoint, upper: endpoint),
            quotaExhaustionIndex: exhaustionIndex(values)
        )
    }

    private func exhaustionIndex(_ values: [Double]) -> Int? {
        values.firstIndex { $0 >= configuration.softQuota }
    }
}
