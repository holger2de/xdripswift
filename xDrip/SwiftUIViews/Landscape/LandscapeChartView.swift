//
//  LandscapeChartView.swift
//  xdrip
//
//  Created by Paul Plant on 16/9/21.
//  Copyright © 2021 Johan Degraeve. All rights reserved.
//

import SwiftUI

private func validLandscapeDimension(_ value: CGFloat) -> CGFloat {
    value.isFinite ? max(value, 0) : 0
}

/// Supported history periods for the landscape comparison baseline.
enum LandscapeComparisonPeriod: Int, CaseIterable, Identifiable {
    case none = 0
    case threeDays = 3
    case sevenDays = 7
    case thirtyDays = 30
    case sixtyDays = 60
    case ninetyDays = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none:
            return Texts_Common.landscapeComparisonNone
        default:
            return Texts_Common.landscapeComparisonDays(rawValue)
        }
    }
}

// MARK: - State Model

/// Owns the selected day trace and recent AGP baseline for the landscape comparison view.
/// Keep snapshot requests and published UI state on the same actor as chart lifecycle changes.
@MainActor
final class LandscapeChartStateModel: ObservableObject {

    @Published var selectedDate = Date().toMidnight()
    @Published var displayedDate = Date().toMidnight()
    @Published var chartState = GlucoseChartState.empty(startDate: Date().toMidnight(), endDate: Date().toMidnight().addingTimeInterval(.hours(24) - 1))
    @Published var baseline = StatisticsManager.LandscapeBaseline.empty
    @Published var rangeSummary = GlucoseClinicalRangeSummary.empty
    @Published var averageMgDl: Double?
    @Published var loopalyzerSnapshot: StatisticsManager.LandscapeLoopalyzerSnapshot?
    @Published private(set) var comparisonPeriod: LandscapeComparisonPeriod
    let showsAIDCharts: Bool

    private let coreDataManager: CoreDataManager
    private let nightscoutSyncManager: NightscoutSyncManager
    private let statisticsManager: StatisticsManager
    private var activeLoadID = UUID()
    private var cachedSnapshots: [LandscapeSnapshotCacheKey: LandscapeDaySnapshot] = [:]
    private var prefetchingSnapshots = Set<LandscapeSnapshotCacheKey>()
    // Each temporary manager must remain alive until its asynchronous chart request completes.
    private var snapshotChartStateManagers: [UUID: GlucoseChartStateManager] = [:]

    private let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate(ConstantsGlucoseChart.dateFormatLandscapeChart)

        return dateFormatter
    }()

    init(coreDataManager: CoreDataManager, nightscoutSyncManager: NightscoutSyncManager) {
        self.coreDataManager = coreDataManager
        self.nightscoutSyncManager = nightscoutSyncManager
        statisticsManager = StatisticsManager(coreDataManager: coreDataManager)
        showsAIDCharts = UserDefaults.standard.dataFlowPolicy.showsAIDData
        comparisonPeriod = LandscapeComparisonPeriod(rawValue: UserDefaults.standard.landscapeComparisonDays) ?? .sevenDays

        refresh()
    }

    var selectedDateText: String {
        dateFormatter.string(from: selectedDate)
    }

    var canMoveForward: Bool {
        !Calendar.current.isDateInToday(selectedDate)
    }

    func moveBackOneDay() {
        guard let date = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) else { return }

        selectDate(date)
    }

    func moveForwardOneDay() {
        guard canMoveForward,
              let date = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) else { return }

        selectDate(date)
    }

    func selectToday() {
        guard !Calendar.current.isDateInToday(selectedDate) else { return }

        selectDate(Date().toMidnight())
    }

    func selectComparisonPeriod(_ period: LandscapeComparisonPeriod) {
        guard comparisonPeriod != period else { return }

        comparisonPeriod = period
        UserDefaults.standard.landscapeComparisonDays = period.rawValue

        DispatchQueue.main.async { [weak self] in
            guard let self, self.comparisonPeriod == period else { return }

            self.startLoad(referenceDate: self.selectedDate, forceResetChart: false)
        }
    }

    func refresh() {
        startLoad(referenceDate: selectedDate, forceResetChart: true)
    }

    private func refreshChart(referenceDate: Date, forceReset: Bool, completion: @escaping (GlucoseChartState) -> Void) {
        let startOfDay = referenceDate
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)
        let endOfDay = nextDay?.addingTimeInterval(-1) ?? startOfDay.addingTimeInterval(.hours(24) - 1)
        let chartStateManager = GlucoseChartStateManager(coreDataManager: coreDataManager, nightscoutSyncManager: nightscoutSyncManager)
        let requestID = UUID()

        snapshotChartStateManagers[requestID] = chartStateManager

        chartStateManager.updateState(
            endDate: endOfDay,
            startDate: startOfDay,
            forceReset: forceReset,
            showTreatments: false
        ) { [weak self] chartState in
            guard self != nil else { return }

            DispatchQueue.main.async {
                self?.snapshotChartStateManagers[requestID] = nil

                guard Calendar.current.isDate(chartState.startDate, inSameDayAs: startOfDay),
                      Calendar.current.isDate(chartState.endDate, inSameDayAs: startOfDay) else {
                    completion(GlucoseChartState.empty(startDate: startOfDay, endDate: endOfDay))
                    return
                }

                completion(chartState)
            }
        }
    }

    private func selectDate(_ date: Date) {
        let startOfDay = date.toMidnight()

        selectedDate = startOfDay
        UISelectionFeedbackGenerator().selectionChanged()

        // Yield once so the selected date renders before any cached or Core Data work.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  Calendar.current.isDate(self.selectedDate, inSameDayAs: startOfDay) else { return }

            self.startLoad(referenceDate: startOfDay, forceResetChart: false)
        }
    }

    private func startLoad(referenceDate: Date, forceResetChart: Bool) {
        let loadID = UUID()
        let key = snapshotCacheKey(for: referenceDate, comparisonPeriod: comparisonPeriod)

        activeLoadID = loadID

        if let snapshot = cachedSnapshots[key], !forceResetChart {
            commitSnapshot(snapshot, loadID: loadID, cacheKey: key)
            return
        }

        buildSnapshot(cacheKey: key, forceResetChart: forceResetChart) { [weak self] snapshot in
            self?.cachedSnapshots[key] = snapshot
            self?.commitSnapshot(snapshot, loadID: loadID, cacheKey: key)
        }
    }

    private func buildSnapshot(cacheKey: LandscapeSnapshotCacheKey, forceResetChart: Bool, completion: @escaping (LandscapeDaySnapshot) -> Void) {
        var loadedChartState: GlucoseChartState?
        var loadedAnalytics: StatisticsManager.LandscapeAnalytics?

        // Commit every visible series together so date navigation never shows mixed days.
        let completeIfReady: () -> Void = { [weak self] in
            guard self != nil,
                  let loadedChartState,
                  let loadedAnalytics else { return }

            completion(LandscapeDaySnapshot(
                chartState: loadedChartState,
                baseline: loadedAnalytics.baseline,
                rangeSummary: loadedAnalytics.rangeSummary,
                averageMgDl: loadedAnalytics.averageMgDl,
                loopalyzerSnapshot: loadedAnalytics.loopalyzer
            ))
        }

        refreshChart(referenceDate: cacheKey.date, forceReset: forceResetChart) { chartState in
            loadedChartState = chartState
            completeIfReady()
        }

        refreshAnalytics(referenceDate: cacheKey.date, daysBack: cacheKey.comparisonDays) { analytics in
            loadedAnalytics = analytics
            completeIfReady()
        }
    }

    private func refreshAnalytics(referenceDate: Date, daysBack: Int, completion: @escaping (StatisticsManager.LandscapeAnalytics) -> Void) {
        Task {
            let analytics = await statisticsManager.landscapeAnalytics(
                referenceDate: referenceDate,
                daysBack: daysBack,
                includesAID: showsAIDCharts
            )

            await MainActor.run {
                completion(analytics)
            }
        }
    }

    private func commitSnapshot(_ snapshot: LandscapeDaySnapshot, loadID: UUID, cacheKey: LandscapeSnapshotCacheKey) {
        guard activeLoadID == loadID,
              comparisonPeriod.rawValue == cacheKey.comparisonDays,
              Calendar.current.isDate(selectedDate, inSameDayAs: cacheKey.date) else { return }

        displayedDate = cacheKey.date
        chartState = snapshot.chartState
        baseline = snapshot.baseline
        rangeSummary = snapshot.rangeSummary
        averageMgDl = snapshot.averageMgDl
        loopalyzerSnapshot = snapshot.loopalyzerSnapshot
        prefetchAdjacentDates(around: cacheKey.date, comparisonPeriod: comparisonPeriod)
    }

    private func prefetchAdjacentDates(around referenceDate: Date, comparisonPeriod: LandscapeComparisonPeriod) {
        let today = Date().toMidnight()

        // Warm the most likely navigation targets without changing the visible loading state.
        [-1, 1, -2, 2].forEach { dayOffset in
            guard let adjacentDate = Calendar.current.date(byAdding: .day, value: dayOffset, to: referenceDate) else { return }

            let key = snapshotCacheKey(for: adjacentDate, comparisonPeriod: comparisonPeriod)

            if key.date <= today {
                prefetchSnapshot(cacheKey: key)
            }
        }
    }

    private func prefetchSnapshot(cacheKey: LandscapeSnapshotCacheKey) {
        guard cachedSnapshots[cacheKey] == nil,
              !prefetchingSnapshots.contains(cacheKey) else { return }

        prefetchingSnapshots.insert(cacheKey)

        buildSnapshot(cacheKey: cacheKey, forceResetChart: false) { [weak self] snapshot in
            self?.cachedSnapshots[cacheKey] = snapshot
            self?.prefetchingSnapshots.remove(cacheKey)
        }
    }

    private func snapshotCacheKey(for date: Date, comparisonPeriod: LandscapeComparisonPeriod) -> LandscapeSnapshotCacheKey {
        LandscapeSnapshotCacheKey(date: date.toMidnight(), comparisonDays: comparisonPeriod.rawValue)
    }

}

