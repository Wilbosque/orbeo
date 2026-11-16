// Orbeo · service worker: recebe as notificações e abre a tela certa ao tocar
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()))

self.addEventListener('push', e => {
  let d = {}
  try { d = e.data ? e.data.json() : {} } catch { d = { body: e.data && e.data.text() } }
  const base = self.registration.scope
  e.waitUntil(self.registration.showNotification(d.title || 'Orbeo', {
    body: d.body || '',
    icon: base + 'icone-192.png',
    badge: base + 'icone-192.png',
    tag: d.tag || undefined,
    renotify: Boolean(d.tag),
    data: { url: base + (d.url || '#/') },
  }))
})

self.addEventListener('notificationclick', e => {
  e.notification.close()
  const url = (e.notification.data && e.notification.data.url) || self.registration.scope
  e.waitUntil((async () => {
    const abertas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const c of abertas) {
      if (c.url.startsWith(self.registration.scope)) { await c.focus(); return c.navigate(url) }
    }
    return self.clients.openWindow(url)
  })())
})
