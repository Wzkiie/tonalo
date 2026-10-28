// Subsonic test server with made-up demo data (artists, albums, covers, lyrics are all invented).
// Serves the app as well, so no real Navidrome server is needed for development or screenshots.
// Usage: node tools/mock_server.js [port]  ->  http://localhost:4599  (server URL = same address, any login)
const http = require('http'), fs = require('fs'), path = require('path'), url = require('url');
const APP = path.join(__dirname, '..', 'app');
const PORT = +process.argv[2] || 4599;
// Pre-rendered PNG covers for the iPhone app, which can't show SVG (see ios/tools/render_covers.swift)
const COVERS = process.env.MOCK_COVERS;

// ---- deterministic random numbers, so the demo library looks the same every time
let seed = 7;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const pick = a => a[Math.floor(rnd() * a.length)];
const hash = s => { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; };
// well-mixed hash (FNV-1a + avalanche) so neighbouring albums get different cover styles
const mix = s => { let h = 2166136261; for (const c of s) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); } h ^= h >>> 13; h = Math.imul(h, 0x5bd1e995); h ^= h >>> 15; return h >>> 0; };

const ARTISTS = ['Nora Vale', 'Glass Harbor', 'Milo Ferro', 'The Quiet Arcade', 'Saffron Lane', 'Echo Park Social',
  'Lumen Drift', 'June & The Satellites', 'Tidewater', 'Cassia Moon', 'Static Orchard', 'Ravi Kade', 'Paper Lanterns',
  'Velvet Tram', 'Odessa Gray', 'North Hollow', 'Kaito Mori', 'Blue Atlas', 'Marlow Keys', 'Siren Coast'];
const GENRES = ['Indie', 'Electronic', 'Hip-Hop', 'Jazz', 'Ambient', 'Rock', 'Pop', 'Soul', 'Lo-Fi', 'Folk'];
const ADJ = ['Golden', 'Neon', 'Slow', 'Paper', 'Silver', 'Quiet', 'Electric', 'Velvet', 'Midnight', 'Summer', 'Hollow',
  'Lucid', 'Wild', 'Distant', 'Bright', 'Faded', 'Northern', 'Glass', 'Sunday', 'Late'];
const NOUN = ['Hour', 'Rain', 'Motion', 'Moon', 'Lines', 'Rooms', 'Heart', 'Signals', 'Avenue', 'Fever', 'Tides', 'Static',
  'Gardens', 'Echoes', 'Weather', 'Machines', 'Letters', 'Skyline', 'Shadows', 'Drive'];
const LYRICS = ['City lights are fading slow', 'We were running out of time', 'Hold the moment, let it go',
  'Every street I used to know', 'Turn the volume up tonight', 'Nothing here is quite the same', 'Whisper softly, call my name',
  'Summer air and open roads', 'All the colors in the rain', 'Dancing in an empty room', 'Waiting for the morning sun',
  'Echoes of a song we sung', 'Paper planes across the sky', 'Never knew the reason why'];

const artists = [], albums = [], songs = [];
ARTISTS.forEach((name, a) => {
  const ar = { id: 'ar' + a, name, coverArt: 'ar' + a, albumCount: 0 };
  artists.push(ar);
  const nAlb = 2 + Math.floor(rnd() * 2);
  for (let b = 0; b < nAlb; b++) {
    const id = `al${a}_${b}`, year = 2012 + Math.floor(rnd() * 14), genre = pick(GENRES);
    const al = { id, name: pick(ADJ) + ' ' + pick(NOUN), artist: name, artistId: ar.id, year, genre, coverArt: id, songCount: 0, duration: 0,
      created: new Date(2026, 0, 1 + a * 3 + b).toISOString() };
    const nTr = 8 + Math.floor(rnd() * 5);
    for (let t = 1; t <= nTr; t++) {
      const dur = 150 + Math.floor(rnd() * 120);
      songs.push({ id: `s${a}_${b}_${t}`, title: pick(ADJ) + ' ' + pick(NOUN), album: al.name, albumId: id, artist: name,
        artistId: ar.id, track: t, duration: dur, coverArt: id, suffix: 'flac', bitRate: 900 + Math.floor(rnd() * 300), year, genre });
      songs[songs.length - 1].playCount = hash(songs[songs.length - 1].id) % 40;
      al.songCount++; al.duration += dur;
    }
    albums.push(al); ar.albumCount++;
  }
});
const playlists = [['Late Night Drive', 40], ['Sunday Coffee', 25], ['Deep Focus', 32], ['Running Mix', 28], ['Rainy Day', 22], ['Throwbacks', 35]]
  .map(([name, n], i) => ({ id: 'pl' + i, name, owner: 'demo', public: i % 2 === 0, coverArt: albums[(i * 7) % albums.length].id,
    entry: Array.from({ length: n }, (_, k) => songs[(i * 37 + k * 11) % songs.length]) }))
  .map(p => Object.assign(p, { songCount: p.entry.length, duration: p.entry.reduce((s, x) => s + x.duration, 0) }));
