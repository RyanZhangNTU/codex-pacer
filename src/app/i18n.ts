import type { OverviewBucket } from './types'

export type AppLanguage = 'zh-CN' | 'en'

export interface SupportedLanguage {
  code: AppLanguage
  label: string
  nativeLabel: string
}

export interface I18nShape {
  language: AppLanguage
  languages: SupportedLanguage[]
  setLanguage: (language: AppLanguage) => void
  t: TranslationSet
}

export type TranslationSet = {
  appTitle: string
  appSubtitle: string
  nav: {
    overview: string
    conversations: string
  }
  actions: {
    rescanNow: string
    refreshPricing: string
    settings: string
    close: string
    cancel: string
    saveSettings: string
    saving: string
  }
  common: {
    autoScan: string
    disabled: string
    everyMinutes: (minutes: number) => string
    quotaWindow: string
    earlier: string
    newer: string
    start: string
    reset: string
    updated: string
    tokens: string
    sessions: string
    session: string
    fast: string
    noData: string
    searchTitleOrSession: string
  }
  status: {
    waitingForFirstScan: string
    fetchingLiveQuotaWindow: string
    scannedFiles: (files: number, sessions: number) => string
    backgroundScanAlreadyRunning: string
    failedToLoad: (bucketLabel: string, error: string) => string
    pricingRefreshed: string
    settingsSaved: string
    waitingLiveQuota: string
  }
  buckets: Record<OverviewBucket, string>
  bucketDescriptions: {
    subscriptionMonth: (day: number) => string
    currentFiveHourWindow: string
    historicalFiveHourWindow: string
    currentSevenDayWindow: string
    historicalSevenDayWindow: string
  }
  metrics: {
    apiValue: string
    wastedQuota: string
    remainingQuota: string
    peakUsed: (value: string) => string
    used: (value: string) => string
    windowStart: string
    remainingTime: string
    totalTokens: string
    conversationCount: string
    subscriptionCost: string
    payoffRatio: string
    planPerMonth: (planType: string, price: string) => string
    monthlyFeeShare: string
  }
  overview: {
    distribution: string
    modelShare: string
    costStructure: string
  }
  conversationList: {
    eyebrow: string
    title: string
    shown: (count: number) => string
    empty: string
  }
  detail: {
    eyebrow: string
    modelBreakdown: string
    conversationModelBreakdown: string
    conversationCostBreakdown: string
    turnTimelineEyebrow: string
    turnUsage: string
    latestTurns: (count: number) => string
    emptyTurns: string
    emptySelection: string
    untitledTurn: string
    unknownModel: string
    subagent: string
    mainSession: string
    sessionLabel: (sessionId: string) => string
  }
  charts: {
    trendEyebrow: string
    valueAndTokens: string
    valueVsTokens: string
    apiValue: string
    tokens: string
    noShareData: string
    byModel: string
    byStructure: string
    byValue: string
    byTokens: string
    liveQuotaEyebrow: string
    fiveHourQuotaTrend: string
    sevenDayQuotaTrend: string
    historicalQuotaNote: string
    currentQuotaNote: string
    noLiveQuotaHistory: string
    remaining: string
    cumulativeValue: string
    windowValue: string
  }
  popup: {
    title: string
    updated: (value: string) => string
    loading: string
    failedTitle: string
    resetIn: (value: string) => string
    speedTitle: string
    speedHint: string
    speedStatus: {
      fast: string
      healthy: string
      slow: string
    }
    resetTimeline5h: string
    resetTimeline7d: string
    modules: {
      apiValue: string
      tokenCount: string
      scanFreshness: string
      liveQuotaFreshness: string
      payoffRatio: string
      conversationCount: string
    }
    actions: {
      openDashboard: string
      refresh: string
      settings: string
    }
  }
  settings: {
    appSettings: string
    syncAndSubscriptionProfile: string
    sections: {
      language: {
        eyebrow: string
        title: string
        description: string
        label: string
        note: string
      }
      sync: {
        eyebrow: string
        title: string
        description: string
        codexHome: string
        codexHomePlaceholder: string
        autoScanEnabled: string
        autoScanEnabledNote: string
        autoScanIntervalMinutes: string
        liveQuotaRefreshIntervalSeconds: string
        liveQuotaRefreshNote: string
        defaultFastModeForNewGpt54Sessions: string
        defaultFastModeForNewGpt54SessionsNote: string
      }
      menuBar: {
        eyebrow: string
        title: string
        description: string
        hideDockIcon: string
        hideDockIconNote: string
        showLogo: string
        showLogoNote: string
        showApiValue: string
        showApiValueNote: string
        showLiveQuotaMetric: string
        showLiveQuotaMetricNote: string
        range: string
        rangeNote: string
        liveMetric: string
        liveMetricRemainingPercent: string
        liveMetricSuggestedUsageSpeed: string
        liveMetricNote: string
        quotaSource: string
        quotaSourceNote: string
        speedEmojiSection: string
        speedShowEmoji: string
        speedShowEmojiNote: string
        speedFastThreshold: string
        speedSlowThreshold: string
        speedThresholdNote: string
        speedHealthyEmoji: string
        speedFastEmoji: string
        speedSlowEmoji: string
        speedEmojiNote: string
        popupEnabled: string
        popupEnabledNote: string
        popupModules: string
        popupModulesNote: string
        popupShowResetTimeline: string
        popupShowActions: string
        moveUp: string
        moveDown: string
      }
      subscription: {
        eyebrow: string
        title: string
        description: string
        planType: string
        currency: string
        currencyNote: string
        monthlyPrice: string
        billingAnchorDay: string
        billingAnchorDayNote: string
      }
      liveQuota: {
        eyebrow: string
        title: string
        description: string
        remaining: (value: string) => string
        timeLeft: (value: string) => string
      }
    }
  }
}

