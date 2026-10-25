// Prüft, ob jede Sprachdatei alle Texte der App übersetzt.
// Nutzung: node tools/i18n_check.js          -> Bericht, Exit-Code 1 bei Lücken
//          node tools/i18n_check.js --keys   -> alle Texte (deutsch) als JSON-Liste
const fs = require('fs'), path = require('path');
const APP = path.join(__dirname, '..', 'app');

// --- Texte aus dem Code sammeln
const keys = new Set();
const str = "'((?:[^'\\\\]|\\\\.)*)'";
for (const f of fs.readdirSync(path.join(APP, 'js')).filter(f => f.endsWith('.js') && f !== 'i18n.js')) {
  const src = fs.readFileSync(path.join(APP, 'js', f), 'utf8');
  for (const m of src.matchAll(new RegExp('\\bT\\(\\s*' + str, 'g'))) keys.add(m[1]);
  for (const m of src.matchAll(new RegExp('\\bT\\(\\s*[^\'()]+\\?\\s*' + str + '\\s*:\\s*' + str, 'g'))) { keys.add(m[1]); keys.add(m[2]); }
  for (const m of src.matchAll(new RegExp('\\bT\\.n\\([^,]+,\\s*' + str + ',\\s*' + str, 'g'))) { keys.add(m[1]); keys.add(m[2]); }
}
const html = fs.readFileSync(path.join(APP, 'index.html'), 'utf8');
for (const m of html.matchAll(/<(\w+)[^>]*\sdata-i18n[^>]*>([^<]+)</g)) keys.add(m[2].trim());
for (const m of html.matchAll(/\stitle="([^"]+)"/g)) keys.add(m[1]);
const all = [...keys].map(k => k.replace(/\\'/g, "'")).sort();

if (process.argv.includes('--keys')) { console.log(JSON.stringify(all, null, 1)); process.exit(0); }

// --- Sprachdateien laden
const dicts = {};
global.I18N = { add: (code, d) => { dicts[code] = d; } };
const langDir = path.join(APP, 'js', 'lang');
for (const f of fs.readdirSync(langDir).filter(f => f.endsWith('.js'))) require(path.join(langDir, f));

let bad = 0;
for (const [code, d] of Object.entries(dicts)) {
  const missing = all.filter(k => !(k in d));
  const unused = Object.keys(d).filter(k => !keys.has(k) && !keys.has(k.replace(/'/g, "\\'")));
  const brokenParams = Object.keys(d).filter(k => {
    const p = s => (s.match(/\{\w+\}/g) || []).sort().join();
    return k in d && p(k) !== p(d[k]);
  });
  const ok = !missing.length && !brokenParams.length;
  if (!ok) bad++;
  console.log(`${ok ? '✓' : '✗'} ${code}: ${Object.keys(d).length}/${all.length} Texte` +
    (missing.length ? `, fehlt: ${missing.length}` : '') + (brokenParams.length ? `, Platzhalter falsch: ${brokenParams.length}` : '') +
    (unused.length ? ` (${unused.length} unbenutzt)` : ''));
  missing.slice(0, 5).forEach(k => console.log('    fehlt: ' + k));
  brokenParams.slice(0, 5).forEach(k => console.log('    Platzhalter: ' + k + ' -> ' + d[k]));
}
console.log(`${all.length} Texte, ${Object.keys(dicts).length} Sprachen + Deutsch`);
process.exit(bad ? 1 : 0);
