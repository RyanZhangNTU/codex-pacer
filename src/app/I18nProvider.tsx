import { useEffect, useState, type ReactNode } from 'react'

import {
  getTranslations,
  LANGUAGE_STORAGE_KEY,
  readStoredLanguage,
  SUPPORTED_LANGUAGES,
  type I18nShape,
} from './i18n'
import { I18nContext } from './I18nContext'

export function I18nProvider({ children }: { children: ReactNode }) {
  const [language, setLanguage] = useState(readStoredLanguage)

  useEffect(() => {
    window.localStorage.setItem(LANGUAGE_STORAGE_KEY, language)
  }, [language])

  const value: I18nShape = {
    language,
    languages: SUPPORTED_LANGUAGES,
    setLanguage,
    t: getTranslations(language),
  }

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}
