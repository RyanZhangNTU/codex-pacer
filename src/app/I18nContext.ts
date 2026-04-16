import { createContext } from 'react'

import type { I18nShape } from './i18n'

export const I18nContext = createContext<I18nShape | null>(null)
