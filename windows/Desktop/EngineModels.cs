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
    string? DeepSeekProgressSetup = null, EngineExpandedPanel? ExpandedPanel = null,
    string? WslAvailability = null,
    IReadOnlyList<EngineAccountCredits>? AccountCredits = null, CodexHooks? CodexHooks = null,
    CodexDelegationStatus? CodexDelegation = null, IReadOnlyList<EngineGroupedQuota>? GroupedQuota = null);
/// Settings → Collaboration, the Claude → Codex pair: the switch, whether its
/// skill is in Pacer's Claude plugin, the user-level skill it replaces, and
/// Codex's self-check: sign-in, version, model catalog and what its own
/// configuration picks for model, effort and fast mode.
internal sealed record CodexDelegationStatus(bool Enabled, bool SkillInstalled, string? LegacySkill, bool CodexFound,
    string? Login = null, string? Version = null, bool? Checking = null, IReadOnlyList<CodexModelChoice>? Models = null, string? DefaultModel = null,
    string? DefaultEffort = null, bool? DefaultFast = null, int Limit = 3, int Pending = 0, string? RunsFolder = null, string? QuotaText = null,
    bool? SeenRun = null, bool? SeenEnded = null);
/// A model from Codex's catalog, with the efforts it supports and its own default effort.
internal sealed record CodexModelChoice(string Slug, string Name, IReadOnlyList<string>? Efforts = null, string? DefaultEffort = null);
/// Codex task tracking through Pacer's hooks: `off`, `settingUp`, `notInstalled`,
/// `needsApproval` (Pending of Pacer's hooks still to allow in Codex), `running`,
/// `notRunning`, `needsCodexUpdate` or `installFailed`.
internal sealed record CodexHooks(string State, int? Pending = null, bool? OpensSettings = null);
/// A module's account credits as the engine knows them, with what the bill
/// service reported; drawn the same way in Settings, Overview and the island.
internal sealed record EngineAccountCredits(string Provider, HarnessAccountCredits Credits, bool Stale,
    HarnessCreditsPresentation? Presentation = null);
/// What a credits module draws, worded by Core: the dial, the summary lines and the breakdown.
internal sealed record HarnessCreditsPresentation(HarnessCreditsDial Dial, string? Plan, IReadOnlyList<HarnessCreditsLine> Lines,
    IReadOnlyList<HarnessCreditsSection> Sections, string BarText);
/// The ring is the month's credits; Top is the days left; Badge is the extra credits, or GapLabel when there are none.
internal sealed record HarnessCreditsDial(double? Fraction, string Center, string? Top, bool TopWarns, string? Badge, string BadgeTone,
    string? GapLabel, string AccessibilityLabel);
internal sealed record HarnessCreditsLine(string Label, string Value, string? Detail, bool Warns);
internal sealed record HarnessCreditsSection(string Title, IReadOnlyList<HarnessCreditsRow> Rows);
internal sealed record HarnessCreditsRow(string Kind, string Name, string Amount, string? Date, string? Chip);
/// Core's account credits as JSON: amounts, the plan cycle and the next expiry, times in seconds since 1970.
internal sealed record HarnessAccountCredits(string State, double? Remaining, double? Total, double? Reserved, string? Plan,
    HarnessAccountCycle? Cycle = null, HarnessAccountExpiration? Expiration = null);
internal sealed record HarnessAccountCycle(double Total, double Remaining, double? Used, double? Reset);
internal sealed record HarnessAccountExpiration(double Credits, double At);
internal sealed record ConnectionPage(string State, string Title, string Detail, string Tone, int SourceCount, int SessionCount,
    bool Retry, IReadOnlyList<ConnectionSourceRow> Sources, IReadOnlyList<ConnectionHostRow> Hosts);
internal sealed record ConnectionSourceRow(string Id, string Key, string Provider, string Name, string Kind, ConnectionModule Module);
internal sealed record ConnectionHostRow(string Id, string Name, string Kind, IReadOnlyList<ConnectionModule> Modules);
internal sealed record ConnectionModule(string Id, string Key, string Provider, string Label, string State, string Tone,
    string SessionsText, int Sessions, bool RetrySetup, bool ReadsQuota);
