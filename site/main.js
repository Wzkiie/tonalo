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

  // iPhone screenshot strip
  var strip = document.getElementById('strip');
  document.querySelectorAll('.strip-nav button').forEach(function (b) {
    b.addEventListener('click', function () {
      strip.scrollBy({ left: Number(b.dataset.dir) * strip.clientWidth * 0.7, behavior: 'smooth' });
    });
  });

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
