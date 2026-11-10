using System;
using System.Collections.Generic;
using System.Text.Json;

namespace CodexPacer.Windows;

internal sealed record EngineSnapshot(
    int ProtocolVersion, string Type, ulong Sequence, bool Demo, double CapturedAt,
    IReadOnlyList<EngineTask> Tasks, IReadOnlyList<EngineRequest> Requests,
    IReadOnlyList<EngineSource> Sources, IReadOnlyList<EngineQuota> Quota,
    IReadOnlyList<EngineNotice> Notices, int RunningCount, int WaitingCount,
    double? TotalTokensPerSecond, bool RateIsFresh, EnginePresentation? Presentation = null, EngineWallet? Wallet = null,
    IReadOnlyList<EngineModule>? Modules = null, EngineQuotaDashboard? QuotaDashboard = null, IReadOnlyList<CompactWarningItem>? CompactWarnings = null,
    JsonElement? CompactContext = null, DeepSeekConnection? DeepseekConnection = null, ClaudeConnection? ClaudeConnection = null,
    ClaudeCloudConnection? ClaudeCloudConnection = null, IReadOnlyList<EngineActivityLink>? ActivityLinks = null,
    EngineNavigationFailure? NavigationError = null, IReadOnlyList<string>? OpeningActivityIDs = null, ClaudeHookSetup? ClaudeSetup = null,
    IReadOnlyList<ClaudeRemoteSetup>? ClaudeRemoteSetups = null, ConnectionPage? Connections = null, string? CodexProgressSetup = null,
    string? DeepSeekProgressSetup = null, EngineExpandedPanel? ExpandedPanel = null);
internal sealed record ConnectionPage(string State, string Title, string Detail, string Tone, int SourceCount, int SessionCount,
    bool Retry, IReadOnlyList<ConnectionSourceRow> Sources, IReadOnlyList<ConnectionHostRow> Hosts);
internal sealed record ConnectionSourceRow(string Id, string Key, string Provider, string Name, string Kind, ConnectionModule Module);
internal sealed record ConnectionHostRow(string Id, string Name, string Kind, IReadOnlyList<ConnectionModule> Modules);
internal sealed record ConnectionModule(string Id, string Key, string Provider, string Label, string State, string Tone,
    string SessionsText, int Sessions, bool RetrySetup, bool ReadsQuota);
internal sealed record ClaudeRemoteSetup(string SourceID, string Context, bool Configured, bool InFlight, bool CanRetry, string? Message, double? RetryAt);
internal sealed record ClaudeHookSetup(string State, bool HooksConfigured, bool TelemetryConfigured, bool StatusLineConfigured, bool TelemetryConflict, bool UpdateAvailable, string? LaunchMode = null);
internal sealed record EngineNavigationFailure(string Id, string Message);
internal sealed record EngineActivityLink(string ActivityID, string Provider, string Context);
internal sealed record EngineNavigationPlan(string Context, string Provider, string Kind, string? Url, string? WebUrl, uint? Pid, ulong? Started, string? Terminal = null);
internal sealed record ClaudeConnection(string Context, bool WebAvailable, bool Refreshing, bool Paused, bool CanChooseOrganization, string State, string? Message);
internal sealed record ClaudeCloudConnection(string Context, bool Enabled, bool WebAvailable);
internal sealed record ClaudeAccountReport(string Context, string SelectedOrganization, IReadOnlyList<ClaudeOrganization> Organizations);
internal sealed record ClaudeOrganization(string ID, string? Name, string? Label = null);
internal sealed record DeepSeekConnection(string Context, string Source, string? Mode, bool HasKey, bool Refreshing, bool WebAvailable, DeepSeekConnectionReading Reading, DeepSeekBalanceStatus? Status = null);
internal sealed record DeepSeekBalanceStatus(string Message, string Tone, IReadOnlyList<QuotaConnectionAction> Actions);
internal sealed record ProviderHomeReport(string Provider, string Home, string EffectiveHome, string? Issue, bool Readable);
internal sealed record DeepSeekConnectionReading(string Title, string Text, string Color, string DetectedText, bool Connected, bool KeyEditor, bool ShowDetection, string? Action, string? ActionLabel);
internal sealed record EngineHostRequest(string RequestID, string Context, bool Cancelled);
internal sealed record CompactWarningItem(string Kind, string? Provider, bool Solid, string? Label, string? Symbol, string Help);

internal sealed record EngineTask(
    string Id, string Provider, string? SessionId, string? TurnId, string? ParentThreadId,
    string Title, string Source, string? SourceId, string Phase, string Stage, string StageLabel,
    string? Model, string? Effort, double? TokensPerSecond, double? RateReportedAt,
    bool RateIsFresh, bool RateIsEstimated, double? FirstTokenLatency,
    double? StartedAt, bool Unread, bool Failed, double? TurnCost, double? TurnPeakCost);