playlists[5].readonly = true; // like Navidrome's smart and auto-imported .m3u playlists: songs can't be changed by hand
const starred = { album: albums.filter((_, i) => i % 6 === 1), artist: artists.filter((_, i) => i % 5 === 2),
  song: songs.filter((_, i) => i % 13 === 4).map(s => Object.assign({}, s, { starred: '2026-01-01T00:00:00Z' })) };
const coverTitle = id => (albums.find(a => a.id === id) || {}).name || '';

// ---- generated cover art (abstract SVG, one style per album)
const PALETTES = [['#ff6b6b', '#4d1f5c'], ['#f7b267', '#c0392b'], ['#4facfe', '#1a2a6c'], ['#43e97b', '#0f3d3e'], ['#fa709a', '#3a1c71'],
  ['#ffd86f', '#fc6262'], ['#a18cd1', '#2c3e50'], ['#30cfd0', '#330867'], ['#f093fb', '#1b1b3a'], ['#c3ec52', '#0ba29d'],
  ['#e0c3fc', '#5b4b8a'], ['#ff9a44', '#2b1055']];
function coverSvg(id) {
  const h = mix(id), [c1, c2] = PALETTES[mix(id + 'p') % PALETTES.length], style = mix(id + 's') % 4;
  let shapes = '';
  if (id.startsWith('ar')) {
    shapes = `<circle cx="150" cy="125" r="58" fill="rgba(0,0,0,.28)"/><path d="M40 300c10-80 55-110 110-110s100 30 110 110z" fill="rgba(0,0,0,.28)"/>`;
  } else if (style === 0) shapes = `<circle cx="${90 + h % 120}" cy="${100 + (h >> 3) % 100}" r="${70 + h % 50}" fill="rgba(255,255,255,.22)"/><circle cx="210" cy="220" r="50" fill="rgba(0,0,0,.18)"/>`;
  else if (style === 1) shapes = Array.from({ length: 6 }, (_, i) => `<rect x="0" y="${40 + i * 42}" width="300" height="${8 + (h >> i) % 14}" fill="rgba(255,255,255,${0.08 + i * 0.03})"/>`).join('');
  else if (style === 2) shapes = Array.from({ length: 5 }, (_, i) => `<circle cx="150" cy="150" r="${120 - i * 22}" fill="none" stroke="rgba(255,255,255,.25)" stroke-width="${3 + i}"/>`).join('');
  else shapes = `<polygon points="0,300 ${80 + h % 140},${60 + h % 90} 300,300" fill="rgba(0,0,0,.25)"/><polygon points="300,0 ${120 + h % 100},${150 + h % 80} 300,300" fill="rgba(255,255,255,.15)"/>`;
  const title = id.startsWith('ar') ? '' : `<text x="20" y="278" font-family="Helvetica, Arial" font-size="17" font-weight="700" letter-spacing="2" fill="rgba(255,255,255,.85)">${coverTitle(id).toUpperCase()}</text>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300" viewBox="0 0 300 300"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0" stop-color="${c1}"/><stop offset="1" stop-color="${c2}"/></linearGradient></defs><rect width="300" height="300" fill="url(#g)"/>${shapes}${title}</svg>`;
}

// ---- 3 minutes of a quiet sine tone as stand-in audio
function wav(sec) {
  const sr = 8000, n = sr * sec, b = Buffer.alloc(44 + n);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr, 28); b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34); b.write('data', 36); b.writeUInt32LE(n, 40);
  // MOCK_SILENT=1 for automated tests: real audio data, but nothing to hear
  const amp = process.env.MOCK_SILENT ? 0 : 12;
  for (let i = 0; i < n; i++) b[44 + i] = 128 + Math.round(amp * Math.sin(i / sr * 2 * Math.PI * 440));
  return b;
}
const WAV = wav(180);

