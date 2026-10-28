/* Hilfsfunktionen. Zielplattform: webOS 5 (Chromium 68) -> kein ?. / ?? / Array.flat */
var APP_VERSION = '1.7.0'; // muss zu appinfo.json passen (build_ipk.py prüft das)
var U = (function () {
  'use strict';

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  // h('div.cls#id', {attr}, children...)
  function h(tag, attrs) {
    var parts = tag.split(/(?=[.#])/);
    var node = document.createElement(parts[0] || 'div');
    for (var i = 1; i < parts.length; i++) {
      if (parts[i][0] === '.') node.classList.add(parts[i].slice(1));
      else node.id = parts[i].slice(1);
    }
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v == null || v === false) return;
        if (k === 'text') node.textContent = v;
        else if (k === 'html') node.innerHTML = v;
        else if (k.indexOf('on') === 0) node.addEventListener(k.slice(2), v);
        else if (k === 'dataset') Object.keys(v).forEach(function (d) { node.dataset[d] = v[d]; });
        else node.setAttribute(k, v === true ? '' : v);
      });
    }
    for (var j = 2; j < arguments.length; j++) append(node, arguments[j]);
    return node;
  }
  function append(node, c) {
    if (c == null || c === false) return;
    if (Array.isArray(c)) { c.forEach(function (x) { append(node, x); }); return; }
    node.appendChild(typeof c === 'object' ? c : document.createTextNode(String(c)));
  }

  function fmtTime(sec) {
    sec = Math.max(0, Math.floor(sec || 0));
    var hh = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    var ss = (s < 10 ? '0' : '') + s;
    if (hh) return hh + ':' + (m < 10 ? '0' : '') + m + ':' + ss;
    return m + ':' + ss;
  }

  function fmtDuration(sec) {
    var m = Math.round((sec || 0) / 60);
    if (m < 60) return T('{n} Min.', { n: m });
    return T('{h} Std. {m} Min.', { h: Math.floor(m / 60), m: m % 60 });
  }

  var store = {
    get: function (k, def) {
      try { var v = localStorage.getItem('nd.' + k); return v == null ? def : JSON.parse(v); } catch (e) { return def; }
    },
    set: function (k, v) { try { localStorage.setItem('nd.' + k, JSON.stringify(v)); } catch (e) { /* voll/gesperrt */ } },
    del: function (k) { try { localStorage.removeItem('nd.' + k); } catch (e) { /* egal */ } }
  };

  // Speicher pro Benutzerkonto (Warteschlange, Einstellungen, letzte Suche …)
  var ns = 'none';
  var ustore = {
    get: function (k, def) { return store.get('u.' + ns + '.' + k, def); },
    set: function (k, v) { store.set('u.' + ns + '.' + k, v); },
    setNs: function (id) { ns = id; },
    peek: function (id, k, def) { return store.get('u.' + id + '.' + k, def); },
    clear: function (id) {
      try {
        var prefix = 'nd.u.' + id + '.', keys = [];
        for (var i = 0; i < localStorage.length; i++) if (localStorage.key(i).indexOf(prefix) === 0) keys.push(localStorage.key(i));
        keys.forEach(function (k) { localStorage.removeItem(k); });
      } catch (e) { /* egal */ }
    }
  };

  function debounce(fn, ms) {
    var t;
    return function () {
      var a = arguments, self = this;
      clearTimeout(t);
      t = setTimeout(function () { fn.apply(self, a); }, ms);
    };
  }

  function shuffle(arr) {
    var a = arr.slice();
    for (var i = a.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1)), t = a[i];
      a[i] = a[j]; a[j] = t;
    }
    return a;
  }

  function asArray(x) { return x == null ? [] : (Array.isArray(x) ? x : [x]); }

  var toastTimer;
  function toast(msg, ms) {
    var t = $('#toast');
    t.textContent = msg;
    t.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.classList.add('hidden'); }, ms || 2500);
  }

  return {
    $: $, $$: $$, esc: esc, h: h, fmtTime: fmtTime, fmtDuration: fmtDuration, store: store, ustore: ustore,
    debounce: debounce, shuffle: shuffle, asArray: asArray, toast: toast
  };
})();
