// Holt die App aus tv/ (dieselbe Oberfläche wie am TV) und den Dienst fürs iPhone, und übernimmt die Version.
// Läuft vor "npm start" und "npm run dist" – die Kopien in web/, service/ und build/ gehören nicht ins Repo.
const fs = require('fs'), path = require('path');
const DESK = path.join(__dirname, '..'), TV = path.join(DESK, '..', 'tv');

function copy(from, to) {
  fs.rmSync(to, { recursive: true, force: true });
  fs.cpSync(from, to, { recursive: true });
}
copy(path.join(TV, 'app'), path.join(DESK, 'web'));

// Am PC strenger als am TV: Skripte nur aus der App selbst. Selbst ein eingeschleuster Text könnte so nichts ausführen.
// Bilder, Musik und Server-Anfragen gehen weiter an jeden Navidrome-Server und jeden Radiosender.
const CSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src * data: blob:; media-src * blob:; " +
  "connect-src *; font-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'";
const indexFile = path.join(DESK, 'web', 'index.html');
const index = fs.readFileSync(indexFile, 'utf8');
if (!index.includes('<meta charset="utf-8">')) throw new Error('index.html: <meta charset> nicht gefunden');
fs.writeFileSync(indexFile, index.replace('<meta charset="utf-8">', '<meta charset="utf-8">\n  <meta http-equiv="Content-Security-Policy" content="' + CSP + '">'));
fs.mkdirSync(path.join(DESK, 'service'), { recursive: true });
for (const f of ['service.js', 'package.json']) fs.copyFileSync(path.join(TV, 'service', f), path.join(DESK, 'service', f));
fs.mkdirSync(path.join(DESK, 'build'), { recursive: true });
fs.copyFileSync(path.join(DESK, '..', 'assets', 'icon-512.png'), path.join(DESK, 'build', 'icon.png'));

// Eine Version für TV und Windows: die aus tv/app/appinfo.json
const version = JSON.parse(fs.readFileSync(path.join(TV, 'app', 'appinfo.json'), 'utf8')).version;
const pkgFile = path.join(DESK, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgFile, 'utf8'));
if (pkg.version !== version) {
  pkg.version = version;
  fs.writeFileSync(pkgFile, JSON.stringify(pkg, null, 2) + '\n');
  console.log('Version ' + version + ' übernommen');
}