internal sealed record ClaudeRemoteSetup(string SourceID, string Context, bool Configured, bool InFlight, bool CanRetry, string? Message, double? RetryAt);
internal sealed record ClaudeHookSetup(string State, bool HooksConfigured, bool TelemetryConfigured, bool StatusLineConfigured, bool TelemetryConflict, bool UpdateAvailable, string? LaunchMode = null,
    string? TelemetryConflictReason = null, bool? ExactRequestSpans = null)
{
    /// Speeds are estimated: Pacer kept existing telemetry settings and no exact span has arrived.
    internal bool SpeedsEstimated => TelemetryConflict && ExactRequestSpans != true;
}
internal sealed record EngineNavigationFailure(string Id, string Message);
internal sealed record EngineActivityLink(string ActivityID, string Provider, string Context);
internal sealed record EngineNavigationPlan(string Context, string Provider, string Kind, string? Url, string? WebUrl, uint? Pid, ulong? Started, string? Terminal = null);
internal sealed record ClaudeConnection(string Context, bool WebAvailable, bool Refreshing, bool Paused, bool CanChooseOrganization, string State, string? Message);
internal sealed record ClaudeCloudConnection(string Context, bool Enabled, bool WebAvailable);
internal sealed record ClaudeAccountReport(string Context, string SelectedOrganization, IReadOnlyList<ClaudeOrganization> Organizations);
internal sealed record ClaudeOrganization(string ID, string? Name, string? Label = null);
internal sealed record DeepSeekConnection(string Context, string Source, string? Mode, bool HasKey, bool Refreshing, bool WebAvailable, DeepSeekConnectionReading Reading, DeepSeekBalanceStatus? Status = null);
internal sealed record DeepSeekBalanceStatus(string Message, string Tone, IReadOnlyList<QuotaConnectionAction> Actions);
internal sealed record ProviderHomeReport(string Provider, string Home, string EffectiveHome, string? Issue, bool Readable, string? DefaultHome = null);
internal sealed record DeepSeekConnectionReading(string Title, string Text, string Color, string DetectedText, bool Connected, bool KeyEditor, bool ShowDetection, string? Action, string? ActionLabel);
/// <param name="Path">A Claude page read's claude.ai path; null for a cookie or balance request.</param>
internal sealed record EngineHostRequest(string RequestID, string Context, bool Cancelled, string? Path = null);
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
internal sealed record EngineModule(string Provider, string Mode, bool? Installed, bool Enabled,
    string? DisplayName = null, string? Symbol = null, string? Status = null, HarnessUsage? Usage = null,
    bool? ProgressConnector = null, bool? HasTaskProgress = null, bool? ReportsSessionUsage = null,
    string? ProgressSetup = null, string? ProgressConnection = null, bool? ReportsAccountCredits = null,
    EngineModuleBrand? Brand = null, string? Website = null, string? Balance = null, bool? Prominent = null,
    bool? Local = null, DeepSeekWeekPresentation? Week = null, EngineModuleLaunch? Launch = null,
    HarnessProgressGuide? ProgressGuide = null, EngineStatusRow? Monitoring = null, EngineStatusRow? Account = null)
{
    /// Found on this computer or turned on explicitly. Older engines send
    /// nothing, so their modules stay listed.
    internal bool IsProminent => Prominent ?? true;
}
/// A row of a module page's Status card, worded by Core: state, tone
/// (`positive`, `neutral`, `attention`), text, a line under it and one action.
internal sealed record EngineStatusRow(string State, string Tone, string Text, string? Detail = null, string? Action = null);
/// The progress ring card for a module whose app must trust Pacer's tool, worded by Core.
internal sealed record HarnessProgressGuide(string Stage, string Chip, string Tone, IReadOnlyList<HarnessProgressStep> Steps,
    string? Line, string? Action, string? ActionTitle, bool Attention, string? Summary, bool Waiting, string Info,
    string? WaitingText = null, string? Picture = null, string? FloatTitle = null, string? FloatNext = null);
internal sealed record HarnessProgressStep(string Title, string State);
internal sealed record EngineModuleBrand(string Dark, string Light, double AccentLift, double AccentLuminance);
internal sealed record EngineModuleLaunch(string Scheme, string Publisher, IReadOnlyList<string> Executables, string? ConnectorsPath);
internal sealed record HarnessUsage(int? ContextUsed, int? ContextCapacity, double? SessionCredits, double MeasuredAt);
internal sealed record CodexSourceCandidate(string Path, string Source, string Label);
internal sealed record CodexSourceReport(string Executable, string? SelectedExecutable, string? ExecutableIssue,
    IReadOnlyList<CodexSourceCandidate> Candidates, string Home, string EffectiveHome, string? HomeIssue, string HistoryTitle);
internal sealed record EngineQuotaDashboard(int SchemaVersion, DashboardLayout Split, DashboardLayout Classic, IReadOnlyList<DashboardProvider> Providers, LegacyQuotaDashboard? LegacyCodex = null);
internal sealed record LegacyQuotaDashboard(bool Fresh, string FreshnessText, string Help, IReadOnlyList<LegacyQuotaBucket> Buckets);
internal sealed record LegacyQuotaBucket(string Id, string? Title, IReadOnlyList<LegacyQuotaWindow> Windows);
internal sealed record LegacyQuotaWindow(string Id, string Label, double? RemainingPercent, double? RemainingTimePercent,
    double? PacePercent, string ValueText, string Countdown, string ResetDate, string PaceText, string AccessibilityLabel);
internal sealed record DashboardLayout(string Kind, IReadOnlyList<DashboardSlot> Slots, int? Columns = null);
internal sealed record DashboardSlot(string Provider, string? Period, bool IdentifiesProvider, string Id, string Title);
internal sealed record DashboardProvider(string Provider, DashboardReading FiveHour, DashboardReading Weekly, QuotaConnectionStatus? Status = null, QuotaHistoryPresentation? History = null);
internal sealed record QuotaHistoryPresentation(string Title, string? SourceText, string FreshnessText, bool NotUpdated, string? ErrorText, string? Placeholder,
    QuotaChartPresentation? Chart, IReadOnlyList<LegacyQuotaBucket> Buckets, QuotaAccountPresentation? Account, string? Warning, string RefreshTitle, bool Refreshing);
