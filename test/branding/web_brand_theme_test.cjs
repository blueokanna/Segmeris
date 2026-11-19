const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../../web/brand-theme.js'), 'utf8');

for (const initiallyDark of [false, true]) {
  test(`favicon/manifest select initial ${initiallyDark ? 'dark' : 'light'} and react to a system change`, () => {
    const elements = new Map();
    let listener;
    const scheme = {
      matches: initiallyDark,
      addEventListener(event, callback) {
        assert.equal(event, 'change');
        listener = callback;
      },
    };
    vm.runInNewContext(source, {
      window: {
        matchMedia(query) {
          assert.equal(query, '(prefers-color-scheme: dark)');
          return scheme;
        },
      },
      document: {
        getElementById(id) {
          const element = { setAttribute(key, value) { this[key] = value; } };
          elements.set(id, element);
          return element;
        },
      },
    });
    const check = (dark) => {
      assert.equal(elements.get('brand-favicon').href, dark ? 'favicon-dark.png' : 'favicon.png');
      assert.equal(elements.get('brand-manifest').href, dark ? 'manifest-dark.json' : 'manifest.json');
      assert.equal(elements.get('brand-touch-icon').href,
        dark ? 'icons/apple-touch-icon-dark.png' : 'icons/apple-touch-icon.png');
    };
    check(initiallyDark);
    scheme.matches = !initiallyDark;
    listener();
    check(!initiallyDark);
  });
}
