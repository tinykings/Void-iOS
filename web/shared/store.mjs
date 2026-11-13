// Stored library state, one per Apple Account (and CloudKit container/environment), so
// switching accounts never shows or pushes another account's data. All updates are
// serialized, so overlapping changes and a sync in flight can't lose each other.
import { emptyState, pendingCount } from "./library.mjs";

export const LIBRARY_KEY = "voidLibrary";
export const SYNC_SETTINGS_KEY = "voidSyncSettings";
export const accountLibraryKey = ({ environment, container, account }) => `${LIBRARY_KEY}:${environment}:${container}:${account}`;

export function createLibrary({ storage, onChange = () => {} }) {
  let queue = Promise.resolve();
  const serialized = task => {
    const run = queue.then(task);
    queue = run.catch(() => {});
    return run;
  };
  const settings = async () => (await storage.get(SYNC_SETTINGS_KEY))[SYNC_SETTINGS_KEY] ?? null;
  const load = async key => {
    const { [key]: stored } = await storage.get(key);
    return stored?.version === 1 ? stored : null;
  };
  // Runs `change` on the latest stored state at `key` and saves what it returns.
  const update = (change, key) => serialized(async () => {
    const state = await load(key) ?? emptyState();
    const next = change(state);
    if (next !== state) await storage.set({ [key]: next });
    return next;
  });

  return {
    settings,
    read: key => serialized(() => load(key)),
    apply: (key, change) => update(change, key),
    // A person's change to the signed-in account's library; schedules a sync.
    async change(change) {
      const active = await settings();
      if (!active) return null;
      let changed = false;
      const next = await update(state => {
        const after = change(state);
        changed = after !== state;
        return after;
      }, accountLibraryKey(active));
      if (changed) onChange();
      return next;
    },
    async view() {
      const active = await settings();
      if (!active) return { state: null, sync: { enabled: false } };
      const state = await serialized(async () => await load(accountLibraryKey(active)) ?? emptyState());
      return { state, sync: { enabled: true, pending: pendingCount(state), lastSync: state.sync.lastSync } };
    },
    // Makes an account's library the active one (creating it), or none.
    async useAccount(syncSettings) {
      await serialized(async () => {
        if (!syncSettings) { await storage.remove(SYNC_SETTINGS_KEY); return; }
        const key = accountLibraryKey(syncSettings);
        if (!(await load(key))) await storage.set({ [key]: emptyState() });
        await storage.set({ [SYNC_SETTINGS_KEY]: syncSettings });
      });
    },
  };
}
