import {useEffect, useLayoutEffect, useRef, useState} from 'react';
import {createPortal} from 'react-dom';
import {CaretDown, Check, X, HardDrives, Cloud} from '@phosphor-icons/react';
import type {BuiltinPresetID, TransferMode} from '../shared/types';
import type {Translate} from './i18n';
import {BUILTIN_PRESETS, presetLabel, presetSummary, presetWritesLocal} from './presets';

export default function OperationPicker({mode, preset, hidden, t, onMode, onPreset, onHide}: {
  mode: TransferMode; preset: BuiltinPresetID | null; hidden: BuiltinPresetID[]; t: Translate;
  onMode(mode: TransferMode): void; onPreset(id: BuiltinPresetID): void; onHide(id: BuiltinPresetID): void;
}) {
  const trigger = useRef<HTMLButtonElement>(null), menu = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState({left: 0, top: 0});
  const close = (focus = true) => { setOpen(false); if (focus) trigger.current?.focus(); };
  const choose = (action: () => void) => { close(); action(); };
  useLayoutEffect(() => {
    if (!open || !trigger.current || !menu.current) return;
    const rect = trigger.current.getBoundingClientRect(), size = menu.current.getBoundingClientRect();
    setPosition({left: Math.max(12, Math.min(rect.left, innerWidth - size.width - 12)), top: rect.bottom + size.height + 8 < innerHeight - 12 ? rect.bottom + 7 : Math.max(12, rect.top - size.height - 7)});
    (menu.current.querySelector<HTMLButtonElement>('button[aria-checked="true"]') || menu.current.querySelector<HTMLButtonElement>('button[role="menuitemradio"]'))?.focus();
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!menu.current?.contains(event.target as Node) && !trigger.current?.contains(event.target as Node)) close(false); };
    const resize = () => close(false);
    document.addEventListener('pointerdown', outside); window.addEventListener('resize', resize);
    return () => { document.removeEventListener('pointerdown', outside); window.removeEventListener('resize', resize); };
  }, [open]);
  return <><button type="button" ref={trigger} className="operation-picker-trigger" data-testid="operation-picker" aria-label={t('operation')} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)} onKeyDown={event => {if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {event.preventDefault();setOpen(true);}}}><span>{preset ? t(presetLabel(preset)) : t(mode)}</span><CaretDown size={13}/></button>{open && createPortal(<div ref={menu} className="operation-menu" role="menu" aria-label={t('operation')} style={position} onKeyDown={event => {
    if (event.key === 'Escape') {event.preventDefault();event.stopPropagation();close();}
    if (event.key === 'Tab') {event.preventDefault();close();}
    if (['ArrowDown','ArrowUp','Home','End'].includes(event.key)) {
      event.preventDefault(); const items = [...(menu.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') || [])], current = items.indexOf(document.activeElement as HTMLButtonElement);
      const index = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : event.key === 'ArrowDown' ? (current + 1) % items.length : (current - 1 + items.length) % items.length;items[index]?.focus();
    }
  }}>
    {BUILTIN_PRESETS.some(id => !hidden.includes(id)) && <><div className="menu-section-title">{t('builtinPresets')}</div>{BUILTIN_PRESETS.filter(id => !hidden.includes(id)).map(id => <div className="preset-menu-row" role="none" key={id}><button type="button" className="preset-hide" role="menuitem" aria-label={`${t('hidePreset')} ${t(presetLabel(id))}`} title={t('hidePresetHint')} onClick={() => {onHide(id); requestAnimationFrame(() => menu.current?.querySelector<HTMLButtonElement>('button[role="menuitemradio"]')?.focus());}}><X size={13}/></button><button type="button" role="menuitemradio" aria-checked={preset === id} onClick={() => choose(() => onPreset(id))}>{presetWritesLocal(id) ? <HardDrives size={18}/> : <Cloud size={18}/>}<span><strong>{t(presetLabel(id))}</strong><small>{t(presetSummary(id))}</small></span>{preset === id && <Check size={16}/>}</button></div>)}<div className="menu-separator" role="separator"/></>}
    <div className="menu-section-title">{t('basicOperations')}</div>{(['copy','sync','move'] as const).map(value => <button type="button" role="menuitemradio" className="operation-menu-mode" aria-checked={!preset && mode === value} key={value} onClick={() => choose(() => onMode(value))}><span className="menu-check">{!preset && mode === value && <Check size={16}/>}</span>{t(value)}</button>)}
    <p className="operation-menu-note">{t('presetApplyHint')}</p>
  </div>, document.body)}</>;
}