internal sealed record EngineRequest(string Id, string Provider, string ActivityId, string Kind, string Label, double DetectedAt);
internal sealed record EngineSource(string Id, string Provider, bool Available, string Transport, string? Reason, ConnectionFailure? Failure = null,
    string? SourceName = null, string? State = null, string? StateLabel = null, int? Sessions = null,
    IReadOnlyList<QuotaWindow>? QuotaWindows = null, bool QuotaRefreshing = false, string? QuotaError = null);
internal sealed record ConnectionFailure(string Kind, string? Method, int? Code);
internal sealed record EngineModule(string Provider, string Mode, bool? Installed, bool Enabled);
internal sealed record CodexSourceCandidate(string Path, string Source, string Label);
internal sealed record CodexSourceReport(string Executable, string? SelectedExecutable, string? ExecutableIssue,
    IReadOnlyList<CodexSourceCandidate> Candidates, string Home, string EffectiveHome, string? HomeIssue, string HistoryTitle);
internal sealed record EngineQuotaDashboard(int SchemaVersion, DashboardLayout Split, DashboardLayout Classic, IReadOnlyList<DashboardProvider> Providers, LegacyQuotaDashboard? LegacyCodex = null);
internal sealed record LegacyQuotaDashboard(bool Fresh, string FreshnessText, string Help, IReadOnlyList<LegacyQuotaBucket> Buckets);
internal sealed record LegacyQuotaBucket(string Id, string? Title, IReadOnlyList<LegacyQuotaWindow> Windows);
internal sealed record LegacyQuotaWindow(string Id, string Label, double? RemainingPercent, double? RemainingTimePercent,
    double? PacePercent, string ValueText, string Countdown, string ResetDate, string PaceText, string AccessibilityLabel);
internal sealed record DashboardLayout(string Kind, IReadOnlyList<DashboardSlot> Slots);
internal sealed record DashboardSlot(string Provider, string Period, bool IdentifiesProvider, string Id, string Title);
internal sealed record DashboardProvider(string Provider, DashboardReading FiveHour, DashboardReading Weekly, QuotaConnectionStatus? Status = null, QuotaHistoryPresentation? History = null);
internal sealed record QuotaHistoryPresentation(string Title, string? SourceText, string FreshnessText, bool NotUpdated, string? ErrorText, string? Placeholder,
    QuotaChartPresentation? Chart, IReadOnlyList<LegacyQuotaBucket> Buckets, QuotaAccountPresentation? Account, string? Warning, string RefreshTitle, bool Refreshing);
internal sealed record QuotaAccountPresentation(string Context, string ResetText, bool ExpirySoon, string ExpiryDescription,
    string ResetsAccessibility, string BalanceText, string BalanceAccessibility, string? DetailMessage, IReadOnlyList<QuotaAccountExpiry> Expiries,
    string? NonExpiringText, string? UnknownText, string? TimeZoneText);
internal sealed record QuotaAccountExpiry(double Timestamp, string DateText, string CountText, string AccessibilityLabel);
internal sealed record QuotaConnectionStatus(string State, string? Message, IReadOnlyList<QuotaConnectionAction> Actions);
internal sealed record QuotaConnectionAction(string Kind, string Title, bool Enabled);
internal sealed record QuotaChartPresentation(string Language, double StartedAt, double ResetsAt, string StartText, string EndText,
    IReadOnlyList<QuotaChartPoint> Points, IReadOnlyList<QuotaChartExpiry> Expiries, bool HasPartialExpiryDetails, string AccessibilityLabel, string LineHelp);
internal sealed record QuotaChartPoint(double Timestamp, double Fraction, double Remaining, string DateText, string ValueText, string AccessibilityLabel);
internal sealed record QuotaChartExpiry(double Timestamp, double Fraction, int Count, string DateText, string CountText, string AccessibilityLabel);
internal sealed record QuotaChartMarker(double Id, double X, double DateX, double Width, int Count, string? CountText,
    string Title, IReadOnlyList<QuotaChartExpiry> Details, string? MoreText, string AccessibilityLabel);
internal sealed record DashboardReading(string Provider, string Period, string Availability, string? WindowID, int? DurationMinutes,
    double? ResetsAt, double? CapturedAt, string? BucketName, double? RemainingPercent, double? RemainingTimePercent, double? PacePercent,
    string ValueText, string TimeText, string Countdown, string ResetDate, string? ResetMoment, string FreshnessText, string? SourceText,
    string? Verdict, string? VerdictText, bool Pressing, string? ProjectionText, string? ProjectionInline, bool ProjectionWarns,
    string? OtherPeriodText, string SplitHelp, string ClassicHelp, string AccessibilityLabel, string ClassicAccessibilityLabel,
    string PaceText = "—", string? ResetAtText = null, bool ProjectionEarly = false);
internal sealed record EngineQuota(string Provider, double CapturedAt, bool Stale, IReadOnlyList<QuotaWindow> Windows);
internal sealed record QuotaWindow(string Id, string Label, double? RemainingPercent, double? RemainingTimePercent,
    double? PacePercent, int? DurationMinutes, double? ResetsAt, string? Countdown = null,
    string? Verdict = null, string? VerdictText = null, bool Pressing = false, string ValueText = "—");
