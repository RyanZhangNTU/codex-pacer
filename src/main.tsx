import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.tsx'
import { I18nProvider } from './app/I18nProvider'
import { MenuBarPopup } from './menu-bar-popup/MenuBarPopup.tsx'
import './styles.css'

declare global {
  interface Window {
    __CODEX_COUNTER_SURFACE__?: 'menu-bar-popup'
  }
}

const searchParams = new URLSearchParams(window.location.search)
const isMenuBarPopupSurface =
  window.__CODEX_COUNTER_SURFACE__ === 'menu-bar-popup' ||
  searchParams.get('surface') === 'menu-bar-popup'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <I18nProvider>
      {isMenuBarPopupSurface ? <MenuBarPopup /> : <App />}
    </I18nProvider>
  </StrictMode>,
)
