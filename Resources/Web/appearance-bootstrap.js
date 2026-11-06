// This synchronous script runs before the main stylesheet and React bundle.
(() => {
  const validTheme = value => typeof value === 'string' && /^(purple|blue|green)-(dark|light|auto)$/.test(value);
  let theme = window.__rbnInitialAppearance?.theme;
  if (!validTheme(theme)) {
    try { theme = localStorage.getItem('rbn:theme'); } catch { /* Storage may be unavailable in an embedded document. */ }
  }
  document.documentElement.dataset.theme = validTheme(theme) ? theme : 'purple-auto';
})();
