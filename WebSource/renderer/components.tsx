import { createPortal } from 'react-dom';
import { Children, cloneElement, isValidElement, useEffect, useId, useRef, useState, useLayoutEffect, type ButtonHTMLAttributes, type PropsWithChildren, type ReactElement, type ReactNode } from 'react';
import { X, WarningCircle, Info } from '@phosphor-icons/react';
import type { Translate } from './i18n';

export function IconButton({ title, children, className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button type="button" title={title} aria-label={props['aria-label'] || title} className={`icon-button ${className}`} {...props}>{children}</button>;
}

export function Dialog({ title, children, onClose, className = '', t }: PropsWithChildren<{title: string; onClose(): void; className?: string; t: Translate}>) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const dialog = ref.current;
    dialog?.showModal();
    return () => { if (dialog?.open) dialog.close(); };
  }, []);
  return <dialog ref={ref} className={`dialog ${className}`} aria-labelledby={titleId}
    onCancel={event => { event.preventDefault(); closeRef.current(); }}
    onClick={event => { if (event.target === event.currentTarget) { const rect = event.currentTarget.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) closeRef.current(); } }}>
    <header className="dialog-header"><h2 id={titleId}>{title}</h2><IconButton title={t('close')} onClick={onClose}><X size={18}/></IconButton></header>
    {children}
  </dialog>;
}

export function Notice({ children, kind = 'info', onClose }: PropsWithChildren<{kind?: 'info' | 'error' | 'success' | 'warning'; onClose?: () => void}>) {
  return <div className={`notice ${kind}`} role={kind === 'error' ? 'alert' : 'status'}>
    {kind === 'error' || kind === 'warning' ? <WarningCircle size={18} weight="duotone"/> : <Info size={18}/>}
    <div>{children}</div>
    {onClose && <IconButton title={document.documentElement.lang === 'ja' ? '閉じる' : document.documentElement.lang === 'en' ? 'Close' : '關閉'} onClick={onClose}><X size={16}/></IconButton>}
  </div>;
}

export function EmptyState({ icon, title, children, action, compact = false }: PropsWithChildren<{ icon: ReactNode; title: string; action?: ReactNode; compact?: boolean }>) {
  return <div className={`empty-state ${compact ? 'compact' : ''}`}><div className="empty-icon">{icon}</div><h3>{title}</h3>{children && <p>{children}</p>}{action}</div>;
}

export function InfoTooltip({ text, label, descriptionId }: {text: string; label?: string; descriptionId?: string}) {
  const button = useRef<HTMLButtonElement>(null);
  const bubble = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [position, setPosition] = useState({left: 0, top: 0});
  const generatedId = useId();
  const suppressFocus = useRef(false);
  const tipId = `${generatedId}-tooltip`;
  const descId = descriptionId || `${generatedId}-description`;
  const closeTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const container = button.current?.closest('dialog') || document.body;
  const close = () => { setOpen(false); setPinned(false); };
  const show = () => { clearTimeout(closeTimer.current); setOpen(true); };
  const leave = () => { if (!pinned) closeTimer.current = setTimeout(() => setOpen(false), 120); };
  useLayoutEffect(() => {
    if (!open || !button.current || !bubble.current) return;
    const anchor = button.current.getBoundingClientRect();
    const surface = container === document.body ? {left: 0, top: 0, right: innerWidth, bottom: innerHeight} : container.getBoundingClientRect();
    const box = bubble.current.getBoundingClientRect();
    const left = Math.max(surface.left + 12, Math.min(anchor.left - 8, surface.right - box.width - 12));
    const below = anchor.bottom + 9;
    const top = below + box.height < surface.bottom - 12 ? below : Math.max(surface.top + 12, anchor.top - box.height - 9);
    setPosition({left: left - surface.left, top: top - surface.top});
  }, [open, text, container]);
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!button.current?.contains(event.target as Node) && !bubble.current?.contains(event.target as Node)) close(); };
    const escape = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape') { event.preventDefault(); event.stopImmediatePropagation(); suppressFocus.current = true; close(); button.current?.focus(); queueMicrotask(() => { suppressFocus.current = false; }); } };
    const scroll = () => { if (!pinned) setOpen(false); };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', escape, true);
    window.addEventListener('resize', close);
    document.addEventListener('scroll', scroll, true);
    return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('keydown', escape, true); window.removeEventListener('resize', close); document.removeEventListener('scroll', scroll, true); };
  }, [open, pinned]);
  useEffect(() => () => clearTimeout(closeTimer.current), []);
  const info = document.documentElement.lang === 'ja' ? '説明' : document.documentElement.lang === 'en' ? 'More information' : '說明';
  return <><span id={descId} className="sr-only">{text}</span><button ref={button} type="button" className="info-tooltip-trigger" aria-label={label ? `${label} — ${info}` : info} aria-describedby={descId} aria-expanded={open} aria-controls={open ? tipId : undefined} onPointerEnter={show} onPointerLeave={leave} onFocus={() => { if (!suppressFocus.current) show(); }} onBlur={() => { if (!pinned) setOpen(false); }} onClick={() => { if (pinned) close(); else { setOpen(true); setPinned(true); } }}><Info size={15}/></button>{open && createPortal(<div ref={bubble} id={tipId} role="tooltip" className="info-tooltip" style={{position: container === document.body ? 'fixed' : 'absolute', ...position}} onPointerEnter={show} onPointerLeave={leave}>{text}</div>, container)}</>;
}

export function Field({ label, hint, children, className = '', inlineHint = false }: PropsWithChildren<{label: string; hint?: string; className?: string; inlineHint?: boolean}>) {
  const id = useId();
  const hintId = `${id}-hint`;
  let assigned = false;
  const connectLabel = (node: ReactNode): ReactNode => {
    if (!isValidElement(node)) return node;
    const element = node as ReactElement<Record<string, unknown>>;
    if (!assigned && typeof element.type === 'string' && ['input', 'select', 'textarea'].includes(element.type)) {
      assigned = true;
      return cloneElement(element, {id, ...(hint ? {'aria-describedby': hintId} : {})});
    }
    if (element.props.children) return cloneElement(element, {children: Children.map(element.props.children as ReactNode, connectLabel)});
    return element;
  };
  return <div className={`field ${className}`}><div className="field-label-row"><label className="field-label" htmlFor={id}>{label}</label>{hint && !inlineHint && <InfoTooltip label={label} text={hint} descriptionId={hintId}/>}</div>{Children.map(children, connectLabel)}{hint && inlineHint && <span className="field-hint" id={hintId}>{hint}</span>}</div>;
}

export function Checkbox({ checked, onChange, children, hint, disabled = false }: PropsWithChildren<{checked: boolean; onChange(value: boolean): void; hint?: string; disabled?: boolean}>) {
  const hintId = useId();
  return <div className="checkbox-with-info"><label className="checkbox-field"><input type="checkbox" aria-label={typeof children === 'string' ? children : undefined} aria-describedby={hint ? hintId : undefined} checked={checked} onChange={event => onChange(event.target.checked)} disabled={disabled}/><span>{children}</span></label>{hint && <InfoTooltip text={hint} label={typeof children === 'string' ? children : undefined} descriptionId={hintId}/>}</div>;
}
