/* Subsonic / OpenSubsonic API-Client (Navidrome) */
var API = (function () {
  'use strict';
  var CLIENT = 'Tonalo';
  var VERSION = '1.16.1';
  var cfg = null; // {url, user, token, salt}

  function normalizeUrl(u) {
    u = String(u || '').trim();
    if (!u) return '';
    if (!/^https?:\/\//i.test(u)) u = 'http://' + u;
    return u.replace(/\/+$/, '').replace(/\/rest$/, '');
  }

  function randSalt() {
    var s = '', c = 'abcdefghijklmnopqrstuvwxyz0123456789';
    for (var i = 0; i < 12; i++) s += c.charAt(Math.floor(Math.random() * c.length));
    return s;
  }

  function makeCreds(url, user, password) {
    var salt = randSalt();
    return { url: normalizeUrl(url), user: user, salt: salt, token: md5(password + salt) };
  }

  function qs(params) {
    var base = { u: cfg.user, t: cfg.token, s: cfg.salt, v: VERSION, c: CLIENT, f: 'json' };
    var parts = [];
    function add(k, v) { if (v != null && v !== '') parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v)); }
    Object.keys(base).forEach(function (k) { add(k, base[k]); });
    Object.keys(params || {}).forEach(function (k) {
      var v = params[k];
      if (Array.isArray(v)) v.forEach(function (x) { add(k, x); });
      else add(k, v);
    });
    return parts.join('&');
  }

  function url(method, params) { return cfg.url + '/rest/' + method + '?' + qs(params); }

  function call(method, params, timeoutMs) {
    if (!cfg) return Promise.reject(new Error('Nicht angemeldet'));
    var ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    var timer = setTimeout(function () { if (ctrl) ctrl.abort(); }, timeoutMs || 20000);
    return fetch(url(method, params), { signal: ctrl ? ctrl.signal : undefined })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (j) {
        clearTimeout(timer);
        var res = j['subsonic-response'];
        if (!res) throw new Error('Ungültige Serverantwort');
        if (res.status !== 'ok') {
          var e = new Error((res.error && res.error.message) || 'Serverfehler');
          e.code = res.error && res.error.code;
          throw e;
        }
        return res;
      }, function (err) {
        clearTimeout(timer);
        if (err && err.name === 'AbortError') throw new Error('Zeitüberschreitung – Server nicht erreichbar');
        throw err;
      });
  }

  function setConfig(c) { cfg = c; }
  function getConfig() { return cfg; }

  function cover(id, size) {
    if (!id || !cfg) return '';
    return url('getCoverArt', { id: id, size: size || 300 });
  }

  function streamUrl(id, opts) {
    var p = { id: id };
    if (opts && opts.maxBitRate) { p.maxBitRate = opts.maxBitRate; p.format = opts.format || 'mp3'; }
    if (opts && opts.offset) p.timeOffset = Math.floor(opts.offset);
    return url('stream', p);
  }

  var A = U.asArray;

  return {
    normalizeUrl: normalizeUrl,
    makeCreds: makeCreds,
    setConfig: setConfig,
    getConfig: getConfig,
    cover: cover,
    streamUrl: streamUrl,
    call: call,

    ping: function () { return call('ping', {}, 10000); },

    albumList: function (type, size, offset, extra) {
      var p = Object.assign({ type: type, size: size || 40, offset: offset || 0 }, extra || {});
      return call('getAlbumList2', p).then(function (r) { return A(r.albumList2 && r.albumList2.album); });
    },
    album: function (id) { return call('getAlbum', { id: id }).then(function (r) { return r.album; }); },
    artists: function () {
      return call('getArtists').then(function (r) {
        var out = [];
        A(r.artists && r.artists.index).forEach(function (ix) { A(ix.artist).forEach(function (a) { out.push(a); }); });
        return out;
      });
    },
    artist: function (id) { return call('getArtist', { id: id }).then(function (r) { return r.artist; }); },
    artistInfo: function (id) {
      return call('getArtistInfo2', { id: id, count: 12 }).then(function (r) { return r.artistInfo2 || {}; })
        .catch(function () { return {}; });
    },
    topSongs: function (name) {
      return call('getTopSongs', { artist: name, count: 20 }).then(function (r) { return A(r.topSongs && r.topSongs.song); })
        .catch(function () { return []; });
    },
    similarSongs: function (id, count) {
      return call('getSimilarSongs2', { id: id, count: count || 50 }).then(function (r) { return A(r.similarSongs2 && r.similarSongs2.song); })
        .catch(function () { return []; });
    },
    playlists: function () { return call('getPlaylists').then(function (r) { return A(r.playlists && r.playlists.playlist); }); },
    playlist: function (id) { return call('getPlaylist', { id: id }).then(function (r) { return r.playlist; }); },
    addToPlaylist: function (playlistId, songIds) {
      return call('updatePlaylist', { playlistId: playlistId, songIdToAdd: songIds });
    },
    createPlaylist: function (name, songIds) { return call('createPlaylist', { name: name, songId: songIds }); },
    genres: function () {
      return call('getGenres').then(function (r) {
        return A(r.genres && r.genres.genre).sort(function (a, b) { return (b.albumCount || 0) - (a.albumCount || 0); });
      });
    },
    randomSongs: function (size, genre) {
      return call('getRandomSongs', { size: size || 100, genre: genre }).then(function (r) { return A(r.randomSongs && r.randomSongs.song); });
    },
    starred: function () {
      return call('getStarred2').then(function (r) {
        var s = r.starred2 || {};
        return { artists: A(s.artist), albums: A(s.album), songs: A(s.song) };
      });
    },
    search: function (q) {
      return call('search3', { query: q, artistCount: 20, albumCount: 40, songCount: 60 }).then(function (r) {
        var s = r.searchResult3 || {};
        return { artists: A(s.artist), albums: A(s.album), songs: A(s.song) };
      });
    },
    star: function (type, id, on) {
      var p = {}; p[type === 'album' ? 'albumId' : type === 'artist' ? 'artistId' : 'id'] = id;
      return call(on ? 'star' : 'unstar', p);
    },
    scrobble: function (id, submission) {
      return call('scrobble', { id: id, submission: submission ? 'true' : 'false', time: Date.now() }).catch(function () { });
    },
    lyrics: function (song) {
      // OpenSubsonic (Navidrome >= 0.50) liefert synchronisierte Lyrics
      return call('getLyricsBySongId', { id: song.id }).then(function (r) {
        var list = A(r.lyricsList && r.lyricsList.structuredLyrics);
        var synced = list.filter(function (l) { return l.synced; })[0];
        var pick = synced || list[0];
        if (!pick) return null;
        return { synced: !!pick.synced, lines: A(pick.line).map(function (l) { return { t: (l.start || 0) / 1000, text: l.value || '' }; }) };
      }).catch(function () {
        return call('getLyrics', { artist: song.artist, title: song.title }).then(function (r) {
          var v = r.lyrics && r.lyrics.value;
          if (!v) return null;
          return { synced: false, lines: v.split(/\r?\n/).map(function (t) { return { t: 0, text: t }; }) };
        }).catch(function () { return null; });
      });
    }
  };
})();
