import type { Endpoint, FileEntry } from '../shared/types';

// A pane remembers folders for this app session. External changes become
// visible on explicit refresh; app changes invalidate the affected paths.
export const LISTING_CACHE_LIMITS = { folders: 64, entries: 50_000, bytes: 16 * 1024 * 1024 };

function normalizedPath(endpoint: Endpoint): string {
  const path = endpoint.remote === null ? endpoint.path.replaceAll('\\', '/') : endpoint.path;
  return path.replace(/\/+$/, '');
}

export function relatedEndpoints(left: Endpoint, right: Endpoint): boolean {
  if (left.remote !== right.remote) return false;
  const a = normalizedPath(left), b = normalizedPath(right);
  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`) || (left.remote !== null && (!a || !b));
}

function key(endpoint: Endpoint): string { return JSON.stringify([endpoint.remote, normalizedPath(endpoint)]); }
type CachedListing = { endpoint: Endpoint; entries: FileEntry[]; bytes: number };

export class ListingCache {
  private listings = new Map<string, CachedListing>();
  private entryCount = 0;
  private byteCount = 0;
  private generation = 0;

  constructor(private limits = LISTING_CACHE_LIMITS) {}
  get epoch(): number { return this.generation; }
  get size(): number { return this.listings.size; }

  get(endpoint: Endpoint): FileEntry[] | undefined {
    if (endpoint.remote === null) return undefined;
    const id = key(endpoint), listing = this.listings.get(id);
    if (!listing) return undefined;
    this.listings.delete(id);
    this.listings.set(id, listing);
    return listing.entries;
  }

  put(endpoint: Endpoint, entries: FileEntry[], epoch = this.generation): boolean {
    if (endpoint.remote === null) return false;
    if (epoch !== this.generation) return false;
    const id = key(endpoint);
    this.remove(id);
    const bytes = 96 + 2 * id.length + entries.reduce((total, entry) => total + 160 + 2 * (entry.name.length + entry.path.length + entry.modified.length), 0);
    // A large folder is still displayed, but does not evict everything else.
    if (entries.length > this.limits.entries || bytes > this.limits.bytes) return false;
    this.listings.set(id, { endpoint: { ...endpoint }, entries, bytes });
    this.entryCount += entries.length;
    this.byteCount += bytes;
    while (this.listings.size > this.limits.folders || this.entryCount > this.limits.entries || this.byteCount > this.limits.bytes) {
      const oldest = this.listings.keys().next().value;
      if (oldest === undefined) break;
      this.remove(oldest);
    }
    return this.listings.has(id);
  }

  invalidate(target: Endpoint): void {
    ++this.generation;
    for (const [id, listing] of this.listings) if (relatedEndpoints(listing.endpoint, target)) this.remove(id);
  }

  clear(): void {
    ++this.generation;
    this.listings.clear();
    this.entryCount = 0;
    this.byteCount = 0;
  }

  private remove(id: string): void {
    const listing = this.listings.get(id);
    if (!listing) return;
    this.entryCount -= listing.entries.length;
    this.byteCount -= listing.bytes;
    this.listings.delete(id);
  }
}
