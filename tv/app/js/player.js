/* Audio-Player mit Warteschlange, Shuffle, Repeat, Scrobbling und Resume, Radiosendern und Sleep-Timer */
var Player = (function () {
  'use strict';

  // Zwei Player, damit beim Überblenden der nächste Song schon anlaufen kann. audio = der, der gerade spielt.
  var players = [new Audio(), new Audio()];
  players.forEach(function (el) { el.preload = 'auto'; });
  var audio = players[0];

  var queue = [];        // Songs in Abspielreihenfolge
  var original = null;   // Originalreihenfolge, wenn Shuffle aktiv
  var index = -1;
  var shuffleOn = false;
  var repeat = 'off';    // off | all | one
  var offset = 0;        // bei transkodierten Streams: Startposition (timeOffset)
  var scrobbled = false;
  var errorStreak = 0;
  var pendingSeek = 0;
  var listeners = {};
  var context = null;    // woher die Warteschlange kommt: { kind: 'radio', name } beim Endlos-Radio
  var station = null;    // Radiosender, der gerade live läuft – die Warteschlange wartet so lange
  var stations = [], stationSeq = 0;
  var sleepAt = 0, sleepEnd = false, fade = 1;
  var master = U.store.get('volume', 1); // Lautstärke in der App – nur am PC einstellbar, am TV regelt das der Fernseher
  var xf = null, xfIn = 1, xfBroken = false, xfStarting = false; // laufendes Überblenden, Lautstärke des neuen Songs dabei

  function on(evt, fn) { (listeners[evt] = listeners[evt] || []).push(fn); }
  function emit(evt, data) { (listeners[evt] || []).forEach(function (fn) { try { fn(data); } catch (e) { console.error(e); } }); }

  function settings() { return App.settings(); }

  function current() { return queue[index] || null; }
  function duration() {
    if (rm) return station ? 0 : (rState && rState.duration) || (current() && current().duration) || 0;
    if (station) return 0;
    var s = current();
    if (s && s.duration) return s.duration;
    return isFinite(audio.duration) ? audio.duration : 0;
  }
  function position() { if (rm) return station ? 0 : rPos(); if (br && br.phase === 'handoff') return br.a.currentTime - br.t0; return station ? (audio.currentTime || 0) : offset + (audio.currentTime || 0); }
  function radioOn() { return typeof Radio !== 'undefined'; }
  function djPlays() { return !!context && context.kind === 'dj' && typeof DJ !== 'undefined'; }

  // Lautstärke angleichen (ReplayGain-Tags) und Ausblenden beim Sleep-Timer
  function levelFor(s) {
    var g = 1, mode = settings().leveling, rg = s && s.replayGain;
    if (!station && rg && mode && mode !== 'off') {
      var album = mode === 'album' && rg.albumGain != null;
      var gain = album ? rg.albumGain : rg.trackGain, peak = album ? rg.albumPeak : rg.trackPeak;
      if (gain != null) { g = Math.pow(10, gain / 20); if (peak) g = Math.min(g, 1 / peak); }
    }
    return g;
  }
  function applyVolume() {
    audio.volume = Math.max(0, Math.min(1, levelFor(current()) * fade * xfIn * master * dipValue()));
  }

  // ---- Überblenden am LG-TV: Der TV spielt immer nur einen Player. Startet der zweite, pausiert er den ersten
  // (am OLED65CX9LA nach 0,2 s gemessen), der Song bricht dann mitten in der Überblendzeit ab. Darum blendet der TV
  // den Song am Ende aus und den nächsten ein, nacheinander in einem Player: 'out' = läuft aus, 'wait' = der nächste lädt
  // (Stille), 'in' = er kommt hoch. Am PC (zwei Player möglich) bleibt das echte Überblenden.
  var dip = { mode: 'idle', t0: 0, dur: 1, keep: false, timer: 0 };
  function dipValue() {
    if (dip.mode === 'idle') return 1;
    var t = Math.max(0, Math.min(1, (Date.now() - dip.t0) / dip.dur));
    if (dip.mode === 'hold') return 0;                              // Element stumm, bis es zum Puffer passt
    if (dip.mode === 'bridge') return Math.cos(Math.PI / 2 * t);    // alter Song unter dem Puffer
    if (dip.mode === 'merge') return Math.sin(Math.PI / 2 * t);     // Element übernimmt vom Puffer
    var v = dip.mode === 'wait' ? 0 : dip.mode === 'out' ? 1 - t : t;
    return v * v; // quadratisch klingt gleichmäßiger als linear
  }
  function setDip(mode, secs) {
    clearInterval(dip.timer); dip.timer = 0;
    dip.mode = mode; dip.t0 = Date.now(); dip.dur = Math.max(100, (secs || 1) * 1000);
    if (mode === 'idle') dip.keep = false;
    else dip.timer = setInterval(function () {
      var age = Date.now() - dip.t0;
      if ((dip.mode === 'out' && age > dip.dur + 1500) || (dip.mode === 'wait' && age > 10000) || (dip.mode === 'in' && age >= dip.dur) ||
          (dip.mode === 'hold' && age > 15000) || (dip.mode === 'merge' && age >= dip.dur)) setDip('idle');
      else applyVolume();
    }, 100);
    applyVolume();
  }
  function maybeFadeOut() {
    var cf = crossfadeSecs();
    if (!cf || station || repeat === 'one' || sleepEnd || audio.paused) return;
    var d = duration(), left = d - position();
    if (br) { // unter dem Puffer ist der alte Song längst stumm: ist seine Länge erreicht, übernimmt der Player den nächsten
      if (br.phase === 'overlap' && d && left <= 0.15) { try { audio.pause(); } catch (e) { /* egal */ } bridgeAfterEnd(); }
      return;
    }
    if (!d || d < cf * 3) return;
    var ni = nextIdx();
    if (ni < 0) return; // letzter Song: normales Ende
    if (dip.mode === 'idle' && left <= cf + 25 && left > 0) prepareBridge(ni);
    if (dip.mode !== 'idle') return;
    if (prep && prep.id === queue[ni].id && prep.state === 'ready' && left <= cf && left >= 0.5 && startBridge(left, ni)) return;
    if (left > cf / 2 || left < 0.3) return;
    setDip('out', left); // der nächste Song ist nicht rechtzeitig vorgeladen: ausblenden und einblenden
  }

  // ---- Echtes Überblenden am TV: den Anfang des nächsten Songs lädt die App vorab und spielt ihn über Web Audio,
  // das neben dem Player läuft (LG empfiehlt Web Audio für Zusatzklänge). Der alte Song im Player blendet dabei aus.
  // Erst wenn er zu Ende ist, lädt der Player den nächsten Song an einer Stelle, die der Puffer dann schon erreicht hat,
  // und übernimmt dort mit einer kurzen Überblendung. Schon das Laden eines zweiten Players würde den ersten stoppen.
  var ac = null, prep = null, br = null, LEAD = 2.5;
  function acx() {
    if (!ac) { var C = window.AudioContext || window.webkitAudioContext; if (!C) return null; try { ac = new C(); } catch (e) { return null; } }
    if (ac.state === 'suspended' && ac.resume) ac.resume();
    return ac;
  }
  function nextIdx() { return index < queue.length - 1 ? index + 1 : (repeat === 'all' ? 0 : -1); }
  // Vorlauf von play() bis zum Ton: gelernt aus dem 'playing'-Ereignis, plus ein kleiner Vorhalt, weil die TV-Hardware den Ton
  // vermutlich etwas später ausgibt als das Ereignis kommt (Web Audio ist schneller). Nachstellbar: U.store 'xfBias' (Sekunden).
  function rawLat() { var v = +U.store.get('xfPlayLat', 0.1); return v >= 0 && v < 1 ? v : 0.1; }
  function biasLat() { var v = +U.store.get('xfBias', 0.08); return v >= 0 && v < 0.5 ? v : 0.08; }
  function playLat() { return rawLat() + biasLat(); }

  // Anfang des nächsten Songs holen (als MP3 vom Server, wie ihn der Player nachher auch bekommt) und dekodieren
  function prepareBridge(ni) {
    var nb = queue[ni], a = acx();
    if (!nb || !a || (prep && prep.id === nb.id) || !window.fetch || !window.AbortController) return;
    var p = prep = { id: nb.id, buf: null, state: 'loading' };
    var want = Math.ceil((crossfadeSecs() + 30) * 45000), ctl = new AbortController(), chunks = [], got = 0;
    function fail(e) { if (prep === p) p.state = 'fail'; console.warn('Überblenden: Vorladen fehlgeschlagen', e && e.message || e); }
    fetch(API.streamUrl(nb.id, { maxBitRate: 320, format: 'mp3' }), { signal: ctl.signal }).then(function (res) {
      if (!res.ok || !res.body) throw new Error('HTTP ' + res.status);
      var rd = res.body.getReader();
      return (function pump() {
        return rd.read().then(function (x) {
          if (x.done) return;
          chunks.push(x.value); got += x.value.length;
          if (got >= want) { ctl.abort(); return; }
          return pump();
        });
      })();
    }).then(function () {
      if (prep !== p) return;
      var bytes = new Uint8Array(got), o = 0, i;
      for (i = 0; i < chunks.length; i++) { bytes.set(chunks[i], o); o += chunks[i].length; }
      a.decodeAudioData(bytes.buffer, function (buf) { if (prep === p) { p.buf = buf; p.state = 'ready'; } }, fail);
    }).catch(fail);
  }

  function startBridge(left, ni) {
    var a = acx(), nb = queue[ni];
    if (!a || !nb || !prep || prep.id !== nb.id || prep.state !== 'ready') return false;
    var D = Math.max(1, left), base = Math.min(1, levelFor(nb) * master), t0 = a.currentTime + 0.05, i;
    var src = a.createBufferSource(), g = a.createGain(), up = new Float32Array(64);
    for (i = 0; i < 64; i++) up[i] = Math.sin(Math.PI / 2 * i / 63) * base;
    src.buffer = prep.buf; src.connect(g); g.connect(a.destination);
    g.gain.value = 0;
    g.gain.setValueCurveAtTime(up, t0, D);
    src.start(t0);
    var b = br = { id: nb.id, ni: ni, a: a, g: g, src: src, buf: prep.buf, base: base, t0: t0, D: D, phase: 'overlap', H: 0, retry: 0, armed: false, playing: false };
    prep = null;
    // Endet der Player nicht rechtzeitig von selbst (Länge im Tag weicht ab), geht es nach der Überblendzeit trotzdem weiter
    b.guard = setTimeout(function () { if (br === b && b.phase === 'overlap') { try { audio.pause(); } catch (e) { /* egal */ } bridgeAfterEnd(); } }, (D + 3) * 1000);
    setDip('bridge', D);
    console.log('Überblenden TV: Puffer ' + b.buf.duration.toFixed(1) + ' s, Überlappung ' + D.toFixed(1) + ' s');
    return true;
  }

  // Der alte Song ist zu Ende: der nächste ist jetzt dran, der Player lädt ihn weiter hinten im Song und bleibt stumm
  function bridgeAfterEnd() {
    var b = br;
    if (!b || b.phase !== 'overlap') return;
    clearTimeout(b.guard);
    b.phase = 'handoff';
    var cur = current();
    if (cur && radioOn()) Radio.listened(cur);
    if (cur && djPlays()) DJ.listened(cur);
    index = b.ni; scrobbled = false; pendingSeek = 0; learnFor = null; fallbackId = b.id;
    if (settings().scrobble) API.scrobble(b.id, false);
    emit('track', current()); emit('queue', queue); persist();
    if (context && context.kind === 'radio' && radioOn()) Radio.refillIfNeeded();
    if (djPlays()) DJ.refillIfNeeded();
    aimElement();
  }
  function aimElement() {
    var b = br;
    if (!b) return;
    clearTimeout(b.timer); clearTimeout(b.watch);
    b.armed = false;
    b.H = Math.ceil(b.a.currentTime - b.t0 + LEAD);
    if (b.retry > 2 || b.H + 4 > b.buf.duration) { bridgeFail(); return; }
    offset = b.H; pendingSeek = 0;
    setDip('hold', 15);
    audio.src = API.streamUrl(b.id, { maxBitRate: 320, format: 'mp3', offset: b.H });
    b.watch = setTimeout(function () { if (br === b && !b.playing) { console.warn('Überblenden: Übergabe hängt'); bridgeFail(); } }, 12000);
  }
  // Das Element hat den Song geladen: gestartet wird es erst, wenn der Puffer fast an seiner Stelle ist
  function bridgeCanPlay() {
    var b = br;
    if (!b || b.phase !== 'handoff' || b.armed) return;
    b.armed = true;
    var wait = b.H - (b.a.currentTime - b.t0) - playLat();
    if (wait < -0.1) { b.retry++; console.warn('Überblenden: Player zu spät (' + wait.toFixed(2) + ' s), neuer Anlauf'); aimElement(); return; }
    b.timer = setTimeout(function () {
      if (br !== b) return;
      var p = audio.play();
      if (p && p.catch) p.catch(function (e) { console.warn('play()', e); });
    }, Math.max(0, wait * 1000));
  }
  // Das Element läuft: Puffer runter, Element hoch, 0,3 s lang. Wie weit der Start vom Plan abwich, merkt sich die App.
  function bridgePlaying() {
    var b = br;
    if (!b || b.phase !== 'handoff' || !b.armed || b.playing) return;
    b.playing = true; clearTimeout(b.watch);
    var tt = b.a.currentTime, eps = (tt - b.t0) - (b.H + (audio.currentTime || 0)), i, down = new Float32Array(64);
    U.store.set('xfPlayLat', Math.max(0, Math.min(0.8, rawLat() + eps + biasLat())));
    for (i = 0; i < 64; i++) down[i] = Math.cos(Math.PI / 2 * i / 63) * b.base;
    b.g.gain.cancelScheduledValues(tt);
    b.g.gain.setValueAtTime(b.base, tt);
    b.g.gain.setValueCurveAtTime(down, tt, 0.4);
    setDip('merge', 0.4);
    b.phase = 'merge';
    b.end = setTimeout(endBridge, 600);
    console.log('Überblenden TV: Übergabe bei ' + b.H + ' s, Versatz ' + Math.round(eps * 1000) + ' ms (Vorhalt ' + Math.round(biasLat() * 1000) + ' ms)');
  }
  function endBridge() {
    var b = br;
    if (!b) return;
    clearTimeout(b.guard); clearTimeout(b.timer); clearTimeout(b.watch); clearTimeout(b.end);
    try { b.src.stop(); } catch (e) { /* egal */ }
    try { b.g.disconnect(); } catch (e) { /* egal */ }
    br = null;
  }
  // Pause, Spulen, Überspringen: die Brücke ist vorbei, der Player macht normal weiter
  function cancelBridge() { endBridge(); }
  function bridgeFail() {
    var b = br;
    if (!b) return;
    endBridge();
    setDip('idle');
    // an der Stelle weiterspielen, an der der Puffer war (kurze Stille statt den Anfang des Songs noch einmal)
    var at = Math.max(0, Math.ceil(b.a.currentTime - b.t0 + 1));
    console.warn('Überblenden: Notfall, der Song läuft bei ' + at + ' s weiter');
    fallbackId = b.id;
    load(at, true);
  }

  function clear(el) {
    el.pause();
    el.removeAttribute('src');
    try { el.load(); } catch (e) { /* egal */ }
  }

  // ---- Überblenden: kurz vor Songende startet der nächste leise im zweiten Player, der alte wird leiser
  function crossfadeSecs() { return +settings().crossfade || 0; }

  function maybeCrossfade() {
    if (!U.desktop) { maybeFadeOut(); return; }
    var cf = crossfadeSecs();
    if (!cf || xf || xfBroken || station || repeat === 'one' || sleepEnd || audio.paused) return;
    var d = duration(), left = d - position();
    if (!d || d < cf * 3 || left > cf || left < 0.5) return;
    var ni = index < queue.length - 1 ? index + 1 : (repeat === 'all' ? 0 : -1);
    if (ni < 0) return;
    var cur = current();
    if (cur && radioOn()) Radio.listened(cur);
    if (cur && djPlays()) DJ.listened(cur);
    var from = audio, fromIndex = index, fromVol = from.volume, t0 = Date.now(), started = false;
    audio = players[from === players[0] ? 1 : 0];
    index = ni;
    xfIn = 0;
    xfStarting = true;
    load(0, true);
    xfStarting = false;
    emit('queue', queue);
    var mine = xf = {
      from: from,
      timer: setInterval(function () {
        var t = Math.min(1, (Date.now() - t0) / (cf * 1000));
        if (!started && !audio.paused && audio.currentTime > 0) started = true;
        // Der Fernseher bekommt den zweiten Player nicht zum Laufen: zurück zum normalen Songwechsel
        if (!started && Date.now() - t0 > (fellBack() ? 12000 : 4000)) { giveUp(); return; }
        xfIn = started ? t : 0;
        applyVolume();
        from.volume = Math.max(0, fromVol * (1 - t));
        if (t >= 1 && started) stopFade();
      }, 100)
    };
    function giveUp() {
      if (xf !== mine) return;
      clearInterval(mine.timer); xf = null; xfIn = 1; xfBroken = true;
      clear(audio);
      audio = from; index = fromIndex;
      from.volume = fromVol;
      emit('track', current()); emit('queue', queue); emit('state');
      console.warn('Überblenden geht hier nicht – normaler Songwechsel');
    }
  }

  // Überblenden sofort beenden: der alte Song verstummt, der neue läuft mit voller Lautstärke
  function stopFade() {
    if (br) cancelBridge();
    if (dip.mode !== 'idle' && !dip.keep) setDip('idle'); // Pause, Spulen, Überspringen: sofort wieder volle Lautstärke
    if (!xf) return;
    clearInterval(xf.timer);
    clear(xf.from);
    xf = null; xfIn = 1;
    applyVolume();
  }
  // Song, den der TV nicht im Original abspielt: er läuft ab dann als MP3 vom Server (auch beim Spulen und Neuladen)
  var fallbackId = null;
  function fellBack() { var s = current(); return !!s && (fallbackId === s.id || knownBad(s)); }

  // Welche Formate dieser TV nicht im Original abspielt, merkt er sich: Songs davon kommen gleich als MP3, ohne Wartezeit.
  // Erst nach zwei bestätigten Fällen (das Original hing, MP3 lief) – ein Netzwerkaussetzer soll kein Format sperren.
  function fmtKey(s) { return (s.suffix || '').toLowerCase() + ((+s.bitDepth > 16 || +s.samplingRate > 48000) ? '|hd' : ''); }
  function badFormats() { return U.store.get('badFormats', {}) || {}; }
  function knownBad(s) { return !!s && !!s.suffix && fmtKey(s).indexOf('mp3') !== 0 && (badFormats()[fmtKey(s)] || 0) >= 2; }
  var learnFor = null; // Song-ID: läuft er jetzt als MP3, nachdem das Original hing, ist das Format als schlecht bestätigt
  function learn(s) {
    if (!s || !s.suffix || fmtKey(s).indexOf('mp3') === 0) return;
    var b = badFormats(), k = fmtKey(s);
    b[k] = (b[k] || 0) + 1;
    U.store.set('badFormats', b);
    // Neutral gehalten, ohne Worte: so sieht man, welches Format hängt
    U.toast(k.toUpperCase().replace('|HD', ' (Hi-Res)') + ' → MP3', 4000);
  }
  function transcoding() { return !!settings().maxBitRate || fellBack(); }
  // Position zum Weitermachen: nur kurz gemerkt (Anruf, kurze Pause), nicht nach Stunden oder Tagen
  var RESUME_MS = 30 * 60 * 1000;
  var OFFER_MS = 3 * 60 * 60 * 1000; // so lange gilt die Warteschlange eines anderen Geräts als Angebot
  function savePos(v, at) { U.ustore.set('pos', v); U.ustore.set('posAt', at || Date.now()); }
  function freshPos() { return Date.now() - (U.ustore.get('posAt', 0) || 0) < RESUME_MS ? (U.ustore.get('pos', 0) || 0) : 0; }

  // Der TV spielt den Song im Original nicht: einmal als MP3 vom Server, an derselben Stelle. false, wenn das schon versucht wurde.
  function retryAsMp3() {
    var cur = current();
    if (!cur || station || transcoding()) return false;
    fallbackId = cur.id;
    learnFor = cur.id;
    var at = Math.floor(pendingSeek || position());
    offset = at > 1 ? at : 0;
    pendingSeek = 0;
    audio.src = API.streamUrl(cur.id, { maxBitRate: 320, format: 'mp3', offset: offset });
    var q = audio.play();
    if (q && q.catch) q.catch(function () { /* egal */ });
    emit('state');
    return true;
  }

  // Manche Formate meldet der TV nicht als Fehler, er bleibt einfach stumm: kommt nach 5 s kein Ton, geht es als MP3 weiter
  var silentWatch = null;
  function watchStart(el, id) {
    clearTimeout(silentWatch);
    silentWatch = setTimeout(function () {
      var s = current();
      if (el !== audio || station || !s || s.id !== id || transcoding()) return;
      if ((el.currentTime || 0) > 0.5 || (el.paused && el.readyState >= 2)) return; // läuft, oder wurde angehalten
      console.warn('Kein Ton nach 5 s – als MP3 neu versucht');
      retryAsMp3();
    }, 5000);
  }

  function load(startAt, autoplay) {
    var s = current();
    if (!s) return;
    if (!xfStarting) stopFade();
    // Der Song lief am TV bis zum Ende aus: der nächste bleibt stumm, bis er läuft, und kommt dann hoch
    if (dip.keep) { dip.keep = false; if (autoplay !== false && dip.mode === 'out') setDip('wait'); else setDip('idle'); }
    if (station) { station = null; stationSeq++; }
    scrobbled = false;
    offset = 0;
    pendingSeek = 0;
    if (fallbackId && fallbackId !== s.id) fallbackId = null;
    var opts = { maxBitRate: settings().maxBitRate, format: settings().format };
    if (fellBack() && !opts.maxBitRate) { opts.maxBitRate = 320; opts.format = 'mp3'; }
    if (startAt > 1) {
      if (transcoding()) { opts.offset = startAt; offset = Math.floor(startAt); }
      else pendingSeek = startAt;
    }
    audio.src = API.streamUrl(s.id, opts);
    applyVolume();
    if (autoplay !== false) {
      watchStart(audio, s.id);
      var p = audio.play();
      if (p && p.catch) p.catch(function (e) { console.warn('play()', e); });
    }
    if (settings().scrobble && autoplay !== false) API.scrobble(s.id, false);
    emit('track', s);
    persist();
    if (context && context.kind === 'radio' && radioOn()) Radio.refillIfNeeded();
    if (autoplay !== false && djPlays()) DJ.refillIfNeeded();
  }

  function playList(songs, start, opts) {
    if (rm) return rPlayList(songs, start, opts);
    songs = (songs || []).filter(Boolean);
    if (!songs.length) { U.toast(T('Keine Songs zum Abspielen')); return; }
    start = start || 0;
    context = (opts && opts.context) || null;
    shuffleOn = !!(opts && opts.shuffle);
    if (shuffleOn) {
      var first = (opts && opts.shuffle && start === 0 && !(opts && opts.keepStart)) ? null : songs[start];
      original = songs.slice();
      var rest = U.shuffle(songs.filter(function (s, i) { return !first || i !== start; }));
      queue = first ? [first].concat(rest) : rest;
      index = 0;
    } else {
      original = null;
      queue = songs.slice();
      index = Math.min(start, queue.length - 1);
    }
    errorStreak = 0;
    load((opts && opts.at) || 0, true); // vom iPhone herübergeholt: an derselben Stelle weiter
    emit('queue', queue);
    emit('mode');
  }

  function playNext(songs) {
    songs = U.asArray(songs);
    if (rm) return rAdd('playNext', songs);
    if (!queue.length) return playList(songs, 0);
    Array.prototype.splice.apply(queue, [index + 1, 0].concat(songs));
    if (original) original = original.concat(songs);
    emit('queue', queue); persist();
    U.toast(T.n(songs.length, 'Wird als Nächstes gespielt', '{n} Songs als Nächstes'));
  }

  function enqueue(songs, quiet) {
    songs = U.asArray(songs);
    if (rm) return rAdd('enqueue', songs);
    if (!queue.length) return playList(songs, 0);
    queue = queue.concat(songs);
    if (original) original = original.concat(songs);
    emit('queue', queue); persist();
    if (!quiet) U.toast(T.n(songs.length, 'Zur Warteschlange hinzugefügt', '{n} Songs hinzugefügt'));
  }

  // Der DJ überlegt es sich anders: alles nach dem laufenden Song macht Platz für songs.
  // Mit ctx übernimmt er eine Warteschlange, die von woanders kam.
  function replaceUpNext(songs, ctx) {
    songs = U.asArray(songs);
    if (!queue.length || index < 0) return playList(songs, 0, { context: ctx || context });
    queue = queue.slice(0, index + 1).concat(songs);
    original = null;
    shuffleOn = false;
    if (ctx) context = ctx;
    emit('queue', queue); emit('mode'); persist();
  }

  // Einen kommenden Song an eine andere Stelle schieben (beide Stellen nach dem laufenden Song)
  function move(from, to) {
    if (rm) return rNo();
    if (from === to || from <= index || to <= index || from >= queue.length || to >= queue.length) return;
    queue.splice(to, 0, queue.splice(from, 1)[0]);
    emit('queue', queue); persist();
  }

  function jump(i) {
    if (i < 0 || i >= queue.length) return;
    if (rm) return rSend({ cmd: 'jump', index: i + rOffset });
    index = i; load(0, true); emit('queue', queue);
  }

  function removeAt(i) {
    if (i < 0 || i >= queue.length) return;
    if (rm) return rNo();
    var wasCurrent = i === index;
    var removed = queue.splice(i, 1)[0];
    if (original) original = original.filter(function (s) { return s !== removed; });
    if (i < index) index--;
    if (wasCurrent) {
      if (!queue.length) { stop(); }
      else { if (index >= queue.length) index = 0; load(0, !audio.paused); }
    }
    emit('queue', queue); persist();
  }

  function next(auto) {
    if (rm) return rSend({ cmd: 'next' });
    if (station) { switchStation(1); return; }
    if (!queue.length) return;
    var cur = current();
    // Das Radio lernt mit: zu Ende gehört = mehr davon, früh übersprungen = weniger
    if (cur && radioOn()) {
      if (auto) Radio.listened(cur);
      else if (context && context.kind === 'radio' && position() < 30) Radio.skipped(cur);
    }
    // Der DJ ebenso: was lief, kommt nicht gleich wieder, und übersprungene Künstler meidet er
    if (cur && djPlays()) { if (auto) DJ.listened(cur); else if (position() < 30) DJ.skipped(cur); }
    if (auto && sleepEnd) {
      sleepDone();
      if (index < queue.length - 1) { index++; load(0, false); emit('queue', queue); }
      return;
    }
    if (auto && repeat === 'one') { load(0, true); return; }
    if (index < queue.length - 1) index++;
    else if (repeat === 'all' || !auto) index = 0;
    else { audio.pause(); emit('state'); autoplay(); return; }
    load(0, true);
    emit('queue', queue);
  }

  // Warteschlange zu Ende: mit ähnlichen Songs weiterspielen (Einstellung „Autoplay“)
  function autoplay() {
    if (!settings().autoplay || !radioOn()) return;
    var at = queue.length;
    Radio.continueAfter(queue).then(function (songs) {
      if (!songs.length || station || queue.length !== at || index !== at - 1 || !audio.paused) return;
      queue = queue.concat(songs);
      if (original) original = original.concat(songs);
      index = at;
      context = { kind: 'radio', name: 'Autoplay' };
      load(0, true);
      emit('queue', queue); emit('mode');
    });
  }

  function prev() {
    if (rm) return rSend({ cmd: 'prev' });
    if (station) { switchStation(-1); return; }
    if (!queue.length) return;
    if (position() > 3) { seek(0); return; }
    index = index > 0 ? index - 1 : (repeat === 'all' ? queue.length - 1 : 0);
    load(0, true);
    emit('queue', queue);
  }

  function toggle() {
    if (rm) return rPlayPause(!rPlaying());
    stopFade();
    if (station) { if (audio.paused) playStation(station); else audio.pause(); return; }
    if (!current()) return;
    if (!audio.src) { load(freshPos(), true); return; }
    if (audio.paused) audio.play(); else audio.pause();
  }
  function play() { if (rm) { if (!rPlaying()) rPlayPause(true); return; } if (audio.paused) toggle(); }
  function pause() { if (rm) { if (rPlaying()) rPlayPause(false); return; } stopFade(); if (!audio.paused) audio.pause(); }

  function stop() {
    stopFade();
    station = null; stationSeq++; context = null;
    audio.pause();
    audio.removeAttribute('src');
    try { audio.load(); } catch (e) { /* egal */ }
    queue = []; original = null; index = -1;
    emit('track', null); emit('queue', queue); emit('state');
    persist();
  }

  function seek(sec) {
    if (rm) return rSeek(sec);
    if (station) return;
    stopFade();
    var d = duration();
    sec = Math.max(0, d ? Math.min(sec, d - 1) : sec);
    if (transcoding()) {
      var wasPaused = audio.paused;
      load(sec, !wasPaused);
    } else {
      try { audio.currentTime = sec; } catch (e) { /* noch nicht geladen */ }
    }
    emit('time');
  }
  function seekBy(delta) { seek(position() + delta); }

  function setShuffle(on) {
    if (on === shuffleOn) return;
    if (rm) { shuffleOn = on; emit('mode'); return rSend({ cmd: 'shuffle', on: on }); }
    var cur = current();
    shuffleOn = on;
    if (on) {
      original = queue.slice();
      var rest = U.shuffle(queue.filter(function (s, i) { return i !== index; }));
      queue = cur ? [cur].concat(rest) : rest;
      index = 0;
    } else if (original) {
      queue = original;
      original = null;
      index = Math.max(0, queue.indexOf(cur));
    }
    emit('queue', queue); emit('mode'); persist();
  }

  function cycleRepeat() {
    if (rm) { repeat = repeat === 'off' ? 'all' : repeat === 'all' ? 'one' : 'off'; emit('mode'); return rSend({ cmd: 'repeat', mode: repeat }); }
    repeat = repeat === 'off' ? 'all' : repeat === 'all' ? 'one' : 'off';
    emit('mode'); persist();
  }

  function setStarred(song, on) {
    if (rm) rSend({ cmd: 'star', id: song.id, on: !!on });
    queue.forEach(function (s) { if (s.id === song.id) s.starred = on ? new Date().toISOString() : undefined; });
    if (on && radioOn()) Radio.liked(song);
    emit('track', current());
  }

  // ---- Radiosender (live): die Warteschlange bleibt stehen und geht danach an derselben Stelle weiter
  // .m3u/.pls sind nur Listen mit der eigentlichen Adresse
  function resolveStream(url) {
    if (!/\.(m3u|pls)(\?|$)/i.test(url)) return Promise.resolve(url);
    return fetch(url).then(function (r) { return r.text(); }).then(function (t) {
      var m = t.match(/^File\d+=(.+)$/mi) || t.match(/^(https?:\/\/\S+)/m);
      return m ? m[1].trim() : url;
    }).catch(function () { return url; });
  }

  function playStation(st, list) {
    if (rm) return rSend({ cmd: 'station', station: slim(st), list: list ? list.slice(0, 60).map(slim) : null });
    if (list) stations = list;
    if (!station && audio.src && current()) savePos(Math.floor(position()));
    stopFade();
    station = st; offset = 0; pendingSeek = 0; errorStreak = 0;
    var my = ++stationSeq;
    audio.pause();
    fade = sleepAt ? fade : 1;
    emit('track', current()); emit('state');
    resolveStream(st.streamUrl).then(function (u) {
      if (my !== stationSeq) return;
      audio.src = u;
      applyVolume();
      var p = audio.play();
      if (p && p.catch) p.catch(function (e) { console.warn('play()', e); });
    });
  }

  // Zurück zur Warteschlange – pausiert an der Stelle, an der sie unterbrochen wurde
  function stopStation() {
    if (rm) return rSend({ cmd: 'stopStation' });
    if (!station) return;
    station = null; stationSeq++;
    audio.pause();
    audio.removeAttribute('src');
    try { audio.load(); } catch (e) { /* egal */ }
    applyVolume();
    emit('track', current()); emit('queue', queue); emit('state');
  }

  function switchStation(d) {
    var n = stations.length, i = -1;
    for (var k = 0; k < n; k++) if (stations[k].id === station.id) i = k;
    if (n < 2 || i < 0) return;
    playStation(stations[(i + d + n) % n]);
  }

  // ---- Sleep-Timer: min > 0 Minuten, -1 = am Ende des Songs, 0 = aus
  function setSleep(min) {
    sleepAt = min > 0 ? Date.now() + min * 60000 : 0;
    sleepEnd = min === -1;
    fade = 1; applyVolume();
    emit('sleep');
  }
  function sleepDone() {
    stopFade();
    sleepAt = 0; sleepEnd = false;
    audio.pause();
    fade = 1; applyVolume();
    emit('sleep'); emit('state');
    U.toast(T('Sleep-Timer: Wiedergabe angehalten'));
  }
  setInterval(function () {
    if (!sleepAt) return;
    var left = sleepAt - Date.now();
    if (left <= 0) { sleepDone(); return; }
    // Die letzten 15 Sekunden langsam leiser werden
    if (left < 15000) { fade = left / 15000; applyVolume(); }
  }, 500);

  // ---- Persistenz (Warteschlange beim nächsten Start wiederherstellen)
  var persistTimer;
  function persistNow(quiet) {
    clearTimeout(persistTimer);
    if (rm) return; // was hier steht, gehört dem anderen Gerät
    // quiet: übernommene Warteschlange – der Server hat sie schon, nicht zurückschicken
    if (!quiet) { U.ustore.set('changed', Date.now()); syncRemote(); }
    U.ustore.set('queue', queue.slice(0, 1000));
    U.ustore.set('index', index);
    U.ustore.set('repeat', repeat);
    U.ustore.set('shuffle', shuffleOn);
    U.ustore.set('context', context);
    // Ohne geladenen Stream ist die Position 0 – gespeicherte Position dann nicht überschreiben
    if (audio.src && !station) savePos(Math.floor(position()));
  }
  function persist() {
    if (rm) return;
    clearTimeout(persistTimer);
    persistTimer = setTimeout(persistNow, 300);
  }

  // ---- Gemeinsame Warteschlange auf dem Server (Weiterhören auf dem iPhone und umgekehrt)
  var remoteSig = '', remoteAt = 0;
  // Sofort, wenn sich Titel oder Warteschlange geändert haben, sonst (nur Position) höchstens alle 30 s
  function syncRemote(force) {
    var s = current();
    if (!s || station) return;
    var start = Math.max(0, index - 100);
    var ids = queue.slice(start, start + 500).map(function (x) { return x.id; });
    var sig = ids.join(',') + '|' + s.id;
    if (!force && sig === remoteSig && Date.now() - remoteAt < 30000) return;
    remoteSig = sig; remoteAt = Date.now();
    API.savePlayQueue(ids, s.id, audio.src ? position() : freshPos());
  }

  function parseDate(iso) {
    // Navidrome liefert Nanosekunden – älteren Browsern reichen Millisekunden
    return Date.parse(String(iso || '').replace(/(\.\d{3})\d+/, '$1')) || 0;
  }

  // Neuere Warteschlange von einem anderen Gerät? Ohne eigene Warteschlange still übernehmen (pausiert),
  // sonst als Angebot zurückgeben – aber nur, wenn hier gerade nichts läuft.
  function checkRemote() {
    if (!audio.paused) return Promise.resolve(null);
    return API.playQueue().then(function (r) {
      var songs = r && U.asArray(r.entry);
      if (!songs || !songs.length || !audio.paused || !r.changedBy || r.changedBy === API.client) return null;
      if (parseDate(r.changed) <= (U.ustore.get('changed', 0) || 0) + 10000) return null;
      if (r.changed === U.ustore.get('queueDismissed', '')) return null;
      // Eine Warteschlange von vor Stunden oder Tagen ist kein „Weiterhören“ mehr – heute lief dort vielleicht nur ein Hörbuch
      var age = Date.now() - parseDate(r.changed);
      if (age > OFFER_MS && queue.length) return null; // ohne eigene Warteschlange wird sie still (pausiert) übernommen
      var i = 0;
      songs.forEach(function (x, k) { if (x.id === r.current && !i) i = k; });
      var offer = { songs: songs, index: i, pos: age > RESUME_MS ? 0 : (r.position || 0) / 1000, changed: r.changed,
        device: { 'Tonalo-iOS': 'iPhone', 'Tonalo-Windows': 'PC', 'Tonalo': 'TV' }[r.changedBy] || r.changedBy };
      if (!queue.length) { take(offer, false); return null; }
      var cur = current();
      if (cur && cur.id === songs[i].id && Math.abs(position() - offer.pos) < 15) return null;
      return offer;
    });
  }

  function take(offer, autoplay) {
    queue = offer.songs.slice(); original = null; shuffleOn = false; index = offer.index; context = null;
    errorStreak = 0;
    if (autoplay) {
      load(offer.pos, true);
    } else {
      audio.pause();
      audio.removeAttribute('src');
      try { audio.load(); } catch (e) { /* egal */ }
      savePos(Math.floor(offer.pos), parseDate(offer.changed) || Date.now());
      U.ustore.set('changed', parseDate(offer.changed));
      persistNow(true);
      emit('track', current());
    }
    emit('queue', queue); emit('mode'); emit('state');
  }

  function dismissRemote(offer) { U.ustore.set('queueDismissed', offer.changed); }

  // Beim Benutzerwechsel: Zustand des alten Kontos sichern und Player leeren (ohne gespeicherte Daten zu löschen)
  function detach() {
    if (rm) leaveRemote(true);
    if (queue.length) persistNow(true);
    remoteSig = '';
    clearTimeout(persistTimer);
    stopFade();
    audio.pause();
    audio.removeAttribute('src');
    try { audio.load(); } catch (e) { /* egal */ }
    queue = []; original = null; index = -1; offset = 0;
    station = null; stationSeq++; context = null; setSleep(0);
    emit('track', null); emit('queue', queue); emit('state');
  }

  function restore() {
    if (rm) return;
    queue = U.ustore.get('queue', []) || [];
    index = U.ustore.get('index', -1);
    repeat = U.ustore.get('repeat', 'off');
    shuffleOn = U.ustore.get('shuffle', false);
    context = U.ustore.get('context', null);
    if (index >= queue.length) index = queue.length ? 0 : -1;
    if (current()) { emit('track', current()); emit('queue', queue); emit('mode'); }
  }

  // ---- Am PC: ein anderes Gerät steuern (der Fernseher, ein anderer Computer) – wie das iPhone.
  // Solange das läuft, spielt hier nichts: Warteschlange, Titel, Zeit und Knöpfe zeigen den Stand dort, und alles,
  // was hier gedrückt oder gestartet wird, geht dorthin. remote.js liefert den Stand und nimmt die Befehle an.
  var rm = null;            // { name, send(cmd), same() } – gesetzt, solange ein Gerät gesteuert wird
  var rState = null, rAt = 0, rOffset = 0, rSig = '', rTimer = null, rSaved = null;

  function rPlaying() { return !!rState && !!rState.playing; }
  // Die Zeit dort rechnet hier weiter, ohne dass beide Uhren stimmen müssen: „at“ und „sent“ sind beide die Uhr des anderen
  function rPos() {
    if (!rState) return 0;
    var base = (+rState.position || 0) + ((+rState.sent || 0) - (+rState.at || 0)) / 1000;
    return Math.max(0, base + (rState.playing ? (Date.now() - rAt) / 1000 : 0));
  }
  function rSend(cmd) { if (rm) rm.send(cmd); }
  function rNo() { U.toast(T('Das geht nur direkt am Gerät.')); }

  // Nur das, was der andere zum Abspielen braucht (wie am iPhone), nicht das ganze Objekt
  function slim(o) {
    var out = {};
    Object.keys(o || {}).forEach(function (k) {
      var v = o[k];
      if (typeof v === 'string' || typeof v === 'boolean' || (typeof v === 'number' && isFinite(v))) out[k] = v;
      else if (k === 'replayGain' && v && typeof v === 'object') out[k] = v;
    });
    return out;
  }

  function rOk() {
    if (rm && rm.same()) return true;
    U.toast(T('{name} ist mit einem anderen Konto angemeldet. Von hier lässt sich nichts hinschicken.', { name: rm ? rm.name : '' }), 5000);
    return false;
  }

  function rPlayList(songs, start, opts) {
    songs = (songs || []).filter(Boolean);
    if (!songs.length) { U.toast(T('Keine Songs zum Abspielen')); return; }
    if (!rOk()) return;
    start = Math.max(0, Math.min(start || 0, songs.length - 1));
    var from = Math.max(0, start - 20); // eine lange Liste geht nicht auf einmal: ein Fenster um den Start
    var list = songs.slice(from, from + 200);
    var ctx = opts && opts.context;
    rSend({ cmd: 'play', songs: list.map(slim), index: start - from, shuffle: !!(opts && opts.shuffle),
      context: ctx ? { kind: ctx.kind, name: ctx.name, id: ctx.id } : null, position: (opts && opts.at) || 0 });
    U.toast(T('Wird auf {name} gespielt', { name: rm.name }));
  }

  function rAdd(cmd, songs) {
    if (!rOk()) return;
    rSend({ cmd: cmd, songs: songs.slice(0, 200).map(slim) });
    U.toast(T('Wird auf {name} gespielt', { name: rm.name }));
  }

  // Die Anzeige sofort ändern, ohne auf den Stand von dort zu warten – der kommt gleich und stellt es richtig
  function rPlayPause(play) {
    if (rState) { rState.position = rPos(); rState.at = rState.sent = rAt = Date.now(); rState.playing = play; }
    emit('state');
    rSend({ cmd: 'play-pause', playing: play });
  }
  function rSeek(sec) {
    var d = duration();
    sec = Math.max(0, d ? Math.min(sec, d - 1) : sec);
    if (rState) { rState.position = sec; rState.at = rState.sent = rAt = Date.now(); }
    emit('time');
    rSend({ cmd: 'seek', position: sec });
  }

  // Der Stand des anderen Geräts: Warteschlange, Titel, Läuft/Pause, Zufall, Wiederholen
  function applyRemote(s, at) {
    if (!rm) return;
    var before = current() ? current().id : null, beforeStation = station ? station.id : null;
    rState = s || null;
    rAt = at || Date.now();
    var active = !!s && !!s.active;
    queue = active && s.queue ? s.queue : [];
    index = active && queue.length ? (s.index >= 0 ? s.index : 0) : -1;
    rOffset = active ? (+s.offset || 0) : 0;
    original = null;
    var sh = active && !!s.shuffle, rp = active && s.repeat ? s.repeat : 'off', ctx = active ? s.context || null : null;
    var modeChanged = sh !== shuffleOn || rp !== repeat || JSON.stringify(ctx) !== JSON.stringify(context);
    shuffleOn = sh; repeat = rp; context = ctx;
    station = active && s.station ? s.station : null;
    var cur = current();
    if ((cur ? cur.id : null) !== before || (station ? station.id : null) !== beforeStation) emit('track', cur);
    var sig = index + '|' + queue.map(function (x) { return x.id; }).join(',');
    if (sig !== rSig) { rSig = sig; emit('queue', queue); }
    if (modeChanged) emit('mode');
    emit('state'); emit('time');
  }

  function attachRemote(opts) {
    if (rm) leaveRemote(true);
    // Was hier lief, bleibt stehen und ist nachher wieder da – pausiert
    rSaved = { queue: queue, original: original, index: index, shuffle: shuffleOn, repeat: repeat, context: context, station: station, pos: audio.src && !station ? position() : 0 };
    if (rSaved.pos) savePos(Math.floor(rSaved.pos));
    stopFade(); stationSeq++;
    players.forEach(clear);
    rm = opts; rState = null; rSig = ''; rOffset = 0;
    queue = []; original = null; index = -1; station = null; context = null;
    clearInterval(rTimer);
    rTimer = setInterval(function () { if (rm && rState && rState.playing) emit('time'); }, 500);
    emit('track', null); emit('queue', queue); emit('mode'); emit('state');
  }

  function leaveRemote(quiet) {
    if (!rm) return;
    clearInterval(rTimer); rTimer = null;
    rm = null; rState = null; rSig = '';
    var b = rSaved; rSaved = null;
    queue = b ? b.queue : []; original = b ? b.original : null; index = b ? b.index : -1;
    shuffleOn = b ? b.shuffle : false; repeat = b ? b.repeat : 'off'; context = b ? b.context : null; station = null;
    if (!quiet) { emit('track', current()); emit('queue', queue); emit('mode'); emit('state'); emit('time'); }
  }

  // ---- Audio-Events (nur vom Player, der gerade spielt – der ausblendende zählt nicht mehr)
  players.forEach(function (el) {
    function listen(name, fn) { el.addEventListener(name, function () { if (el === audio) fn(); }); }
    listen('loadedmetadata', function () {
      if (pendingSeek) { try { audio.currentTime = pendingSeek; } catch (e) { /* egal */ } pendingSeek = 0; }
    });
    listen('playing', function () {
      errorStreak = 0;
      if (dip.mode === 'wait') setDip('in', crossfadeSecs() / 2);
      bridgePlaying();
      emit('state');
    });
    listen('pause', function () {
      emit('state');
      if (station) return;
      persist(); setTimeout(function () { syncRemote(true); }, 400);
    });
    listen('waiting', function () { emit('state'); });
    listen('canplay', function () { bridgeCanPlay(); });
    listen('ended', function () {
      if (station) { emit('state'); return; }
      if (br && br.phase === 'overlap') { bridgeAfterEnd(); return; }
      if (dip.mode === 'out') dip.keep = true;
      next(true);
    });
    listen('timeupdate', function () {
      emit('time');
      if (station) return;
      if (learnFor && audio.currentTime > 1) { var ls = current(); if (ls && ls.id === learnFor) learn(ls); learnFor = null; }
      maybeCrossfade();
      var s = current(), d = duration(), p = position();
      if (s && !scrobbled && settings().scrobble && d && (p > d / 2 || p > 240)) {
        scrobbled = true;
        API.scrobble(s.id, true);
      }
      if (Math.floor(p) % 5 === 0) persist();
    });
    listen('error', function () {
      if (station) { U.toast(T('Dieser Sender kann gerade nicht abgespielt werden.')); emit('state'); return; }
      if (!audio.src || !current()) return;
      // Ein Format, das der TV nicht abspielt (z. B. ALAC, Opus): einmal vom Server als MP3 umwandeln lassen, an derselben Stelle
      if (retryAsMp3()) return;
      errorStreak++;
      var code = audio.error ? audio.error.code : '?';
      U.toast(T(errorStreak < 4 ? 'Wiedergabefehler ({code}) – Song wird übersprungen' : 'Wiedergabefehler ({code}) – gestoppt', { code: code }));
      if (errorStreak < 4 && queue.length > 1) setTimeout(function () { next(true); }, 1200);
      else { try { audio.pause(); } catch (e) { /* egal */ } }
      emit('state');
    });
  });

  return {
    on: on,
    // Am PC: die Adresse des Servers hat gewechselt (Heimnetz verlassen) – der laufende Song kommt von der alten und reißt ab
    attachRemote: attachRemote,
    applyRemote: applyRemote,
    detachRemote: function () { leaveRemote(false); },
    remoteActive: function () { return !!rm; },
    addressChanged: function () {
      if (rm) return;
      var s = current();
      if (!s || station || !audio.src || audio.src.indexOf(API.base() + '/') === 0) return;
      load(position(), !audio.paused);
    },
    playList: playList,
    playNext: playNext,
    enqueue: enqueue,
    move: move,
    jump: jump,
    removeAt: removeAt,
    next: function () { next(false); },
    prev: prev,
    toggle: toggle,
    play: play,
    pause: pause,
    stop: stop,
    seek: seek,
    seekBy: seekBy,
    setShuffle: setShuffle,
    cycleRepeat: cycleRepeat,
    setStarred: setStarred,
    restore: restore,
    detach: detach,
    current: current,
    queue: function () { return queue; },
    index: function () { return index; },
    position: position,
    duration: duration,
    paused: function () { return rm ? !rPlaying() : (br && br.phase === 'handoff' ? false : audio.paused); },
    buffering: function () { return !rm && !audio.paused && audio.readyState < 3; },
    shuffle: function () { return shuffleOn; },
    repeat: function () { return repeat; },
    checkRemote: checkRemote,
    take: take,
    dismissRemote: dismissRemote,
    reloadCurrent: function () { if (!rm && current() && audio.src && !station) load(position(), !audio.paused); },
    applyVolume: applyVolume,
    volume: function () { return master; },
    setVolume: function (v) { master = Math.max(0, Math.min(1, +v || 0)); U.store.set('volume', master); applyVolume(); emit('volume'); },
    context: function () { return context; },
    setContext: function (c) { context = c || null; emit('mode'); persist(); },
    replaceUpNext: replaceUpNext,
    // Etwas außerhalb des Players hat sich geändert, das die Ansichten zeigen (der Name des DJ-Sets)
    touch: function () { emit('mode'); },
    playStation: playStation,
    stopStation: stopStation,
    station: function () { return station; },
    stations: function () { return stations; },
    setSleep: setSleep,
    // Restzeit in ms, -1 = am Ende des Songs, 0 = aus
    sleepLeft: function () { return sleepEnd ? -1 : sleepAt ? Math.max(1, sleepAt - Date.now()) : 0; }
  };
})();