private struct LandscapeSnapshotCacheKey: Hashable {
    let date: Date
    let comparisonDays: Int
}

private struct LandscapeDaySnapshot {
    let chartState: GlucoseChartState
    let baseline: StatisticsManager.LandscapeBaseline
    let rangeSummary: GlucoseClinicalRangeSummary
    let averageMgDl: Double?
    let loopalyzerSnapshot: StatisticsManager.LandscapeLoopalyzerSnapshot?
}

private extension StatisticsManager.LandscapeBaseline {
    static var empty: StatisticsManager.LandscapeBaseline {
        StatisticsManager.LandscapeBaseline(
            dayCount: 0,
            usesMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl,
            agpPoints: []
        )
    }
}

// MARK: - Main View

/// Full-screen AGP comparison with selected-day glucose and range summary.
struct LandscapeChartView: View {

    enum Presentation: Equatable {
        case standard
        case expandedIPad
    }

    @ObservedObject var stateModel: LandscapeChartStateModel
    let presentation: Presentation

    // The badge and AGP share one selection so their clinical boundaries always agree.
    @State private var rangeMode = LandscapeTIRBadge.RangeMode.timeInRange

    private enum Layout {
        static let screenPadding: CGFloat = 6
        static let contentSpacing: CGFloat = 8
        static let expandedContentSpacing: CGFloat = 22
        static let expandedPanelHorizontalInset: CGFloat = 16
        static let chartColumnSpacing: CGFloat = 18
        static let agpColumnFraction = 0.65
        static let toolbarHeight: CGFloat = 48
        static let expandedToolbarHeight: CGFloat = 64
        static let expandedSummaryHeight: CGFloat = 72
        static let expandedMinimumChartHeight: CGFloat = 360
        static let expandedMaximumChartHeight: CGFloat = 640
        static let expandedChartHeightFraction: CGFloat = 0.72
    }

    init(stateModel: LandscapeChartStateModel, presentation: Presentation = .standard) {
        self.stateModel = stateModel
        self.presentation = presentation
    }

    var body: some View {
        Group {
            switch presentation {
            case .standard:
                VStack(spacing: Layout.contentSpacing) {
                    toolbar

                    chartContent
                }
            case .expandedIPad:
                GeometryReader { geometry in
                    VStack(spacing: Layout.expandedContentSpacing) {
                        toolbar
                            .padding(.horizontal, Layout.expandedPanelHorizontalInset)
                        expandedSummary
                            .padding(.horizontal, Layout.expandedPanelHorizontalInset)

                        chartContent
                            .frame(height: expandedChartHeight(for: geometry.size.height))

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(Layout.screenPadding)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConstantsAppColors.background)
    }

    @ViewBuilder private var chartContent: some View {
        if stateModel.showsAIDCharts {
            GeometryReader { geometry in
                let availableWidth = validLandscapeDimension(
                    geometry.size.width - Layout.chartColumnSpacing
                )

                HStack(spacing: Layout.chartColumnSpacing) {
                    landscapeAGPColumn
                        .frame(width: availableWidth * Layout.agpColumnFraction)

                    LandscapeLoopalyzerCharts(
                        snapshot: stateModel.loopalyzerSnapshot,
                        showsNowRule: Calendar.current.isDateInToday(stateModel.displayedDate)
                    )
                        .frame(width: availableWidth * (1 - Layout.agpColumnFraction))
                }
            }
        } else {
            landscapeAGPColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var landscapeAGPColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation == .standard {
                comparisonPeriodMenu
                    .padding(.leading, 8)
            }

            landscapeAGPChart
        }
    }

    private var landscapeAGPChart: some View {
        LandscapeAGPComparisonChart(
            chartState: stateModel.chartState,
            baseline: stateModel.baseline,
            displayedDate: stateModel.displayedDate,
            canMoveForward: stateModel.canMoveForward,
            moveBackOneDay: stateModel.moveBackOneDay,
            moveForwardOneDay: stateModel.moveForwardOneDay,
            selectToday: stateModel.selectToday,
            usesTightRange: rangeMode == .timeInTightRange
        )
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(stateModel.selectedDateText)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(ConstantsAppColors.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
                .onTapGesture(count: 2) {
                    stateModel.selectToday()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            averageGlucoseLabel
                .font(.system(size: 15))
                .foregroundStyle(ConstantsAppColors.primaryText)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(Texts_Common.statisticsAverageGlucose)
                .accessibilityValue(averageGlucoseText)

            LandscapeTIRBadge(
                rangeSummary: stateModel.rangeSummary,
                isExpandedIPad: presentation == .expandedIPad,
                rangeMode: $rangeMode
            )
        }
        .padding(.horizontal, 14)
        .frame(height: presentation == .expandedIPad ? Layout.expandedToolbarHeight : Layout.toolbarHeight)
        .background(ConstantsAppColors.homePanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius, style: .continuous))
    }

    private var expandedSummary: some View {
        HStack(spacing: 0) {
            VStack(spacing: 5) {
                Text(Texts_Common.statisticsPeriod)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ConstantsAppColors.secondaryText)

                comparisonPeriodMenu
            }
            .frame(maxWidth: .infinity)

            summaryDivider
            summaryMetric(title: Texts_Common.statisticsAverageGlucose, value: averageGlucoseText)
            summaryDivider
            summaryMetric(title: Texts_Common.cvStatistics, value: cvText)
        }
        .padding(.horizontal, 18)
        .frame(height: Layout.expandedSummaryHeight)
        .background(ConstantsAppColors.homePanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius + 8, style: .continuous))
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ConstantsAppColors.secondaryText)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ConstantsAppColors.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Divider()
            .frame(height: 38)
            .overlay(ConstantsAppColors.tertiaryText.opacity(0.35))
    }

