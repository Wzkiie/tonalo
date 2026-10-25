/* SVG-Icons (24x24). f = gefüllt, e = gefüllt mit Aussparungen, s = Kontur */
var Icon = (function () {
  'use strict';
  var P = {
    logo: ['e', 'M6 1.5h12A4.5 4.5 0 0 1 22.5 6v12a4.5 4.5 0 0 1-4.5 4.5H6A4.5 4.5 0 0 1 1.5 18V6A4.5 4.5 0 0 1 6 1.5zM5.55 9.50h1.70v5.00h-1.70zM8.35 7.50h1.70v9.00h-1.70zM11.15 5.50h1.70v13.00h-1.70zM13.95 8.00h1.70v8.00h-1.70zM16.75 9.70h1.70v4.60h-1.70z'],
    play: ['f', 'M8 5.14v13.72a1 1 0 0 0 1.52.85l10.9-6.86a1 1 0 0 0 0-1.7L9.52 4.29A1 1 0 0 0 8 5.14z'],
    pause: ['f', 'M6.5 4h3.5a.5.5 0 0 1 .5.5v15a.5.5 0 0 1-.5.5H6.5a.5.5 0 0 1-.5-.5v-15a.5.5 0 0 1 .5-.5zm7.5 0h3.5a.5.5 0 0 1 .5.5v15a.5.5 0 0 1-.5.5H14a.5.5 0 0 1-.5-.5v-15A.5.5 0 0 1 14 4z'],
    next: ['f', 'M5 5.6v12.8a.8.8 0 0 0 1.25.66L15.5 12.6a.8.8 0 0 0 0-1.2L6.25 4.94A.8.8 0 0 0 5 5.6zM17 4.5h2a.5.5 0 0 1 .5.5v14a.5.5 0 0 1-.5.5h-2a.5.5 0 0 1-.5-.5V5a.5.5 0 0 1 .5-.5z'],
    prev: ['f', 'M19 5.6v12.8a.8.8 0 0 1-1.25.66L8.5 12.6a.8.8 0 0 1 0-1.2l9.25-6.46A.8.8 0 0 1 19 5.6zM7 4.5H5a.5.5 0 0 0-.5.5v14a.5.5 0 0 0 .5.5h2a.5.5 0 0 0 .5-.5V5A.5.5 0 0 0 7 4.5z'],
    shuffle: ['s', 'M3 7h3.2c2 0 3.2.9 4.3 2.6l3 4.8c1.1 1.7 2.3 2.6 4.3 2.6H21M3 17h3.2c1.4 0 2.4-.5 3.2-1.4M14.6 8.4c.8-.9 1.8-1.4 3.2-1.4H21M18.5 4.5 21 7l-2.5 2.5M18.5 14.5 21 17l-2.5 2.5'],
    repeat: ['s', 'M4 12V9.5A3.5 3.5 0 0 1 7.5 6H20M17 3l3 3-3 3M20 12v2.5a3.5 3.5 0 0 1-3.5 3.5H4M7 21l-3-3 3-3'],
    heart: ['s', 'M12 20.3s-7.6-4.6-9.4-9.3C1.4 7.9 3.4 4.3 7 4.3c2 0 3.6 1.1 5 3 1.4-1.9 3-3 5-3 3.6 0 5.6 3.6 4.4 6.7-1.8 4.7-9.4 9.3-9.4 9.3z'],
    heartFill: ['f', 'M12 20.3s-7.6-4.6-9.4-9.3C1.4 7.9 3.4 4.3 7 4.3c2 0 3.6 1.1 5 3 1.4-1.9 3-3 5-3 3.6 0 5.6 3.6 4.4 6.7-1.8 4.7-9.4 9.3-9.4 9.3z'],
    more: ['f', 'M5 10.2a1.8 1.8 0 1 1 0 3.6 1.8 1.8 0 0 1 0-3.6zm7 0a1.8 1.8 0 1 1 0 3.6 1.8 1.8 0 0 1 0-3.6zm7 0a1.8 1.8 0 1 1 0 3.6 1.8 1.8 0 0 1 0-3.6z'],
    home: ['f', 'M12.7 2.8a1 1 0 0 0-1.4 0l-8 7.5a1 1 0 0 0-.3.7V20a1 1 0 0 0 1 1h5v-6.5h6V21h5a1 1 0 0 0 1-1v-9a1 1 0 0 0-.3-.7z'],
    search: ['s', 'M10.5 3.5a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM15.6 15.6 21 21'],
    library: ['f', 'M4 3.5h2.5a.5.5 0 0 1 .5.5v16a.5.5 0 0 1-.5.5H4a.5.5 0 0 1-.5-.5V4a.5.5 0 0 1 .5-.5zm5.5 0H12a.5.5 0 0 1 .5.5v16a.5.5 0 0 1-.5.5H9.5A.5.5 0 0 1 9 20V4a.5.5 0 0 1 .5-.5zm5.2 1 2.4-.65a.5.5 0 0 1 .6.35l4.1 15.4a.5.5 0 0 1-.35.6l-2.4.65a.5.5 0 0 1-.6-.35L14.35 5.1a.5.5 0 0 1 .35-.6z'],
    artist: ['s', 'M12 3.5a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM4.5 20.5c.6-3.8 3.6-6 7.5-6s6.9 2.2 7.5 6'],
    playlist: ['s', 'M3.5 6h12M3.5 11h12M3.5 16h7M18.5 4.5v11M18.5 15.5a2.5 2.5 0 1 1-2.5-2.5h2.5'],
    genre: ['s', 'M4 4h6.5v6.5H4zM13.5 4H20v6.5h-6.5zM4 13.5h6.5V20H4zM13.5 13.5H20V20h-6.5z'],
    bars: ['f', 'M4 13h2.5v7H4zM9 8h2.5v12H9zM14 11h2.5v9H14zM19 5h2.5v15H19z'],
    queue: ['s', 'M3.5 5.5h14M3.5 10.5h14M3.5 15.5h8M15.5 14v6l5-3z'],
    settings: ['s', 'M4 6.5h9M17 6.5h3M15 4.5v4M4 12h3M11 12h9M9 10v4M4 17.5h10M18 17.5h2M16 15.5v4'],
    expand: ['s', 'M4 9.5V4h5.5M14.5 4H20v5.5M20 14.5V20h-5.5M9.5 20H4v-5.5'],
    mic: ['s', 'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3'],
    plus: ['s', 'M12 4.5v15M4.5 12h15'],
    addQueue: ['s', 'M3.5 5.5h12M3.5 10.5h12M3.5 15.5h6M17.5 13v7M14 16.5h7'],
    playNext: ['s', 'M3.5 6h11M3.5 11h7M3.5 16h7M14 10.5v9l6.5-4.5z'],
    radio: ['s', 'M12 10.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM8.2 8.2a5.4 5.4 0 0 0 0 7.6M15.8 8.2a5.4 5.4 0 0 1 0 7.6M5.4 5.4a9.3 9.3 0 0 0 0 13.2M18.6 5.4a9.3 9.3 0 0 1 0 13.2'],
    album: ['s', 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 9.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z'],
    close: ['s', 'M5.5 5.5l13 13M18.5 5.5l-13 13'],
    clock: ['s', 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17zM12 7.5V12l3 2'],
    swap: ['s', 'M4 8h14M15 5l3 3-3 3M20 16H6M9 13l-3 3 3 3'],
    refresh: ['s', 'M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v4.5H15'],
    logout: ['s', 'M9.5 20H5.5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h4M15.5 16.5 20 12l-4.5-4.5M20 12H9.5'],
    power: ['s', 'M12 3v8M7 5.8a8 8 0 1 0 10 0'],
    trash: ['s', 'M4.5 6.5h15M9.5 6.5V4.5h5v2M6.5 6.5l1 13h9l1-13']
  };

  function svg(name, size, extraCls) {
    var p = P[name];
    if (!p) return '';
    var s = size || 24;
    var common = 'class="ic' + (extraCls ? ' ' + extraCls : '') + '" width="' + s + '" height="' + s + '" viewBox="0 0 24 24" aria-hidden="true"';
    if (p[0] === 'f') return '<svg ' + common + ' fill="currentColor"><path d="' + p[1] + '"/></svg>';
    if (p[0] === 'e') return '<svg ' + common + ' fill="currentColor"><path fill-rule="evenodd" d="' + p[1] + '"/></svg>';
    return '<svg ' + common + ' fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="' + p[1] + '"/></svg>';
  }

  // Wiederholen „eins“: Repeat-Icon mit kleiner 1
  function repeatOne(size) {
    var s = size || 24;
    return '<svg class="ic" width="' + s + '" height="' + s + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="' + P.repeat[1] + '"/><text x="12" y="14.6" font-size="7.5" font-weight="700" text-anchor="middle" fill="currentColor" stroke="none">1</text></svg>';
  }

  function el(name, size, extraCls) {
    var span = document.createElement('span');
    span.className = 'ic-wrap';
    span.innerHTML = svg(name, size, extraCls);
    return span.firstChild;
  }

  return { svg: svg, el: el, repeatOne: repeatOne };
})();
