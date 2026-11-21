/* GBoard (Samsung) reports phantom visualViewport states during its
   open/minimize/close transitions — a shrunken height sometimes persists
   after the keyboard is gone, and the Flutter view freezes mid-layout
   (composer stranded near the header, message list hidden). The keyboard
   occupies real space only while an editable field keeps focus AND the
   viewport actually shrank; every other state reports the full layout
   viewport so the engine's metrics never stick to a phantom value. Must
   run before the Flutter engine captures window.visualViewport.
   External file (not inline): CSP script-src 'self' blocks inline scripts. */
(function () {
  // Fail-safe: нераспознанная платформа/ошибка → шим не активируется,
  // остаётся исходный visualViewport (старое поведение, ничего не ломается).
  try {
    // GBoard phantom visualViewport states — Android-specific (Samsung Internet /
    // GBoard). Desktop engines (webkit QA included) report sane viewports; the
    // proxy there only destabilises layout, so the shim installs on Android only.
    if (!/Android/i.test(navigator.userAgent || '')) {
      window.__shadeShim = 'inactive-non-android';
      return;
    }
    const real = window.visualViewport;
    if (!real) { window.__shadeShim = 'inactive-no-viewport'; return; }
  const typing = () => {
    const el = document.activeElement;
    return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
  };
  const kbOpen = () => typing() && real.height < window.innerHeight - 80;
  const view = {
    get height() { return kbOpen() ? real.height : window.innerHeight; },
    get width() { return real.width; },
    get offsetTop() { return kbOpen() ? real.offsetTop : 0; },
    get offsetLeft() { return kbOpen() ? real.offsetLeft : 0; },
    get scale() { return real.scale; },
    addEventListener: (...a) => real.addEventListener(...a),
    removeEventListener: (...a) => real.removeEventListener(...a),
    dispatchEvent: (...a) => real.dispatchEvent(...a),
  };
  Object.defineProperty(window, 'visualViewport', { configurable: true, get: () => view });
  window.__shadeShim = 'active-android';
  } catch (e) { window.__shadeShim = 'error-original-viewport'; }
})();