    private var dailyValuesMgDl: [Double] {
        zip(stateModel.chartState.bgReadingDates, stateModel.chartState.bgReadingValues)
            .filter { date, value in
                value > 0 && Calendar.current.isDate(date, inSameDayAs: stateModel.displayedDate)
            }
            .map { $0.1 }
    }

    private var averageMgDl: Double? {
        guard !dailyValuesMgDl.isEmpty else { return nil }

        return dailyValuesMgDl.reduce(0, +) / Double(dailyValuesMgDl.count)
    }

    private var averageGlucoseLabel: Text {
        guard let averageMgDl = stateModel.averageMgDl else { return Text("-").bold() }

        let usesMgDl = stateModel.baseline.usesMgDl
        let value = averageMgDl.mgDlToMmolAndToString(mgDl: usesMgDl)
        let unit = usesMgDl ? Texts_Common.mgdl : Texts_Common.mmol

        return Text("\(Text(value).bold()) \(Text(unit).foregroundColor(Color(.colorSecondary)))")
    }

    private var averageGlucoseText: String {
        guard let averageMgDl = stateModel.averageMgDl else { return "-" }

        let usesMgDl = stateModel.baseline.usesMgDl
        let unit = usesMgDl ? Texts_Common.mgdl : Texts_Common.mmol

        return "\(averageMgDl.mgDlToMmolAndToString(mgDl: usesMgDl)) \(unit)"
    }

    private var cvText: String {
        guard let averageMgDl, averageMgDl > 0 else { return "-" }

        let variance = dailyValuesMgDl.reduce(0) { partialResult, value in
            partialResult + pow(value - averageMgDl, 2)
        } / Double(dailyValuesMgDl.count)
        let cv = sqrt(variance) / averageMgDl * 100

        return GlucoseReportFormatting.percentage(cv)
    }

    private func expandedChartHeight(for availableHeight: CGFloat) -> CGFloat {
        let validAvailableHeight = validLandscapeDimension(availableHeight)
        let heightAfterHeader = max(
            0,
            validAvailableHeight
                - Layout.expandedToolbarHeight
                - Layout.expandedSummaryHeight
                - (Layout.expandedContentSpacing * 2)
        )
        let preferredHeight = min(
            Layout.expandedMaximumChartHeight,
            max(Layout.expandedMinimumChartHeight, validAvailableHeight * Layout.expandedChartHeightFraction)
        )

        return min(preferredHeight, heightAfterHeader)
    }

