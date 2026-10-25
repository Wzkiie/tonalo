/* Übersetzungen. Deutsch ist die Ausgangssprache: T('Text') liefert die Übersetzung oder den deutschen Text.
   Sprachdateien in js/lang/*.js registrieren sich mit I18N.add(code, { 'Deutscher Text': 'Übersetzung' }). */
var I18N = (function () {
  'use strict';
  var LANGS = {
    de: 'Deutsch', en: 'English', es: 'Español', fr: 'Français', it: 'Italiano',
    pt: 'Português', nl: 'Nederlands', pl: 'Polski', tr: 'Türkçe'
  };
  var LOCALES = { de: 'de-DE', en: 'en-US', es: 'es-ES', fr: 'fr-FR', it: 'it-IT', pt: 'pt-BR', nl: 'nl-NL', pl: 'pl-PL', tr: 'tr-TR' };
  var dicts = {};
  var lang = 'de';

  // Gespeicherte Wahl, sonst Systemsprache des TVs, sonst Englisch
  function detect() {
    var chosen = U.store.get('lang', 'auto');
    if (chosen !== 'auto' && LANGS[chosen]) return chosen;
    var sys = (navigator.languages && navigator.languages[0]) || navigator.language || 'en';
    var code = String(sys).slice(0, 2).toLowerCase();
    return LANGS[code] ? code : 'en';
  }

  function fill(s, params) {
    if (!params) return s;
    return s.replace(/\{(\w+)\}/g, function (m, k) { return params[k] != null ? params[k] : m; });
  }

  // Schlüssel dürfen einen Kontext tragen ('Künstler|Einzahl'); ohne Übersetzung wird er abgeschnitten
  function T(s, params) {
    var d = dicts[lang];
    return fill((d && d[s]) || s.replace(/\|.*$/, ''), params);
  }
  // Einzahl/Mehrzahl: T.n(3, '{n} Album', '{n} Alben')
  T.n = function (n, one, other) { return T(n === 1 ? one : other, { n: n }); };

  lang = detect();
  document.documentElement.lang = lang;

  return {
    T: T,
    add: function (code, d) { dicts[code] = d; },
    lang: function () { return lang; },
    locale: function () { return LOCALES[lang] || 'en-US'; },
    choice: function () { return U.store.get('lang', 'auto'); },
    languages: LANGS,
    // Sprache wählen ('auto' = Systemsprache) – App lädt danach neu, damit alle Texte stimmen
    set: function (code) { U.store.set('lang', code); location.reload(); },
    // Texte im statischen HTML übersetzen
    applyStatic: function (root) {
      U.$$('[data-i18n]', root).forEach(function (el) { el.textContent = T(el.textContent.trim()); });
      U.$$('[title]', root).forEach(function (el) { el.title = T(el.title); });
    }
  };
})();
var T = I18N.T;
