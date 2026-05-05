function parseDateInput(value: string) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!match) return null

  const year = Number(match[1])
  const month = Number(match[2])
  const day = Number(match[3])
  if (month < 1 || month > 12) return null

  const lastDay = new Date(year, month, 0).getDate()
  if (day < 1 || day > lastDay) return null

  return { year, month, day }
}

function formatDateInput(year: number, month: number, day: number) {
  return [
    String(year).padStart(4, '0'),
    String(month).padStart(2, '0'),
    String(day).padStart(2, '0'),
  ].join('-')
}

export function todayLocalInputValue(date = new Date()) {
  return formatDateInput(date.getFullYear(), date.getMonth() + 1, date.getDate())
}

export function addOneCalendarMonth(value: string) {
  const parsed = parseDateInput(value)
  if (!parsed) return value

  const targetMonthIndex = parsed.month
  const targetYear = parsed.year + Math.floor(targetMonthIndex / 12)
  const targetMonth = (targetMonthIndex % 12) + 1
  const targetLastDay = new Date(targetYear, targetMonth, 0).getDate()
  return formatDateInput(targetYear, targetMonth, Math.min(parsed.day, targetLastDay))
}
