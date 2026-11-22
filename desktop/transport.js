// Play/Pause, Zurück, Weiter außerhalb des Fensters: Windows zeigt sie unter der Vorschau in der Taskleiste,
// der Mac im Menü des Dock-Symbols. Die Oberfläche meldet nur Zustand und Titel, Befehle gehen als Text zurück.
const { app, Menu, nativeImage } = require('electron');

const MAC = process.platform === 'darwin';
const CMDS = ['prev', 'toggle', 'next'];

// Symbole selbst gezeichnet (weiß auf transparent), damit keine Bilddateien nötig sind
function glyph(kind, size, color) {
  const buf = Buffer.alloc(size * size * 4);
  const u = size / 16;
  function inside(x, y) {
    x /= u; y /= u;
    if (kind === 'play') return x >= 4 && x <= 12.5 && Math.abs(y - 8) <= (12.5 - x) * (5.5 / 8.5) + 0.01 && x >= 4;
    if (kind === 'pause') return y >= 3.5 && y <= 12.5 && ((x >= 4 && x <= 7) || (x >= 9 && x <= 12));
    const bar = kind === 'prev' ? x >= 3 && x <= 5 : x >= 11 && x <= 13;
    const tri = kind === 'prev' ? x >= 5.5 && x <= 13 && Math.abs(y - 8) <= (x - 5.5) * 0.75 : x >= 3 && x <= 10.5 && Math.abs(y - 8) <= (10.5 - x) * 0.75;
    return (y >= 3.5 && y <= 12.5 && bar) || tri;
  }
  for (let py = 0; py < size; py++) for (let px = 0; px < size; px++) {
    if (!inside(px + 0.5, py + 0.5)) continue;
    const i = (py * size + px) * 4;
    buf[i] = color[2]; buf[i + 1] = color[1]; buf[i + 2] = color[0]; buf[i + 3] = 255; // BGRA
  }
  return nativeImage.createFromBitmap(buf, { width: size, height: size, scaleFactor: size / 16 });
}

function setupTransport(getWin, fromUs, ipcMain) {
  let state = { has: false, playing: false, title: '', artist: '' };
  let icons = null;

  function send(cmd) {
    const w = getWin();
    if (w && !w.isDestroyed() && CMDS.includes(cmd)) w.webContents.send('media-cmd', cmd);
  }

  function thumbs() {
    const w = getWin();
    if (MAC || !w || w.isDestroyed()) return;
    if (!icons) icons = { prev: glyph('prev', 32, [255, 255, 255]), next: glyph('next', 32, [255, 255, 255]), play: glyph('play', 32, [255, 255, 255]), pause: glyph('pause', 32, [255, 255, 255]) };
    const on = state.has;
    try { w.setThumbarButtons([
      { tooltip: 'Zurück', icon: icons.prev, flags: on ? [] : ['disabled'], click: () => send('prev') },
      { tooltip: state.playing ? 'Pause' : 'Wiedergabe', icon: state.playing ? icons.pause : icons.play, flags: on ? [] : ['disabled'], click: () => send('toggle') },
      { tooltip: 'Weiter', icon: icons.next, flags: on ? [] : ['disabled'], click: () => send('next') }
    ]); } catch (_) { /* Taskleisten-Buttons sind nur eine Zugabe */ }
  }

  function dock() {
    if (!MAC || !app.dock) return;
    const on = state.has;
    const items = [];
    if (on && state.title) items.push({ label: state.artist ? state.title + ' – ' + state.artist : state.title, enabled: false }, { type: 'separator' });
    items.push(
      { label: state.playing ? 'Pause' : 'Wiedergabe', enabled: on, click: () => send('toggle') },
      { label: 'Nächster Titel', enabled: on, click: () => send('next') },
      { label: 'Vorheriger Titel', enabled: on, click: () => send('prev') }
    );
    try { app.dock.setMenu(Menu.buildFromTemplate(items)); } catch (_) { /* nur eine Zugabe */ }
  }

  ipcMain.on('media-state', (e, s) => {
    if (!fromUs(e) || !s || typeof s !== 'object') return;
    const next = {
      has: s.has === true,
      playing: s.playing === true,
      title: String(s.title || '').slice(0, 200),
      artist: String(s.artist || '').slice(0, 200)
    };
    const same = next.has === state.has && next.playing === state.playing && next.title === state.title && next.artist === state.artist;
    state = next;
    if (!same) { thumbs(); dock(); }
  });

  // Die Schaltflächen hängen am Fenster und gehen bei einem Neuladen verloren – dann neu setzen
  return { refresh() { thumbs(); dock(); } };
}

module.exports = { setupTransport };
