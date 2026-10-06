// Sumak Ops — push notifications + network-first app shell.
// Cache name bumps on each change so a deploy does not keep serving an old index.html.
const SHELL_CACHE = 'sumak-ops-shell-v2';

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== SHELL_CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET' || req.mode !== 'navigate') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith((async () => {
    try {
      const fresh = await fetch(req);
      if (fresh && fresh.ok) {
        const cache = await caches.open(SHELL_CACHE);
        cache.put(req, fresh.clone());
      }
      return fresh;
    } catch (err) {
      const cached = await caches.match(req);
      if (cached) return cached;
      const shell = await caches.match('/index.html');
      if (shell) return shell;
      throw err;
    }
  })());
});

self.addEventListener('push', (event) => {
  let data = { title: 'Sumak Ops', body: 'You have a new update.', url: '/' };
  try {
    if (event.data) data = { ...data, ...event.data.json() };
  } catch (e) {}
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: 'https://cdn.jsdelivr.net/gh/lucide-icons/lucide@main/icons/leaf.svg',
      badge: 'https://cdn.jsdelivr.net/gh/lucide-icons/lucide@main/icons/leaf.svg',
      data: { url: data.url || '/', linkType: data.linkType || null, linkId: data.linkId || null },
      vibrate: [100, 50, 100]
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const d = event.notification.data || {};
  const targetUrl = d.url || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ('focus' in client) {
          // App already open — tell it where to go
          client.postMessage({ type: 'notification-click', linkType: d.linkType, linkId: d.linkId });
          return client.focus();
        }
      }
      // App was closed — open it, passing the destination in the URL
      let openUrl = targetUrl;
      if (d.linkType) {
        openUrl = '/?notif=' + encodeURIComponent(d.linkType) + (d.linkId ? '&id=' + encodeURIComponent(d.linkId) : '');
      }
      if (self.clients.openWindow) return self.clients.openWindow(openUrl);
    })
  );
});
