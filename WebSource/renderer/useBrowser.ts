import { useCallback, useRef, useState } from 'react';
import type { Endpoint, FileEntry, Selection } from '../shared/types';
import { endpointEqual, errorMessage, parentEndpoint } from './utils';

export function useBrowser() {
  const [endpoint, setEndpoint] = useState<Endpoint>({ remote: null, path: '' });
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [hasListing, setHasListing] = useState(false);
  const [selection, setSelectionState] = useState<Selection[]>([]);
  const [focusedEntry, setFocusedEntry] = useState<Selection | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [missingSelection, setMissingSelection] = useState(false);
  const [pathDirty, setPathDirty] = useState(false);
  const [canBack, setCanBack] = useState(false);
  const [canForward, setCanForward] = useState(false);
  const endpointRef = useRef(endpoint);
  const selectionRef = useRef(selection);
  const history = useRef<Endpoint[]>([]);
  const future = useRef<Endpoint[]>([]);
  const generation = useRef(0);
  const nextTab = useRef(1);
  const activeTabRef = useRef('tab-1');
  const [activeTab, setActiveTab] = useState('tab-1');
  const tabState = useRef(new Map<string, {endpoint: Endpoint; selection: Selection[]; history: Endpoint[]; future: Endpoint[]}>([['tab-1', {endpoint: {remote: null, path: ''}, selection: [], history: [], future: []}]]));
  const [tabs, setTabs] = useState([{id: 'tab-1', endpoint: {remote: null, path: ''} as Endpoint}]);
  const publishTabs = useCallback(() => setTabs(Array.from(tabState.current, ([id, value]) => ({id, endpoint: value.endpoint}))), []);


  const setSelection = useCallback((next: Selection[]) => {
    selectionRef.current = next;
    const tab = tabState.current.get(activeTabRef.current);
    if (tab) tab.selection = next;
    setSelectionState(next);
    setMissingSelection(false);
  }, []);
  const clearSelections = useCallback(() => {
    for (const tab of tabState.current.values()) tab.selection = [];
    setSelection([]);
    setFocusedEntry(null);
  }, [setSelection]);
  const load = useCallback(async (target: Endpoint) => {
    const id = ++generation.current;
    setLoading(true); setError('');
    try {
      const result = await window.rclone.list(target);
      if (id !== generation.current) return;
      // Keep the last successful listing on screen until the current request
      // completes. React batches this replacement with the loading state below.
      setEntries(result);
      setHasListing(true);
      setFocusedEntry(current => current && result.some(entry => entry.name === current.name && entry.isDir === current.isDir) ? current : null);
      const missing = selectionRef.current.some(item => !result.some(entry => entry.name === item.name && entry.isDir === item.isDir));
      // Keep missing selections visible as an error. Never silently expand a saved selection to a whole-folder operation.
      setMissingSelection(missing);
    } catch (reason) {
      if (id !== generation.current) return;
      setError(errorMessage(reason));
    } finally {
      if (id === generation.current) setLoading(false);
    }
  }, []);
  const navigate = useCallback((target: Endpoint, wanted: Selection[] = [], record = true) => {
    if (record && !endpointEqual(endpointRef.current, target)) {
      if (endpointRef.current.path || endpointRef.current.remote) history.current = [...history.current.slice(-99), endpointRef.current];
      future.current = [];
    }
    endpointRef.current = target;
    setEndpoint(target); setSelection(wanted); setFocusedEntry(null); setPathDirty(false);
    setCanBack(history.current.length > 0); setCanForward(future.current.length > 0);
    tabState.current.set(activeTabRef.current, {endpoint: target, selection: wanted, history: history.current, future: future.current});
    publishTabs();
    void load(target);
  }, [load, setSelection, publishTabs]);
  const reload = useCallback(() => {
    if (endpointRef.current.path || endpointRef.current.remote) void load(endpointRef.current);
  }, [load]);
  const back = useCallback(() => {
    const target = history.current.pop();
    if (target) { future.current = [...future.current.slice(-99), endpointRef.current]; navigate(target, [], false); }
  }, [navigate]);
  const forward = useCallback(() => {
    const target = future.current.pop();
    if (target) { history.current = [...history.current.slice(-99), endpointRef.current]; navigate(target, [], false); }
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
    history.current = target.history; future.current = target.future;
    navigate(target.endpoint, target.selection, false);
  }, [navigate]);
  const newTab = useCallback(() => {
    if (tabState.current.size >= 12) return;
    const id = `tab-${++nextTab.current}`;
    const target = {endpoint: {...endpointRef.current}, selection: [], history: [], future: []};
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
  return { tabs, activeTab, newTab, switchTab, closeTab, endpoint, entries, hasListing, selection, focusedEntry, loading, error, missingSelection, pathDirty, canBack, canForward, navigate, reload, back, forward, up, setSelection, clearSelections, setFocusedEntry, setPathDirty };
}

export type BrowserState = ReturnType<typeof useBrowser>;
