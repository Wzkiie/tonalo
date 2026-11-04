// Stand-in for an Audiobookshelf server with made-up items and silent audio, for testing the iPhone app.
// Modelled on the real server's routes (advplyr/audiobookshelf). It is not the real thing – check against a real server too.
// Usage: node ios/tools/abs_mock.js [port]   login: any user with password "demo"
// MOCK_TOKEN_SECONDS=<n>: access tokens run out after n seconds, to try the renewal. MOCK_LOG=1: print the requests.
// MOCK_REQUIRE_HEADER=<name>: answers 403 without that header, like Cloudflare Access.
// MOCK_SLOW_DOWNLOAD=1: a file takes 12 seconds, to watch the progress. MOCK_NO_DOWNLOAD=1: this user isn't allowed to download. MOCK_ANY_TOKEN=1: a login from before a restart still counts.
const http = require('http'), crypto = require('crypto');
const PORT = +process.argv[2] || 4610;
const TOKEN_SECONDS = +process.env.MOCK_TOKEN_SECONDS || 3600;

// Silent WAV of the given length: real audio data, nothing to hear
function silence(seconds) {
  const rate = 8000, n = seconds * rate, b = Buffer.alloc(44 + n, 0x80);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate, 28);
  b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34); b.write('data', 36); b.writeUInt32LE(n, 40);
  return b;
}
const FILE = +process.env.MOCK_FILE_SECONDS || 120, WAV = silence(FILE); // every file is 2 minutes (MOCK_FILE_SECONDS for longer ones)

const chapters = (titles) => titles.map((title, i) => { const len = (FILE * 3) / titles.length * (FILE === 120 ? 0.75 : 1) ; return { id: i, start: i * len, end: (i + 1) * len, title }; });
const BOOKS = [
  { id: 'book-1', title: 'Das stille Buch', authorName: 'Nora Vale', narratorName: 'Milo Ferro', seriesName: 'Stille, Band 1', files: 3,
    description: '<p>Ein erfundenes <b>Hörbuch</b> zum Testen, aufgeteilt auf drei Dateien.</p>',
    chapters: chapters(['Anfang', 'Mitte über zwei Dateien', 'Weiter', 'Ende']) },
  { id: 'book-2', title: 'Ohne Kapitel', authorName: 'Glass Harbor', narratorName: null, seriesName: '', files: 1, description: '', chapters: [] },
  { id: 'book-3', title: 'Lange Nacht', authorName: 'Saffron Lane', narratorName: 'Ravi Kade', seriesName: '', files: 2, description: 'Noch ein Test.',
    chapters: chapters(['Eins', 'Zwei', 'Drei']) },
];
const EPISODES = [1, 2, 3].map((n) => ({ id: 'ep-' + n, title: 'Folge ' + n, subtitle: '', duration: FILE, publishedAt: n * 1000, audioFile: { ino: 'ep-' + n, duration: FILE, metadata: { ext: '.wav', size: 960044 } } }));
const PODCAST = { id: 'pod-1', title: 'Der stille Podcast', author: 'Echo Park Social', description: 'Ein erfundener Podcast.' };

