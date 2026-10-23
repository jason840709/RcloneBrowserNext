import { useCallback, useEffect, useRef, useState } from 'react';
import type { Endpoint, FileEntry, Selection } from '../shared/types';
import { ListingCache, relatedEndpoints } from './listingCache';
import { endpointEqual, errorMessage, parentEndpoint } from './utils';

type Tab = { endpoint: Endpoint; selection: Selection[]; history: Endpoint[]; future: Endpoint[] };
type Plan = Tab & { tabId: string; intent: 'navigate' | 'back' | 'forward' | 'refresh' | 'tab'; closeTabId?: string };
type NavigationFailure = { plan: Plan; message: string };
type Pending = { requestId: string; plan: Plan; epoch: number; cancelled: boolean; cancelling: boolean; cancelPromise?: Promise<void> };
const initialEndpoint: Endpoint = { remote: null, path: '' };

export function useBrowser() {
  // Path and rows are one committed value. Pending navigation never relabels
  // an old listing, or modifies history before a successful response.
  const [listing, setListing] = useState<{ endpoint: Endpoint; entries: FileEntry[]; hasListing: boolean }>({ endpoint: initialEndpoint, entries: [], hasListing: false });
  const { endpoint, entries, hasListing } = listing;
  const [selection, setSelectionState] = useState<Selection[]>([]);
  const [focusedEntry, setFocusedEntry] = useState<Selection | null>(null);
  const [loading, setLoading] = useState(false);
  const [pendingEndpoint, setPendingEndpoint] = useState<Endpoint | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [error, setError] = useState('');
  const [missingSelection, setMissingSelection] = useState(false);
  const [pathDirty, setPathDirty] = useState(false);
  const [canBack, setCanBack] = useState(false);
  const [canForward, setCanForward] = useState(false);
  const endpointRef = useRef(initialEndpoint);
  const hasListingRef = useRef(false);
  const deferredRefresh = useRef(false);
  const selectionRef = useRef<Selection[]>([]);
  const history = useRef<Endpoint[]>([]);
  const future = useRef<Endpoint[]>([]);
  const cache = useRef<ListingCache | null>(null);
  if (!cache.current) cache.current = new ListingCache();
  const pending = useRef<Pending | null>(null);
  const cancellations = useRef(new Set<Promise<void>>());
  const lastFailed = useRef<Plan | null>(null);
  const initialPlan = useRef<Plan | null>(null);
  const mounted = useRef(true);
  const nextTab = useRef(1);
  const activeTabRef = useRef('tab-1');
  const [activeTab, setActiveTab] = useState('tab-1');
  const tabState = useRef(new Map<string, Tab>([['tab-1', { endpoint: initialEndpoint, selection: [], history: [], future: [] }]]));
  const [tabs, setTabs] = useState([{ id: 'tab-1', endpoint: initialEndpoint }]);
  const publishTabs = useCallback(() => setTabs(Array.from(tabState.current, ([id, value]) => ({ id, endpoint: value.endpoint }))), []);

  const setSelection = useCallback((next: Selection[]) => {
    selectionRef.current = next;
    const tab = tabState.current.get(activeTabRef.current);
    if (tab) tab.selection = next;
    if (pending.current?.plan.intent === 'refresh') pending.current.plan.selection = next;
    setSelectionState(next);
    setMissingSelection(false);
  }, []);
  const clearSelections = useCallback(() => {
    for (const tab of tabState.current.values()) tab.selection = [];
    if (pending.current) pending.current.plan.selection = [];
    setSelection([]);
    setFocusedEntry(null);
  }, [setSelection]);

  const cancelRequest = useCallback((request: Pending): Promise<void> => {
    request.cancelled = true;
    if (request.cancelPromise) return request.cancelPromise;
    const promise = window.rclone.cancelList(request.requestId).then(() => {});
    request.cancelPromise = promise;
    cancellations.current.add(promise);
    void promise.then(() => cancellations.current.delete(promise), () => cancellations.current.delete(promise));
    return promise;
  }, []);
  const retire = useCallback(() => {
    const request = pending.current;
    pending.current = null;
    if (request) void cancelRequest(request).catch(() => {});
  }, [cancelRequest]);

  const commit = useCallback((plan: Plan, result: FileEntry[], retainedFailure?: NavigationFailure) => {
    if (!mounted.current || !tabState.current.has(plan.tabId)) return;
    endpointRef.current = plan.endpoint;
    hasListingRef.current = true;
    deferredRefresh.current = false;
    selectionRef.current = plan.selection;
    history.current = plan.history;
    future.current = plan.future;
    activeTabRef.current = plan.tabId;
    tabState.current.set(plan.tabId, { endpoint: plan.endpoint, selection: plan.selection, history: plan.history, future: plan.future });
    if (plan.closeTabId) tabState.current.delete(plan.closeTabId);
    const failure = retainedFailure && tabState.current.has(retainedFailure.plan.tabId) ? retainedFailure : undefined;
    setListing({ endpoint: plan.endpoint, entries: result, hasListing: true });
    setSelectionState(plan.selection);
    setFocusedEntry(current => plan.intent === 'refresh' && current && result.some(entry => entry.name === current.name && entry.isDir === current.isDir) ? current : null);
    // A saved selection must never silently become a whole-folder transfer.
    setMissingSelection(plan.selection.some(item => !result.some(entry => entry.name === item.name && entry.isDir === item.isDir)));
    setActiveTab(plan.tabId);
    setCanBack(plan.history.length > 0);
    setCanForward(plan.future.length > 0);
    if (plan.intent !== 'refresh') setPathDirty(false);
    setError(failure?.message || ''); setLoading(false); setCancelling(false);
    setPendingEndpoint(null);
    lastFailed.current = failure?.plan || null;
    initialPlan.current = null;
    publishTabs();
  }, [publishTabs]);

  const currentPlan = useCallback((): Plan => ({ tabId: activeTabRef.current, intent: 'refresh', endpoint: endpointRef.current, selection: selectionRef.current, history: history.current, future: future.current }), []);
  const load = useCallback(function load(plan: Plan, force = false, retainedFailure?: NavigationFailure) {
    if (!mounted.current || pending.current?.cancelling) return;
    // Starting a fresh read of the retained location consumes its deferred
    // refresh. A failed or cancelled refresh must not retry itself forever.
    if (endpointEqual(plan.endpoint, endpointRef.current)) deferredRefresh.current = false;
    if (!hasListingRef.current && !endpointRef.current.path && !endpointRef.current.remote) initialPlan.current = plan;
    retire();
    lastFailed.current = retainedFailure?.plan || null;
    setError(retainedFailure?.message || ''); setCancelling(false);
    if (plan.intent !== 'refresh') setPathDirty(false);
    const remembered = force ? undefined : cache.current!.get(plan.endpoint);
    if (remembered !== undefined) { commit(plan, remembered, retainedFailure); return; }
    const request: Pending = { requestId: crypto.randomUUID(), plan, epoch: cache.current!.epoch, cancelled: false, cancelling: false };
    pending.current = request;
    setPendingEndpoint(plan.endpoint);
    setLoading(true);
    void window.rclone.list(plan.endpoint, { requestId: request.requestId }).then(result => {
      if (!mounted.current || pending.current !== request || request.cancelled) return;
      if (result.requestId !== request.requestId || !Array.isArray(result.entries) || (result.status !== 'completed' && result.status !== 'cancelled')) throw new Error('The folder response did not match its request.');
      pending.current = null;
      if (result.status === 'cancelled') {
        setLoading(false); setPendingEndpoint(null);
        if (deferredRefresh.current) load(currentPlan(), true, retainedFailure);
        return;
      }
      cache.current!.put(plan.endpoint, result.entries, request.epoch);
      commit(plan, result.entries, retainedFailure);
    }).catch(reason => {
      if (!mounted.current || pending.current !== request || request.cancelled) return;
      // A bridge timeout may precede native cleanup. Keep that cancellation
      // observable to resetContext before it allows configuration writes.
      void cancelRequest(request).catch(() => {});
      pending.current = null;
      lastFailed.current = plan;
      const message = errorMessage(reason);
      setError(message); setLoading(false); setCancelling(false);
      setPendingEndpoint(null);
      // An unrelated navigation can hide a required refresh of the retained
      // rows. Recover those rows while preserving the failed target for Retry.
      if (deferredRefresh.current) load(currentPlan(), true, { plan, message });
    });
  }, [commit, retire, cancelRequest, currentPlan]);

  const navigate = useCallback((target: Endpoint, wanted: Selection[] = [], record = true) => {
    const changed = !endpointEqual(endpointRef.current, target);
    load({ tabId: activeTabRef.current, intent: 'navigate', endpoint: { ...target }, selection: wanted,
      history: record && changed && hasListingRef.current ? [...history.current.slice(-99), endpointRef.current] : history.current,
      future: record && changed ? [] : future.current });
  }, [load]);
  const reload = useCallback(() => {
    if (pending.current?.cancelling) return;
    setPathDirty(false);
    cache.current!.clear();
    if (endpointRef.current.path || endpointRef.current.remote) load(currentPlan(), true);
    else if (pending.current) load(pending.current.plan, true);
    else if (initialPlan.current) load(initialPlan.current, true);
    else { retire(); setLoading(false); setPendingEndpoint(null); }
  }, [load, currentPlan, retire]);
  const refreshCurrent = useCallback(() => {
    if (pending.current) return;
    if (endpointRef.current.path || endpointRef.current.remote) load(currentPlan(), true);
  }, [load, currentPlan]);
  const invalidate = useCallback((target: Endpoint): boolean => {
    cache.current!.invalidate(target);
    const affectsCurrent = relatedEndpoints(endpointRef.current, target);
    if (affectsCurrent && hasListingRef.current) deferredRefresh.current = true;
    const request = pending.current;
    if (request && !request.cancelled && relatedEndpoints(request.plan.endpoint, target)) load(request.plan, true);
    else if (request && !request.cancelled) request.epoch = cache.current!.epoch;
    return affectsCurrent;
  }, [load]);
  const resetContext = useCallback((): Promise<void> => {
    cache.current!.clear();
    deferredRefresh.current = false;
    const intended = pending.current?.plan || initialPlan.current;
    if (!hasListingRef.current && intended) {
      // Before the first listing there is no old data to retain. Remember the
      // intended location so a config reload can retry it instead of a blank.
      endpointRef.current = intended.endpoint;
      const tab = tabState.current.get(activeTabRef.current);
      if (tab) tab.endpoint = endpointRef.current;
      publishTabs();
    }
    retire();
    lastFailed.current = null;
    clearSelections();
    hasListingRef.current = false;
    setListing({ endpoint: endpointRef.current, entries: [], hasListing: false });
    setLoading(false); setCancelling(false); setError(''); setPathDirty(false);
    setPendingEndpoint(null);
    // A connection/configuration change must wait until old native readers have
    // stopped, including a superseded request whose cancellation is in flight.
    return Promise.all([...cancellations.current]).then(() => {});
  }, [clearSelections, retire, publishTabs]);
  const cancelLoading = useCallback(async () => {
    const request = pending.current;
    if (!request) return;
    if (request.cancelling) return request.cancelPromise;
    request.cancelling = true;
    request.cancelled = true;
    setCancelling(true);
    try { await cancelRequest(request); }
    catch (reason) { if (mounted.current && pending.current === request) setError(errorMessage(reason)); }
    finally {
      if (mounted.current && pending.current === request) {
        pending.current = null;
        setLoading(false); setCancelling(false);
        setPendingEndpoint(null);
        if (deferredRefresh.current) load(currentPlan(), true);
      }
    }
  }, [cancelRequest, load, currentPlan]);
  const retry = useCallback(() => {
    if (lastFailed.current && tabState.current.has(lastFailed.current.tabId)) load(lastFailed.current, true);
    else { lastFailed.current = null; setError(''); refreshCurrent(); }
  }, [load, refreshCurrent]);

  const travel = useCallback((direction: 'back' | 'forward') => {
    const request = pending.current;
    const base = request && (request.plan.intent === 'back' || request.plan.intent === 'forward') ? request.plan : currentPlan();
    const source = direction === 'back' ? base.history : base.future;
    const target = source.at(-1);
    if (!target) return;
    load({ tabId: base.tabId, intent: direction, endpoint: target, selection: [],
      history: direction === 'back' ? source.slice(0, -1) : [...base.history.slice(-99), base.endpoint],
      future: direction === 'forward' ? source.slice(0, -1) : [...base.future.slice(-99), base.endpoint] });
  }, [load, currentPlan]);
  const back = useCallback(() => travel('back'), [travel]);
  const forward = useCallback(() => travel('forward'), [travel]);
  const up = useCallback(() => {
    const target = parentEndpoint(endpointRef.current);
    if (!endpointEqual(target, endpointRef.current)) navigate(target);
  }, [navigate]);
  const switchTab = useCallback((id: string) => {
    if (id === activeTabRef.current) { if (hasListingRef.current && pending.current && !pending.current.cancelling) load(currentPlan()); return; }
    const target = tabState.current.get(id);
    if (target) load({ ...target, tabId: id, intent: 'tab' });
  }, [load, currentPlan]);
  const newTab = useCallback(() => {
    if (tabState.current.size >= 12 || !hasListingRef.current || pending.current?.cancelling) return;
    const id = `tab-${++nextTab.current}`;
    const target: Tab = { endpoint: { ...endpointRef.current }, selection: [], history: [], future: [] };
    tabState.current.set(id, target);
    publishTabs();
    load({ ...target, tabId: id, intent: 'tab' });
  }, [load, publishTabs]);
  const closeTab = useCallback((id: string) => {
    if (tabState.current.size <= 1 || !tabState.current.has(id) || pending.current?.cancelling) return;
    if (id === activeTabRef.current) {
      const ids = Array.from(tabState.current.keys()), index = ids.indexOf(id);
      const next = ids[index + 1] || ids[index - 1];
      load({ ...tabState.current.get(next)!, tabId: next, intent: 'tab', closeTabId: id });
    } else {
      const closesPending = pending.current?.plan.tabId === id;
      if (closesPending) { retire(); setLoading(false); setPendingEndpoint(null); }
      tabState.current.delete(id);
      if (lastFailed.current?.tabId === id) { lastFailed.current = null; setError(''); }
      publishTabs();
      if (closesPending && deferredRefresh.current) load(currentPlan(), true);
    }
  }, [load, publishTabs, retire, currentPlan]);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; retire(); cache.current!.clear(); };
  }, [retire]);

  return { tabs, activeTab, newTab, switchTab, closeTab, endpoint, entries, hasListing, selection, focusedEntry, loading, pendingEndpoint, cancelling, error, missingSelection, pathDirty, canBack, canForward, navigate, reload, refreshCurrent, invalidate, resetContext, cancelLoading, retry, back, forward, up, setSelection, clearSelections, setFocusedEntry, setPathDirty };
}

export type BrowserState = ReturnType<typeof useBrowser>;
