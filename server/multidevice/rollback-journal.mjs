// Lossless rollback journal: merges a NEWER live snapshot (the journal source)
// into an OLDER restored backup so that messages, ACKs, read state, retractions
// and directory revisions created AFTER the backup point survive the restore.
//
// Model: v2 relay state is event-monotonic. `receipts`, `delivery` and
// `retractions` are append-only ledgers (bounded by caps, never pruned except
// retraction TTL), queues are derived projections (send adds; ack/retract/
// revocation remove). Therefore the live snapshot knows everything the backup
// knew, plus newer events. The merge:
//   - accounts: immutable root/genesis must agree; the newer history chain is
//     kept ONLY if it extends the older one as an exact signed prefix (the
//     registry constructor re-verifies every signature afterwards);
//   - queues: live entries win; backup-only entries are restored unless the
//     live ledgers prove they were acknowledged, retracted or revoked after
//     the backup point (never resurrect deleted ciphertext);
//   - ledgers: union with live precedence (digest conflicts fail closed);
//   - migration/legacyInbox: dedup union, ACK tombstones combined.
// Anything ambiguous fails closed: a failed merge changes nothing.
import { check } from '../../client/web/protocol/device-v2.mjs';
import { messageRef } from './registry.mjs';

const MAX_INBOX_ENTRIES = 200;
const MAX_INBOX_BYTES = 30 * 1024 * 1024;
const MAX_ACKED = 1000;

const sameJson = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const isPrefix = (shorter, longer) =>
  shorter.length <= longer.length && shorter.every((m, i) => sameJson(m, longer[i]));

function mergeAccount(account, older, newer, stats) {
  check(older.root === newer.root, `rollback root conflict: ${account}`);
  check(older.legacy === newer.legacy, `rollback legacy-flag conflict: ${account}`);
  let genesis;
  if (older.genesis && newer.genesis) {
    check(sameJson(older.genesis, newer.genesis), `rollback genesis conflict: ${account}`);
    genesis = newer.genesis;
  } else if (newer.genesis) {
    genesis = newer.genesis; // enrolled after the backup point
  } else {
    check(!older.genesis, `rollback genesis lost: ${account}`);
    genesis = null;
  }
  let history, retired;
  if (isPrefix(older.history, newer.history)) {
    history = newer.history; retired = newer.retired;
    if (newer.history.length > older.history.length) stats.directoryRevisionsReplayed += newer.history.length - older.history.length;
  } else if (isPrefix(newer.history, older.history)) {
    history = older.history; retired = older.retired; // journal older than backup
  } else {
    throw new Error(`rollback directory divergence: ${account}`);
  }
  if (genesis && !history.length) throw new Error(`rollback genesis without directory: ${account}`);
  const rotation = newer.rotation || older.rotation || null;
  if (older.rotation && newer.rotation) {
    check(sameJson(older.rotation, newer.rotation), `rollback rotation conflict: ${account}`);
  }
  return { root: newer.root, legacy: newer.legacy,
    googleSub: newer.googleSub || older.googleSub || null,
    genesis: genesis ? structuredClone(genesis) : null,
    history: structuredClone(history), retired: structuredClone(retired),
    ...(rotation ? { rotation: structuredClone(rotation) } : {}) };
}

function mergeMigrationSection(older = {}, newer = {}) {
  const accounts = {};
  const names = new Set([...Object.keys(older.accounts || {}), ...Object.keys(newer.accounts || {})]);
  for (const name of names) {
    const a = older.accounts?.[name], b = newer.accounts?.[name];
    if (!a) { accounts[name] = structuredClone(b); continue; }
    if (!b) { accounts[name] = structuredClone(a); continue; }
    if (a.rootFingerprint && b.rootFingerprint) {
      check(a.rootFingerprint === b.rootFingerprint, `rollback fingerprint conflict: ${name}`);
    }
    const acked = [...(b.acked || [])];
    for (const ref of a.acked || []) if (!acked.includes(ref)) acked.push(ref);
    const earliest = (x, y) => (x == null ? y : y == null ? x : Math.min(x, y));
    accounts[name] = {
      ...structuredClone(a), ...structuredClone(b),
      status: a.status === 'enrolled' || b.status === 'enrolled' ? 'enrolled' : (b.status || a.status),
      attempts: Math.max(a.attempts || 0, b.attempts || 0),
      acked: acked.slice(-MAX_ACKED),
      preparedAt: earliest(a.preparedAt, b.preparedAt),
      enrolledAt: earliest(a.enrolledAt, b.enrolledAt),
      inboxImported: Math.max(a.inboxImported || 0, b.inboxImported || 0),
      inboxTruncated: Boolean(a.inboxTruncated || b.inboxTruncated),
      rootFingerprint: b.rootFingerprint || a.rootFingerprint || null,
      lastError: b.lastError ?? null,
    };
  }
  return { format: newer.format || older.format || 1, accounts };
}