// MOCK_EN=1: invented English books for screenshots, with some of them started. MOCK_BOOK_COVERS=<dir>: <id>.png is the cover of that item
if (process.env.MOCK_EN) {
  const EN = [
    ['The Last Lighthouse', 'Nora Vale', 'Milo Ferro', 'Tidewater, Book 1', ['The Keeper', 'Storm Season', 'Salt on the Glass', 'The Long Night', 'Morning Tide']],
    ['Paper Cities', 'Ellis Moor', 'Ines Harlow', '', ['Folded Maps', 'The Cartographer', 'Rain on Paper', 'A Door in the Margin']],
    ['Salt and Static', 'Saffron Lane', 'Ravi Kade', '', ['Signal', 'Noise', 'Between Stations', 'Clear Channel']],
    ['A Field Guide to Quiet', 'Glass Harbor', null, '', ['Morning', 'Midday', 'Evening']],
    ['Midnight Orchard', 'Ravi Kade', 'Nora Vale', 'Tidewater, Book 2', ['Windfall', 'The Gate', 'Frost', 'Blossom', 'Harvest']],
  ];
  BOOKS.length = 0;
  EN.forEach(([title, authorName, narratorName, seriesName, ch], i) => BOOKS.push({ id: 'book-' + (i + 1), title, authorName, narratorName, seriesName, files: 3,
    description: '<p>An invented audiobook, made up for this demo.</p>', chapters: chapters(ch) }));
  EPISODES.forEach((e, i) => { e.title = 'Episode ' + (i + 1); });
  PODCAST.title = 'The Quiet Hour'; PODCAST.description = 'An invented podcast.';
}
const authorId = (name) => 'aut-' + name.toLowerCase().replace(/\W+/g, '-');
const tracks = (b) => Array.from({ length: b.files }, (_, i) => ({ index: i + 1, ino: b.id + '-' + (i + 1), startOffset: i * FILE, duration: FILE, metadata: { ext: '.wav', size: WAV.length } }));
const book = (b) => ({
  id: b.id, libraryId: 'lib-books', mediaType: 'book', addedAt: Date.now(),
  media: { duration: b.files * FILE, chapters: b.chapters, numTracks: b.files, tracks: tracks(b),
    metadata: { title: b.title, authorName: b.authorName, narratorName: b.narratorName, seriesName: b.seriesName, description: b.description, publishedYear: '2026',
      authors: [{ id: authorId(b.authorName), name: b.authorName }], narrators: b.narratorName ? [b.narratorName] : [],
      series: b.seriesName ? [{ id: 'ser-' + b.seriesName.split(',')[0].toLowerCase().replace(/\W+/g, '-'), name: b.seriesName.split(',')[0], sequence: (b.seriesName.match(/\d+/) || ['1'])[0] }] : [] } },
});
const podcast = () => ({
  id: PODCAST.id, libraryId: 'lib-pods', mediaType: 'podcast', addedAt: Date.now(),
  media: { numEpisodes: EPISODES.length, episodes: EPISODES, metadata: { title: PODCAST.title, author: PODCAST.author, description: PODCAST.description } },
});

const tokens = new Map(), refreshes = new Set(), sessions = new Map(), progress = new Map();
const log = (...a) => { if (process.env.MOCK_LOG) console.log(...a); };

function newTokens() {
  const access = 'a' + crypto.randomBytes(8).toString('hex'), refresh = 'r' + crypto.randomBytes(8).toString('hex');
  tokens.set(access, Date.now() + TOKEN_SECONDS * 1000);
  refreshes.add(refresh);
  return { accessToken: access, refreshToken: refresh, token: 'legacy-' + access };
}

function save(item, episode, currentTime, duration, finished) {
  const key = episode ? item + '/' + episode : item;
  const isFinished = finished ?? currentTime >= duration - 10;
  progress.set(key, { libraryItemId: item, episodeId: episode || null, currentTime, duration, progress: duration ? Math.min(1, currentTime / duration) : 0, isFinished, lastUpdate: Date.now() });
}

if (process.env.MOCK_EN) {
  const dur = (b) => b.files * FILE;
  [['book-1', 0.38], ['book-3', 0.62], ['book-5', 0.12], ['book-2', 1]].forEach(([id, f]) => { const b = BOOKS.find((x) => x.id === id); save(id, null, dur(b) * f, dur(b)); });
}