    private var comparisonPeriodMenu: some View {
        HStack(spacing: presentation == .expandedIPad ? 8 : 6) {
            Text(Texts_Common.landscapeComparingWithLast)
                .foregroundStyle(comparisonPeriodColor)
                .font(comparisonPeriodFont)

            Menu {
                ForEach(LandscapeComparisonPeriod.allCases) { period in
                    Button {
                        stateModel.selectComparisonPeriod(period)
                    } label: {
                        if stateModel.comparisonPeriod == period {
                            Label(period.title, systemImage: "checkmark")
                                .font(.system(size: 15))
                        } else {
                            Text(period.title)
                                .font(.system(size: 15))
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(stateModel.comparisonPeriod.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(comparisonPeriodFont)
                .foregroundStyle(comparisonPeriodColor)
            }
            .buttonStyle(.plain)

            .dynamicTypeSize(.xSmall ... .large)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var comparisonPeriodColor: Color {
        presentation == .expandedIPad
            ? ConstantsAppColors.primaryText
            : ConstantsAppColors.secondaryText
    }

    private var comparisonPeriodFont: Font {
        presentation == .expandedIPad
            ? .system(size: 18, weight: .semibold)
            : .system(size: 15)
    }

}

/// Full-width AGP insight card used at the end of the iPad Home dashboard. It shares the same
/// state model and chart renderer as the dedicated landscape view, without its Loopalyzer column.
struct IPadHomeAGPView: View {
    @StateObject private var stateModel: LandscapeChartStateModel
    let refreshRevision: Int

    init(
        coreDataManager: CoreDataManager,
        nightscoutSyncManager: NightscoutSyncManager,
        refreshRevision: Int
    ) {
        _stateModel = StateObject(wrappedValue: LandscapeChartStateModel(
            coreDataManager: coreDataManager,
            nightscoutSyncManager: nightscoutSyncManager
        ))
        self.refreshRevision = refreshRevision
    }

    var body: some View {
        LandscapeAGPComparisonChart(
            chartState: stateModel.chartState,
            baseline: stateModel.baseline,
            displayedDate: stateModel.displayedDate,
            canMoveForward: stateModel.canMoveForward,
            moveBackOneDay: stateModel.moveBackOneDay,
            moveForwardOneDay: stateModel.moveForwardOneDay,
            selectToday: stateModel.selectToday
        )
        .padding(8)
        .background(ConstantsAppColors.homePanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius + 8, style: .continuous))
        .onChange(of: refreshRevision) { _ in
            stateModel.refresh()
        }
    }
}

private struct LandscapeLoopalyzerCharts: View {
    let snapshot: StatisticsManager.LandscapeLoopalyzerSnapshot?
    let showsNowRule: Bool

    private enum Layout {
        static let chartSpacing: CGFloat = 14
        static let chartChromeHeight: CGFloat = 112
    }

    var body: some View {
        GeometryReader { geometry in
            if let snapshot {
                LandscapeLoopalyzerChart(
                    points: snapshot.points,
                    insulinTreatmentMarkers: snapshot.insulinTreatmentMarkers,
                    carbTreatmentMarkers: snapshot.carbTreatmentMarkers,
                    plotHeight: max(
                        44,
                        (validLandscapeDimension(geometry.size.height) - Layout.chartChromeHeight) / 3
                    ),
                    chartSpacing: Layout.chartSpacing,
                    showsNowRule: showsNowRule
                )
            }
        }
    }
}

// MARK: - Chart

private struct LandscapeAGPComparisonChart: View {

    private enum Layout {
        static let navigationAxisSpacing: CGFloat = 14
        static let trailingAxisLabelWidth: CGFloat = 34
    }

    let chartState: GlucoseChartState
    let baseline: StatisticsManager.LandscapeBaseline
    let displayedDate: Date
    let canMoveForward: Bool
    let moveBackOneDay: () -> Void
    let moveForwardOneDay: () -> Void
    let selectToday: () -> Void
    var usesTightRange = false

    @State private var hasTriggeredSwipe = false
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        AGPChartView(
            points: baseline.agpPoints,
            usesMgDl: baseline.usesMgDl,
            presentation: .landscapeComparison,
            glucosePoints: agpGlucosePoints,
            showsNowRule: Calendar.current.isDateInToday(displayedDate),
            emptyMessage: Texts_Common.statisticsWaitingForGlucoseData,
            usesTightRange: usesTightRange
        )
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 0)
        .overlay {
            chartNavigationHints
                .padding(.leading, Layout.navigationAxisSpacing)
                .padding(.trailing, Layout.navigationAxisSpacing + Layout.trailingAxisLabelWidth)
                .padding(.top, 28)
                .padding(.bottom, 28)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        contentWidth = geometry.size.width
                    }
                    .onChange(of: geometry.size.width) { newValue in
                        contentWidth = newValue
                    }
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(daySwipeGesture)
        .simultaneousGesture(dayTapGesture)
        .simultaneousGesture(todayDoubleTapGesture)
    }

    private var glucosePoints: [LandscapeGlucosePoint] {
        let pairs = zip(chartState.bgReadingDates, chartState.bgReadingValues)
            .filter { date, _ in
                date >= chartState.startDate &&
                    date <= chartState.endDate &&
                    Calendar.current.isDate(date, inSameDayAs: chartState.startDate)
            }
            .map { date, value in
                LandscapeGlucosePoint(date: date, minuteOfDay: minuteOfDay(for: date), valueMgDl: value, isLatest: false)
            }
            .sorted { $0.minuteOfDay < $1.minuteOfDay }

        guard let latest = pairs.last else { return pairs }

        return pairs.map { point in
            LandscapeGlucosePoint(date: point.date, minuteOfDay: point.minuteOfDay, valueMgDl: point.valueMgDl, isLatest: point.id == latest.id)
        }
    }

    private var agpGlucosePoints: [AGPChartGlucosePoint] {
        glucosePoints.map { point in
            AGPChartGlucosePoint(
                id: point.id,
                minuteOfDay: point.minuteOfDay,
                valueMgDl: point.valueMgDl,
                isLatest: point.isLatest
            )
        }
    }

    private func minuteOfDay(for date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)

        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private var chartNavigationHints: some View {
        HStack {
            navigationHint(systemName: "chevron.left")

            Spacer()

            if canMoveForward {
                navigationHint(systemName: "chevron.right")
            }
        }
        .allowsHitTesting(false)
    }

    private func navigationHint(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(ConstantsAppColors.primaryText.opacity(0.72))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.2), in: Circle())
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
    }

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !hasTriggeredSwipe,
                      abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 45 else { return }

                hasTriggeredSwipe = true

                if value.translation.width < 0 {
                    moveForwardOneDay()
                } else {
                    moveBackOneDay()
                }
            }
            .onEnded { _ in
                hasTriggeredSwipe = false
            }
    }

    private var dayTapGesture: some Gesture {
        // Keep edge taps independent from the centre double tap so rapid navigation never resets.
        SpatialTapGesture(count: 1)
            .onEnded { tap in
                selectDateFromTapLocation(tap.location)
            }
    }

    private var todayDoubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { tap in
                guard isInChartCentre(tap.location) else { return }

                selectToday()
            }
    }

    private func selectDateFromTapLocation(_ location: CGPoint) {
        guard contentWidth > 0 else { return }

        // Keep the centre half of the plot passive for reading and future chart interaction.
        if location.x <= contentWidth * 0.25 {
            moveBackOneDay()
        } else if location.x >= contentWidth * 0.75 {
            moveForwardOneDay()
        }
    }

    private func isInChartCentre(_ location: CGPoint) -> Bool {
        guard contentWidth > 0 else { return false }

        return location.x > contentWidth * 0.25 && location.x < contentWidth * 0.75
    }

}

private struct LandscapeGlucosePoint: Identifiable {
    let id: String
    let date: Date
    let minuteOfDay: Int
    let valueMgDl: Double
    let isLatest: Bool

    init(date: Date, minuteOfDay: Int, valueMgDl: Double, isLatest: Bool) {
        self.date = date
        self.minuteOfDay = minuteOfDay
        self.valueMgDl = valueMgDl
        self.isLatest = isLatest
        id = "\(date.timeIntervalSince1970)-\(valueMgDl)"
    }
}

// MARK: - Toolbar TIR

private struct LandscapeTIRBadge: View {

    enum RangeMode: CaseIterable {
        case timeInRange
        case timeInTightRange

        var title: String {
            switch self {
            case .timeInRange:
                return "TIR"
            case .timeInTightRange:
                return "TITR"
            }
        }

    }

    /// Both distributions come from StatisticsManager's validated selected-calendar-day samples.
    let rangeSummary: GlucoseClinicalRangeSummary
    var isExpandedIPad = false

    @Binding var rangeMode: RangeMode

