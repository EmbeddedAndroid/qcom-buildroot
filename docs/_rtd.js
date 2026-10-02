// Shared ReadTheDocs-style nav/theme runtime for build/docs/.
// Pure core (below) is node-testable; browser bootstrap is added in Task 2.
(function (root) {
  'use strict';

  // Pages without a group are shared entry points; a group collects the
  // shared concept pages or the pages of one board.
  var NAV = [
    { id: 'index',     file: 'index.html',          title: 'Home',                  subtitle: 'Overview · boards' },
    { id: 'why',       file: 'why.html',            title: 'Why this Build System', subtitle: 'Rationale' },
    { id: 'toolchain', file: 'toolchain.html',      title: 'Host Setup',            subtitle: 'Packages · repo · toolchains · qdl', group: 'Concepts' },
    { id: 'build',     file: 'build-system.html',   title: 'Build System',          subtitle: 'Manifests · makefiles · images',    group: 'Concepts' },
    { id: 'signing',   file: 'signing.html',        title: 'Signing',               subtitle: 'TZ stage · SWIV · qtestsign',       group: 'Concepts' },
    { id: 'flashing',  file: 'flashing.html',       title: 'Flashing',              subtitle: 'EDL · qdl · partitions',            group: 'Concepts' },
    { id: 'iq9075',    file: 'iq-9075-evk.html',    title: 'IQ-9075 EVK',           subtitle: 'Boot chain · build · flash',        group: 'IQ-9075 EVK (Lemans)' },
    { id: 'quick',     file: 'quick-start.html',    title: 'IQ-9075 EVK Quick Start', subtitle: 'init · sync · build · flash',     group: 'IQ-9075 EVK (Lemans)' },
    { id: 'focused',   file: 'lemans-focused.html', title: 'Lemans: Focused',       subtitle: 'Platform · Boot · Projects',        group: 'IQ-9075 EVK (Lemans)' },
    { id: 'full',      file: 'lemans.html',         title: 'Lemans: Comprehensive', subtitle: 'Build System Deep Dive',            group: 'IQ-9075 EVK (Lemans)' },
    { id: 'ventuno',   file: 'ventuno-q.html',      title: 'Arduino VENTUNO Q',     subtitle: 'Boot chain · build · sign · flash', group: 'Arduino VENTUNO Q (Monaco)' },
    { id: 'ventuno-qs', file: 'quick-start-ventuno-q.html', title: 'VENTUNO Q Quick Start', subtitle: 'init · sync · build · sign · flash', group: 'Arduino VENTUNO Q (Monaco)' },
    { id: 'ventuno-focused', file: 'ventuno-q-focused.html', title: 'Monaco: Focused', subtitle: 'Platform · Boot · Projects', group: 'Arduino VENTUNO Q (Monaco)' },
    { id: 'uno-q',     file: 'uno-q.html',          title: 'Arduino UNO Q',         subtitle: 'Boot chain · build · sign · flash', group: 'Arduino UNO Q (Agatti)' },
  ];

  function basename(path) {
    if (!path) return 'index.html';
    var cleaned = String(path).split('?')[0].split('#')[0];
    if (cleaned === '/' || cleaned.slice(-1) === '/') return 'index.html';
    var seg = cleaned.split('/').filter(Boolean).pop();
    return (seg || 'index.html').toLowerCase();
  }

  function currentIndex(nav, path) {
    var b = basename(path);
    for (var i = 0; i < nav.length; i++) {
      if (nav[i].file.toLowerCase() === b) return i;
    }
    return -1;
  }

  // First page of a group, the link target of its breadcrumb.
  function groupHead(nav, group) {
    for (var i = 0; i < nav.length; i++) {
      if (nav[i].group === group) return nav[i];
    }
    return null;
  }

  function breadcrumbFor(nav, path) {
    var crumbs = [{ title: 'Docs', href: 'index.html' }];
    var i = currentIndex(nav, path);
    if (i > 0) {
      if (nav[i].group) {
        crumbs.push({ title: nav[i].group, href: groupHead(nav, nav[i].group).file });
      }
      crumbs.push({ title: nav[i].title, href: nav[i].file });
    }
    return crumbs;
  }

  function prevNextFor(nav, path) {
    var i = currentIndex(nav, path);
    if (i < 0) return { prev: null, next: null };
    return {
      prev: i > 0 ? nav[i - 1] : null,
      next: i < nav.length - 1 ? nav[i + 1] : null,
    };
  }

  var api = { NAV: NAV, basename: basename, currentIndex: currentIndex,
              groupHead: groupHead, breadcrumbFor: breadcrumbFor,
              prevNextFor: prevNextFor };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.RTD = api;

  // ---- Browser bootstrap (no-op in node / on non-rtd pages) ----
  if (typeof document === 'undefined') return;

  function el(tag, cls, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }

  function buildSidebar(path) {
    var side = el('nav', 'rtd-side');
    var head = el('div', 'rtd-side-head',
      '<a href="index.html">OP-TEE · Qualcomm<span class="sub">Open boot firmware</span></a>');
    side.appendChild(head);
    var ul = el('ul');
    var curIdx = api.currentIndex(api.NAV, path);
    var group = null;
    api.NAV.forEach(function (item, i) {
      if (item.group && item.group !== group) {
        ul.appendChild(el('li', 'rtd-caption', item.group));
      }
      group = item.group || null;
      var li = el('li');
      if (i === curIdx) li.className = 'current';
      li.appendChild(el('a', null,
        item.title + (item.subtitle ? '<span class="sub">' + item.subtitle + '</span>' : '')));
      li.firstChild.setAttribute('href', item.file);
      ul.appendChild(li);
      // in-page section sub-nav for the current deck/article page
      if (i === curIdx) {
        var subs = document.querySelectorAll('main.rtd-doc [data-sec]');
        if (subs.length) {
          var sub = el('ul', 'rtd-subnav');
          subs.forEach(function (s) {
            var a = el('a', null, s.getAttribute('data-sec-title') || s.id);
            a.setAttribute('href', '#' + s.id);
            var sli = el('li'); sli.appendChild(a); sub.appendChild(sli);
          });
          li.appendChild(sub);
        }
      }
    });
    side.appendChild(ul);
    return side;
  }

  function buildBreadcrumb(path) {
    var bc = el('div', 'rtd-breadcrumb');
    var trail = api.breadcrumbFor(api.NAV, path);
    trail.forEach(function (c, i) {
      if (i) bc.appendChild(el('span', 'sep', '»'));
      var a = el('a', null, c.title); a.setAttribute('href', c.href);
      bc.appendChild(a);
    });
    return bc;
  }

  function buildPrevNext(path) {
    var pn = api.prevNextFor(api.NAV, path);
    var f = el('footer', 'rtd-prevnext');
    if (pn.prev) { var p = el('a', null, '← ' + pn.prev.title); p.setAttribute('href', pn.prev.file); f.appendChild(p); }
    f.appendChild(el('span', 'spacer'));
    if (pn.next) { var n = el('a', null, pn.next.title + ' →'); n.setAttribute('href', pn.next.file); f.appendChild(n); }
    return f;
  }

  function addAnchors(main) {
    main.querySelectorAll('h1[id], h2[id], h3[id]').forEach(function (h) {
      var a = el('a', 'rtd-anchor', '¶'); a.setAttribute('href', '#' + h.id);
      h.appendChild(a);
    });
  }

  function boot() {
    if (!document.body.classList.contains('rtd')) return;
    var main = document.querySelector('main.rtd-doc');
    if (!main) return;
    var path = location.pathname || '';
    document.body.insertBefore(buildSidebar(path), document.body.firstChild);
    main.insertBefore(buildBreadcrumb(path), main.firstChild);
    main.appendChild(buildPrevNext(path));
    addAnchors(main);
    var logo = el('a', 'rtd-logo',
      '<img class="mark" src="assets/qualcomm-mark.svg" alt="">' +
      '<img class="word" src="img/qualcomm-logo.svg" alt="Qualcomm">');
    logo.setAttribute('href', 'https://www.qualcomm.com');
    logo.setAttribute('target', '_blank');
    logo.setAttribute('rel', 'noopener');
    document.body.appendChild(logo);
  }

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', boot);
  else boot();

  function bootDeck() {
    if (!document.body.classList.contains('rtd')) return;
    if (!document.body.hasAttribute('data-deck')) return;
    var btn = el('button', 'rtd-present-btn', '▶ Present');
    document.body.appendChild(btn);
    function enter() {
      document.body.classList.add('presenting');
      btn.innerHTML = '✕ Exit';
      if (typeof window.__deckGo === 'function') window.__deckGo(window.__deckCur || 0);
    }
    function exit() {
      document.body.classList.remove('presenting');
      btn.innerHTML = '▶ Present';
      window.location.href = 'index.html';
    }
    btn.addEventListener('click', function () {
      if (document.body.classList.contains('presenting')) exit();
      else enter();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && document.body.classList.contains('presenting')) exit();
    });
  }
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', bootDeck);
  else bootDeck();
})(typeof window !== 'undefined' ? window : globalThis);