internal sealed record EngineNotice(string Id, string Kind, string Title, string Detail, string? Category = null, string? Body = null,
    string? PrivateBody = null, IReadOnlyList<EngineNoticeAction>? Actions = null, EngineNoticeAction? DefaultAction = null);
internal sealed record EngineNoticeAction(string Kind, string Title, string? Reference = null);
internal sealed record EngineNotificationActivation(string Kind, EngineActivityLink? Link);

internal sealed record EnginePresentation(IReadOnlyList<EngineTaskRow> Rows, int PageSize, int RowCapacity,
    int PageCount, EngineHeader Header, string? TaskCountText = null);
internal sealed record EngineTaskRow(string Id, string Provider, string Title, string Status,
    string? Source, string? SourceLabel, string? SourceKind, string Phase, string Symbol, string? Attention,
    string Model, string? Effort, double? TokensPerSecond, bool RateIsFresh, string? RatePlaceholder,
    string? TurnTime, int Subagents, bool Unread, bool Failed, bool Dimmed, string? Cost, bool PeakCost, string? RateText = null, string? SubagentText = null,
    string? ProgressState = null, double? ProgressFraction = null, bool? ProgressStale = null, string? ProgressText = null,
    string? ProgressMode = null);
internal sealed record EngineHeader(int ActiveCount, string? CoreSymbol, IReadOnlyDictionary<string, int> Orbit,
    string? Attention, string? Ending, string? EndingProvider, bool EndingIsCore, string? ActiveCountText = null,
    double? ProgressFraction = null, bool? ProgressLongStep = null, bool? ProgressStale = null,
    IReadOnlyList<EngineTaskShare>? ProgressTasks = null, double? ProgressAverage = null, bool? ProgressAverageStale = null,
    string? ProgressAverageProvider = null, int? ProgressReported = null, bool? ProgressSegments = null);
// One running task's share of the badge's multi-task ring.
internal sealed record EngineTaskShare(string Provider, double? Fraction, bool Stale);
internal sealed record WalletSpan(double Start, double End);
internal sealed record EngineWallet(string State, double? Balance, string Whole, string Cents, string Subtitle,
    string? Compact, IReadOnlyList<double> Hourly, IReadOnlyList<WalletSpan> Peak, double Angle, bool PeakNow,
    double Today, double Elsewhere, double? AverageDaily, double? RunwayDays, DeepSeekDialPresentation? Dial = null, DeepSeekSoloPresentation? Solo = null, DeepSeekSettingsReading? Settings = null,
    DeepSeekAlertPresentation? Alert = null, ReminderReading? Reminders = null);
internal sealed record ReminderReading(string LowPlaceholder, string SpikePlaceholder);
internal sealed record DeepSeekAlertPresentation(string Kind, string? BudgetKind, bool Solid, string? Label, string? Symbol, string Help);
internal sealed record DeepSeekSettingsReading(double SuggestedDaily, double SuggestedWeekly, string? DailyReference, string? WeeklyReference,
    string? BalanceText, string? RunwayText, string? CompactBudgetKind, double? CompactBudgetPercent, bool CompactBudgetDimmed, string? ConnectionText = null,
    IReadOnlyList<WalletSpan>? PricingSpans = null);
internal sealed record DeepSeekDialPresentation(string Subtitle, string SubtitleTone, string BalanceTone, string SegmentTone,
    bool DimmedFace, bool StaleCaption, string? ConnectTitle, string Freshness, string Help, string AccessibilityLabel, string PeakHelp, string? PeakText);
internal sealed record DeepSeekSoloPresentation(string TodayLabel, string TodayText, string TodayHelp, string? PeakUntil,
    DeepSeekSpeedPresentation? Speed, DeepSeekDistribution? Distribution, DeepSeekWeekPresentation? Week, IReadOnlyList<DeepSeekBudgetPresentation> Budgets);
internal sealed record DeepSeekSpeedPresentation(string Label, IReadOnlyList<double> Fractions, double? LineFraction,
    string RateText, bool Spiking, string Help, string AccessibilityLabel);
internal sealed record DeepSeekDistribution(string Title, IReadOnlyList<DeepSeekPart> Parts, string UsageTitle, string UsageHelp);
internal sealed record DeepSeekPart(string Title, string AmountText, double Fraction, double Opacity, bool Elsewhere, string Help);
internal sealed record DeepSeekWeekPresentation(string Title, string? LineText, double? LineFraction, IReadOnlyList<DeepSeekDay> Days, string AccessibilityLabel);
internal sealed record DeepSeekDay(double Timestamp, string Label, bool Today, double WithinFraction, double OverFraction, string Help);
internal sealed record DeepSeekBudgetPresentation(string Kind, string Label, double Fraction, double? TimeFraction,
    double? PacePercent, string PaceText, string? Verdict, string? VerdictText, bool Exceeded, bool Pressing, string Whole,
    string Cents, string Countdown, string ResetText, string? ProjectionText, bool ProjectionWarns, string Help, string SpentText);
