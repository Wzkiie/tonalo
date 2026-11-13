(function () {
  var top = document.getElementById('top');
  function onScroll() { top.classList.toggle('scrolled', window.scrollY > 8); }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // Fade sections in as they come into view
  var items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
      });
    }, { rootMargin: '0px 0px -8% 0px' });
    items.forEach(function (el) { io.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add('in'); });
  }

  // iPhone tour: one phone that stays put. A strip with every screen sits inside its frame and follows the
  // scroll position: while a feature is near the middle of the window its screen holds still, and on the way to
  // the next feature the strip glides on. Without this script the phone keeps the home screen.
  var tour = document.getElementById('tour');
  if (tour) {
    var steps = [].slice.call(tour.querySelectorAll('.step'));
    var texts = steps.map(function (s) { return s.querySelector('.step-text'); });
    var count = steps.length;
    var wide = window.matchMedia('(min-width: 901px)');
    var calm = window.matchMedia('(prefers-reduced-motion: reduce)');
    var make = function (name) { var d = document.createElement('div'); d.className = name; return d; };
    var stage = make('tour-stage'), glow = make('tour-glow'), frame = make('tour-frame'), reel = make('tour-reel');
    var screens = steps.map(function (s) { return reel.appendChild(s.querySelector('img').cloneNode()); });
    frame.appendChild(reel);
    stage.appendChild(glow);
    stage.appendChild(frame);
    tour.appendChild(stage);

    // each step's color as numbers, so the light behind the phone can blend from one to the next
    var colors = steps.map(function (s) {
      var c = getComputedStyle(s).getPropertyValue('--c').trim().replace('#', '');
      return [0, 2, 4].map(function (k) { return parseInt(c.substr(k, 2), 16); });
    });
    var clamp = function (v) { return v < 0 ? 0 : v > 1 ? 1 : v; };
    var ease = function (t) { return t * t * (3 - 2 * t); };

    // where the middle of the window is, counted in steps: 2.5 is halfway between the third and fourth
    var position = function () {
      var mid = window.innerHeight / 2, prev = 0, i, r, c;
      for (i = 0; i < count; i++) {
        r = texts[i].getBoundingClientRect();
        c = r.top + r.height / 2;
        if (mid <= c) return i === 0 ? 0 : i - 1 + (mid - prev) / (c - prev);
        prev = c;
      }
      return count - 1;
    };
    var paint = function (p) {
      var i = Math.min(Math.floor(p), count - 2), t = p - i;
      // hold the screen for the first and last quarter of the way, glide in between
      var k = calm.matches ? (t < .5 ? 0 : 1) : ease(clamp((t - .26) / .48));
      reel.style.transform = 'translate3d(0,' + (-(i + k) / count * 100) + '%,0)';
      var a = colors[i], b = colors[i + 1];
      stage.style.setProperty('--glow', 'rgba(' + [0, 1, 2].map(function (n) { return Math.round(a[n] + (b[n] - a[n]) * k); }).join(',') + ',.32)');
      texts.forEach(function (el, j) {
        el.style.opacity = (1 - .74 * ease(clamp((Math.abs(p - j) - .3) / .35))).toFixed(3);
      });
    };

    // follow the scroll with a little inertia, so a mouse wheel's jumps come out as one movement
    var at = 0, frameId = 0;
    var tick = function () {
      frameId = 0;
      if (!wide.matches) return;
      var to = position();
      at = calm.matches || Math.abs(to - at) < .002 ? to : at + (to - at) * .22;
      paint(at);
      if (at !== to) frameId = requestAnimationFrame(tick);
    };
    var follow = function () { if (!frameId) frameId = requestAnimationFrame(tick); };
    var layout = function () {
      if (wide.matches) { at = position(); paint(at); }
      else texts.forEach(function (el) { el.style.opacity = ''; });
    };
    window.addEventListener('scroll', follow, { passive: true });
    window.addEventListener('resize', layout);
    if (wide.addEventListener) wide.addEventListener('change', layout); else wide.addListener(layout);

    // the strip's screens are lazy like every screenshot; fetch them all shortly before the tour comes up
    if ('IntersectionObserver' in window) {
      var near = new IntersectionObserver(function (entries) {
        if (!entries.some(function (e) { return e.isIntersecting; })) return;
        screens.forEach(function (img) { img.loading = 'eager'; });
        near.disconnect();
      }, { rootMargin: '1200px 0px' });
      near.observe(tour);
    } else {
      screens.forEach(function (img) { img.loading = 'eager'; });
    }

    tour.classList.add('js');
    layout();
  }

  // Screenshots open large
  // Changelog: show one app or both
  var filter = document.querySelectorAll('.log-filter button');
  filter.forEach(function (b) {
    b.addEventListener('click', function () {
      filter.forEach(function (o) { o.setAttribute('aria-pressed', String(o === b)); });
      document.querySelectorAll('.log .entry').forEach(function (e) {
        e.hidden = b.dataset.show !== 'all' && e.dataset.app !== b.dataset.show;
      });
    });
  });

  var lb = document.getElementById('lb');
  if (!lb || !lb.showModal) return;
  var lbImg = lb.querySelector('img');
  document.querySelectorAll('img.shot').forEach(function (img) {
    img.addEventListener('click', function () {
      lbImg.src = img.currentSrc || img.src;
      lbImg.alt = img.alt;
      lb.showModal();
    });
  });
  lb.addEventListener('click', function () { lb.close(); });
})();