export const SUPPORTED_LANGUAGES: SupportedLanguage[] = [
  { code: 'zh-CN', label: '简体中文', nativeLabel: '简体中文' },
  { code: 'en', label: 'English', nativeLabel: 'English' },
]

const translations: Record<AppLanguage, TranslationSet> = {
  'zh-CN': {
    appTitle: '订阅回本盘',
    appSubtitle: 'Codex Pacer',
    nav: {
      overview: '总览',
      conversations: '对话',
    },
    actions: {
      rescanNow: '立即扫描',
      refreshPricing: '刷新定价',
      settings: '设置',
      close: '关闭',
      cancel: '取消',
      saveSettings: '保存设置',
      saving: '保存中…',
    },
    common: {
      autoScan: '自动扫描',
      disabled: '已关闭',
      everyMinutes: (minutes) => `每 ${minutes} 分钟`,
      quotaWindow: '额度窗口',
      earlier: '更早',
      newer: '较新',
      start: '开始',
      reset: '重置',
      updated: '更新于',
      tokens: 'Tokens',
      sessions: '会话',
      session: '会话',
      fast: 'Fast',
      noData: '暂无数据',
      searchTitleOrSession: '搜索标题或会话 ID',
    },
    status: {
      waitingForFirstScan: '等待首次扫描…',
      fetchingLiveQuotaWindow: '正在获取 live quota 窗口…',
      scannedFiles: (files, sessions) => `已扫描 ${files} 个文件，刷新 ${sessions} 个会话。`,
      backgroundScanAlreadyRunning: '后台扫描已在进行中，正在刷新本地快照。',
      failedToLoad: (bucketLabel, error) => `加载${bucketLabel}失败：${error}`,
      pricingRefreshed: '已按内置官方映射刷新定价目录。',
      settingsSaved: '设置已保存。',
      waitingLiveQuota: '等待 live quota',
    },
    buckets: {
      five_hour: '5小时',
      day: '日',
      seven_day: '7天',
      week: '周',
      subscription_month: '订阅月',
      month: '月',
      year: '年',
      total: '总计',
    },
    bucketDescriptions: {
      subscriptionMonth: (day) => `每月${day}号起`,
      currentFiveHourWindow: '当前 5 小时额度窗口',
      historicalFiveHourWindow: '历史 5 小时额度窗口',
      currentSevenDayWindow: '当前 7 天额度窗口',
      historicalSevenDayWindow: '历史 7 天额度窗口',
    },
    metrics: {
      apiValue: 'API 等价价值',
      wastedQuota: '浪费额度',
      remainingQuota: '剩余额度',
      peakUsed: (value) => `峰值已用 ${value}`,
      used: (value) => `已用 ${value}`,
      windowStart: '时间段开始',
      remainingTime: '剩余时间',
      totalTokens: 'Tokens 总量',
      conversationCount: '对话数',
      subscriptionCost: '订阅费',
      payoffRatio: '回本比例',
      planPerMonth: (planType, price) => `${planType} · ${price}/月`,
      monthlyFeeShare: '占月费比例',
    },
    overview: {
      distribution: '分布',
      modelShare: '模型占比',
      costStructure: '成本结构',
    },
    conversationList: {
      eyebrow: '对话列表',
      title: '根会话',
      shown: (count) => `显示 ${count} 条`,
      empty: '当前筛选条件下没有匹配对话。',
    },
    detail: {
      eyebrow: '对话详情',
      modelBreakdown: '模型分布',
      conversationModelBreakdown: '对话模型分布',
      conversationCostBreakdown: '对话成本结构',
      turnTimelineEyebrow: 'Turn 时间线',
      turnUsage: 'Turn 用量',
      latestTurns: (count) => `最近 ${count} 个 turn`,
      emptyTurns: '该对话暂无 turn 级来源数据。',
      emptySelection: '选择一个对话以查看详细账本。',
      untitledTurn: '未命名 turn',
      unknownModel: '未知模型',
      subagent: '子代理',
      mainSession: '主会话',
      sessionLabel: (sessionId) => `会话 ${sessionId.slice(0, 8)}`,
    },
    charts: {
      trendEyebrow: '趋势',
      valueAndTokens: '价值与 Tokens',
      valueVsTokens: '价值 / Tokens',
      apiValue: 'API 价值',
      tokens: 'Tokens',
      noShareData: '当前窗口没有可用占比数据。',
      byModel: '按模型',
      byStructure: '按结构',
      byValue: '按价值',
      byTokens: '按 tokens',
      liveQuotaEyebrow: 'Live quota',
      fiveHourQuotaTrend: '5 小时额度轨迹',
      sevenDayQuotaTrend: '7 天额度轨迹',
      historicalQuotaNote: '完整历史窗口 / 剩余额度 / 累积价值',
      currentQuotaNote: '当前窗口起点到重置点 / 剩余额度 / 累积价值',
      noLiveQuotaHistory: '当前窗口还没有可用的 live quota 历史记录。',
      remaining: '剩余',
      cumulativeValue: '累积价值',
      windowValue: '窗口价值',
    },
    popup: {
      title: '菜单栏',
      updated: (value) => `更新 · ${value}`,
      loading: '正在加载菜单栏概览…',
      failedTitle: '菜单栏概览加载失败',
      resetIn: (value) => `${value}后重置`,
      speedTitle: '7天节奏',
      speedHint: '100% = 额度消耗与时间同步；低于 100% 偏快，高于 100% 偏慢',
      speedStatus: {
        fast: '放慢',
        healthy: '正常',
        slow: '可加速',
      },
      resetTimeline5h: '5h reset',
      resetTimeline7d: '7d reset',
      modules: {
        apiValue: 'API',
        tokenCount: 'Tokens',
        scanFreshness: '上次扫描',
        liveQuotaFreshness: '额度快照',
        payoffRatio: '回本',
        conversationCount: '对话',
      },
      actions: {
        openDashboard: '主窗口',
        refresh: '刷新',
        settings: '设置',
      },
    },
    settings: {
      appSettings: '应用设置',
      syncAndSubscriptionProfile: '同步与订阅配置',
      sections: {
        language: {
          eyebrow: '语言',
          title: '界面语言',
          description: '切换应用展示语言，当前实现支持中英双语，并为后续新增语言保留扩展位。',
          label: '显示语言',
          note: '语言偏好保存在本地设备，不影响已有同步配置。',
        },
        sync: {
          eyebrow: '同步',
          title: '扫描与数据源',
          description: '控制 Codex 数据目录、自动扫描频率，以及 live quota 的刷新周期。',
          codexHome: 'Codex home',
          codexHomePlaceholder: '默认使用 CODEX_HOME 或 ~/.codex',
          autoScanEnabled: '启用自动扫描',
          autoScanEnabledNote: '关闭后仅保留手动扫描，不再按周期自动刷新数据。',
          autoScanIntervalMinutes: '自动扫描间隔（分钟）',
          liveQuotaRefreshIntervalSeconds: 'Live quota 刷新间隔（秒）',
          liveQuotaRefreshNote: '独立控制 `5小时 / 7天` live quota 的主动刷新与历史持久化频率。',
          defaultFastModeForNewGpt54Sessions: '新 gpt-5.4 / gpt-5.5 对话默认按快速模式计费',
          defaultFastModeForNewGpt54SessionsNote:
            '仅影响新导入、且原始 session 未显式写入 `fast_mode/quick_mode` 的 gpt-5.4 / gpt-5.5 对话；不会改动已有对话。',
        },
        menuBar: {
          eyebrow: '菜单栏',
          title: '菜单栏显示',
          description: '统一管理菜单栏里的 logo、金额、live quota 指标和指标来源。',
          hideDockIcon: '菜单栏可见时隐藏程序坞图标',
          hideDockIconNote: '启用后应用以菜单栏作为入口；若菜单栏项目被隐藏，程序坞图标会保持显示。',
          showLogo: '在 macOS 菜单栏显示 logo',
          showLogoNote: '关闭后仅保留文字内容；若同时关闭所有文字指标，菜单栏项目会隐藏。',
          showApiValue: '在 macOS 菜单栏显示 API 价值',
          showApiValueNote: '关闭后仍可单独保留 logo 或 live quota 指标。',
          showLiveQuotaMetric: '在菜单栏显示 live quota 指标',
          showLiveQuotaMetricNote: '在菜单栏价钱右侧附加显示一个 live quota 指标。',
          range: '菜单栏统计范围',
          rangeNote: '选择菜单栏金额对应的统计尺度。`5小时 / 7天` 会使用 Codex live rate limits 当前窗口。',
          liveMetric: '菜单栏 live 指标',
          liveMetricRemainingPercent: '剩余百分比',
          liveMetricSuggestedUsageSpeed: '建议使用速度百分比',
          liveMetricNote: '`建议使用速度百分比 = 剩余额度 ÷ 剩余时间占比 × 100%`。`100%` 表示节奏健康；越低说明用得越快，越高说明还能更积极使用。',
          quotaSource: '菜单栏额度来源',
          quotaSourceNote: '指定菜单栏右侧使用 `5小时` 或 `7天` 额度窗口作为指标来源，只显示一个。',
          speedEmojiSection: '速度状态 Emoji',
          speedShowEmoji: '显示速度状态 emoji',
          speedShowEmojiNote: '关闭后菜单栏只显示百分比，不显示健康/过快/过慢状态图标。',
          speedFastThreshold: '过快阈值（%）',
          speedSlowThreshold: '过慢阈值（%）',
          speedThresholdNote: '低于“过快阈值”显示过快 emoji；高于“过慢阈值”显示过慢 emoji；中间区间显示健康 emoji。',
          speedHealthyEmoji: '健康 emoji',
          speedFastEmoji: '过快 emoji',
          speedSlowEmoji: '过慢 emoji',
          speedEmojiNote: '可输入任意短 emoji 或符号，建议保持简短以避免菜单栏拥挤。',
          popupEnabled: '启用菜单栏弹窗',
          popupEnabledNote: '左键点击菜单栏项目时，弹出一个紧凑面板展示额度和关键信息。',
          popupModules: '弹窗附加模块',
          popupModulesNote: '核心额度卡片始终显示；这里可控制附加信息卡片的显示与顺序。',
          popupShowResetTimeline: '显示 reset 时间条',
          popupShowActions: '显示底部操作按钮',
          moveUp: '上移',
          moveDown: '下移',
        },
        subscription: {
          eyebrow: '订阅',
          title: '订阅口径',
          description: '这些参数会直接影响回本、订阅月和相关成本计算。',
          planType: '套餐类型',
          currency: '货币',
          currencyNote: '当前金额与回本计算只支持 USD。若你原来填过其他币种，请把月费改成对应的美元金额。',
          monthlyPrice: '月订阅价格',
          billingAnchorDay: '订阅月起始日',
          billingAnchorDayNote: '订阅月会按这个日期切分。例如设置为 23，则统计范围是每月 23 号到次月 22 号。',
        },
        liveQuota: {
          eyebrow: 'Live Quota',
          title: '当前额度窗口',
          description: '总览中的 `5小时 / 7天` 视图和这里使用同一份 live quota 快照与刷新周期。',
          remaining: (value) => `剩余 ${value}`,
          timeLeft: (value) => `还剩 ${value}`,
        },
      },
    },
  },
  en: {
    appTitle: 'Subscription Payoff',
    appSubtitle: 'Codex Pacer',
    nav: {
      overview: 'Overview',
      conversations: 'Conversations',
    },
    actions: {
      rescanNow: 'Rescan now',
      refreshPricing: 'Refresh pricing',
      settings: 'Settings',
      close: 'Close',
      cancel: 'Cancel',
      saveSettings: 'Save settings',
      saving: 'Saving…',
    },
    common: {
      autoScan: 'Auto scan',
      disabled: 'Disabled',
      everyMinutes: (minutes) => `Every ${minutes} min`,
      quotaWindow: 'Quota window',
      earlier: 'Earlier',
      newer: 'Newer',
      start: 'Start',
      reset: 'Reset',
      updated: 'Updated',
      tokens: 'Tokens',
      sessions: 'sessions',
      session: 'Session',
      fast: 'Fast',
      noData: 'No data',
      searchTitleOrSession: 'Search title or session id',
    },
    status: {
      waitingForFirstScan: 'Waiting for first scan…',
      fetchingLiveQuotaWindow: 'Fetching live quota window…',
      scannedFiles: (files, sessions) => `Scanned ${files} files, refreshed ${sessions} sessions.`,
      backgroundScanAlreadyRunning: 'Background scan is already running. Refreshing local snapshots.',
      failedToLoad: (bucketLabel, error) => `Failed to load ${bucketLabel}: ${error}`,
      pricingRefreshed: 'Pricing catalog refreshed from built-in official mappings.',
      settingsSaved: 'Settings saved.',
      waitingLiveQuota: 'Waiting for live quota',
    },
    buckets: {
      five_hour: '5h',
      day: 'Day',
      seven_day: '7d',
      week: 'Week',
      subscription_month: 'Billing month',
      month: 'Month',
      year: 'Year',
      total: 'Total',
    },
    bucketDescriptions: {
      subscriptionMonth: (day) => `Starts on day ${day} each month`,
      currentFiveHourWindow: 'Current 5-hour quota window',
      historicalFiveHourWindow: 'Historical 5-hour quota window',
      currentSevenDayWindow: 'Current 7-day quota window',
      historicalSevenDayWindow: 'Historical 7-day quota window',
    },
    metrics: {
      apiValue: 'API value',
      wastedQuota: 'Wasted quota',
      remainingQuota: 'Remaining quota',
      peakUsed: (value) => `Peak used ${value}`,
      used: (value) => `Used ${value}`,
      windowStart: 'Window start',
      remainingTime: 'Time remaining',
      totalTokens: 'Total tokens',
      conversationCount: 'Conversations',
      subscriptionCost: 'Subscription cost',
      payoffRatio: 'Payoff ratio',
      planPerMonth: (planType, price) => `${planType} · ${price}/mo`,
      monthlyFeeShare: 'Share of monthly fee',
    },
    overview: {
      distribution: 'Distribution',
      modelShare: 'Model share',
      costStructure: 'Cost structure',
    },
    conversationList: {
      eyebrow: 'Conversation list',
      title: 'Root sessions',
      shown: (count) => `${count} shown`,
      empty: 'No conversations matched the current filter.',
    },
    detail: {
      eyebrow: 'Conversation detail',
      modelBreakdown: 'Model breakdown',
      conversationModelBreakdown: 'Conversation model breakdown',
      conversationCostBreakdown: 'Conversation cost structure',
      turnTimelineEyebrow: 'Turn timeline',
      turnUsage: 'Turn usage',
      latestTurns: (count) => `Latest ${count} turns`,
      emptyTurns: 'No turn-level source data is available for this conversation.',
      emptySelection: 'Select a conversation to inspect its detailed ledger.',
      untitledTurn: 'Untitled turn',
      unknownModel: 'Unknown model',
      subagent: 'Subagent',
      mainSession: 'Main session',
      sessionLabel: (sessionId) => `Session ${sessionId.slice(0, 8)}`,
    },
    charts: {
      trendEyebrow: 'Trend',
      valueAndTokens: 'Value and tokens',
      valueVsTokens: 'Value / Tokens',
      apiValue: 'API value',
      tokens: 'Tokens',
      noShareData: 'No share data in this window.',
      byModel: 'By model',
      byStructure: 'By structure',
      byValue: 'By value',
      byTokens: 'By tokens',
      liveQuotaEyebrow: 'Live quota',
      fiveHourQuotaTrend: '5-hour quota trend',
      sevenDayQuotaTrend: '7-day quota trend',
      historicalQuotaNote: 'Full historical window / remaining quota / cumulative value',
      currentQuotaNote: 'Current window start to reset / remaining quota / cumulative value',
      noLiveQuotaHistory: 'No live quota history is available for the current window yet.',
      remaining: 'Remaining',
      cumulativeValue: 'Cumulative value',
      windowValue: 'Window value',
    },
    popup: {
      title: 'Menu bar',
      updated: (value) => `Updated · ${value}`,
      loading: 'Loading menu bar snapshot…',
      failedTitle: 'Failed to load menu bar snapshot',
      resetIn: (value) => `Resets in ${value}`,
      speedTitle: '7D pace',
      speedHint: '100% = quota and time are aligned; below 100% is faster, above 100% is slower',
      speedStatus: {
        fast: 'Slow down',
        healthy: 'On pace',
        slow: 'Push harder',
      },
      resetTimeline5h: '5h reset',
      resetTimeline7d: '7d reset',
      modules: {
        apiValue: 'API',
        tokenCount: 'Tokens',
        scanFreshness: 'Last scan',
        liveQuotaFreshness: 'Quota age',
        payoffRatio: 'Payoff',
        conversationCount: 'Chats',
      },
      actions: {
        openDashboard: 'Dashboard',
        refresh: 'Refresh',
        settings: 'Settings',
      },
    },
    settings: {
      appSettings: 'App settings',
      syncAndSubscriptionProfile: 'Sync and subscription profile',
      sections: {
        language: {
          eyebrow: 'Language',
          title: 'Interface language',
          description: 'Switch the app language. The current structure supports Chinese and English now while keeping room for more languages later.',
          label: 'Display language',
          note: 'This preference is stored locally and does not change synced settings.',
        },
        sync: {
          eyebrow: 'Sync',
          title: 'Scan and data sources',
          description: 'Control the Codex data directory, automatic scan cadence, and live quota refresh interval.',
          codexHome: 'Codex home',
          codexHomePlaceholder: 'Defaults to CODEX_HOME or ~/.codex',
          autoScanEnabled: 'Auto scan enabled',
          autoScanEnabledNote: 'When disabled, only manual scans are kept and periodic refresh stops.',
          autoScanIntervalMinutes: 'Auto scan interval (minutes)',
          liveQuotaRefreshIntervalSeconds: 'Live quota refresh interval (seconds)',
          liveQuotaRefreshNote: 'Separately controls active refresh and history persistence for `5h / 7d` live quota snapshots.',
          defaultFastModeForNewGpt54Sessions: 'Default new gpt-5.4 / gpt-5.5 sessions to fast-mode billing',
          defaultFastModeForNewGpt54SessionsNote:
            'Only affects newly imported gpt-5.4 / gpt-5.5 sessions when the raw session does not explicitly contain `fast_mode/quick_mode`; existing sessions are unchanged.',
        },
        menuBar: {
          eyebrow: 'Menu Bar',
          title: 'Menu bar display',
          description: 'Manage the logo, amount, live quota metric, and source used in the macOS menu bar.',
          hideDockIcon: 'Hide Dock icon while menu bar is visible',
          hideDockIconNote: 'Uses the menu bar item as the app entry point. If the menu bar item is hidden, the Dock icon stays visible.',
          showLogo: 'Show logo in macOS menu bar',
          showLogoNote: 'When disabled, only text stays visible. If every text metric is also off, the tray item is hidden.',
          showApiValue: 'Show API value in macOS menu bar',
          showApiValueNote: 'You can turn this off and still keep the logo or live quota metric visible.',
          showLiveQuotaMetric: 'Show live quota metric in menu bar',
          showLiveQuotaMetricNote: 'Adds one live quota metric to the right side of the menu bar amount.',
          range: 'Menu bar range',
          rangeNote: 'Choose the aggregation window for the menu bar amount. `5h / 7d` uses the current live rate limit window.',
          liveMetric: 'Menu bar live metric',
          liveMetricRemainingPercent: 'Remaining percent',
          liveMetricSuggestedUsageSpeed: 'Suggested usage speed %',
          liveMetricNote: '`Suggested usage speed % = remaining quota ÷ remaining time share × 100%`. `100%` means the pace is balanced; lower means you are burning quota faster, higher means you can be more aggressive.',
          quotaSource: 'Menu bar quota source',
          quotaSourceNote: 'Choose whether the menu bar uses the `5h` or `7d` quota window as the single metric source.',
          speedEmojiSection: 'Speed status emoji',
          speedShowEmoji: 'Show speed-status emoji',
          speedShowEmojiNote: 'When disabled, the menu bar shows only the percentage without status icons.',
          speedFastThreshold: 'Fast threshold (%)',
          speedSlowThreshold: 'Slow threshold (%)',
          speedThresholdNote: 'Below the fast threshold shows the fast-usage emoji; above the slow threshold shows the slow-usage emoji; the middle range shows the healthy emoji.',
          speedHealthyEmoji: 'Healthy emoji',
          speedFastEmoji: 'Too-fast emoji',
          speedSlowEmoji: 'Too-slow emoji',
          speedEmojiNote: 'Any short emoji or symbol works, but shorter values keep the menu bar cleaner.',
          popupEnabled: 'Enable menu bar popup',
          popupEnabledNote: 'Left-clicking the menu bar item opens a compact quota popup with the most important metrics.',
          popupModules: 'Popup secondary modules',
          popupModulesNote: 'Core quota cards always stay visible; use this list to control extra cards and their order.',
          popupShowResetTimeline: 'Show reset timeline row',
          popupShowActions: 'Show footer action buttons',
          moveUp: 'Move up',
          moveDown: 'Move down',
        },
        subscription: {
          eyebrow: 'Subscription',
          title: 'Subscription framing',
          description: 'These parameters directly affect payoff, billing-month slicing, and related cost calculations.',
          planType: 'Plan type',
          currency: 'Currency',
          currencyNote: 'Cost and payoff metrics currently support USD only. If you previously entered another currency, update the monthly price to its USD amount.',
          monthlyPrice: 'Monthly subscription price',
          billingAnchorDay: 'Subscription month starts on',
          billingAnchorDayNote: 'The billing month is split by this day. For example, `23` means each window runs from the 23rd to the 22nd of the next month.',
        },
        liveQuota: {
          eyebrow: 'Live Quota',
          title: 'Current quota windows',
          description: 'The `5h / 7d` overview views and this section share the same live quota snapshot and refresh cadence.',
          remaining: (value) => `Remaining ${value}`,
          timeLeft: (value) => `${value} left`,
        },
      },
    },
  },
}

export const LANGUAGE_STORAGE_KEY = 'codex-counter.language'

export function getTranslations(language: AppLanguage) {
  return translations[language]
}

export function getNumberLocale(language: AppLanguage) {
  return language === 'zh-CN' ? 'zh-CN' : 'en-US'
}

export function getDateTimeLocale(language: AppLanguage) {
  return language === 'zh-CN' ? 'zh-CN' : 'en-SG'
}

export function getRelativeTimeLocale(language: AppLanguage) {
  return language === 'zh-CN' ? 'zh-CN' : 'en'
}

export function readStoredLanguage(): AppLanguage {
  if (typeof window === 'undefined') return 'zh-CN'
  const stored = window.localStorage.getItem(LANGUAGE_STORAGE_KEY)
  return stored === 'en' || stored === 'zh-CN' ? stored : 'zh-CN'
}