    var body: some View {
        HStack(spacing: isExpandedIPad ? 22 : 8) {
            tirBar

            HStack(spacing: isExpandedIPad ? 12 : 0) {
                percentageText(wholePercentages[0], ConstantsAppColors.statisticsLow)
                separator
                percentageText(wholePercentages[1], ConstantsAppColors.statisticsInRange, weight: .bold)
                separator
                percentageText(wholePercentages[2], ConstantsAppColors.statisticsHigh)
            }
            .fixedSize(horizontal: true, vertical: false)

            Menu {
                ForEach(RangeMode.allCases, id: \.self) { mode in
                    Button {
                        rangeMode = mode
                    } label: {
                        if rangeMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                                .font(.system(size: 15))
                        } else {
                            Text(mode.title)
                                .font(.system(size: 15))
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(rangeMode.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ConstantsAppColors.primaryText)
            }
            .buttonStyle(.plain)
            .dynamicTypeSize(.xSmall ... .large)
        }
        .frame(height: isExpandedIPad ? 48 : 40)
        .accessibilityLabel(rangeMode.title)
        .accessibilityValue("\(Texts_Common.lowStatistics) \(percentage(wholePercentages[0])), \(Texts_Common.inRangeStatistics) \(percentage(wholePercentages[1])), \(Texts_Common.highStatistics) \(percentage(wholePercentages[2]))")
    }

    private var tirBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(ConstantsAppColors.statisticsLow)
                    .frame(width: segmentWidth(for: lowPercentage, totalWidth: geometry.size.width))

                Rectangle()
                    .fill(ConstantsAppColors.statisticsInRange)
                    .frame(width: segmentWidth(for: inRangePercentage, totalWidth: geometry.size.width))

                Rectangle()
                    .fill(ConstantsAppColors.statisticsHigh)
                    .frame(width: segmentWidth(for: highPercentage, totalWidth: geometry.size.width))
            }
            .background(Color.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(
            minWidth: isExpandedIPad ? 130 : 35,
            idealWidth: isExpandedIPad ? 180 : 130,
            maxWidth: isExpandedIPad ? 180 : 130,
            minHeight: isExpandedIPad ? 22 : 18,
            maxHeight: isExpandedIPad ? 22 : 18
        )
    }

    /// One shared calculation supplies the exact bar geometry, visible whole-number labels and
    /// accessibility value. StatisticsManager has already limited it to the selected day.
    private var rangeDistribution: GlucoseRangeDistribution {
        switch rangeMode {
        case .timeInRange:
            return rangeSummary.timeInRange
        case .timeInTightRange:
            return rangeSummary.timeInTightRange
        }
    }

    private var lowPercentage: Double {
        rangeDistribution.belowPercentage
    }

    private var inRangePercentage: Double {
        rangeDistribution.inRangePercentage
    }

    private var highPercentage: Double {
        rangeDistribution.abovePercentage
    }

    private var wholePercentages: [Int] {
        rangeDistribution.wholePercentages
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(ConstantsAppColors.tertiaryText)
            .padding(.horizontal, 4)
    }

    private func segmentWidth(for percentage: Double, totalWidth: CGFloat) -> CGFloat {
        validLandscapeDimension(totalWidth) * CGFloat(max(0, min(100, percentage)) / 100)
    }

    private func percentage(_ value: Int) -> String {
        "\(value)%"
    }

    private func percentageText(_ value: Int, _ color: Color, weight: Font.Weight = .regular) -> some View {
        Text(percentage(value))
            .font(.system(size: 15, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.9)
    }
}


// MARK: - Classic Landscape Presentation

// MARK: - State Model

/// Owns the selected day, chart cache and statistics used by the landscape Home presentation.
///
/// The same chart and statistics managers remain alive while the user moves between days, avoiding
/// a new data stack for each SwiftUI body update.
@MainActor
final class ClassicLandscapeChartStateModel: ObservableObject {

    // MARK: - TIR Data Structure

    /// Time-in-range percentages calculated for one calendar day.
    struct DailyTIRData: Identifiable {
        let date: Date
        let lowPercentage: Double
        let inRangePercentage: Double
        let highPercentage: Double

        var id: Date {
            date
        }
    }

    // MARK: - Published State

    @Published var selectedDate = Date().toMidnight()
    @Published var dailyTIRData = [DailyTIRData]()
    @Published var statistics = RootHomeStatisticsState()
    @Published var chartState = GlucoseChartState.empty(startDate: Date().toMidnight(), endDate: Date().toMidnight().addingTimeInterval(.hours(24) - 1))
    @Published var isLoadingChart = false
    @Published var isLoadingStatistics = false
    @Published var showTreatments = UserDefaults.standard.showTreatmentsOnLandscapeChart
    @Published var showStatistics = UserDefaults.standard.showStatisticsOnLandscapeChart

    // MARK: - Private Properties

    private var tirWindowStartDate = Date().toMidnight()
    private var chartStateManager: GlucoseChartStateManager?
    private var statisticsManager: StatisticsManager?

    private let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate(ConstantsGlucoseChart.dateFormatLandscapeChart)

        return dateFormatter
    }()

    // MARK: - Initialisation

    init() {}

    init(coreDataManager: CoreDataManager, nightscoutSyncManager: NightscoutSyncManager) {
        configure(coreDataManager: coreDataManager, nightscoutSyncManager: nightscoutSyncManager)
    }

    // MARK: - Configuration

    /// Creates the managers once and loads the current landscape presentation.
    func configure(coreDataManager: CoreDataManager, nightscoutSyncManager: NightscoutSyncManager) {
        guard chartStateManager == nil else { return }

        chartStateManager = GlucoseChartStateManager(coreDataManager: coreDataManager, nightscoutSyncManager: nightscoutSyncManager)
        statisticsManager = StatisticsManager(coreDataManager: coreDataManager)

        refreshForDisplay()
    }

    /// Resets the selected day to today when the landscape screen becomes visible.
    func refreshForDisplay() {
        guard chartStateManager != nil, statisticsManager != nil else { return }

        selectedDate = Date().toMidnight()
        tirWindowStartDate = selectedDate.addingTimeInterval(Double(-(ConstantsStatistics.numberOfDaysForTIRChartLandscapeView - 1)) * .hours(24))

        calculateDailyTIRData()
        refreshSelectedDay(forceReset: true)
    }

    // MARK: - Derived State

    var selectedDateText: String {
        dateFormatter.string(from: selectedDate)
    }

    var canMoveForward: Bool {
        !Calendar.current.isDateInToday(selectedDate)
    }

    var yAxisMinimumForTIR: Double {
        let tirValues = dailyTIRData.map(\.inRangePercentage).filter { $0 > 0 }
        let tirValuesMin = min(ConstantsStatistics.tirChartYAxisMinimumAxisValue, tirValues.min() ?? 0)

        return UserDefaults.standard.tirChartHasDynamicYAxis ? max(0.0, tirValuesMin - ConstantsStatistics.tirChartYAxisMinimumOffset) : 0
    }

    // MARK: - User Actions

    func setShowTreatments(_ value: Bool) {
        showTreatments = value
        UserDefaults.standard.showTreatmentsOnLandscapeChart = value
        refreshChart(forceReset: false)
    }

    func setShowStatistics(_ value: Bool) {
        showStatistics = value
        UserDefaults.standard.showStatisticsOnLandscapeChart = value
    }

    func moveBackOneDay() {
        if Calendar.current.isDate(selectedDate, inSameDayAs: tirWindowStartDate) {
            tirWindowStartDate = tirWindowStartDate.addingTimeInterval(-.hours(24))
            selectedDate = tirWindowStartDate
            calculateDailyTIRData()
        } else {
            selectedDate = selectedDate.addingTimeInterval(-.hours(24)).toMidnight()
        }

        UISelectionFeedbackGenerator().selectionChanged()
        refreshSelectedDay(forceReset: false)
    }

    func moveForwardOneDay() {
        guard !Calendar.current.isDateInToday(selectedDate) else { return }

        if Calendar.current.isDate(selectedDate, inSameDayAs: tirWindowEndDate) {
            tirWindowStartDate = tirWindowStartDate.addingTimeInterval(.hours(24)).toMidnight()
            selectedDate = selectedDate.addingTimeInterval(.hours(24)).toMidnight()
            calculateDailyTIRData()
        } else {
            selectedDate = selectedDate.addingTimeInterval(.hours(24)).toMidnight()
        }

        UISelectionFeedbackGenerator().selectionChanged()
        refreshSelectedDay(forceReset: false)
    }

    func selectToday() {
        selectedDate = Date().toMidnight()
        tirWindowStartDate = selectedDate.addingTimeInterval(Double(-(ConstantsStatistics.numberOfDaysForTIRChartLandscapeView - 1)) * .hours(24))

        UISelectionFeedbackGenerator().selectionChanged()
        calculateDailyTIRData()
        refreshSelectedDay(forceReset: false)
    }

    func selectTIRDate(_ date: Date) {
        guard !Calendar.current.isDate(date, inSameDayAs: selectedDate) else { return }

        selectedDate = date.toMidnight()
        UISelectionFeedbackGenerator().selectionChanged()
        refreshSelectedDay(forceReset: false)
    }

    func toggleTIRYAxisMode() {
        UserDefaults.standard.tirChartHasDynamicYAxis.toggle()
        objectWillChange.send()
    }

    // MARK: - Refresh

    private func refreshSelectedDay(forceReset: Bool) {
        refreshChart(forceReset: forceReset)
        refreshStatistics()
    }

    private func refreshChart(forceReset: Bool) {
        guard let chartStateManager = chartStateManager else { return }

        let startOfDay = selectedDate
        let endOfDay = startOfDay.addingTimeInterval(.hours(24) - 1)

        isLoadingChart = true
        chartStateManager.updateState(
            endDate: endOfDay,
            startDate: startOfDay,
            forceReset: forceReset,
            showTreatments: showTreatments
        ) { [weak self] chartState in
            self?.chartState = chartState
            self?.isLoadingChart = false
        }
    }

    private func refreshStatistics() {
        guard let statisticsManager = statisticsManager else { return }

        let startOfDay = selectedDate
        let endOfDay = startOfDay.addingTimeInterval(.hours(24) - 1)

        isLoadingStatistics = true
        statisticsManager.calculateStatistics(fromDate: startOfDay, toDate: endOfDay) { [weak self] statistics in
            self?.statistics = Self.makeStatisticsState(from: statistics)
            self?.isLoadingStatistics = false
        }
    }

    private func calculateDailyTIRData() {
        guard let statisticsManager = statisticsManager else { return }

        let startDayForWindow = tirWindowStartDate
        let endOfWindow = startDayForWindow.addingTimeInterval(Double(ConstantsStatistics.numberOfDaysForTIRChartLandscapeView) * .hours(24) - 1)

        statisticsManager.calculateDailyTIR(fromDate: startDayForWindow, toDate: endOfWindow) { [weak self] statisticsByDay in
            guard let self = self else { return }

            var values = [DailyTIRData]()

            for dayIndex in 0 ..< ConstantsStatistics.numberOfDaysForTIRChartLandscapeView {
                let date = Calendar.current.startOfDay(for: startDayForWindow.addingTimeInterval(Double(dayIndex) * .hours(24)))
                let statistics = statisticsByDay[date] ?? StatisticsManager.Statistics(
                    lowStatisticValue: 0,
                    highStatisticValue: 0,
                    inRangeStatisticValue: 0,
                    averageStatisticValue: 0,
                    a1CStatisticValue: 0,
                    cVStatisticValue: 0,
                    lowLimitForTIR: UserDefaults.standard.timeInRangeType.lowerLimit,
                    highLimitForTIR: UserDefaults.standard.timeInRangeType.higherLimit,
                    numberOfDaysUsed: 0
                )

                values.append(
                    DailyTIRData(
                        date: date,
                        lowPercentage: statistics.lowStatisticValue,
                        inRangePercentage: statistics.inRangeStatisticValue,
                        highPercentage: statistics.highStatisticValue
                    )
                )
            }

            self.dailyTIRData = values
        }
    }

    // MARK: - Formatting

    private var tirWindowEndDate: Date {
        tirWindowStartDate.addingTimeInterval(Double(ConstantsStatistics.numberOfDaysForTIRChartLandscapeView) * .hours(24) - 1)
    }

    private static func makeStatisticsState(from statistics: StatisticsManager.Statistics) -> RootHomeStatisticsState {
        let isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        let lowLimitText = "(<\(formattedLimit(statistics.lowLimitForTIR, isMgDl: isMgDl)))"
        let highLimitText = "(>\(formattedLimit(statistics.highLimitForTIR, isMgDl: isMgDl)))"
        let hasData = statistics.lowStatisticValue.value != 0 || statistics.inRangeStatisticValue.value != 0 || statistics.highStatisticValue.value != 0

        guard hasData else {
            return RootHomeStatisticsState(
                low: RootHomeMetricState(title: Texts_Common.lowStatistics, value: "-%", valueColor: ConstantsAppColors.statisticsLow),
                inRange: RootHomeMetricState(title: UserDefaults.standard.timeInRangeType.title, value: "-%", valueColor: ConstantsAppColors.statisticsInRange),
                high: RootHomeMetricState(title: Texts_Common.highStatistics, value: "-%", valueColor: ConstantsAppColors.statisticsHigh),
                average: RootHomeMetricState(title: Texts_Common.averageStatistics, value: isMgDl ? "- mg/dl" : "- mmol/l", valueColor: ConstantsAppColors.tertiaryText),
                a1c: RootHomeMetricState(title: Texts_Common.a1cStatistics, value: UserDefaults.standard.useIFCCA1C ? "- mmol" : "-%", valueColor: ConstantsAppColors.tertiaryText),
                cv: RootHomeMetricState(title: Texts_Common.cvStatistics, value: "-%", valueColor: ConstantsAppColors.tertiaryText),
                lowLimitText: lowLimitText,
                highLimitText: highLimitText,
                    showsActivityIndicator: false
            )
        }

        let averageValue = isMgDl
            ? "\(Int(statistics.averageStatisticValue.round(toDecimalPlaces: 0))) mg/dl"
            : "\(statistics.averageStatisticValue.round(toDecimalPlaces: 1)) mmol/l"
        let a1cValue = UserDefaults.standard.useIFCCA1C
            ? "\(Int(statistics.a1CStatisticValue.round(toDecimalPlaces: 0))) mmol"
            : "\(statistics.a1CStatisticValue.round(toDecimalPlaces: 1))%"

        return RootHomeStatisticsState(
            low: RootHomeMetricState(title: Texts_Common.lowStatistics, value: "\(Int(statistics.lowStatisticValue.round(toDecimalPlaces: 0)))%", valueColor: ConstantsAppColors.statisticsLow),
            inRange: RootHomeMetricState(title: UserDefaults.standard.timeInRangeType.title, value: "\(Int(statistics.inRangeStatisticValue.round(toDecimalPlaces: 0)))%", valueColor: ConstantsAppColors.statisticsInRange),
            high: RootHomeMetricState(title: Texts_Common.highStatistics, value: "\(Int(statistics.highStatisticValue.round(toDecimalPlaces: 0)))%", valueColor: ConstantsAppColors.statisticsHigh),
            average: RootHomeMetricState(title: Texts_Common.averageStatistics, value: averageValue),
            a1c: RootHomeMetricState(title: Texts_Common.a1cStatistics, value: a1cValue),
            cv: RootHomeMetricState(title: Texts_Common.cvStatistics, value: "\(Int(statistics.cVStatisticValue.round(toDecimalPlaces: 0)))%"),
            lowLimitText: lowLimitText,
            highLimitText: highLimitText,
            showsActivityIndicator: false
        )
    }

    private static func formattedLimit(_ value: Double, isMgDl: Bool) -> String {
        isMgDl ? Int(value).description : value.round(toDecimalPlaces: 1).description
    }

}

// MARK: - Main View

/// Full-screen landscape Home view containing daily navigation, statistics and the glucose chart.
struct ClassicLandscapeChartView: View {

