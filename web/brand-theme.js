// Browser-tab branding follows the system preference. Manifest icons have no
// standard media member: select a complete, valid manifest with a stable app id.
// Installed PWA/OS shortcuts may cache their icon; changing this link does not
// promise a live update to an already installed app's launcher icon.
(() => {
  const scheme = window.matchMedia('(prefers-color-scheme: dark)');
  const favicon = document.getElementById('brand-favicon');
  const manifest = document.getElementById('brand-manifest');
  const touchIcon = document.getElementById('brand-touch-icon');
  const update = () => {
    const dark = scheme.matches;
    favicon.setAttribute('href', dark ? 'favicon-dark.png' : 'favicon.png');
    manifest.setAttribute('href', dark ? 'manifest-dark.json' : 'manifest.json');
    touchIcon.setAttribute('href', dark
      ? 'icons/apple-touch-icon-dark.png'
      : 'icons/apple-touch-icon.png');
  };
  update();
  scheme.addEventListener('change', update);
})();
