/* Räumliche Navigation für die LG-Fernbedienung (Pfeiltasten + Magic-Remote-Zeiger) */
var Nav = (function () {
  'use strict';

  var KEY = {
    LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, ENTER: 13,
    BACK: 461, ESC: 27, BACKSPACE: 8,
    PLAY: 415, PAUSE: 19, PLAYPAUSE: 179, STOP: 413, FF: 417, RW: 412,
    NEXT: 176, PREV: 177,
    RED: 403, GREEN: 404, YELLOW: 405, BLUE: 406,
    CH_UP: 33, CH_DOWN: 34, INFO: 457
  };

  var current = null;
  var scopeFn = function () { return document.body; };
  var handlers = []; // globale Tasten-Handler (Mediatasten etc.)
  var lastPointerFocus = 0;
  // Bildschirmtastatur von webOS: offen, solange ein Eingabefeld tippt. Meldet webOS sich nie (Browser),
  // zählt nur, ob ein Eingabefeld den Fokus hat.
  var kbKnown = false, kbOpen = false;
  document.addEventListener('keyboardStateChange', function (e) {
    kbKnown = true;
    kbOpen = !!(e.detail && e.detail.visibility);
  });
  function typing() {
    var a = document.activeElement;
    var inInput = !!a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA');
    return inInput && (kbKnown ? kbOpen : true);
  }

  function isVisible(el) {
    if (!el.offsetParent && getComputedStyle(el).position !== 'fixed') return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function focusables() {
    var scope = scopeFn();
    if (!scope) return [];
    return U.$$('.focusable', scope).filter(function (el) { return !el.disabled && isVisible(el); });
  }

  function regionOf(el) { var r = el && el.closest ? el.closest('[data-region]') : null; return r ? r.getAttribute('data-region') : null; }

  function containerOf(el) { return el && el.closest ? el.closest('.nav-container') : null; }

  function scrollIntoView(el) {
    var node = el.parentElement;
    while (node && node !== document.body) {
      var cs = getComputedStyle(node);
      var r = el.getBoundingClientRect(), pr = node.getBoundingClientRect();
      // Rects sind bei skalierter Bühne (Browser-Test) verkleinert, scrollTop nicht
      var k = node.offsetHeight ? pr.height / node.offsetHeight : 1;
      if (/(auto|scroll)/.test(cs.overflowY) && node.scrollHeight > node.clientHeight) {
        var m = Math.min(160, node.clientHeight / 4) * k;
        if (r.top < pr.top + m) node.scrollTop -= (pr.top + m - r.top) / k;
        else if (r.bottom > pr.bottom - m) node.scrollTop += (r.bottom - (pr.bottom - m)) / k;
      }
      if (/(auto|scroll)/.test(cs.overflowX) && node.scrollWidth > node.clientWidth) {
        var mx = Math.min(200, node.clientWidth / 4) * k;
        r = el.getBoundingClientRect();
        if (r.left < pr.left + mx) node.scrollLeft -= (pr.left + mx - r.left) / k;
        else if (r.right > pr.right - mx) node.scrollLeft += (r.right - (pr.right - mx)) / k;
      }
      node = node.parentElement;
    }
  }

  function focus(el, opts) {
    if (!el) return;
    if (current && current !== el) current.classList.remove('focused');
    current = el;
    el.classList.add('focused');
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      if (!(opts && opts.noInputFocus)) { try { el.focus({ preventScroll: true }); } catch (e) { el.focus(); } }
    } else if (document.activeElement && document.activeElement !== document.body && document.activeElement.blur) {
      document.activeElement.blur();
    }
    var c = containerOf(el);
    if (c) c._lastFocused = el;
    if (!(opts && opts.noScroll)) scrollIntoView(el);
    el.dispatchEvent(new CustomEvent('navfocus', { bubbles: true }));
  }

  function rectOf(el) { return el.getBoundingClientRect(); }

  function best(dir, from, list) {
    var r = rectOf(from);
    var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    var bestEl = null, bestScore = Infinity;
    list.forEach(function (el) {
      if (el === from) return;
      var c = rectOf(el);
      var ccx = c.left + c.width / 2, ccy = c.top + c.height / 2;
      var primary, secondary, overlap;
      if (dir === 'right') {
        if (c.left < r.right - 4 && ccx <= cx + 1) return;
        if (ccx <= cx) return;
        primary = Math.max(0, c.left - r.right);
        overlap = Math.min(r.bottom, c.bottom) - Math.max(r.top, c.top);
        secondary = overlap > 0 ? 0 : Math.abs(ccy - cy);
      } else if (dir === 'left') {
        if (c.right > r.left + 4 && ccx >= cx - 1) return;
        if (ccx >= cx) return;
        primary = Math.max(0, r.left - c.right);
        overlap = Math.min(r.bottom, c.bottom) - Math.max(r.top, c.top);
        secondary = overlap > 0 ? 0 : Math.abs(ccy - cy);
      } else if (dir === 'down') {
        if (ccy <= cy + 1 || c.top < r.bottom - 4 - Math.min(r.height, c.height) / 2) return;
        primary = Math.max(0, c.top - r.bottom);
        secondary = Math.abs(ccx - cx);
        if (c.left <= cx && c.right >= cx) secondary = 0;
      } else {
        if (ccy >= cy - 1 || c.bottom > r.top + 4 + Math.min(r.height, c.height) / 2) return;
        primary = Math.max(0, r.top - c.bottom);
        secondary = Math.abs(ccx - cx);
        if (c.left <= cx && c.right >= cx) secondary = 0;
      }
      var score = primary + secondary * 3;
      if (score < bestScore) { bestScore = score; bestEl = el; }
    });
    return bestEl;
  }

  function move(dir) {
    var list = focusables();
    if (!list.length) return false;
    if (!current || list.indexOf(current) < 0) { focus(preferred(list)); return true; }
    // Reihenfolge: erst im eigenen Bereich (data-region) bleiben, dann bei ▲▼ den Mini-Player
    // (.nav-fallback) als Ausweichziel, erst danach alles andere (z. B. Seitenleiste)
    var isFb = function (el) { return el.classList.contains('nav-fallback'); };
    var region = regionOf(current);
    var tiers = [list.filter(function (el) { return regionOf(el) === region; })];
    if (dir === 'up' || dir === 'down') tiers.push(list.filter(isFb));
    else tiers.push(list.filter(function (el) { return !isFb(el); }));
    tiers.push(list);
    var target = null;
    for (var t = 0; t < tiers.length && !target; t++) target = best(dir, current, tiers[t]);
    if (!target) {
      current.dispatchEvent(new CustomEvent('navedge', { bubbles: true, detail: dir }));
      return false;
    }
    // Beim Wechsel in einen anderen Container: zuletzt fokussiertes Element dort wiederherstellen
    var tc = containerOf(target);
    if (tc && tc !== containerOf(current) && tc._lastFocused && tc.contains(tc._lastFocused) &&
        list.indexOf(tc._lastFocused) >= 0 && !tc.hasAttribute('data-no-remember')) {
      target = tc._lastFocused;
    }
    focus(target);
    return true;
  }

  function preferred(list) {
    var scope = scopeFn();
    var pref = scope && U.$('.focusable[data-autofocus]', scope);
    if (pref && list.indexOf(pref) >= 0) return pref;
    return list[0];
  }

  function focusFirst(root) {
    var list = focusables();
    if (root) {
      var inRoot = list.filter(function (el) { return root.contains(el); });
      var pref = U.$('.focusable[data-autofocus]', root);
      if (pref && inRoot.indexOf(pref) >= 0) return focus(pref);
      if (inRoot.length) return focus(inRoot[0]);
    }
    if (list.length) focus(preferred(list));
  }

  function onKey(fn) { handlers.push(fn); }

  function dirOf(code) {
    return code === KEY.LEFT ? 'left' : code === KEY.RIGHT ? 'right' : code === KEY.UP ? 'up' : code === KEY.DOWN ? 'down' : null;
  }

  document.addEventListener('keydown', function (e) {
    var code = e.keyCode;
    // Globale Handler zuerst (Bildschirmschoner, Mediatasten, Zurück)
    for (var i = handlers.length - 1; i >= 0; i--) {
      if (handlers[i](e, code) === true) { e.preventDefault(); return; }
    }
    var dir = dirOf(code);
    var inInput = current && (current.tagName === 'INPUT') && document.activeElement === current;
    if (dir) {
      // Die Pfeiltasten gehören dann der Bildschirmtastatur – nicht aus dem Feld wegspringen
      if (inInput && kbKnown && kbOpen) return;
      if (inInput && (dir === 'left' || dir === 'right')) {
        var pos = current.selectionStart, len = current.value.length;
        if ((dir === 'left' && pos > 0) || (dir === 'right' && pos < len)) return; // Cursor bewegen
      }
      e.preventDefault();
      move(dir);
      return;
    }
    if (code === KEY.ENTER) {
      if (!current) return;
      if (current.tagName === 'INPUT') {
        if (document.activeElement !== current) { e.preventDefault(); current.focus(); }
        else current.dispatchEvent(new CustomEvent('submit', { bubbles: true }));
        return;
      }
      e.preventDefault();
      current.click();
      return;
    }
    if (code === KEY.YELLOW || code === KEY.INFO) {
      if (current) { e.preventDefault(); current.dispatchEvent(new CustomEvent('options', { bubbles: true })); }
    }
  }, true);

  // Magic-Remote-Zeiger: Hover setzt den Fokus – außer beim Tippen. Sonst nimmt schon das Überfahren
  // eines Knopfs auf dem Weg zur Bildschirmtastatur dem Eingabefeld den Fokus, und die Tastatur geht zu.
  document.addEventListener('mouseover', function (e) {
    var el = e.target.closest && e.target.closest('.focusable');
    if (!el || el === current) return;
    var scope = scopeFn();
    if (scope && !scope.contains(el)) return;
    if (typing()) return;
    lastPointerFocus = Date.now();
    focus(el, { noScroll: true, noInputFocus: true });
  });

  // Beim Tippen bekommt erst ein echter Klick mit dem Zeiger den Fokus
  document.addEventListener('mousedown', function (e) {
    var el = e.target.closest && e.target.closest('.focusable');
    if (el && el !== current && typing()) focus(el, { noScroll: true, noInputFocus: true });
  }, true);

  return {
    KEY: KEY,
    focus: focus,
    move: move,
    focusFirst: focusFirst,
    onKey: onKey,
    current: function () { return current; },
    setScope: function (fn) { scopeFn = fn; },
    pointerActive: function () { return Date.now() - lastPointerFocus < 1500; }
  };
})();