    @ObservedObject var stateModel: ClassicLandscapeChartStateModel

    private enum Layout {
        static let screenPadding: CGFloat = 10
        static let spacing: CGFloat = 10
        static let toolbarHeight: CGFloat = 40
        static let statisticsWidth: CGFloat = 190
        static let tirChartHeight: CGFloat = 110
    }

    var body: some View {
        VStack(spacing: Layout.spacing) {
            toolbar

            HStack(spacing: Layout.spacing) {
                if stateModel.showStatistics {
                    ClassicLandscapeStatisticsPanel(state: stateModel.statistics, isLoading: stateModel.isLoadingStatistics)
                        .frame(width: Layout.statisticsWidth)
                }

                VStack(spacing: Layout.spacing) {
                    if stateModel.showStatistics {
                        ClassicLandscapeTIRChartView(
                            values: stateModel.dailyTIRData,
                            selectedDate: stateModel.selectedDate,
                            yAxisMinimum: stateModel.yAxisMinimumForTIR,
                            selectDate: stateModel.selectTIRDate
                        )
                        .frame(height: Layout.tirChartHeight)
                        .onTapGesture(count: 3, perform: stateModel.toggleTIRYAxisMode)
                    }

                    ClassicLandscapeGlucoseChartView(
                        chartState: stateModel.chartState,
                        isLoading: stateModel.isLoadingChart,
                        moveBackOneDay: stateModel.moveBackOneDay,
                        moveForwardOneDay: stateModel.moveForwardOneDay,
                        selectToday: stateModel.selectToday
                    )
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Layout.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConstantsAppColors.background)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(stateModel.selectedDateText)
                .font(.title3)
                .foregroundStyle(ConstantsAppColors.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(Texts_SettingsView.sectionTitleTreatments, isOn: Binding(get: {
                stateModel.showTreatments
            }, set: {
                stateModel.setShowTreatments($0)
            }))
            .toggleStyle(.switch)
            .font(.callout)
            .foregroundStyle(ConstantsAppColors.primaryText)

            Toggle(Texts_SettingsView.sectionTitleStatistics, isOn: Binding(get: {
                stateModel.showStatistics
            }, set: {
                stateModel.setShowStatistics($0)
            }))
            .toggleStyle(.switch)
            .font(.callout)
            .foregroundStyle(ConstantsAppColors.primaryText)

            HStack(spacing: 8) {
                Button(action: stateModel.moveBackOneDay) {
                    Image(systemName: "chevron.backward")
                        .font(.headline)
                }

                Button(action: stateModel.moveForwardOneDay) {
                    Image(systemName: "chevron.forward")
                        .font(.headline)
                }
                .disabled(!stateModel.canMoveForward)
            }
            .buttonStyle(.bordered)
        }
        .frame(height: Layout.toolbarHeight)
    }

}

// MARK: - Glucose Chart

/// Renders the selected day using the shared SwiftUI glucose chart.
private struct ClassicLandscapeGlucoseChartView: View {

    let chartState: GlucoseChartState
    let isLoading: Bool
    let moveBackOneDay: () -> Void
    let moveForwardOneDay: () -> Void
    let selectToday: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                GlucoseChartView(
                    glucoseChartType: .widgetSystemLarge,
                    bgReadingValues: nil,
                    bgReadingDates: nil,
                    isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl,
                    urgentLowLimitInMgDl: UserDefaults.standard.urgentLowMarkValue,
                    lowLimitInMgDl: UserDefaults.standard.lowMarkValue,
                    highLimitInMgDl: UserDefaults.standard.highMarkValue,
                    urgentHighLimitInMgDl: UserDefaults.standard.urgentHighMarkValue,
                    liveActivityType: nil,
                    hoursToShowScalingHours: 24,
                    glucoseCircleDiameterScalingHours: 6,
                    overrideChartHeight: geometry.size.height,
                    overrideChartWidth: geometry.size.width,
                    highContrast: nil,
                    chartState: chartState
                )
                .mainChartYAxisContext()
                .transaction { transaction in
                    transaction.animation = nil
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }

                            if value.translation.width < 0 {
                                moveForwardOneDay()
                            } else {
                                moveBackOneDay()
                            }
                        }
                )
                .onTapGesture(count: 2, perform: selectToday)
                .clipped()

