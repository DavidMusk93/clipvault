// ClipVault Service Worker — app-shell cache to kill reload white screen.
//
// Strategies:
//   HTML navigations      -> stale-while-revalidate (instant paint, background refresh)
//   /assets/*             -> stale-while-revalidate (cv= params bust on deploy)
//   3rd-party CDN libs    -> stale-while-revalidate (marked/purify/beautify/fonts)
//   /api/*, /s/*, /mcp, /trae, /grafana, /ostore, /mem -> network only (never intercept)
//
// Deploy semantics: after a deploy the first reload may render one generation
// stale, refreshed in background; the NEXT reload is fully fresh. Asset refs
// are query-versioned (cv=), so shell/asset generations stay consistent.

const VERSION = 'v1';
const SHELL = `cv-shell-${VERSION}`;
const STATIC = `cv-static-${VERSION}`;

self.addEventListener('install', (e) => {
  e.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keep = new Set([SHELL, STATIC]);
    for (const key of await caches.keys()) {
      if (!keep.has(key)) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

const isNav = (req) =>
  req.mode === 'navigate' ||
  (req.headers.get('accept') || '').includes('text/html');

const BYPASS_PATHS = [
  '/api/', '/s/', '/mcp', '/trae', '/grafana', '/ostore', '/mem', '/sw.js',
];

const CDN_HOST = /(^|\.)fonts\.(googleapis|gstatic)\.com$|(^|\.)cdnjs\.cloudflare\.com$|(^|\.)cdn\.jsdelivr\.net$/;

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  if (url.origin === self.location.origin) {
    if (BYPASS_PATHS.some((p) => url.pathname.startsWith(p) || url.pathname === p)) return;
    if (isNav(req)) {
      e.respondWith(staleWhileRevalidate(SHELL, req));
      return;
    }
    if (url.pathname.startsWith('/assets/')) {
      e.respondWith(staleWhileRevalidate(STATIC, req));
      return;
    }
    return; // other same-origin: network
  }

  if (CDN_HOST.test(url.hostname)) {
    e.respondWith(staleWhileRevalidate(STATIC, req));
  }
  // other origins: network only
});

// Serve from cache immediately (if present), refresh cache in background.
async function staleWhileRevalidate(cacheName, req) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(req, { ignoreSearch: false });
  const refresh = fetch(req)
    .then((res) => {
      // Never cache auth redirect chains (302 -> login): redirected responses
      // would poison the shell cache with the login page.
      if (res && !res.redirected && (res.ok || res.type === 'opaque')) {
        cache.put(req, res.clone());
      }
      return res;
    })
    .catch(() => null);
  if (cached) {
    refresh.catch(() => {}); // background update, never blocks paint
    return cached;
  }
  const net = await refresh;
  if (net) return net.clone();
  return new Response('offline', { status: 504, statusText: 'offline' });
}