// MOCK_VERSION pretends to be another server version – a second instance with a different one stands in for a foreign server
const SERVER = { version: '1.16.1', type: 'demo', serverVersion: process.env.MOCK_VERSION || '1.0', openSubsonic: true };
const ok = o => ({ 'subsonic-response': Object.assign({ status: 'ok' }, SERVER, o) });
const byId = (list, id) => list.find(x => x.id === id);
const sorters = {
  alphabeticalByName: (a, b) => a.name.localeCompare(b.name), alphabeticalByArtist: (a, b) => a.artist.localeCompare(b.artist),
  newest: (a, b) => b.created.localeCompare(a.created), recent: (a, b) => hash(a.id + 'r') - hash(b.id + 'r'),
  frequent: (a, b) => hash(a.id + 'f') - hash(b.id + 'f'), random: () => Math.random() - 0.5,
};

// Play queue shared between clients (savePlayQueue / getPlayQueue), like Navidrome keeps it per user
let playQueue = null;
const list = v => v == null ? [] : Array.isArray(v) ? v : [v];
const withCounts = p => Object.assign(p, { songCount: p.entry.length, duration: p.entry.reduce((s, x) => s + x.duration, 0) });

http.createServer((req, res) => {
  // POST forms (OpenSubsonic "formPost") carry the same parameters in the body
  if (req.method === 'POST') {
    let data = '';
    req.on('data', c => { data += c; });
    req.on('end', () => {
      const u = url.parse(req.url, true);
      for (const [k, v] of new URLSearchParams(data)) u.query[k] = k in u.query ? list(u.query[k]).concat(v) : v;
      handle(req, res, u);
    });
    return;
  }
  handle(req, res, url.parse(req.url, true));
}).listen(PORT, () => console.log(`Demo server: http://localhost:${PORT}`));

// Radio stations: an endless stream of MOCK_RADIO (an ADTS .aac file, 20 seconds) that names a song
// from the library every 20 seconds (ICY metadata, like Icecast/Shoutcast). Without MOCK_RADIO they're only listed.
const RADIO = process.env.MOCK_RADIO ? fs.readFileSync(process.env.MOCK_RADIO) : null;
function radio(req, res, u) {
  const host = 'http://' + req.headers.host, n = u.pathname.split('/')[2].replace(/\..*/, '');
  if (u.pathname.endsWith('.m3u')) { res.writeHead(200, { 'Content-Type': 'audio/x-mpegurl' }); return res.end(`#EXTM3U\n#EXTINF:-1,Station\n${host}/radio/${n}\n`); }
  if (u.pathname.endsWith('.pls')) { res.writeHead(200, { 'Content-Type': 'audio/x-scpls' }); return res.end(`[playlist]\nNumberOfEntries=1\nFile1=${host}/radio/${n}\n`); }
  if (!RADIO) { res.writeHead(404); return res.end(); }
  const metaint = 400, icy = req.headers['icy-metadata'] === '1';
  res.writeHead(200, Object.assign({ 'Content-Type': 'audio/aac', 'icy-name': 'Demo ' + n }, icy ? { 'icy-metaint': String(metaint) } : {}));
  const perSecond = Math.ceil(RADIO.length / 20), started = Date.now();
  let at = 0, sinceMeta = 0;
  const title = () => { const s = songs[(Math.floor((Date.now() - started) / 20000) + hash(n)) % songs.length]; return `${s.artist} - ${s.title}`; };
  const meta = () => {
    const text = Buffer.from(`StreamTitle='${title().replace(/'/g, '')}';`), len = Math.ceil(text.length / 16);
    const b = Buffer.alloc(1 + len * 16); b[0] = len; text.copy(b, 1); return b;
  };
  const send = bytes => {
    const out = [];
    while (bytes > 0) {
      const take = Math.min(bytes, RADIO.length - at, icy ? metaint - sinceMeta : Infinity);
      out.push(RADIO.subarray(at, at + take)); at = (at + take) % RADIO.length; bytes -= take; sinceMeta += take;
      if (icy && sinceMeta === metaint) { out.push(meta()); sinceMeta = 0; }
    }
    res.write(Buffer.concat(out));
  };
  send(perSecond * 4); // a few seconds ahead, so playback starts right away
  const timer = setInterval(() => send(perSecond), 1000);
  res.on('close', () => clearInterval(timer));
}

