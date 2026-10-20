import { useCallback, useRef, useState } from 'react';
import type { Endpoint, FileEntry, Selection } from '../shared/types';
import { endpointEqual, errorMessage, parentEndpoint } from './utils';

export function useBrowser() {
  const [endpoint, setEndpoint] = useState<Endpoint>({ remote: null, path: '' });
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [selection, setSelectionState] = useState<Selection[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [missingSelection, setMissingSelection] = useState(false);
  const [pathDirty, setPathDirty] = useState(false);
  const [canBack, setCanBack] = useState(false);
  const endpointRef = useRef(endpoint);
  const selectionRef = useRef(selection);
  const history = useRef<Endpoint[]>([]);
  const generation = useRef(0);
  const nextTab = useRef(1);
  const activeTabRef = useRef('tab-1');
  const [activeTab, setActiveTab] = useState('tab-1');
  const tabState = useRef(new Map<string, {endpoint: Endpoint; selection: Selection[]; history: Endpoint[]}>([['tab-1', {endpoint: {remote: null, path: ''}, selection: [], history: []}]]));
  const [tabs, setTabs] = useState([{id: 'tab-1', endpoint: {remote: null, path: ''} as Endpoint}]);
  const publishTabs = useCallback(() => setTabs(Array.from(tabState.current, ([id, value]) => ({id, endpoint: value.endpoint}))), []);


  const setSelection = useCallback((next: Selection[]) => {
    selectionRef.current = next;
    const tab = tabState.current.get(activeTabRef.current);
    if (tab) tab.selection = next;
    setSelectionState(next);
    setMissingSelection(false);
  }, []);
  const load = useCallback(async (target: Endpoint, wanted: Selection[]) => {
    const id = ++generation.current;
    setLoading(true); setError('');
    try {
      const result = await window.rclone.list(target);
      if (id !== generation.current) return;
      setEntries(result);
      const missing = selectionRef.current.some(item => !result.some(entry => entry.name === item.name && entry.isDir === item.isDir));
      // Keep missing selections visible as an error. Never silently expand a saved selection to a whole-folder operation.
      setMissingSelection(missing);
    } catch (reason) {
      if (id !== generation.current) return;
      setEntries([]); setError(errorMessage(reason));
    } finally {
      if (id === generation.current) setLoading(false);
    }
  }, []);
  const navigate = useCallback((target: Endpoint, wanted: Selection[] = [], record = true) => {
    if (record && (endpointRef.current.path || endpointRef.current.remote) && !endpointEqual(endpointRef.current, target)) history.current.push(endpointRef.current);
    endpointRef.current = target;
    setEndpoint(target); setSelection(wanted); setEntries([]); setPathDirty(false);
    setCanBack(history.current.length > 0);
    tabState.current.set(activeTabRef.current, {endpoint: target, selection: wanted, history: history.current});
    publishTabs();
    void load(target, wanted);
  }, [load, setSelection, publishTabs]);
  const reload = useCallback(() => {
    if (endpointRef.current.path || endpointRef.current.remote) void load(endpointRef.current, selectionRef.current);
  }, [load]);
  const back = useCallback(() => {
    const target = history.current.pop();
    if (target) navigate(target, [], false);
  }, [navigate]);
  const up = useCallback(() => {
    const target = parentEndpoint(endpointRef.current);
    if (!endpointEqual(target, endpointRef.current)) navigate(target);
  }, [navigate]);
  const switchTab = useCallback((id: string) => {
    if (id === activeTabRef.current) return;
    const target = tabState.current.get(id);
    if (!target) return;
    activeTabRef.current = id; setActiveTab(id);
    history.current = target.history;
    navigate(target.endpoint, target.selection, false);
  }, [navigate]);
  const newTab = useCallback(() => {
    if (tabState.current.size >= 12) return;
    const id = `tab-${++nextTab.current}`;
    const target = {endpoint: {...endpointRef.current}, selection: [], history: []};
    tabState.current.set(id, target);
    switchTab(id);
  }, [switchTab]);
  const closeTab = useCallback((id: string) => {
    if (tabState.current.size <= 1 || !tabState.current.has(id)) return;
    const ids = Array.from(tabState.current.keys());
    const index = ids.indexOf(id);
    if (id === activeTabRef.current) switchTab(ids[index + 1] || ids[index - 1]);
    tabState.current.delete(id);
    publishTabs();
  }, [switchTab, publishTabs]);
  return { tabs, activeTab, newTab, switchTab, closeTab, endpoint, entries, selection, loading, error, missingSelection, pathDirty, canBack, navigate, reload, back, up, setSelection, setPathDirty };
}

export type BrowserState = ReturnType<typeof useBrowser>;
