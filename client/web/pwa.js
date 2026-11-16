'use strict';
window.addEventListener('flutter-first-frame', () => {
  document.getElementById('loading')?.remove();
});
setTimeout(() => {
  const message = document.getElementById('loading-message');
  if (message) {
    message.textContent = 'Загрузка занимает больше времени. Проверьте подключение и повторите попытку.';
    document.getElementById('retry').style.display = 'inline-block';
  }
}, 30000);
// The build script produces a versioned, static-only service worker. Never
// register a legacy Flutter worker or cache any relay/auth responses.
if ('serviceWorker' in navigator && window.isSecureContext) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('shade-sw.js', { scope: './', updateViaCache: 'none' })
      .catch(() => { /* Online shell remains usable if offline storage is denied. */ });
  });
}
