import { useEffect, useRef, useState } from 'react'
import { ChevronDown, ChevronUp } from 'lucide-react'

import { formatPercent, formatRemainingDuration } from '../app/format'
import { SUPPORTED_LANGUAGES, type AppLanguage } from '../app/i18n'
import { useI18n } from '../app/useI18n'
import type {
  LiveRateLimitSnapshot,
  MenuBarPopupModuleId,
  OverviewBucket,
  SubscriptionProfile,
  SyncSettings,
} from '../app/types'

interface SettingsPanelProps {
  isOpen: boolean
  language: AppLanguage
  liveRateLimits: LiveRateLimitSnapshot | null
  syncSettings: SyncSettings | null
  subscriptionProfile: SubscriptionProfile | null
  onClose: () => void
  onLanguageChange: (language: AppLanguage) => void
  onSave: (payload: {
    syncSettings: SyncSettings
    subscriptionProfile: SubscriptionProfile
  }) => Promise<void>
}

interface SwitchFieldProps {
  label: string
  checked: boolean
  disabled?: boolean
  onChange: (checked: boolean) => void
}

function SwitchField({ label, checked, disabled = false, onChange }: SwitchFieldProps) {
  return (
    <label className={`switch-field${disabled ? ' is-disabled' : ''}`}>
      <span>{label}</span>
      <input
        checked={checked}
        className="switch-input"
        disabled={disabled}
        onChange={(event) => onChange(event.target.checked)}
        role="switch"
        type="checkbox"
      />
      <span className="switch-track" aria-hidden="true">
        <span />
      </span>
    </label>
  )
}

function refreshSecondsToMinutes(seconds: number) {
  return Math.max(1, Math.round(seconds / 60))
}

function refreshMinutesToSeconds(minutes: number) {
  return Math.min(60, Math.max(1, minutes)) * 60
}

function isMacOs() {
  return typeof navigator !== 'undefined' && navigator.platform.toLowerCase().includes('mac')
}

