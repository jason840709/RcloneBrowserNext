import { useEffect, useRef } from 'react';
import { CaretDown, GearSix, TerminalWindow, Question, Check, ArrowClockwise, Info } from '@phosphor-icons/react';
import type { Language, Theme } from '../shared/types';
import type { Translate } from './i18n';
import { themeIcon } from './appearance';

export default function ApplicationMenu({t, language, theme, onSettings, onHelp, onConfigure, onLanguage, onAbout, onEngineUpdate, onAppUpdate}: {
  t: Translate; language: Language; theme: Theme; onSettings(): void; onHelp(): void; onConfigure(): void; onLanguage(language: Language): void; onAbout(): void; onEngineUpdate(): void; onAppUpdate(): void;
}) {
  const root = useRef<HTMLDetailsElement>(null);
  const trigger = useRef<HTMLElement>(null);
  const close = (restoreFocus = false) => { if (root.current) root.current.open = false; if (restoreFocus) trigger.current?.focus(); };
  useEffect(() => {
    const outside = (event: PointerEvent) => { if (root.current && !root.current.contains(event.target as Node)) close(); };
    document.addEventListener('pointerdown', outside);
    return () => document.removeEventListener('pointerdown', outside);
  }, []);
  const select = (action: () => void) => { close(); action(); };
  return <details className="application-menu" ref={root} onKeyDown={event => {
    if (event.key === 'Escape') { event.preventDefault(); close(true); }
    if (['ArrowDown','ArrowUp','Home','End'].includes(event.key)) {
      event.preventDefault();
      if (root.current) root.current.open = true;
      const items = [...(root.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') || [])];
      const current = items.indexOf(document.activeElement as HTMLButtonElement);
      const index = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : event.key === 'ArrowDown' ? (current + 1) % items.length : (current - 1 + items.length) % items.length;
      items[index]?.focus();
    }
  }}>
    <summary ref={trigger} className="brand" aria-label={t('appMenu')} aria-haspopup="menu"><img className="app-mark" src={themeIcon(theme)} alt=""/><span>Rclone Browser <strong>Next</strong></span><CaretDown size={13}/></summary>
    <div className="application-menu-content" role="menu" aria-label={t('appMenu')}>
      <button type="button" role="menuitem" onClick={() => select(onAbout)}><Info size={18}/>{t('aboutApp')}</button>
      <div className="menu-separator" role="separator"/>
      <button type="button" role="menuitem" onClick={() => select(onConfigure)}><TerminalWindow size={18}/>{t('configLabel')}</button>
      <button type="button" role="menuitem" onClick={() => select(onSettings)}><GearSix size={18}/>{t('settings')}<kbd>⌘ ,</kbd></button>
      <div className="menu-separator" role="separator"/>
      <div className="menu-section-title">{t('language')}</div>
      <button type="button" role="menuitemradio" aria-checked={language === 'system'} onClick={() => select(() => onLanguage('system'))}><span className="menu-check">{language === 'system' && <Check size={16}/>}</span>{t('systemLanguage')}</button>
      {([{value: 'zh-TW', label: '繁體中文'}, {value: 'en', label: 'English'}, {value: 'ja', label: '日本語'}] as const).map(item => <button type="button" key={item.value} role="menuitemradio" aria-checked={language === item.value} onClick={() => select(() => onLanguage(item.value))}><span className="menu-check">{language === item.value && <Check size={16}/>}</span>{item.label}</button>)}
      <div className="menu-separator" role="separator"/>
      <button type="button" role="menuitem" onClick={() => select(onEngineUpdate)}><ArrowClockwise size={18}/>{t('checkEngineUpdates')}</button>
      <button type="button" role="menuitem" onClick={() => select(onAppUpdate)}><ArrowClockwise size={18}/>{t('checkAppUpdates')}</button>
      <div className="menu-separator" role="separator"/>
      <button type="button" role="menuitem" onClick={() => select(onHelp)}><Question size={18}/>{t('help')}</button>
    </div>
  </details>;
}
