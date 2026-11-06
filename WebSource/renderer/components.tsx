import { createPortal } from 'react-dom';
import { Children, cloneElement, isValidElement, useEffect, useId, useRef, useState, useLayoutEffect, type ButtonHTMLAttributes, type PropsWithChildren, type ReactElement, type ReactNode } from 'react';
import { X, WarningCircle, Info } from '@phosphor-icons/react';
import type { Translate } from './i18n';

export function IconButton({ title, children, className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button type="button" title={title} aria-label={props['aria-label'] || title} className={`icon-button ${className}`} {...props}>{children}</button>;
}

/**
 * A sheet. Clicking the dimmed area around it (in the page or, on macOS, over
 * the native toolbar) closes it like Cancel. When it holds unsaved edits
 * (`guarded`) or cannot be dismissed right now, the click gives a short nudge
 * instead, so nothing is lost by a stray click.
 */
export function Dialog({ title, children, onClose, className = '', t, dismissible = true, guarded = false }: PropsWithChildren<{title: string; onClose(): void; className?: string; t: Translate; dismissible?: boolean; guarded?: boolean}>) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  const state = useRef({dismissible, guarded});
  state.current = {dismissible, guarded};
  const pressedOutside = useRef(false);
  const outside = (event: {clientX: number; clientY: number}) => {
    const box = ref.current?.getBoundingClientRect();
    return Boolean(box) && (event.clientX < box!.left || event.clientX > box!.right || event.clientY < box!.top || event.clientY > box!.bottom);
  };
  const dismissFromBackdrop = () => {
    const dialog = ref.current;
    if (!dialog) return;
    if (state.current.dismissible && !state.current.guarded) { closeRef.current(); return; }
    dialog.removeAttribute('data-nudge');
    void dialog.offsetWidth; // restart the nudge if it is already playing
    dialog.setAttribute('data-nudge', '');
    window.setTimeout(() => dialog.removeAttribute('data-nudge'), 320);
  };
  // Layout-effect cleanup runs before React detaches the <dialog>, so the
  // exit snapshot is taken from the live node in the same frame.
  useLayoutEffect(() => {
    const dialog = ref.current;
    dialog?.showModal();
    const nativeDismiss = () => dismissFromBackdrop();
    dialog?.addEventListener('rbn-dismiss', nativeDismiss);
    return () => {
      dialog?.removeEventListener('rbn-dismiss', nativeDismiss);
      if (dialog) leaveDialogGhost(dialog);
      if (dialog?.open) dialog.close();
    };
  }, []);
  return <dialog ref={ref} className={`dialog ${className}`} aria-labelledby={titleId}
    onCancel={event => { event.preventDefault(); if (dismissible) closeRef.current(); }}
    onPointerDown={event => { pressedOutside.current = event.target === event.currentTarget && outside(event); }}
    onClick={event => { if (pressedOutside.current && event.target === event.currentTarget && outside(event)) dismissFromBackdrop(); pressedOutside.current = false; }}>
    <header className="dialog-header"><h2 id={titleId}>{title}</h2><IconButton title={t('close')} disabled={!dismissible} onClick={onClose}><X size={18}/></IconButton></header>
    {children}
  </dialog>;
}

/**
 * A sheet is removed from the DOM as soon as its owner stops rendering it, so
 * no close path (Esc, Cancel, Save, a state change elsewhere) can animate it.
 * Leave an inert copy in its place that fades out once. Reduce Motion skips it.
 */
