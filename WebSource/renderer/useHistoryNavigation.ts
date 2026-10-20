import {useEffect, useRef} from 'react';

type Direction = 'back'|'forward';
type Gesture = {direction: Direction; domTime?: number; nativeTime?: number; dispatched: boolean; receivedAt: number; timer?: ReturnType<typeof setTimeout>};
const eventEpoch = (stamp: number) => stamp > 1e12 ? stamp : performance.timeOrigin + stamp;

/** Pair native and DOM copies of the same physical press without debouncing
 * successive presses. The native host may miss events translated by a driver. */
export function useHistoryNavigation(navigate: (direction: Direction, x?: number, y?: number) => void) {
  const callback = useRef(navigate); callback.current = navigate;
  const gestures = useRef<Gesture[]>([]);
  const down = useRef(new Map<number,number>());
  const released = useRef(new Map<number,number>());
  useEffect(() => {
    const recent = () => {
      gestures.current = gestures.current.filter(item => Date.now()-item.receivedAt < 2500 || item.nativeTime !== undefined && [...down.current.values()].some(time => Math.abs(time-item.nativeTime!)<=80));
      return gestures.current;
    };
    const native = (event: Event) => {
      const detail=(event as CustomEvent).detail;
      if (detail?.direction !== 'back' && detail?.direction !== 'forward') return;
      const direction=detail.direction as Direction;
      const time=typeof detail.eventTime === 'number' && Number.isFinite(detail.eventTime) ? detail.eventTime : Date.now();
      const list=recent();
      if (list.some(item => item.direction===direction && item.nativeTime===time)) return;
      const match=list.filter(item => item.direction===direction && item.nativeTime===undefined && item.domTime!==undefined && Math.abs(item.domTime-time)<=80).sort((a,b)=>Math.abs(a.domTime!-time)-Math.abs(b.domTime!-time))[0];
      if (match) {
        match.nativeTime=time;clearTimeout(match.timer);
        if (match.dispatched) return;
        match.dispatched=true;
      } else list.push({direction,nativeTime:time,dispatched:true,receivedAt:Date.now()});
      callback.current(direction,detail.x,detail.y);
    };
    const sideButton = (event: MouseEvent) => {
      if (event.button!==3 && event.button!==4) return;
      event.preventDefault();event.stopImmediatePropagation();
      const stamp=eventEpoch(event.timeStamp),direction=event.button===3?'back':'forward';
      if (event.type==='mousedown') {down.current.set(event.button,stamp);released.current.delete(event.button);return;}
      // Most engines emit auxclick after mouseup; accept it only as a fallback.
      if (event.type==='auxclick' && Math.abs(stamp-(released.current.get(event.button)||0))<120) {released.current.delete(event.button);return;}
      if (event.type==='mouseup') released.current.set(event.button,stamp);
      const time=down.current.get(event.button)??stamp,list=recent();
      down.current.delete(event.button);
      if (list.some(item=>item.direction===direction&&item.domTime===time)) return;
      const match=list.filter(item=>item.direction===direction&&item.domTime===undefined&&item.nativeTime!==undefined&&Math.abs(item.nativeTime-time)<=80).sort((a,b)=>Math.abs(a.nativeTime!-time)-Math.abs(b.nativeTime!-time))[0];
      if (match) {match.domTime=time;return;}
      const gesture:Gesture={direction,domTime:time,dispatched:false,receivedAt:Date.now()};
      const x=event.clientX,y=event.clientY;
      gesture.timer=setTimeout(()=>{if(!gesture.dispatched){gesture.dispatched=true;callback.current(direction,x,y);}},50);
      list.push(gesture);
    };
    const key = (event: KeyboardEvent) => {
      if ((event.target as HTMLElement)?.closest?.('input,textarea,select,[contenteditable="true"]')) return;
      const modifier=event.metaKey||event.ctrlKey;
      const direction=event.key==='BrowserBack'||event.altKey&&event.key==='ArrowLeft'||modifier&&(event.code==='BracketLeft'||event.key==='[') ? 'back'
        : event.key==='BrowserForward'||event.altKey&&event.key==='ArrowRight'||modifier&&(event.code==='BracketRight'||event.key===']') ? 'forward' : null;
      if (!direction) return;
      event.preventDefault();event.stopImmediatePropagation();callback.current(direction);
    };
    window.addEventListener('rbn:navigate-history',native);window.addEventListener('keydown',key);
    for(const type of ['mousedown','mouseup','auxclick'])document.addEventListener(type,sideButton as EventListener,true);
    return()=>{window.removeEventListener('rbn:navigate-history',native);window.removeEventListener('keydown',key);for(const type of ['mousedown','mouseup','auxclick'])document.removeEventListener(type,sideButton as EventListener,true);for(const item of gestures.current)clearTimeout(item.timer);};
  },[]);
}
