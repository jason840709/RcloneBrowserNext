/**
 * Gliding thumbs for every segmented control and tab bar.
 *
 * The thumb is drawn by CSS (the track's ::before, see styles/controls.css);
 * this module only measures the selected segment and writes --thumb-x and
 * --thumb-w on the track. It works for any markup the app uses (buttons with
 * aria-pressed / .selected / .active / aria-current, radio labels with a
 * checked input), so no component needs its own thumb logic.
 *
 * The first measurement is applied without a transition so a freshly shown
 * control never slides in from the left; after that every change glides.
 */
const TRACKS = '.segmented, .filter-tabs, .mode-picker, .options-tabs, .report-tabs, .account-mode-switch, .interface-scale-picker, .main-nav, .direction-picker, .preferences-tabs';
const SELECTED = ':scope > :is([aria-pressed="true"], .selected, .active, [aria-current="page"], [aria-checked="true"], :has(input:checked))';

let scheduled = false;
const resize = new ResizeObserver(() => schedule());
const observed = new WeakSet<Element>();

function place(track: HTMLElement) {
  if (!observed.has(track)) { observed.add(track); resize.observe(track); }
  const selected = track.querySelector<HTMLElement>(SELECTED);
  if (!selected || selected.offsetWidth === 0) { track.style.setProperty('--thumb-opacity', '0'); return; }
  const values = {'--thumb-x': `${selected.offsetLeft}px`, '--thumb-w': `${selected.offsetWidth}px`, '--thumb-y': `${selected.offsetTop}px`, '--thumb-h': `${selected.offsetHeight}px`};
  for (const [name, value] of Object.entries(values)) if (track.style.getPropertyValue(name) !== value) track.style.setProperty(name, value);
  track.style.setProperty('--thumb-opacity', '1');
  // Enable the transition only after the first position has been painted.
  if (track.dataset.thumb !== 'ready' && track.dataset.thumb !== 'pending') {
    track.dataset.thumb = 'pending';
    requestAnimationFrame(() => requestAnimationFrame(() => { track.dataset.thumb = 'ready'; }));
  }
}

function update() {
  scheduled = false;
  document.querySelectorAll<HTMLElement>(TRACKS).forEach(place);
}

function schedule() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(update);
}

export function installSegmentThumbs() {
  const mutations = new MutationObserver(schedule);
  mutations.observe(document.documentElement, {subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'aria-pressed', 'aria-checked', 'aria-current', 'lang', 'data-theme']});
  // Radio inputs change by property, which mutation observers do not see.
  document.addEventListener('change', schedule, true);
  document.addEventListener('click', schedule, true);
  window.addEventListener('resize', schedule);
  document.fonts?.ready.then(schedule).catch(() => {});
  schedule();
}
