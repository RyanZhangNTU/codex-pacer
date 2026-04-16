import { useEffect, useRef, useState } from 'react'

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
                <p>{t.settings.sections.language.description}</p>
              </div>

              <div className="settings-grid">
                <label className="field field-span-2">
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
                  <span className="field-note">{t.settings.sections.language.note}</span>
                </label>
              </div>
            </section>

            <section className="settings-section">
              <div className="settings-section-head">
                <p className="eyebrow">{t.settings.sections.sync.eyebrow}</p>
                <h4>{t.settings.sections.sync.title}</h4>
                <p>{t.settings.sections.sync.description}</p>
              </div>

              <div className="settings-grid">
                <label className="field field-span-2">
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

                <label className="field">
                  <span>{t.settings.sections.sync.autoScanEnabled}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">{t.settings.sections.sync.autoScanEnabledNote}</span>
                    <input
                      checked={draftSync.autoScanEnabled}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                autoScanEnabled: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>

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

                <label className="field field-span-2">
                  <span>{t.settings.sections.sync.liveQuotaRefreshIntervalSeconds}</span>
                  <input
                    min={5}
                    max={3600}
                    step={5}
                    type="number"
                    value={draftSync.liveQuotaRefreshIntervalSeconds}
                    onChange={(event) =>
                      setDraftSync((current) =>
                        current
                          ? {
                              ...current,
                              liveQuotaRefreshIntervalSeconds: Math.min(
                                3600,
                                Math.max(5, Number(event.target.value || 60)),
                              ),
                            }
                          : current,
                      )
                    }
                  />
                  <span className="field-note">
                    {t.settings.sections.sync.liveQuotaRefreshNote}
                  </span>
                </label>

                <label className="field field-span-2">
                  <span>{t.settings.sections.sync.defaultFastModeForNewGpt54Sessions}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">
                      {t.settings.sections.sync.defaultFastModeForNewGpt54SessionsNote}
                    </span>
                    <input
                      checked={draftSync.defaultFastModeForNewGpt54Sessions}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                defaultFastModeForNewGpt54Sessions: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>
              </div>
            </section>

            <section className="settings-section">
              <div className="settings-section-head">
                <p className="eyebrow">{t.settings.sections.menuBar.eyebrow}</p>
                <h4>{t.settings.sections.menuBar.title}</h4>
                <p>{t.settings.sections.menuBar.description}</p>
              </div>

              <div className="settings-grid">
                <label className="field">
                  <span>{t.settings.sections.menuBar.showLogo}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">{t.settings.sections.menuBar.showLogoNote}</span>
                    <input
                      checked={draftSync.showMenuBarLogo}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                showMenuBarLogo: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.showApiValue}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">{t.settings.sections.menuBar.showApiValueNote}</span>
                    <input
                      checked={draftSync.showMenuBarDailyApiValue}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                showMenuBarDailyApiValue: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.showLiveQuotaMetric}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">
                      {t.settings.sections.menuBar.showLiveQuotaMetricNote}
                    </span>
                    <input
                      checked={draftSync.showMenuBarLiveQuotaPercent}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                showMenuBarLiveQuotaPercent: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>

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
                  <span className="field-note">{t.settings.sections.menuBar.rangeNote}</span>
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
                  <span className="field-note">{t.settings.sections.menuBar.liveMetricNote}</span>
                </label>

                <label className="field field-span-2">
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
                  <span className="field-note">{t.settings.sections.menuBar.quotaSourceNote}</span>
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.speedShowEmoji}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">{t.settings.sections.menuBar.speedShowEmojiNote}</span>
                    <input
                      disabled={
                        !draftSync.showMenuBarLiveQuotaPercent ||
                        draftSync.menuBarLiveQuotaMetric !== 'suggested_usage_speed'
                      }
                      checked={draftSync.menuBarSpeedShowEmoji}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                menuBarSpeedShowEmoji: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>

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
                  <span className="field-note">{t.settings.sections.menuBar.speedThresholdNote}</span>
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

                <label className="field field-span-2">
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
                  <span className="field-note">{t.settings.sections.menuBar.speedEmojiNote}</span>
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.popupEnabled}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">{t.settings.sections.menuBar.popupEnabledNote}</span>
                    <input
                      checked={draftSync.menuBarPopupEnabled}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                menuBarPopupEnabled: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>

                <label className="field">
                  <span>{t.settings.sections.menuBar.popupShowResetTimeline}</span>
                  <div className="field-checkbox-row">
                    <span className="field-note">{t.settings.sections.menuBar.popupModulesNote}</span>
                    <input
                      checked={draftSync.menuBarPopupShowResetTimeline}
                      onChange={(event) =>
                        setDraftSync((current) =>
                          current
                            ? {
                                ...current,
                                menuBarPopupShowResetTimeline: event.target.checked,
                              }
                            : current,
                        )
                      }
                      type="checkbox"
                    />
                  </div>
                </label>

                <div className="field field-span-2 popup-module-editor">
                  <span>{t.settings.sections.menuBar.popupModules}</span>
                  <span className="field-note">{t.settings.sections.menuBar.popupModulesNote}</span>
                  <div className="popup-module-list">
                    {popupModuleOptions.map((option) => {
                      const enabled = draftSync.menuBarPopupModules.includes(option.value)
                      const index = draftSync.menuBarPopupModules.indexOf(option.value)
                      return (
                        <div className="popup-module-item" key={option.value}>
                          <label className="popup-module-toggle">
                            <input
                              checked={enabled}
                              onChange={(event) => togglePopupModule(option.value, event.target.checked)}
                              type="checkbox"
                            />
                            <span>{option.label}</span>
                          </label>
                          <div className="popup-module-actions">
                            <button
                              className="ghost-button"
                              disabled={!enabled || index <= 0}
                              onClick={() => movePopupModule(option.value, -1)}
                              type="button"
                            >
                              {t.settings.sections.menuBar.moveUp}
                            </button>
                            <button
                              className="ghost-button"
                              disabled={!enabled || index < 0 || index >= draftSync.menuBarPopupModules.length - 1}
                              onClick={() => movePopupModule(option.value, 1)}
                              type="button"
                            >
                              {t.settings.sections.menuBar.moveDown}
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
                <p>{t.settings.sections.subscription.description}</p>
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
                  <span className="field-note">{t.settings.sections.subscription.currencyNote}</span>
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
                  <span className="field-note">
                    {t.settings.sections.subscription.billingAnchorDayNote}
                  </span>
                </label>
              </div>
            </section>

            {liveRateLimits ? (
              <section className="settings-section">
                <div className="settings-section-head">
                  <p className="eyebrow">{t.settings.sections.liveQuota.eyebrow}</p>
                  <h4>{t.settings.sections.liveQuota.title}</h4>
                  <p>{t.settings.sections.liveQuota.description}</p>
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
