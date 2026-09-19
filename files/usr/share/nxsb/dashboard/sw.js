// nxsb: kill-switch service worker. The app no longer registers one (LAN-served, no offline mode);
// this replaces any worker a browser installed earlier: clears its caches and unregisters itself.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) { return Promise.all(ks.map(function (k) { return caches.delete(k); })); })
    .then(function () { return self.registration.unregister(); }));
});
