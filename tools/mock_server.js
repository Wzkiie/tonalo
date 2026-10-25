// Mini-Subsonic-Mock zum Testen ohne echten Server (serviert auch ./app)
// Nutzung: node tools/mock_server.js app  ->  http://localhost:4599, Server-URL http://localhost:4599, beliebige Zugangsdaten
const http = require('http'), fs = require('fs'), path = require('path'), url = require('url');
const APP = process.argv[2];
const artists = [], albums = [], songs = [];
const genres = ['Deutschrap', 'Pop', 'Rock', 'Electronic'];
for (let a = 1; a <= 30; a++) {
  artists.push({ id: 'ar' + a, name: 'Künstler ' + a, albumCount: 3, coverArt: 'ar' + a });
  for (let b = 1; b <= 3; b++) {
    const id = `al${a}_${b}`;
    const al = { id, name: `Album ${b} von K${a}`, artist: 'Künstler ' + a, artistId: 'ar' + a, year: 2000 + a, songCount: 8, duration: 8 * 200, genre: genres[a % 4], coverArt: id };
    albums.push(al);
    for (let t = 1; t <= 8; t++) songs.push({ id: `s${a}_${b}_${t}`, title: `Titel ${t} (${a}/${b})`, album: al.name, albumId: id, artist: al.artist, artistId: al.artistId, track: t, duration: 200, coverArt: id, suffix: 'wav', bitRate: 1411, year: al.year });
  }
}
function wav(sec) {
  const sr = 8000, n = sr * sec, b = Buffer.alloc(44 + n);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr, 28); b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34); b.write('data', 36); b.writeUInt32LE(n, 40);
  for (let i = 0; i < n; i++) b[44 + i] = 128 + Math.round(20 * Math.sin(i / sr * 2 * Math.PI * 440));
  return b;
}
const WAV = wav(200);
function color(id) { let h = 0; for (const c of id) h = (h * 31 + c.charCodeAt(0)) % 360; return h; }
const ok = (o) => ({ 'subsonic-response': Object.assign({ status: 'ok', version: '1.16.1', type: 'mock', serverVersion: '0.0', openSubsonic: true }, o) });
http.createServer((req, res) => {
  const u = url.parse(req.url, true), q = u.query;
  if (u.pathname.startsWith('/rest/')) {
    const m = u.pathname.slice(6).replace('.view', '');
    if (m === 'getCoverArt') {
      res.writeHead(200, { 'Content-Type': 'image/svg+xml' });
      return res.end(`<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300"><rect width="300" height="300" fill="hsl(${color(q.id)},60%,45%)"/><text x="150" y="170" font-size="50" text-anchor="middle" fill="#fff">${q.id}</text></svg>`);
    }
    if (m === 'stream') { res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': WAV.length, 'Accept-Ranges': 'bytes' }); return res.end(WAV); }
    let body;
    if (q.p !== undefined && false) body = null;
    switch (m) {
      case 'ping': body = ok({}); break;
      case 'getAlbumList2': { let l = albums; if (q.type === 'random') l = [...albums].sort(() => Math.random() - .5); if (q.type === 'byGenre') l = albums.filter(a => a.genre === q.genre); const o = +q.offset || 0; body = ok({ albumList2: { album: l.slice(o, o + (+q.size || 10)) } }); break; }
      case 'getAlbum': { const al = albums.find(a => a.id === q.id); body = ok({ album: Object.assign({}, al, { song: songs.filter(s => s.albumId === q.id) }) }); break; }
      case 'getArtists': body = ok({ artists: { index: [{ name: 'K', artist: artists }] } }); break;
      case 'getArtist': { const ar = artists.find(a => a.id === q.id); body = ok({ artist: Object.assign({}, ar, { album: albums.filter(a => a.artistId === q.id) }) }); break; }
      case 'getArtistInfo2': body = ok({ artistInfo2: { biography: 'Eine Test-Biografie für diesen Künstler.', similarArtist: artists.slice(0, 5) } }); break;
      case 'getTopSongs': body = ok({ topSongs: { song: songs.slice(0, 10) } }); break;
      case 'getSimilarSongs2': body = ok({ similarSongs2: { song: songs.slice(20, 60) } }); break;
      case 'getPlaylists': body = ok({ playlists: { playlist: [{ id: 'pl1', name: 'Chill', songCount: 20, duration: 4000, coverArt: 'pl1' }] } }); break;
      case 'getPlaylist': body = ok({ playlist: { id: 'pl1', name: 'Chill', songCount: 20, duration: 4000, owner: 'demo', entry: songs.slice(40, 60) } }); break;
      case 'getGenres': body = ok({ genres: { genre: genres.map(g => ({ value: g, albumCount: 20, songCount: 160 })) } }); break;
      case 'getRandomSongs': body = ok({ randomSongs: { song: [...songs].sort(() => Math.random() - .5).slice(0, +q.size || 10) } }); break;
      case 'getStarred2': body = ok({ starred2: { album: albums.slice(0, 4), artist: artists.slice(0, 3), song: songs.slice(0, 6) } }); break;
      case 'search3': { const s = (q.query || '').toLowerCase(); body = ok({ searchResult3: { artist: artists.filter(a => a.name.toLowerCase().includes(s)).slice(0, 20), album: albums.filter(a => a.name.toLowerCase().includes(s)).slice(0, 40), song: songs.filter(a => a.title.toLowerCase().includes(s)).slice(0, 60) } }); break; }
      case 'getLyricsBySongId': body = ok({ lyricsList: { structuredLyrics: [{ synced: true, line: Array.from({ length: 40 }, (_, i) => ({ start: i * 4000, value: 'Zeile ' + (i + 1) + ' des Songtexts' })) }] } }); break;
      default: body = ok({});
    }
    res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    return res.end(JSON.stringify(body));
  }
  let p = path.join(APP, u.pathname === '/' ? 'index.html' : decodeURIComponent(u.pathname));
  fs.readFile(p, (e, d) => {
    if (e) { res.writeHead(404); return res.end(); }
    const ext = path.extname(p);
    res.writeHead(200, { 'Content-Type': { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css', '.png': 'image/png', '.json': 'application/json' }[ext] || 'application/octet-stream' });
    res.end(d);
  });
}).listen(4599, () => console.log('mock on 4599'));