internal sealed record QuotaAccountPresentation(string Context, string ResetText, bool ExpirySoon, string ExpiryDescription,
    string ResetsAccessibility, string BalanceText, string BalanceAccessibility, string? DetailMessage, IReadOnlyList<QuotaAccountExpiry> Expiries,
    string? NonExpiringText, string? UnknownText, string? TimeZoneText, string? NextExpiryText = null, string? PanelText = null,
    string? PanelCountText = null, string? PanelTimeText = null);
internal sealed record QuotaAccountExpiry(double Timestamp, string DateText, string CountText, string AccessibilityLabel, string RemainingText = "", bool Soon = false);
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
internal sealed record EngineQuotaBucket(string Id, string? Name, IReadOnlyList<QuotaWindow> Windows);
internal sealed record EngineGroupedQuota(string Provider, double CapturedAt, string? AccountScope, IReadOnlyList<EngineQuotaBucket> Buckets);
internal sealed record EngineQuota(string Provider, double CapturedAt, bool Stale, IReadOnlyList<QuotaWindow> Windows);
internal sealed record QuotaWindow(string Id, string Label, double? RemainingPercent, double? RemainingTimePercent,
    double? PacePercent, int? DurationMinutes, double? ResetsAt, string? Countdown = null,
    string? Verdict = null, string? VerdictText = null, bool Pressing = false, string ValueText = "—");
internal sealed record EngineNotice(string Id, string Kind, string Title, string Detail, string? Category = null, string? Body = null,
    string? PrivateBody = null, IReadOnlyList<EngineNoticeAction>? Actions = null, EngineNoticeAction? DefaultAction = null);
internal sealed record EngineNoticeAction(string Kind, string Title, string? Reference = null);
internal sealed record EngineNotificationActivation(string Kind, EngineActivityLink? Link);

internal sealed record EnginePresentation(IReadOnlyList<EngineTaskRow> Rows, int PageSize, int RowCapacity,
    int PageCount, EngineHeader Header, string? TaskCountText = null, bool? CanMarkRead = null);
internal sealed record EngineTaskRow(string Id, string Provider, string Title, string Status,
    string? Source, string? SourceLabel, string? SourceKind, string Phase, string Symbol, string? Attention,
    string Model, string? Effort, double? TokensPerSecond, bool RateIsFresh, string? RatePlaceholder,
    string? TurnTime, int Subagents, bool Unread, bool Failed, bool Dimmed, string? Cost, bool PeakCost, string? RateText = null, string? SubagentText = null,
    string? ProgressState = null, double? ProgressFraction = null, bool? ProgressStale = null, string? ProgressText = null,
    string? ProgressMode = null, string? DelegatedText = null, IReadOnlyList<EngineTaskRow>? Delegations = null,
    string? ParentID = null, bool? CanStop = null, IReadOnlyList<IReadOnlyList<string>>? DetailLines = null,
    string? DelegationsFolded = null,
    // Its subagents as dots, every one, most urgent first (attention, running, failed, completed), and what
    // they read aloud; a row draws as many as fit. Its subagent lines while it works, and the rest folded under them.
    IReadOnlyList<string>? SubagentDots = null, string? SubagentDotsText = null,
    IReadOnlyList<EngineSubagentLine>? SubagentLines = null, string? SubagentsFolded = null,
    // On a Codex for Claude run's row: its mode as a tag (task, review, follow-up).
    string? ModeTag = null);
/// One subagent under its task: its own row for the icon and ring, its state
/// (running, approval, input, completed, failed, stopped, unknown), its speed while it writes,
/// and its time or how it ended. Its line shows its type and name as tags, its title,
/// then its speed, state, time and model.
internal sealed record EngineSubagentLine(EngineTaskRow Row, string State, string? RateText, bool RateIsFresh, string Detail, string AccessibilityText,
    string? TypeTag = null, string? NameTag = null, string? Title = null, string? Model = null, string? StatusText = null, string? Time = null)
{
    internal bool IsActive => State is "running" or "approval" or "input";
}
internal sealed record EngineHeader(int ActiveCount, string? CoreSymbol, IReadOnlyDictionary<string, int> Orbit,
    string? Attention, string? Ending, string? EndingProvider, bool EndingIsCore, string? ActiveCountText = null,
    double? ProgressFraction = null, bool? ProgressLongStep = null, bool? ProgressStale = null,
    IReadOnlyList<EngineTaskShare>? ProgressTasks = null, double? ProgressAverage = null, bool? ProgressAverageStale = null,
    string? ProgressAverageProvider = null, int? ProgressReported = null, bool? ProgressSegments = null, int? DelegatedRunning = null,
    string? DelegatedText = null);
// One running task's share of the badge's multi-task ring, with the Codex for Claude runs working for it.
internal sealed record EngineTaskShare(string Provider, double? Fraction, bool Stale, int? Helpers = null);
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