                if isLoading {
                    ProgressView()
                        .padding(8)
                }
            }
        }
    }

}

// MARK: - Statistics

/// Selected-day statistics displayed beside the chart when enabled.
private struct ClassicLandscapeStatisticsPanel: View {

    let state: RootHomeStatisticsState
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 7) {
                ClassicLandscapeStatisticRow(metric: state.low, limitText: state.lowLimitText)
                ClassicLandscapeStatisticRow(metric: state.inRange)
                ClassicLandscapeStatisticRow(metric: state.high, limitText: state.highLimitText)
            }

            Spacer(minLength: 0)

            ZStack {
                ClassicLandscapePieChartView(
                    low: state.low.classicPercentValue,
                    inRange: state.inRange.classicPercentValue,
                    high: state.high.classicPercentValue
                )

                if isLoading {
                    ProgressView()
                        .tint(ConstantsAppColors.primaryText)
                }
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 0)

            VStack(spacing: 7) {
                ClassicLandscapeStatisticRow(metric: state.average)
                ClassicLandscapeStatisticRow(metric: state.a1c)
                ClassicLandscapeStatisticRow(metric: state.cv)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(ConstantsAppColors.homePanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

}

/// One title and value pair in the landscape statistics panel.
private struct ClassicLandscapeStatisticRow: View {

    let metric: RootHomeMetricState
    var limitText = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            HStack(spacing: 4) {
                Text(metric.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(ConstantsAppColors.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if !limitText.isEmpty {
                    Text(limitText)
                        .font(.system(size: 15))
                        .foregroundStyle(ConstantsAppColors.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Spacer(minLength: 4)

            Text(metric.value)
                .font(.system(size: 15))
                .foregroundStyle(metric.valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

}

/// Selected-day low, in-range and high percentages as a pie chart.
private struct ClassicLandscapePieChartView: View {

    let low: Double
    let inRange: Double
    let high: Double

    var body: some View {
        ZStack {
            if total > 0 {
                ClassicLandscapePieSlice(startAngle: .degrees(referenceAngle), endAngle: .degrees(referenceAngle + inRangeAngle))
                    .fill(ConstantsAppColors.statisticsInRange)

                ClassicLandscapePieSlice(startAngle: .degrees(referenceAngle + inRangeAngle), endAngle: .degrees(referenceAngle + inRangeAngle + lowAngle))
                    .fill(ConstantsAppColors.statisticsLow)

                ClassicLandscapePieSlice(startAngle: .degrees(referenceAngle + inRangeAngle + lowAngle), endAngle: .degrees(referenceAngle + 360))
                    .fill(ConstantsAppColors.statisticsHigh)
            } else {
                Circle()
                    .fill(ConstantsAppColors.tertiaryText)
            }
        }
        .frame(width: 80, height: 80)
    }

    private var total: Double {
        low + inRange + high
    }

    private var inRangeAngle: Double {
        360 * inRange / total
    }

    private var lowAngle: Double {
        360 * low / total
    }

    private var referenceAngle: Double {
        90 - (inRangeAngle / 2)
    }

}

/// One percentage slice in the landscape time-in-range pie chart.
private struct ClassicLandscapePieSlice: Shape {

    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()

        return path
    }

}

// MARK: - TIR Chart

/// Multi-day time-in-range bar chart used to select the day shown below.
private struct ClassicLandscapeTIRChartView: View {

    let values: [ClassicLandscapeChartStateModel.DailyTIRData]
    let selectedDate: Date
    let yAxisMinimum: Double
    let selectDate: (Date) -> Void

    private let yAxisMaximum = 100.0
    private let referencePercents = [0.0, 25.0, 50.0, 75.0, 100.0]

    var body: some View {
        GeometryReader { geometry in
            let layout = makeLayout(size: geometry.size)

            HStack(spacing: layout.axisLabelGap) {
                plotArea(layout: layout)
                    .frame(width: layout.chartWidth, height: layout.totalHeight, alignment: .topLeading)

                yAxisLabels(layout: layout)
                    .frame(width: layout.yAxisLabelWidth, height: layout.totalHeight, alignment: .topLeading)
            }
            .padding(.horizontal, layout.horizontalPadding)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(ConstantsAppColors.homePanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func plotArea(layout: ClassicTIRLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(referencePercents.filter { $0 >= yAxisMinimum }, id: \.self) { percent in
                Rectangle()
                    .fill(ConstantsAppColors.secondaryText.opacity(0.4))
                    .frame(width: layout.chartWidth, height: 1)
                    .offset(y: yPosition(percent: percent, layout: layout))
            }

            HStack(alignment: .bottom, spacing: layout.barSpacing) {
                ForEach(values) { value in
                    tirBar(value, layout: layout)
                }
            }
            .frame(width: layout.chartWidth, height: layout.totalHeight, alignment: .bottom)
        }
    }

    private func yAxisLabels(layout: ClassicTIRLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(referencePercents.filter { $0 >= yAxisMinimum }, id: \.self) { percent in
                let y = yPosition(percent: percent, layout: layout)

                Text("\(Int(percent))%")
                    .font(.system(size: 10))
                    .foregroundStyle(ConstantsAppColors.secondaryText.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: layout.yAxisLabelWidth, alignment: .trailing)
                    .offset(y: y - 6)
            }
        }
    }

    private func tirBar(_ value: ClassicLandscapeChartStateModel.DailyTIRData, layout: ClassicTIRLayout) -> some View {
        let isSelected = Calendar.current.isDate(value.date, inSameDayAs: selectedDate)
        let normalizedHeight = normalized(value.inRangePercentage)
        let barHeight = max(0, CGFloat(normalizedHeight) * layout.chartHeight)
        let dayText = dayLabel(for: value.date)

        return VStack(spacing: 0) {
            Text(value.inRangePercentage > 0 ? "\(Int(value.inRangePercentage.rounded()))%" : "-")
                .font(.system(size: isSelected ? 11 : 10, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? ConstantsAppColors.primaryText : (value.inRangePercentage > 0 ? ConstantsAppColors.secondaryText : ConstantsAppColors.tertiaryText))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: layout.topPadding)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isSelected ? ConstantsAppColors.statisticsInRange : ConstantsAppColors.statisticsInRange.opacity(0.55))
                    .frame(height: barHeight)
            }
            .frame(height: layout.chartHeight, alignment: .bottom)

            Text(dayText)
                .font(.system(size: isSelected ? 15 : 12, weight: isSelected ? .heavy : .regular))
                .foregroundStyle(isSelected ? ConstantsAppColors.primaryText : (value.inRangePercentage > 0 ? ConstantsAppColors.secondaryText : ConstantsAppColors.tertiaryText))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: layout.bottomPadding)
        }
        .frame(width: layout.barWidth, height: layout.totalHeight)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            selectDate(value.date)
        }
    }

    private func makeLayout(size: CGSize) -> ClassicTIRLayout {
        let topPadding: CGFloat = 24
        let bottomPadding: CGFloat = 24
        let horizontalPadding: CGFloat = 8
        let yAxisLabelWidth: CGFloat = 30
        let axisLabelGap: CGFloat = 4
        let chartWidth = max(1, size.width - (horizontalPadding * 2) - axisLabelGap - yAxisLabelWidth)
        let chartHeight = max(1, size.height - topPadding - bottomPadding)
        let barSpacing: CGFloat = 6
        let totalSpacing = barSpacing * CGFloat(max(values.count - 1, 0))
        let barWidth = max(1, (chartWidth - totalSpacing) / CGFloat(max(values.count, 1)))

        return ClassicTIRLayout(topPadding: topPadding, bottomPadding: bottomPadding, horizontalPadding: horizontalPadding, axisLabelGap: axisLabelGap, yAxisLabelWidth: yAxisLabelWidth, barSpacing: barSpacing, chartWidth: chartWidth, chartHeight: chartHeight, barWidth: barWidth)
    }

    private func normalized(_ percent: Double) -> Double {
        guard percent > 0 else { return 0 }

        return max(0, min(1, (percent - yAxisMinimum) / (yAxisMaximum - yAxisMinimum)))
    }

    private func yPosition(percent: Double, layout: ClassicTIRLayout) -> CGFloat {
        let normalized = max(0, min(1, (percent - yAxisMinimum) / (yAxisMaximum - yAxisMinimum)))

        return layout.topPadding + layout.chartHeight - CGFloat(normalized) * layout.chartHeight
    }

    private func dayLabel(for date: Date) -> String {
        let day = Calendar.current.component(.day, from: date)
        let month = Calendar.current.component(.month, from: date)
        guard let firstDate = values.first?.date else { return "\(day)" }

        let previousDate = Calendar.current.date(byAdding: .day, value: -1, to: date)
        let previousMonth = previousDate.map { Calendar.current.component(.month, from: $0) } ?? 0

        if Calendar.current.isDate(date, inSameDayAs: firstDate) || month != previousMonth {
            return shortMonthName(for: month)
        }

        return "\(day)"
    }

    private func shortMonthName(for monthNumber: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.setLocalizedDateFormatFromTemplate("MMM")

        var components = DateComponents()
        components.month = monthNumber
        components.day = 1
        components.year = 2000

        return Calendar.current.date(from: components).map { dateFormatter.string(from: $0).capitalized } ?? ""
    }

}

/// Stable dimensions shared by all bars, labels and gridlines in the TIR plot.
private struct ClassicTIRLayout {
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let horizontalPadding: CGFloat
    let axisLabelGap: CGFloat
    let yAxisLabelWidth: CGFloat
    let barSpacing: CGFloat
    let chartWidth: CGFloat
    let chartHeight: CGFloat
    let barWidth: CGFloat

    var totalHeight: CGFloat {
        topPadding + chartHeight + bottomPadding
    }
}

private extension RootHomeMetricState {
    var classicPercentValue: Double {
        Double(value.replacingOccurrences(of: "%", with: "")) ?? 0
    }
}