export function SettingsPanel({
  isOpen,
  language,
  liveRateLimits,
  syncSettings,
  subscriptionProfile,
  onClose,
  onLanguageChange,
  onSave,
}: SettingsPanelProps) {
  const { t } = useI18n()
  const [draftSync, setDraftSync] = useState<SyncSettings | null>(syncSettings)
  const [draftSubscription, setDraftSubscription] = useState<SubscriptionProfile | null>(
    subscriptionProfile,
  )
  const [saving, setSaving] = useState(false)
  const wasOpenRef = useRef(false)
  const showDockSettings = isMacOs()

  useEffect(() => {
    const justOpened = isOpen && !wasOpenRef.current

    if (justOpened || (!draftSync && syncSettings) || (!draftSubscription && subscriptionProfile)) {
      setDraftSync(syncSettings)
      setDraftSubscription(subscriptionProfile)
      setSaving(false)
    } else if (!isOpen && wasOpenRef.current) {
      setDraftSync(syncSettings)
      setDraftSubscription(subscriptionProfile)
      setSaving(false)
    }

    wasOpenRef.current = isOpen
  }, [draftSubscription, draftSync, isOpen, subscriptionProfile, syncSettings])

  if (!isOpen || !draftSync || !draftSubscription) return null

  const menuBarBucketOptions: Array<{ value: OverviewBucket; label: string }> = [
    { value: 'five_hour', label: t.buckets.five_hour },
    { value: 'day', label: t.buckets.day },
    { value: 'seven_day', label: t.buckets.seven_day },
    { value: 'week', label: t.buckets.week },
    { value: 'subscription_month', label: t.buckets.subscription_month },
    { value: 'month', label: t.buckets.month },
    { value: 'year', label: t.buckets.year },
    { value: 'total', label: t.buckets.total },
  ]

  const menuBarLiveQuotaOptions = [
    { value: 'five_hour', label: t.buckets.five_hour },
    { value: 'seven_day', label: t.buckets.seven_day },
  ] as const

  const menuBarLiveQuotaMetricOptions = [
    { value: 'remaining_percent', label: t.settings.sections.menuBar.liveMetricRemainingPercent },
    {
      value: 'suggested_usage_speed',
      label: t.settings.sections.menuBar.liveMetricSuggestedUsageSpeed,
    },
  ] as const

  const popupModuleOptions: Array<{ value: MenuBarPopupModuleId; label: string }> = [
    { value: 'api_value', label: t.popup.modules.apiValue },
    { value: 'token_count', label: t.popup.modules.tokenCount },
    { value: 'scan_freshness', label: t.popup.modules.scanFreshness },
    { value: 'live_quota_freshness', label: t.popup.modules.liveQuotaFreshness },
    { value: 'payoff_ratio', label: t.popup.modules.payoffRatio },
    { value: 'conversation_count', label: t.popup.modules.conversationCount },
  ]

  function togglePopupModule(moduleId: MenuBarPopupModuleId, enabled: boolean) {
    setDraftSync((current) => {
      if (!current) return current
      const nextModules = enabled
        ? current.menuBarPopupModules.includes(moduleId)
          ? current.menuBarPopupModules
          : [...current.menuBarPopupModules, moduleId]
        : current.menuBarPopupModules.filter((item) => item !== moduleId)

      return {
        ...current,
        menuBarPopupModules: nextModules,
      }
    })
  }

  function movePopupModule(moduleId: MenuBarPopupModuleId, direction: -1 | 1) {
    setDraftSync((current) => {
      if (!current) return current
      const index = current.menuBarPopupModules.indexOf(moduleId)
      if (index < 0) return current

      const nextIndex = index + direction
      if (nextIndex < 0 || nextIndex >= current.menuBarPopupModules.length) return current

      const nextModules = [...current.menuBarPopupModules]
      const [item] = nextModules.splice(index, 1)
      nextModules.splice(nextIndex, 0, item)

      return {
        ...current,
        menuBarPopupModules: nextModules,
      }
    })
  }

  async function handleSubmit() {
    if (!draftSync || !draftSubscription) return
    setSaving(true)
    try {
      const nextSync = draftSync
      const nextSubscription = draftSubscription
      await onSave({
        syncSettings: nextSync,
        subscriptionProfile: nextSubscription,
      })
      onClose()
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal-panel settings-modal-panel" onClick={(event) => event.stopPropagation()}>
        <div className="modal-header">
          <div>
            <p className="eyebrow">{t.settings.appSettings}</p>
            <h3>{t.settings.syncAndSubscriptionProfile}</h3>
          </div>
          <button className="ghost-button" onClick={onClose} type="button">
            {t.actions.close}
          </button>
        </div>

        <div className="modal-scroll">
          <div className="settings-sections">
            <section className="settings-section">
              <div className="settings-section-head">
                <p className="eyebrow">{t.settings.sections.language.eyebrow}</p>
                <h4>{t.settings.sections.language.title}</h4>
              </div>

              <div className="settings-grid">
                <label className="field">
                  <span>{t.settings.sections.language.label}</span>
                  <select
                    value={language}
                    onChange={(event) => onLanguageChange(event.target.value as AppLanguage)}
                  >
                    {SUPPORTED_LANGUAGES.map((option) => (
                      <option key={option.code} value={option.code}>
                        {option.nativeLabel} · {option.label}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
            </section>

            <section className="settings-section">
              <div className="settings-section-head">
                <p className="eyebrow">{t.settings.sections.sync.eyebrow}</p>
                <h4>{t.settings.sections.sync.title}</h4>
              </div>

              <div className="settings-grid">
                <label className="field">
                  <span>{t.settings.sections.sync.codexHome}</span>
                  <input
                    value={draftSync.codexHome ?? ''}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              codexHome: event.target.value.trim() || null,
                            }
                          : current,
                      )
                    }
                    placeholder={t.settings.sections.sync.codexHomePlaceholder}
                  />
                </label>

                <SwitchField
                  checked={draftSync.autoScanEnabled}
                  label={t.settings.sections.sync.autoScanEnabled}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            autoScanEnabled: checked,
                          }
                        : current,
                    )
                  }
                />

                <label className="field">
                  <span>{t.settings.sections.sync.autoScanIntervalMinutes}</span>
                  <input
                    min={1}
                    step={1}
                    type="number"
                    value={draftSync.autoScanIntervalMinutes}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              autoScanIntervalMinutes: Math.max(1, Number(event.target.value || 5)),
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <label className="field">
                  <span>{t.settings.sections.sync.liveQuotaRefreshIntervalSeconds}</span>
                  <input
                    min={1}
                    max={60}
                    step={1}
                    type="number"
                    value={refreshSecondsToMinutes(draftSync.liveQuotaRefreshIntervalSeconds)}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              liveQuotaRefreshIntervalSeconds: refreshMinutesToSeconds(
                                Number(event.target.value || 5),
                              ),
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <SwitchField
                  checked={draftSync.defaultFastModeForNewGpt54Sessions}
                  label={t.settings.sections.sync.defaultFastModeForNewGpt54Sessions}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            defaultFastModeForNewGpt54Sessions: checked,
                          }
                        : current,
                    )
                  }
                />
              </div>
            </section>

            <section className="settings-section">
              <div className="settings-section-head">
                <p className="eyebrow">{t.settings.sections.menuBar.eyebrow}</p>
                <h4>{t.settings.sections.menuBar.title}</h4>
              </div>

              <div className="settings-grid">
                {showDockSettings ? (
                  <SwitchField
                    checked={draftSync.hideDockIconWhenMenuBarVisible}
                    label={t.settings.sections.menuBar.hideDockIcon}
                    onChange={(checked) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              hideDockIconWhenMenuBarVisible: checked,
                            }
                          : current,
                      )
                    }
                  />
                ) : null}

                <SwitchField
                  checked={draftSync.showMenuBarLogo}
                  label={t.settings.sections.menuBar.showLogo}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            showMenuBarLogo: checked,
                          }
                        : current,
                    )
                  }
                />

                <SwitchField
                  checked={draftSync.showMenuBarDailyApiValue}
                  label={t.settings.sections.menuBar.showApiValue}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            showMenuBarDailyApiValue: checked,
                          }
                        : current,
                    )
                  }
                />

                <SwitchField
                  checked={draftSync.showMenuBarLiveQuotaPercent}
                  label={t.settings.sections.menuBar.showLiveQuotaMetric}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            showMenuBarLiveQuotaPercent: checked,
                          }
                        : current,
                    )
                  }
                />

                <label className="field">
                  <span>{t.settings.sections.menuBar.range}</span>
                  <select
                    value={draftSync.menuBarBucket}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarBucket: event.target.value as OverviewBucket,
                            }
                          : current,
                      )
                    }
                  >
                    {menuBarBucketOptions.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.liveMetric}</span>
                  <select
                    disabled={!draftSync.showMenuBarLiveQuotaPercent}
                    value={draftSync.menuBarLiveQuotaMetric}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarLiveQuotaMetric: event.target.value as
                                | 'remaining_percent'
                                | 'suggested_usage_speed',
                            }
                          : current,
                      )
                    }
                  >
                    {menuBarLiveQuotaMetricOptions.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.quotaSource}</span>
                  <select
                    disabled={!draftSync.showMenuBarLiveQuotaPercent}
                    value={draftSync.menuBarLiveQuotaBucket}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarLiveQuotaBucket: event.target.value as 'five_hour' | 'seven_day',
                            }
                          : current,
                      )
                    }
                  >
                    {menuBarLiveQuotaOptions.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                </label>

                <SwitchField
                  checked={draftSync.menuBarSpeedShowEmoji}
                  disabled={
                    !draftSync.showMenuBarLiveQuotaPercent ||
                    draftSync.menuBarLiveQuotaMetric !== 'suggested_usage_speed'
                  }
                  label={t.settings.sections.menuBar.speedShowEmoji}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            menuBarSpeedShowEmoji: checked,
                          }
                        : current,
                    )
                  }
                />

                <label className="field">
                  <span>{t.settings.sections.menuBar.speedFastThreshold}</span>
                  <input
                    disabled={
                      !draftSync.showMenuBarLiveQuotaPercent ||
                      draftSync.menuBarLiveQuotaMetric !== 'suggested_usage_speed'
                    }
                    min={0}
                    max={1000}
                    step={1}
                    type="number"
                    value={draftSync.menuBarSpeedFastThresholdPercent}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarSpeedFastThresholdPercent: Math.max(
                                0,
                                Math.min(1000, Number(event.target.value || 0)),
                              ),
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.speedSlowThreshold}</span>
                  <input
                    disabled={
                      !draftSync.showMenuBarLiveQuotaPercent ||
                      draftSync.menuBarLiveQuotaMetric !== 'suggested_usage_speed'
                    }
                    min={0}
                    max={1000}
                    step={1}
                    type="number"
                    value={draftSync.menuBarSpeedSlowThresholdPercent}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarSpeedSlowThresholdPercent: Math.max(
                                0,
                                Math.min(1000, Number(event.target.value || 0)),
                              ),
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.speedHealthyEmoji}</span>
                  <input
                    disabled={
                      !draftSync.showMenuBarLiveQuotaPercent ||
                      draftSync.menuBarLiveQuotaMetric !== 'suggested_usage_speed'
                    }
                    value={draftSync.menuBarSpeedHealthyEmoji}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarSpeedHealthyEmoji: event.target.value,
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.speedFastEmoji}</span>
                  <input
                    disabled={
                      !draftSync.showMenuBarLiveQuotaPercent ||
                      draftSync.menuBarLiveQuotaMetric !== 'suggested_usage_speed'
                    }
                    value={draftSync.menuBarSpeedFastEmoji}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarSpeedFastEmoji: event.target.value,
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.speedSlowEmoji}</span>
                  <input
                    disabled={
                      !draftSync.showMenuBarLiveQuotaPercent ||
                      draftSync.menuBarLiveQuotaMetric !== 'suggested_usage_speed'
                    }
                    value={draftSync.menuBarSpeedSlowEmoji}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              menuBarSpeedSlowEmoji: event.target.value,
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <SwitchField
                  checked={draftSync.menuBarPopupEnabled}
                  label={t.settings.sections.menuBar.popupEnabled}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            menuBarPopupEnabled: checked,
                          }
                        : current,
                    )
                  }
                />

                <SwitchField
                  checked={draftSync.menuBarPopupShowResetTimeline}
                  label={t.settings.sections.menuBar.popupShowResetTimeline}
                  onChange={(checked) =>
                    setDraftSync((current) =>
                      current
                        ? {
                            ...current,
                            menuBarPopupShowResetTimeline: checked,
                          }
                        : current,
                    )
                  }
                />

                <div className="field popup-module-editor">
                  <span>{t.settings.sections.menuBar.popupModules}</span>
                  <div className="popup-module-list">
                    {popupModuleOptions.map((option) => {
                      const enabled = draftSync.menuBarPopupModules.includes(option.value)
                      const index = draftSync.menuBarPopupModules.indexOf(option.value)
                      return (
                        <div className="popup-module-item" key={option.value}>
                          <label className="popup-module-toggle">
                            <input
                              checked={enabled}
                              className="switch-input"
                              onChange={(event) => togglePopupModule(option.value, event.target.checked)}
                              role="switch"
                              type="checkbox"
                            />
                            <span className="switch-track" aria-hidden="true">
                              <span />
                            </span>
                            <span>{option.label}</span>
                          </label>
                          <div className="popup-module-actions">
                            <button
                              aria-label={t.settings.sections.menuBar.moveUp}
                              className="ghost-button popup-icon-button"
                              disabled={!enabled || index <= 0}
                              onClick={() => movePopupModule(option.value, -1)}
                              type="button"
                            >
                              <ChevronUp aria-hidden="true" size={15} />
                            </button>
                            <button
                              aria-label={t.settings.sections.menuBar.moveDown}
                              className="ghost-button popup-icon-button"
                              disabled={!enabled || index < 0 || index >= draftSync.menuBarPopupModules.length - 1}
                              onClick={() => movePopupModule(option.value, 1)}
                              type="button"
                            >
                              <ChevronDown aria-hidden="true" size={15} />
                            </button>
                          </div>
                        </div>
                      )
                    })}
                  </div>
                </div>
              </div>
            </section>

            <section className="settings-section">
              <div className="settings-section-head">
                <p className="eyebrow">{t.settings.sections.subscription.eyebrow}</p>
                <h4>{t.settings.sections.subscription.title}</h4>
              </div>

              <div className="settings-grid">
                <label className="field">
                  <span>{t.settings.sections.subscription.planType}</span>
                  <input
                    value={draftSubscription.planType}
                    onChange={(event) =>
                      setDraftSubscription((current) =>
                        current
                          ? {
                              ...current,
                              planType: event.target.value,
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <label className="field">
                  <span>{t.settings.sections.subscription.currency}</span>
                  <input disabled readOnly value={draftSubscription.currency} />
                </label>

                <label className="field">
                  <span>{t.settings.sections.subscription.monthlyPrice}</span>
                  <input
                    min={0}
                    step={0.01}
                    type="number"
                    value={draftSubscription.monthlyPrice}
                    onChange={(event) =>
                      setDraftSubscription((current) =>
                        current
                          ? {
                              ...current,
                              monthlyPrice: Math.max(0, Number(event.target.value || 0)),
                            }
                          : current,
                      )
                    }
                  />
                </label>

                <label className="field">
                  <span>{t.settings.sections.subscription.billingAnchorDay}</span>
                  <input
                    min={1}
                    max={28}
                    step={1}
                    type="number"
                    value={draftSubscription.billingAnchorDay}
                    onChange={(event) =>
                      setDraftSubscription((current) =>
                        current
                          ? {
                              ...current,
                              billingAnchorDay: Math.min(28, Math.max(1, Number(event.target.value || 1))),
                            }
                          : current,
                      )
                    }
                  />
                </label>
              </div>
            </section>

            {liveRateLimits ? (
              <section className="settings-section">
                <div className="settings-section-head">
                  <p className="eyebrow">{t.settings.sections.liveQuota.eyebrow}</p>
                  <h4>{t.settings.sections.liveQuota.title}</h4>
                </div>

                <div className="field field-readonly live-quota-field">
                  <div className="live-quota-grid">
                    <div className="live-quota-row">
                      <strong>{t.buckets.five_hour}</strong>
                      <span>
                        {t.settings.sections.liveQuota.remaining(
                          formatPercent((liveRateLimits.primary?.remainingPercent ?? 0) / 100, language),
                        )}
                      </span>
                      <span>
                        {t.settings.sections.liveQuota.timeLeft(
                          formatRemainingDuration(liveRateLimits.primary?.resetsAt ?? null, language),
                        )}
                      </span>
                    </div>
                    <div className="live-quota-row">
                      <strong>{t.buckets.seven_day}</strong>
                      <span>
                        {t.settings.sections.liveQuota.remaining(
                          formatPercent(
                            (liveRateLimits.secondary?.remainingPercent ?? 0) / 100,
                            language,
                          ),
                        )}
                      </span>
                      <span>
                        {t.settings.sections.liveQuota.timeLeft(
                          formatRemainingDuration(liveRateLimits.secondary?.resetsAt ?? null, language),
                        )}
                      </span>
                    </div>
                  </div>
                </div>
              </section>
            ) : null}
          </div>
        </div>

        <div className="modal-actions">
          <button className="ghost-button" onClick={onClose} type="button">
            {t.actions.cancel}
          </button>
          <button className="accent-button" disabled={saving} onClick={handleSubmit} type="button">
            {saving ? t.actions.saving : t.actions.saveSettings}
          </button>
        </div>
      </div>
    </div>
  )
}
