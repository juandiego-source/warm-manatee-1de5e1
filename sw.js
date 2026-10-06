// Sumak Ops — push notification service worker
self.addEventListener('install', (event) => {
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
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