function handle(req, res, u) {
  const q = u.query;
  if (u.pathname.startsWith('/radio/')) return radio(req, res, u);
  if (u.pathname.startsWith('/rest/')) {
    const m = u.pathname.slice(6).replace('.view', '');
    if (process.env.MOCK_LOG) console.log(req.method, req.headers.host, Object.keys(req.headers).filter(h => h.startsWith('x-')).join(',') || '-', m, q.u ? '' : 'NOLOGIN', Object.entries(q).filter(([k]) => !'utscvf'.includes(k) || k.length > 1).map(([k, v]) => `${k}=${v}`).join(' '));
    // Like Navidrome: without a login only an error comes back – but with the server's type and version
    if (!q.u && m !== 'getCoverArt' && m !== 'stream' && m !== 'download') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ 'subsonic-response': Object.assign({ status: 'failed' }, SERVER, { error: { code: 10, message: 'Missing parameter: u' } }) }));
    }
    if (m === 'getCoverArt' && COVERS && fs.existsSync(path.join(COVERS, (q.id || '') + '.png'))) {
      res.writeHead(200, { 'Content-Type': 'image/png' }); return res.end(fs.readFileSync(path.join(COVERS, q.id + '.png')));
    }
    if (m === 'getCoverArt') { res.writeHead(200, { 'Content-Type': 'image/svg+xml', 'Access-Control-Allow-Origin': '*' }); return res.end(coverSvg(q.id || '')); }
    if (m === 'stream' || m === 'download') {
      // Byte ranges like a real server – AVPlayer on iOS refuses streams without them
      const r = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
      if (!r) {
        res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': WAV.length, 'Accept-Ranges': 'bytes' });
        if (!process.env.MOCK_SLOW) return res.end(WAV);
        // MOCK_SLOW=1: whole-file requests (downloads) trickle in over ~20 s, to test what happens mid-download
        let at = 0;
        const step = () => { if (res.destroyed) return; const next = Math.min(at + 36000, WAV.length); res.write(WAV.subarray(at, next)); at = next; if (at < WAV.length) setTimeout(step, 500); else res.end(); };
        return step();
      }
      const start = r[1] ? +r[1] : WAV.length - +r[2], end = r[1] && r[2] ? Math.min(+r[2], WAV.length - 1) : WAV.length - 1;
      res.writeHead(206, { 'Content-Type': 'audio/wav', 'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes', 'Content-Range': `bytes ${start}-${end}/${WAV.length}` });
      return res.end(WAV.subarray(start, end + 1));
    }
    let body;
    switch (m) {
      case 'getAlbumList2': {
        let l = q.type === 'byGenre' ? albums.filter(a => a.genre === q.genre) : q.type === 'starred' ? starred.album : albums.slice().sort(sorters[q.type] || sorters.newest);
        const o = +q.offset || 0; body = ok({ albumList2: { album: l.slice(o, o + (+q.size || 10)) } }); break;
      }
      case 'getAlbum': body = ok({ album: Object.assign({}, byId(albums, q.id), { song: songs.filter(s => s.albumId === q.id) }) }); break;
      case 'getArtists': body = ok({ artists: { index: [{ name: '#', artist: artists.slice().sort((a, b) => a.name.localeCompare(b.name)) }] } }); break;
      case 'getArtist': body = ok({ artist: Object.assign({}, byId(artists, q.id), { album: albums.filter(a => a.artistId === q.id) }) }); break;
      case 'getArtistInfo2': {
        const ar = byId(artists, q.id) || {};
        body = ok({ artistInfo2: { biography: `${ar.name} is a fictional act from the Tonalo demo library. Their records mix warm analog textures with late-night melodies, and every song you see here was made up for screenshots.`,
          similarArtist: artists.filter(x => x.id !== q.id).slice(hash(q.id) % 10, hash(q.id) % 10 + 6) } });
        break;
      }
      // MOCK_NO_TOPSONGS=1: like Navidrome without Last.fm, which has no top songs
      case 'getTopSongs': body = ok({ topSongs: process.env.MOCK_NO_TOPSONGS ? {} : { song: songs.filter(s => s.artist === q.artist).slice(0, 10) } }); break;
      // Different songs per seed, like Last.fm would; MOCK_NO_SIMILAR=1 is a server without Last.fm
      case 'getSimilarSongs2': body = ok({ similarSongs2: process.env.MOCK_NO_SIMILAR ? {} : { song: songs.slice().sort((a, b) => hash(a.id + q.id) - hash(b.id + q.id)).slice(0, +q.count || 50) } }); break;
      case 'getPlaylists': body = ok({ playlists: { playlist: playlists.map(p => Object.assign({}, p, { entry: undefined })) } }); break;
      case 'getPlaylist': body = ok({ playlist: byId(playlists, q.id) }); break;
      case 'getGenres': body = ok({ genres: { genre: GENRES.map(g => ({ value: g, albumCount: albums.filter(a => a.genre === g).length, songCount: songs.filter(s => s.genre === g).length })) } }); break;
      case 'getRandomSongs': body = ok({ randomSongs: { song: songs.filter(s => !q.genre || s.genre === q.genre).sort(() => Math.random() - 0.5).slice(0, +q.size || 10) } }); break;
      case 'getInternetRadioStations': {
        const host = 'http://' + req.headers.host;
        body = ok({ internetRadioStations: { internetRadioStation: [
          { id: 'r1', name: 'Demo FM', streamUrl: `${host}/radio/1`, homePageUrl: 'https://example.org' },
          { id: 'r2', name: 'Night Lounge', streamUrl: `${host}/radio/2.m3u` },
          { id: 'r3', name: 'Morning Drive', streamUrl: `${host}/radio/3.pls` },
        ] } }); break;
      }
      case 'getStarred2': body = ok({ starred2: starred }); break;
      case 'search3': {
        const s = (q.query || '').toLowerCase(), has = x => x.toLowerCase().includes(s);
        body = ok({ searchResult3: { artist: artists.filter(a => has(a.name)), album: albums.filter(a => has(a.name) || has(a.artist)).slice(0, 40), song: songs.filter(x => has(x.title) || has(x.artist)).slice(0, 60) } });
        break;
      }
      case 'getPlayQueue': body = ok(playQueue ? { playQueue } : {}); break;
      case 'savePlayQueue': {
        const entry = list(q.id).map(id => byId(songs, id)).filter(Boolean);
        playQueue = entry.length ? { entry, current: q.current || entry[0].id, position: +q.position || 0, username: 'demo',
          changed: new Date().toISOString(), changedBy: q.c } : null;
        body = ok({}); break;
      }
      case 'createPlaylist': {
        const entry = list(q.songId).map(id => byId(songs, id)).filter(Boolean);
        let pl = byId(playlists, q.playlistId);
        if (pl) pl.entry = entry; // with an id it replaces the songs, as in Navidrome
        else playlists.push(pl = { id: 'pl' + Date.now(), name: q.name || 'New playlist', owner: 'demo', public: false, coverArt: entry[0] && entry[0].coverArt, entry });
        withCounts(pl);
        body = ok({ playlist: pl }); break;
      }
      case 'updatePlaylist': {
        const pl = byId(playlists, q.playlistId);
        if (!pl) { body = { 'subsonic-response': { status: 'failed', version: '1.16.1', error: { code: 70, message: 'Playlist not found' } } }; break; }
        if (pl.readonly && (q.songIdToAdd || q.songIndexToRemove)) {
          body = { 'subsonic-response': { status: 'failed', version: '1.16.1', error: { code: 50, message: 'User is not authorized for the given operation' } } }; break;
        }
        if (q.name) pl.name = q.name;
        const drop = new Set(list(q.songIndexToRemove).map(Number));
        pl.entry = pl.entry.filter((_, i) => !drop.has(i)).concat(list(q.songIdToAdd).map(id => byId(songs, id)).filter(Boolean));
        withCounts(pl);
        body = ok({}); break;
      }
      case 'deletePlaylist': { const i = playlists.findIndex(p => p.id === q.id); if (i >= 0) playlists.splice(i, 1); body = ok({}); break; }
      case 'getLyricsBySongId': body = ok({ lyricsList: { structuredLyrics: [{ synced: true, line: Array.from({ length: 32 }, (_, i) => ({ start: i * 4500, value: LYRICS[(i + hash(q.id || '')) % LYRICS.length] })) }] } }); break;
      default: body = ok({});
    }
    // MOCK_DELAY=<ms>: answer slowly, like a server on a bad connection
    const send = () => { res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }); res.end(JSON.stringify(body)); };
    return process.env.MOCK_DELAY ? setTimeout(send, +process.env.MOCK_DELAY) : send();
  }
  const p = path.join(APP, u.pathname === '/' ? 'index.html' : decodeURIComponent(u.pathname));
  if (p !== APP && !p.startsWith(APP + path.sep)) { res.writeHead(403); return res.end(); }
  fs.readFile(p, (e, d) => {
    if (e) { res.writeHead(404); return res.end(); }
    const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css', '.png': 'image/png', '.json': 'application/json' };
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(d);
  });
}
