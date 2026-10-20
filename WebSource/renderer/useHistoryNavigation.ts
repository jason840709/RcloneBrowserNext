import {useEffect, useRef} from 'react';

type Direction = 'back'|'forward';
type Phase = 'down'|'up';
type NativePhase = Phase|'swipe'|'command';
type Gesture = {direction: Direction; domDown?: number; domUp?: number; nativeTime?: number; nativePhase?: NativePhase; dispatched: boolean; receivedAt: number; timer?: ReturnType<typeof setTimeout>};
const eventEpoch = (stamp: number) => stamp > 1e12 ? stamp : performance.timeOrigin + stamp;
const isEditing = (target: EventTarget|null) => target instanceof HTMLElement && Boolean(target.closest('input,textarea,select,[contenteditable="true"]'));

/** Pair native and DOM copies of the same physical press without debouncing
 * successive presses. The native host may miss events translated by a driver. */
export function useHistoryNavigation(navigate: (direction: Direction, x?: number, y?: number) => void) {
  const callback = useRef(navigate); callback.current = navigate;
  const gestures = useRef<Gesture[]>([]);
  const down = useRef(new Map<number,Gesture>());
  const released = useRef(new Map<number,number>());
  useEffect(() => {
    const recent = () => {
      gestures.current = gestures.current.filter(item => Date.now()-item.receivedAt < 2500 || [...down.current.values()].includes(item));
      return gestures.current;
    };
    const dispatchDOM = (gesture: Gesture, x: number, y: number) => {
      if (gesture.dispatched || gesture.timer) return;
      // Give the native copy a chance to arrive, but do not require a mouseup:
      // some mouse drivers deliver only one phase to the web view.
      gesture.timer = setTimeout(() => {
        if (!gesture.dispatched) { gesture.dispatched = true; callback.current(gesture.direction, x, y); }
      }, 50);
    };
    const native = (event: Event) => {
      const detail=(event as CustomEvent).detail;
      if (detail?.direction !== 'back' && detail?.direction !== 'forward') return;
      const direction=detail.direction as Direction;
      const phase: NativePhase = detail.phase === 'swipe' || detail.phase === 'command' || detail.phase === 'up' ? detail.phase : 'down';
      if (phase === 'command' && isEditing(document.activeElement)) return;
      const time=typeof detail.eventTime === 'number' && Number.isFinite(detail.eventTime) ? detail.eventTime : Date.now();
      const list=recent();
      if (list.some(item => item.direction===direction && item.nativeTime===time && item.nativePhase===phase)) return;
      // A driver-generated native swipe is a completed navigation action, not
      // a mouse down/up pair. Keep it separate from nearby physical clicks.
      if (phase === 'swipe' || phase === 'command') {
        list.push({direction,nativeTime:time,nativePhase:phase,dispatched:true,receivedAt:Date.now()});
        callback.current(direction,detail.x,detail.y);
        return;
      }
      const domTime = (item: Gesture) => phase === 'up' ? item.domUp : item.domDown ?? item.domUp;
      let match=list.filter(item => item.direction===direction && item.nativeTime===undefined && domTime(item)!==undefined && Math.abs(domTime(item)!-time)<=80).sort((a,b)=>Math.abs(domTime(a)!-time)-Math.abs(domTime(b)!-time))[0];
      // If the host saw only the release, it can arrive after a long DOM press.
      // Pair it with that still-held gesture, not a new navigation command.
      if (!match && phase === 'up') {
        const held = down.current.get(direction === 'back' ? 3 : 4);
        if (held?.nativeTime === undefined && held?.domDown !== undefined && held.domDown <= time + 80) match = held;
      }
      if (match) {
        match.nativeTime=time;match.nativePhase=phase;clearTimeout(match.timer);
        if (match.dispatched) return;
        match.dispatched=true;
      } else list.push({direction,nativeTime:time,nativePhase:phase,dispatched:true,receivedAt:Date.now()});
      callback.current(direction,detail.x,detail.y);
    };
    const sideButton = (event: MouseEvent) => {
      // A driver may omit a release. Later mouse events still report which
      // buttons are physically held, so retire stale presses before pairing.
      if (event.type === 'mousedown' || event.type === 'mouseup') {
        for (const button of down.current.keys()) {
          if (button !== event.button && (event.buttons & (1 << button)) === 0) down.current.delete(button);
        }
      }
      if (event.button!==3 && event.button!==4) return;
      event.preventDefault();event.stopImmediatePropagation();
      const stamp=eventEpoch(event.timeStamp),direction=event.button===3?'back':'forward';
      const list = recent();
      const matchNative = (phase: Phase) => list.filter(item => item.direction === direction && item.nativeTime !== undefined && item.nativePhase === phase && item.domDown === undefined && item.domUp === undefined && Math.abs(item.nativeTime - stamp) <= 80)
        .sort((a,b) => Math.abs(a.nativeTime! - stamp) - Math.abs(b.nativeTime! - stamp))[0];
      if (event.type==='mousedown') {
        released.current.delete(event.button);
        const duplicate = list.find(item => item.direction === direction && item.domDown === stamp);
        if (duplicate) return;
        const gesture = matchNative('down') || {direction, dispatched: false, receivedAt: Date.now()} as Gesture;
        gesture.domDown = stamp;
        if (!list.includes(gesture)) list.push(gesture);
        down.current.set(event.button, gesture);
        dispatchDOM(gesture, event.clientX, event.clientY);
        return;
      }
      // Most engines emit auxclick after mouseup; accept it only as a fallback.
      if (event.type==='auxclick' && Math.abs(stamp-(released.current.get(event.button)||0))<120) {released.current.delete(event.button);return;}
      if (event.type==='mouseup') released.current.set(event.button,stamp);
      const held=down.current.get(event.button);
      down.current.delete(event.button);
      if (list.some(item=>item.direction===direction&&item.domUp===stamp)) return;
      const gesture = held || matchNative('up') || matchNative('down') || {direction, dispatched: false, receivedAt: Date.now()} as Gesture;
      gesture.domUp=stamp;
      if (!list.includes(gesture)) list.push(gesture);
      dispatchDOM(gesture, event.clientX, event.clientY);
    };
    const key = (event: KeyboardEvent) => {
      if (isEditing(event.target)) return;
      const modifier=event.metaKey||event.ctrlKey;
      const direction=event.key==='BrowserBack'||event.altKey&&event.key==='ArrowLeft'||modifier&&(event.code==='BracketLeft'||event.key==='[') ? 'back'
        : event.key==='BrowserForward'||event.altKey&&event.key==='ArrowRight'||modifier&&(event.code==='BracketRight'||event.key===']') ? 'forward' : null;
      if (!direction) return;
      event.preventDefault();event.stopImmediatePropagation();callback.current(direction);
    };
    window.addEventListener('rbn:navigate-history',native);window.addEventListener('keydown',key);
    for(const type of ['mousedown','mouseup','auxclick'])document.addEventListener(type,sideButton as EventListener,true);
    return()=>{window.removeEventListener('rbn:navigate-history',native);window.removeEventListener('keydown',key);for(const type of ['mousedown','mouseup','auxclick'])document.removeEventListener(type,sideButton as EventListener,true);for(const item of gestures.current)clearTimeout(item.timer);gestures.current=[];down.current.clear();released.current.clear();};
  },[]);
}
