const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const rtd = require('./_rtd.js');

test('NAV is ordered and complete', () => {
  const files = rtd.NAV.map(n => n.file);
  assert.deepStrictEqual(files, [
    'index.html', 'why.html',
    'toolchain.html', 'build-system.html', 'signing.html', 'flashing.html',
    'iq-9075-evk.html', 'quick-start.html',
    'lemans-focused.html', 'lemans.html',
    'ventuno-q.html', 'quick-start-ventuno-q.html',
  ]);
});

test('every NAV page exists', () => {
  rtd.NAV.forEach(n => {
    assert.ok(fs.existsSync(path.join(__dirname, n.file)), n.file);
  });
});

test('pages of a group are contiguous', () => {
  const seen = [];
  let last = null;
  rtd.NAV.forEach(n => {
    const g = n.group || null;
    if (g !== last && g !== null) {
      assert.ok(!seen.includes(g), 'group ' + g + ' is split');
      seen.push(g);
    }
    last = g;
  });
  assert.deepStrictEqual(seen, ['Concepts', 'IQ-9075 EVK (Lemans)', 'Arduino VENTUNO Q (Monaco)']);
});

test('basename normalizes paths', () => {
  assert.strictEqual(rtd.basename('/a/b/why.html'), 'why.html');
  assert.strictEqual(rtd.basename('why.html'), 'why.html');
  assert.strictEqual(rtd.basename('/'), 'index.html');
  assert.strictEqual(rtd.basename(''), 'index.html');
  assert.strictEqual(rtd.basename('/docs/'), 'index.html');
});

test('currentIndex matches by basename, case-insensitive', () => {
  assert.strictEqual(rtd.currentIndex(rtd.NAV, '/x/WHY.HTML'), 1);
  assert.strictEqual(rtd.currentIndex(rtd.NAV, '/'), 0);
  assert.strictEqual(rtd.currentIndex(rtd.NAV, 'nope.html'), -1);
});

test('breadcrumbFor: index shows only Docs root', () => {
  assert.deepStrictEqual(rtd.breadcrumbFor(rtd.NAV, 'index.html'),
    [{ title: 'Docs', href: 'index.html' }]);
});

test('breadcrumbFor: ungrouped leaf page appends its title', () => {
  const bc = rtd.breadcrumbFor(rtd.NAV, 'why.html');
  assert.strictEqual(bc.length, 2);
  assert.deepStrictEqual(bc[0], { title: 'Docs', href: 'index.html' });
  assert.strictEqual(bc[1].href, 'why.html');
  assert.strictEqual(typeof bc[1].title, 'string');
});

test('breadcrumbFor: grouped page shows its group, linked to the first page', () => {
  assert.deepStrictEqual(rtd.breadcrumbFor(rtd.NAV, 'signing.html'), [
    { title: 'Docs', href: 'index.html' },
    { title: 'Concepts', href: 'toolchain.html' },
    { title: 'Signing', href: 'signing.html' },
  ]);
  const bc = rtd.breadcrumbFor(rtd.NAV, 'lemans.html');
  assert.deepStrictEqual(bc[1], { title: 'IQ-9075 EVK (Lemans)', href: 'iq-9075-evk.html' });
  const vq = rtd.breadcrumbFor(rtd.NAV, 'quick-start-ventuno-q.html');
  assert.deepStrictEqual(vq[1], { title: 'Arduino VENTUNO Q (Monaco)', href: 'ventuno-q.html' });
});

test('groupHead: unknown group has no head', () => {
  assert.strictEqual(rtd.groupHead(rtd.NAV, 'nope'), null);
});

test('prevNextFor: ends are null, middle links both ways', () => {
  assert.strictEqual(rtd.prevNextFor(rtd.NAV, 'index.html').prev, null);
  assert.strictEqual(rtd.prevNextFor(rtd.NAV, 'quick-start-ventuno-q.html').next, null);
  const mid = rtd.prevNextFor(rtd.NAV, 'quick-start.html');
  assert.strictEqual(mid.prev.file, 'iq-9075-evk.html');
  assert.strictEqual(mid.next.file, 'lemans-focused.html');
});