function mergeLegacyInbox(older = {}, newer = {}, migrationAccounts) {
  const out = {};
  const names = new Set([...Object.keys(older), ...Object.keys(newer)]);
  for (const name of names) {
    const acked = new Set(migrationAccounts[name]?.acked || []);
    const seen = new Set(), seenRefs = new Set();
    const entries = [];
    let bytes = 0, truncated = false;
    // Newer entries first: they carry the fresher timestamps for the same ref.
    for (const e of [...(newer[name] || []), ...(older[name] || [])]) {
      const ref = `${e.from}:${e.id}`;
      if (acked.has(ref) || seen.has(e.digest) || seenRefs.has(ref)) continue;
      const size = Buffer.byteLength(JSON.stringify(e));
      if (entries.length >= MAX_INBOX_ENTRIES || bytes + size > MAX_INBOX_BYTES) { truncated = true; break; }
      entries.push(structuredClone(e)); seen.add(e.digest); seenRefs.add(ref); bytes += size;
    }
    if (entries.length) out[name] = entries;
    if (truncated && migrationAccounts[name]) migrationAccounts[name].inboxTruncated = true;
  }
  return out;
}

// Pure merge. `restored` = older backup snapshot, `live` = newer journal source.
// Returns { snapshot, stats }; throws on any conflict (caller changes nothing).
export function mergeRollbackSnapshots({ restored, live }) {
  check(restored?.format === 2 && live?.format === 2, 'Invalid snapshot format');
  const stats = { accountsKept: 0, accountsFromJournal: 0, directoryRevisionsReplayed: 0,
    queueEntriesPreserved: 0, acksApplied: 0, retractionsApplied: 0, inboxEntriesPreserved: 0 };
  const merged = { format: 2, accounts: {}, queues: {}, receipts: {}, delivery: {},
    stickers: {}, retractions: {}, pushSubscriptions: {} };

  const names = new Set([...Object.keys(restored.accounts), ...Object.keys(live.accounts)]);
  for (const name of names) {
    const older = restored.accounts[name], newer = live.accounts[name];
    if (older && newer) { merged.accounts[name] = mergeAccount(name, older, newer, stats); stats.accountsKept++; }
    else if (newer) { merged.accounts[name] = structuredClone(newer); stats.accountsFromJournal++; }
    else merged.accounts[name] = structuredClone(older); // prepared rollback after backup: re-run rollback if intended
  }

  // Ledgers: append-only, live precedence. Digest conflicts fail closed.
  for (const [ref, digest] of Object.entries(restored.receipts || {})) {
    if (Object.hasOwn(live.receipts || {}, ref)) {
      check(live.receipts[ref] === digest, `rollback receipt conflict: ${ref}`);
    } else merged.receipts[ref] = digest;
  }
  Object.assign(merged.receipts, live.receipts || {});
  merged.delivery = { ...structuredClone(restored.delivery || {}), ...structuredClone(live.delivery || {}) };
  merged.retractions = { ...structuredClone(restored.retractions || {}), ...structuredClone(live.retractions || {}) };
  stats.retractionsApplied = Object.keys(merged.retractions).length;

  const active = (account, id) =>
    merged.accounts[account]?.history.at(-1)?.devices.some(d => d.id === id) || false;
  const acknowledged = (ref, account, id) =>
    merged.delivery[ref]?.devices?.find(d => d.account === account && d.id === id)?.acknowledgedAt != null;

  // Queues: live projection wins; backup-only entries survive unless the live
  // ledgers prove post-backup ACK/retract/revocation.
  const queueKeys = new Set([...Object.keys(restored.queues || {}), ...Object.keys(live.queues || {})]);
  for (const key of queueKeys) {
    const [account, id] = key.split(':');
    const liveQueue = live.queues?.[key] || [];
    const liveRefs = new Set(liveQueue.map(messageRef));
    const extra = (restored.queues?.[key] || []).filter(m => {
      const ref = messageRef(m);
      if (liveRefs.has(ref)) return false;
      // Unknown to the live ledger (capacity eviction): keep — client-side
      // dedup makes a rare re-delivery harmless, loss is not acceptable.
      return !Object.hasOwn(live.receipts || {}, ref);
    });
    const queue = [...structuredClone(liveQueue), ...structuredClone(extra)].filter(m => {
      const ref = messageRef(m);
      if (merged.retractions[ref]) return false;
      if (acknowledged(ref, account, id)) { stats.acksApplied++; return false; }
      return active(account, id) && active(m.from, m.deviceId);
    });
    // Keep the exact live projection shape (including empty queue keys).
    merged.queues[key] = queue;
    stats.queueEntriesPreserved += queue.length;
  }

  // Push subscriptions: live precedence; backup-only keys need an active device.
  merged.pushSubscriptions = { ...structuredClone(restored.pushSubscriptions || {}), ...structuredClone(live.pushSubscriptions || {}) };
  for (const key of Object.keys(merged.pushSubscriptions)) {
    const [account, id] = key.split(':');
    if (!active(account, id)) delete merged.pushSubscriptions[key];
  }

  merged.stickers = { ...structuredClone(restored.stickers || {}), ...structuredClone(live.stickers || {}) };
  merged.migration = mergeMigrationSection(restored.migration, live.migration);
  merged.legacyInbox = mergeLegacyInbox(restored.legacyInbox, live.legacyInbox, merged.migration.accounts);
  stats.inboxEntriesPreserved = Object.values(merged.legacyInbox).reduce((n, q) => n + q.length, 0);
  return { snapshot: merged, stats };
}