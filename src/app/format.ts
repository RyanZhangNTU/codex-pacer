import type { AppLanguage } from './i18n'
import { getDateTimeLocale, getNumberLocale, getRelativeTimeLocale } from './i18n'

export function formatUsd(value: number, language: AppLanguage = 'zh-CN') {
  return new Intl.NumberFormat(getNumberLocale(language), {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: value >= 100 ? 0 : 2,
  }).format(value)
}

export function formatPercent(value: number, language: AppLanguage = 'zh-CN') {
  return new Intl.NumberFormat(getNumberLocale(language), {
    style: 'percent',
    maximumFractionDigits: 0,
  }).format(value)
}

export function formatTokenCount(value: number, language: AppLanguage = 'zh-CN') {
  return new Intl.NumberFormat(getNumberLocale(language), {
    notation: value >= 100_000 ? 'compact' : 'standard',
    maximumFractionDigits: value >= 100_000 ? 1 : 0,
  }).format(value)
}

export function formatDateTime(value: string | null, language: AppLanguage = 'zh-CN') {
  if (!value) return 'n/a'
  return new Intl.DateTimeFormat(getDateTimeLocale(language), {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value))
}

export function formatCompactDateTime(value: string | null, language: AppLanguage = 'zh-CN') {
  if (!value) return 'n/a'
  return new Intl.DateTimeFormat(getDateTimeLocale(language), {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(value))
}

export function formatShortDate(value: string | null, language: AppLanguage = 'zh-CN') {
  if (!value) return 'n/a'
  return new Intl.DateTimeFormat(getDateTimeLocale(language), {
    month: 'short',
    day: 'numeric',
  }).format(new Date(value))
}

export function formatRelative(value: string | null, language: AppLanguage = 'zh-CN') {
  if (!value) return 'n/a'
  const diffMs = new Date(value).getTime() - Date.now()
  const diffMinutes = Math.round(diffMs / 60000)
  const formatter = new Intl.RelativeTimeFormat(getRelativeTimeLocale(language), {
    numeric: 'auto',
  })
  if (Math.abs(diffMinutes) < 60) return formatter.format(diffMinutes, 'minute')
  const diffHours = Math.round(diffMinutes / 60)
  if (Math.abs(diffHours) < 48) return formatter.format(diffHours, 'hour')
  const diffDays = Math.round(diffHours / 24)
  return formatter.format(diffDays, 'day')
}

export function formatDurationBetween(
  startValue: string | null,
  endValue: string | null,
  language: AppLanguage = 'zh-CN',
) {
  if (!startValue || !endValue) return 'n/a'
  const totalMinutes = Math.max(
    0,
    Math.round((new Date(endValue).getTime() - new Date(startValue).getTime()) / 60000),
  )
  const days = Math.floor(totalMinutes / (24 * 60))
  const hours = Math.floor((totalMinutes % (24 * 60)) / 60)
  const minutes = totalMinutes % 60

  if (language === 'en') {
    if (days > 0) return `${days}d ${hours}h`
    return `${hours}h ${minutes}m`
  }

  if (days > 0) return `${days}天${hours}小时`
  return `${hours}小时${minutes}分钟`
}

export function formatRemainingDuration(endValue: string | null, language: AppLanguage = 'zh-CN') {
  if (!endValue) return 'n/a'
  return formatDurationBetween(new Date().toISOString(), endValue, language)
}

export function todayInputValue() {
  return new Date().toISOString().slice(0, 10)
}