function shelves(lib) {
  const started = (items) => items.filter((i) => { const p = progress.get(i.id); return p && !p.isFinished; });
  if (lib === 'lib-pods') {
    return [{ id: 'episodes-recently-added', label: 'Newest Episodes', type: 'episode', entities: [{ ...podcast(), recentEpisode: EPISODES[2] }] },
      { id: 'recently-added', label: 'Recently Added', type: 'podcast', entities: [podcast()] }];
  }
  const all = BOOKS.map(book), cont = started(all);
  return [...(cont.length ? [{ id: 'continue-listening', label: 'Continue Listening', type: 'book', entities: cont }] : []),
    { id: 'recently-added', label: 'Recently Added', type: 'book', entities: all },
    // Shapes the app doesn't show, like the real server sends them
    { id: 'newest-authors', label: 'Newest Authors', type: 'authors', entities: [{ id: 'x', name: 'Nora Vale' }] }];
}

function startSession(itemId, episodeId, res, json) {
  const b = BOOKS.find((x) => x.id === itemId);
  const ep = episodeId && EPISODES.find((e) => e.id === episodeId);
  if (!b && !ep) return json(404, 'Not found');
  const files = b ? b.files : 1, duration = files * FILE, id = 'play_' + crypto.randomBytes(6).toString('hex');
  const tracks = Array.from({ length: files }, (_, i) => ({ index: i + 1, startOffset: i * FILE, duration: FILE, title: 'Datei ' + (i + 1), contentUrl: `/public/session/${id}/track/${i + 1}`, mimeType: 'audio/wav' }));
  const key = episodeId ? itemId + '/' + episodeId : itemId, currentTime = progress.get(key)?.currentTime || 0;
  const s = { id, libraryItemId: itemId, episodeId: episodeId || null, displayTitle: b ? b.title : ep.title, displayAuthor: b ? b.authorName : PODCAST.author, duration, currentTime, chapters: b ? b.chapters : [], audioTracks: tracks, mediaType: b ? 'book' : 'podcast', libraryItem: b ? book(b) : podcast() };
  sessions.set(id, s);
  console.log('SESSION start', itemId, episodeId || '', 'at', currentTime);
  json(200, s);
}

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x'), path = u.pathname;
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', () => {
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch (e) { /* no JSON */ }
    const json = (code, o) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(typeof o === 'string' ? o : JSON.stringify(o)); };
    const m = (re) => re.exec(path);
    log(req.method, req.url, Object.keys(req.headers).filter((h) => h.startsWith('x-') || h.startsWith('cf-')).join(','));

    if (process.env.MOCK_REQUIRE_HEADER && !req.headers[process.env.MOCK_REQUIRE_HEADER.toLowerCase()]) { console.log('BLOCKED', path); res.writeHead(403); return res.end('Forbidden'); }
  if (path === '/status') return json(200, { app: 'audiobookshelf', isInit: true, language: 'en-us', serverVersion: '2.30.0' });
    if (path === '/login' && req.method === 'POST') {
      if (body.password !== 'demo') return json(401, 'Invalid credentials');
      const t = newTokens();
      console.log('LOGIN', req.headers['x-return-tokens'] ? 'with tokens' : 'WITHOUT x-return-tokens');
      return json(200, { user: { id: 'u1', username: body.username, ...(req.headers['x-return-tokens'] ? t : { token: t.token }) }, userDefaultLibraryId: 'lib-books' });
    }
    if (path === '/auth/refresh' && req.method === 'POST') {
      const r = req.headers['x-refresh-token'];
      if (!refreshes.has(r)) return json(401, 'bad refresh');
      refreshes.delete(r);
      console.log('REFRESH');
      return json(200, { user: newTokens() });
    }
    if (path === '/logout') { refreshes.delete(req.headers['x-refresh-token']); console.log('LOGOUT'); return json(200, {}); }

    // The session id is the permission here, like on the real server: no login needed
    const track = m(/^\/public\/session\/([^/]+)\/track\/(\d+)$/);
    if (track) {
      const s = sessions.get(track[1]);
      if (!s || !s.audioTracks.some((t) => t.index === +track[2])) { console.log('TRACK 404', track[1]); res.writeHead(404); return res.end(); }
      const range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
      if (!range) { res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': WAV.length, 'Accept-Ranges': 'bytes' }); return res.end(WAV); }
      const start = +range[1] || 0, end = range[2] ? +range[2] : WAV.length - 1;
      res.writeHead(206, { 'Content-Type': 'audio/wav', 'Accept-Ranges': 'bytes', 'Content-Range': `bytes ${start}-${end}/${WAV.length}`, 'Content-Length': end - start + 1 });
      return res.end(WAV.subarray(start, end + 1));
    }

    const bearer = (req.headers.authorization || '').replace('Bearer ', '');
    if (!path.startsWith('/api/')) return json(404, 'Not found');
    if (!process.env.MOCK_ANY_TOKEN && !(tokens.get(bearer) > Date.now())) { console.log('401', path); return json(401, 'Unauthorized'); }

    if (path === '/api/libraries') return json(200, { libraries: [{ id: 'lib-books', name: 'Hörbücher', mediaType: 'book' }, { id: 'lib-pods', name: 'Podcasts', mediaType: 'podcast' }] });
    if (path === '/api/me') return json(200, { id: 'u1', permissions: { download: !process.env.MOCK_NO_DOWNLOAD }, mediaProgress: [...progress.values()] });
    if (path === '/api/me/items-in-progress') {
      const started = [...progress.values()].filter((p) => !p.isFinished && p.currentTime > 0);
      return json(200, { libraryItems: started.flatMap((p) => {
        const b = BOOKS.find((i) => i.id === p.libraryItemId);
        if (b) return [{ ...book(b), progressLastUpdate: p.lastUpdate }];
        return p.episodeId ? [{ ...podcast(), recentEpisode: EPISODES.find((e) => e.id === p.episodeId), progressLastUpdate: p.lastUpdate }] : [];
      }) });
    }
    let x;
    if ((x = m(/^\/api\/items\/([^/]+)\/file\/([^/]+)\/download$/))) {
      if (process.env.MOCK_NO_DOWNLOAD) return json(403, 'Forbidden');
      console.log('DOWNLOAD', x[1], x[2]);
      res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': WAV.length });
      if (process.env.MOCK_SLOW_DOWNLOAD) {
        let at = 0;
        const step = Math.ceil(WAV.length / 60);
        const timer = setInterval(() => {
          res.write(WAV.subarray(at, at + step));
          at += step;
          if (at >= WAV.length) { clearInterval(timer); res.end(); }
        }, 200);
        res.on('close', () => clearInterval(timer));
        return;
      }
      return res.end(WAV);
    }
    if ((x = m(/^\/api\/libraries\/([^/]+)\/authors$/))) {
      if (x[1] === 'lib-pods') return json(200, { authors: [] });
      return json(200, { authors: BOOKS.map((b) => ({ id: authorId(b.authorName), name: b.authorName, numBooks: 1 })) });
    }
    if ((x = m(/^\/api\/libraries\/([^/]+)\/series$/))) {
      return json(200, { results: x[1] === 'lib-pods' ? [] : [{ id: 'ser-1', name: 'Stille', books: [book(BOOKS[0])] }], total: 1 });
    }
    if ((x = m(/^\/api\/authors\/([^/]+)\/image$/))) { res.writeHead(404); return res.end(); }
    if ((x = m(/^\/api\/authors\/([^/]+)$/))) {
      const mine = BOOKS.filter((b) => authorId(b.authorName) === x[1]);
      if (!mine.length) return json(404, 'Not found');
      return json(200, { id: x[1], name: mine[0].authorName, description: 'Eine erfundene Biografie zum Testen.', libraryItems: mine.map(book),
        series: mine.some((b) => b.seriesName) ? [{ id: 'ser-1', name: 'Stille', items: mine.filter((b) => b.seriesName).map(book) }] : [] });
    }
    if ((x = m(/^\/api\/libraries\/([^/]+)\/personalized$/))) return json(200, shelves(x[1]));
    if ((x = m(/^\/api\/libraries\/([^/]+)\/items$/))) {
      const filter = /^(\w+)\.(.+)$/.exec(u.searchParams.get('filter') || '');
      const wanted = filter && Buffer.from(decodeURIComponent(filter[2]), 'base64').toString();
      const picked = BOOKS.filter((b) => !filter || (filter[1] === 'narrators' ? b.narratorName === wanted : filter[1] === 'series' ? !!b.seriesName && wanted === 'ser-1' : true));
      if (filter) console.log('FILTER', filter[1], wanted);
      const all = x[1] === 'lib-pods' ? (filter ? [] : [podcast()]) : picked.map(book), page = +u.searchParams.get('page') || 0, limit = +u.searchParams.get('limit') || 100;
      return json(200, { results: all.slice(page * limit, (page + 1) * limit), total: all.length, page, limit });
    }
    if ((x = m(/^\/api\/libraries\/([^/]+)\/search$/))) {
      const q = (u.searchParams.get('q') || '').toLowerCase();
      if (x[1] === 'lib-pods') return json(200, { podcast: PODCAST.title.toLowerCase().includes(q) ? [{ libraryItem: podcast() }] : [] });
      return json(200, { book: BOOKS.filter((b) => (b.title + b.authorName).toLowerCase().includes(q)).map((b) => ({ libraryItem: book(b) })),
        authors: BOOKS.filter((b) => b.authorName.toLowerCase().includes(q)).map((b) => ({ id: authorId(b.authorName), name: b.authorName })),
        series: 'stille'.includes(q) ? [{ series: { id: 'ser-1', name: 'Stille' }, books: [] }] : [],
        narrators: BOOKS.filter((b) => (b.narratorName || '').toLowerCase().includes(q)).map((b) => ({ name: b.narratorName, numBooks: 1 })) });
    }
    if ((x = m(/^\/api\/items\/([^/]+)\/cover$/))) {
      const file = process.env.MOCK_BOOK_COVERS && require('path').join(process.env.MOCK_BOOK_COVERS, x[1] + '.png');
      if (file && require('fs').existsSync(file)) { res.writeHead(200, { 'Content-Type': 'image/png' }); return res.end(require('fs').readFileSync(file)); }
      res.writeHead(200, { 'Content-Type': 'image/png' });
      // 1x1 PNG, enough to see a cover arrive
      return res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEBgIApD5fRAAAAABJRU5ErkJggg==', 'base64'));
    }
    if ((x = m(/^\/api\/items\/([^/]+)\/play(?:\/([^/]+))?$/)) && req.method === 'POST') return startSession(x[1], x[2], res, json);
    if ((x = m(/^\/api\/items\/([^/]+)$/))) {
      if (x[1] === PODCAST.id) return json(200, podcast());
      const b = BOOKS.find((i) => i.id === x[1]);
      return b ? json(200, book(b)) : json(404, 'Not found');
    }
    if ((x = m(/^\/api\/session\/([^/]+)\/(sync|close)$/)) && req.method === 'POST') {
      const s = sessions.get(x[1]);
      if (!s) { console.log('SESSION unknown', x[2]); return json(404, 'Not found'); }
      save(s.libraryItemId, s.episodeId, body.currentTime, s.duration);
      console.log('SESSION', x[2], 'at', Math.round(body.currentTime), 'listened', Math.round(body.timeListened));
      if (x[2] === 'close') sessions.delete(x[1]);
      return json(200, {});
    }
    if ((x = m(/^\/api\/me\/progress\/([^/]+)(?:\/([^/]+))?$/)) && req.method === 'PATCH') {
      const key = x[2] ? x[1] + '/' + x[2] : x[1];
      const old = progress.get(key) || { currentTime: 0, duration: 1 };
      save(x[1], x[2], body.currentTime ?? old.currentTime, body.duration ?? old.duration, body.isFinished);
      console.log('PROGRESS', key, body);
      return json(200, {});
    }
    return json(404, 'Not found');
  });
}).listen(PORT, () => console.log('Audiobookshelf stand-in on http://localhost:' + PORT));
