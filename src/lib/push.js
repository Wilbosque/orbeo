// Notificações no celular: estado do aparelho, ativar e desativar
import * as api from '#backend'

const deB64u = s => {
  const t = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)
  return Uint8Array.from(atob(t), c => c.charCodeAt(0))
}
const ehIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
const instalado = () => window.matchMedia?.('(display-mode: standalone)').matches || window.navigator.standalone === true

export function registrarSW() {
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js', { scope: './' }).catch(() => {})
}

/** 'sem_suporte' | 'instalar' (iPhone fora da tela inicial) | 'bloqueado' | 'desligado' | 'ligado' */
export async function estadoPush() {
  if (ehIOS() && !instalado()) return 'instalar'
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return 'sem_suporte'
  if (Notification.permission === 'denied') return 'bloqueado'
  const reg = await navigator.serviceWorker.getRegistration('./')
  const sub = await reg?.pushManager.getSubscription()
  return sub ? 'ligado' : 'desligado'
}

export async function ativarPush() {
  // O pedido de permissão precisa nascer do toque no botão (exigência do iPhone)
  const perm = await Notification.requestPermission()
  if (perm !== 'granted') throw new Error(perm === 'denied'
    ? 'As notificações foram bloqueadas. Libere em Ajustes do aparelho → Notificações → Orbeo.'
    : 'Permissão não concedida.')
  const reg = await navigator.serviceWorker.register('./sw.js', { scope: './' })
  await navigator.serviceWorker.ready
  const chave = await api.pushChavePublica()
  let sub = await reg.pushManager.getSubscription()
  if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: deB64u(chave) })
  await api.salvarInscricaoPush(sub.toJSON(), aparelho())
}

export async function desativarPush() {
  const reg = await navigator.serviceWorker.getRegistration('./')
  const sub = await reg?.pushManager.getSubscription()
  if (sub) { await api.removerInscricaoPush(sub.endpoint).catch(() => {}); await sub.unsubscribe() }
}

function aparelho() {
  const u = navigator.userAgent
  if (/iphone/i.test(u)) return 'iPhone'
  if (/ipad/i.test(u)) return 'iPad'
  if (/android/i.test(u)) return 'Android'
  if (/mac/i.test(u)) return 'Mac'
  if (/windows/i.test(u)) return 'Windows'
  return 'Navegador'
}