function leaveDialogGhost(dialog: HTMLDialogElement) {
  if (!dialog.open || !dialog.isConnected || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  // Read live values before anything changes: scroll offsets and the current
  // opacity (a sheet closed during its entrance fades from where it is).
  const scrolled = [...dialog.querySelectorAll<HTMLElement>('*')].map((node, index) => [index, node.scrollTop] as const).filter(([, top]) => top > 0);
  const opacity = getComputedStyle(dialog).opacity;
  const copy = dialog.cloneNode(true) as HTMLDialogElement;
  copy.removeAttribute('open');
  copy.setAttribute('aria-hidden', 'true');
  copy.inert = true;
  // A cloned radio keeps its name and would join (and uncheck) the live group.
  for (const node of [copy, ...copy.querySelectorAll<HTMLElement>('[id], [data-testid], [role], [name]')]) {
    node.removeAttribute('id'); node.removeAttribute('data-testid'); node.removeAttribute('role'); node.removeAttribute('name');
  }
  const layer = document.createElement('div');
  layer.className = 'dialog-ghost';
  layer.setAttribute('aria-hidden', 'true');
  const scrim = document.createElement('div');
  scrim.className = 'dialog-ghost-scrim';
  layer.append(scrim, copy);
  document.body.append(layer);
  const copies = [...copy.querySelectorAll<HTMLElement>('*')];
  for (const [index, top] of scrolled) if (copies[index]) copies[index].scrollTop = top;
  const exit = copy.animate([{opacity}, {opacity: 0, transform: 'translateY(6px) scale(0.97)'}], {duration: 180, easing: 'cubic-bezier(0.23, 1, 0.32, 1)', fill: 'forwards'});
  const remove = () => layer.remove();
  exit.finished.then(remove, remove);
  window.setTimeout(remove, 400);
}

export function Notice({ children, kind = 'info', onClose }: PropsWithChildren<{kind?: 'info' | 'error' | 'success' | 'warning'; onClose?: () => void}>) {
  return <div className={`notice ${kind}`} role={kind === 'error' ? 'alert' : 'status'}>
    {kind === 'error' || kind === 'warning' ? <WarningCircle size={18} weight="duotone"/> : <Info size={18}/>}
    <div>{children}</div>
    {onClose && <IconButton title={document.documentElement.lang === 'ja' ? '閉じる' : document.documentElement.lang === 'en' ? 'Close' : '關閉'} onClick={onClose}><X size={16}/></IconButton>}
  </div>;
}

export function EmptyState({ icon, title, children, action, compact = false, kind = 'info' }: PropsWithChildren<{ icon: ReactNode; title: string; action?: ReactNode; compact?: boolean; kind?: 'info'|'error' }>) {
  return <div className={`empty-state ${compact ? 'compact' : ''}`}><div className={`status-card status-card-${kind}`} role={kind === 'error' ? 'alert' : undefined}><div className="empty-icon">{icon}</div><h3>{title}</h3>{children && <p>{children}</p>}{action && <div className="status-card-actions">{action}</div>}</div></div>;
}

/** Temporary feedback stays out of document flow; only its opacity/transform animate. */
export function FloatingNotice({ message, kind = 'success', serial = 0, onClose }: {message: string; kind?: 'success'|'error'|'info'; serial?: number; onClose(): void}) {
  const [visible, setVisible] = useState(false);
  const anchor = useRef<HTMLSpanElement>(null);
  const [container, setContainer] = useState<HTMLElement>(document.body);
  useLayoutEffect(() => { setContainer(anchor.current?.closest('dialog') || document.body); }, []);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const finish = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const callback = useRef(onClose); callback.current = onClose;
  const dismiss = () => { clearTimeout(finish.current); clearTimeout(timer.current); setVisible(false); finish.current = setTimeout(() => callback.current(), 200); };
  const schedule = () => { clearTimeout(timer.current); if (message) timer.current = setTimeout(dismiss, 5000); };
  useEffect(() => {
    clearTimeout(timer.current); clearTimeout(finish.current);
    if (!message) { setVisible(false); return; }
    const frame = requestAnimationFrame(() => setVisible(true)); schedule();
    return () => { cancelAnimationFrame(frame); clearTimeout(timer.current); clearTimeout(finish.current); };
  }, [message, kind, serial]);
  if (!message) return <span ref={anchor} hidden aria-hidden="true"/>;
  return <><span ref={anchor} hidden aria-hidden="true"/>{createPortal(<div className={`app-notice floating-notice floating-${kind}`} data-visible={visible} onPointerEnter={() => clearTimeout(timer.current)} onPointerLeave={schedule} onFocusCapture={() => clearTimeout(timer.current)} onBlurCapture={schedule}><Notice kind={kind} onClose={dismiss}>{message}</Notice></div>, container)}</>;
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
  const openTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const show = () => { clearTimeout(closeTimer.current); clearTimeout(openTimer.current); setOpen(true); };
  // Like a macOS help tag: hovering waits a moment, focus and click open at once.
  const hover = () => { clearTimeout(closeTimer.current); clearTimeout(openTimer.current); if (!open) openTimer.current = setTimeout(() => setOpen(true), 400); };
  const leave = () => { clearTimeout(openTimer.current); if (!pinned) closeTimer.current = setTimeout(() => setOpen(false), 120); };
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
  useEffect(() => () => { clearTimeout(closeTimer.current); clearTimeout(openTimer.current); }, []);
  const info = document.documentElement.lang === 'ja' ? '説明' : document.documentElement.lang === 'en' ? 'More information' : '說明';
  return <><span id={descId} className="sr-only">{text}</span><button ref={button} type="button" className="info-tooltip-trigger" aria-label={label ? `${label} — ${info}` : info} aria-describedby={descId} aria-expanded={open} aria-controls={open ? tipId : undefined} onPointerEnter={hover} onPointerLeave={leave} onFocus={() => { if (!suppressFocus.current) show(); }} onBlur={() => { if (!pinned) setOpen(false); }} onClick={() => { if (pinned) close(); else { setOpen(true); setPinned(true); } }}><Info size={15}/></button>{open && createPortal(<div ref={bubble} id={tipId} role="tooltip" className="info-tooltip" style={{position: container === document.body ? 'fixed' : 'absolute', ...position}} onPointerEnter={show} onPointerLeave={leave}>{text}</div>, container)}</>;
}

function shortHint(text: string): string {
  const match = text.match(/^.*?(?:。|[.!?](?=\s|$))/u);
  const first = match?.[0] || text;
  return first.length <= 120 ? first : '';
}

export function Field({ label, hint, summary, children, className = '', inlineHint = false }: PropsWithChildren<{label: string; hint?: string; summary?: string; className?: string; inlineHint?: boolean}>) {
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
  return <div className={`field ${className}`}><div className="field-label-row"><label className="field-label" htmlFor={id}>{label}</label>{hint && !inlineHint && (summary || shortHint(hint) !== hint) && <InfoTooltip label={label} text={hint} descriptionId={hintId}/>}</div>{Children.map(children, connectLabel)}{(summary || hint && !inlineHint && shortHint(hint)) && <span className={`field-hint ${summary ? '' : 'option-brief'}`} id={!summary && hint && shortHint(hint) === hint ? hintId : undefined}>{summary || shortHint(hint!)}</span>}{hint && inlineHint && <span className="field-hint" id={hintId}>{hint}</span>}</div>;
}

export function Checkbox({ checked, onChange, children, hint, disabled = false }: PropsWithChildren<{checked: boolean; onChange(value: boolean): void; hint?: string; disabled?: boolean}>) {
  const hintId = useId();
  // The help button sits on the title line, right after the label, so every row aligns.
  return <div className="checkbox-with-info"><label className="checkbox-field"><input type="checkbox" aria-label={typeof children === 'string' ? children : undefined} aria-describedby={hint ? hintId : undefined} checked={checked} onChange={event => onChange(event.target.checked)} disabled={disabled}/><span className="checkbox-copy"><span className="checkbox-title"><span>{children}</span>{hint && shortHint(hint) !== hint && <InfoTooltip text={hint} label={typeof children === 'string' ? children : undefined} descriptionId={hintId}/>}</span>{hint && shortHint(hint) && <small className="option-brief" id={shortHint(hint) === hint ? hintId : undefined}>{shortHint(hint)}</small>}</span></label></div>;
}
