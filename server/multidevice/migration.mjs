// Migration engine v1 -> v2. Operates ONLY through the device registry's
// serialized transactions (persist-before-visible) and a READ-ONLY v1 source.
// Additive snapshot sections: `migration` (per-account state) and `legacyInbox`
// (one-way ciphertext bridge for pending v1 offline messages). Legacy users,
// messages, tokens and keys are never rewritten; E2EE payloads are never
// decrypted here. Enrollment itself is client-driven: the original RSA signs
// the genesis on the device and the private key never leaves it.
import { createHash } from 'node:crypto';
import { legacyRoot } from './registry.mjs';
import { check, verifyRotation } from '../../client/web/protocol/device-v2.mjs';
import { validateLegacyUser } from './v1-source.mjs';

export const MIGRATION_FORMAT = 1;
const MAX_INBOX_ENTRIES = 200;
const MAX_INBOX_BYTES = 30 * 1024 * 1024;
const MAX_ACKED = 1000;
// Error codes stored in the audit trail. Raw error text is never persisted:
// it could contain key material or user data.
const KNOWN_CODES = new Set([
  'not_in_source', 'invalid_account', 'missing_public_key', 'unparsable_public_key',
  'unsupported_key_type', 'unsupported_key_size', 'root_mismatch', 'not_legacy',
  'messaging_unreadable', 'inbox_full', 'prepare_failed', 'rollback_refused_enrolled',
]);
const codeOf = e => (KNOWN_CODES.has(e?.message) ? e.message : 'prepare_failed');
const sha256hex = value => createHash('sha256').update(value).digest('hex');

export function createMigration({ registry, source, clock = Date.now }) {
  check(registry && typeof registry.updateState === 'function', 'Registry required');

  const sections = next => {
    next.migration ||= { format: MIGRATION_FORMAT, accounts: {} };
    next.legacyInbox ||= {};
    check(next.migration.format === MIGRATION_FORMAT, 'Unsupported migration format');
    return next;
  };

  async function importQueue(next, account, { overwriteProfile = false } = {}) {
    const queue = await source.queueFor(account); // throws messaging_unreadable
    const inbox = next.legacyInbox[account] ||= [];
    const record = next.migration.accounts[account] ||= { attempts: 0, acked: [] };
    record.acked ||= [];
    // Dedup by v1 message identity (from:id) AND ciphertext digest: a retry
    // with the same ID never duplicates, acked messages never return.
    const refOf = e => `${e.from}:${e.id}`;
    const acked = new Set(record.acked);
    const seen = new Set(inbox.map(e => e.digest));
    const seenRefs = new Set(inbox.map(refOf));
    let bytes = inbox.reduce((n, e) => n + Buffer.byteLength(JSON.stringify(e)), 0);
    let imported = 0;
    for (const envelope of queue) {
      const digest = sha256hex(envelope.data);
      const ref = refOf(envelope);
      if (seen.has(digest) || seenRefs.has(ref) || acked.has(ref)) continue;
      const entry = { id: envelope.id, from: envelope.from, timestamp: envelope.timestamp,
        data: envelope.data, digest };
      const size = Buffer.byteLength(JSON.stringify(entry));
      if (inbox.length >= MAX_INBOX_ENTRIES || bytes + size > MAX_INBOX_BYTES) {
        record.inboxTruncated = true;
        break;
      }
      inbox.push(entry); seen.add(digest); seenRefs.add(ref); bytes += size; imported++;
    }
    record.inboxImported = (record.inboxImported || 0) + imported;
    if (overwriteProfile) importProfile(next, account);
    return imported;
  }

  // v1 profile/stickers/avatars live in stickers.json with the same business
  // shape the v2 adapter reuses. avatarOwner is recomputed for the v2 encoding
  // of the SAME immutable key (SPKI base64 instead of PEM): ownership stays
  // bound to the key, never to a mutable username.
  function importProfile(next, account) {
    const profile = source.profileFor?.(account);
    if (!profile) return false;
    const root = next.accounts[account]?.root;
    if (!root) return false;
    next.stickers ||= {};
    next.stickers[account] = { ...profile, avatarOwner: sha256hex(root) };
    return true;
  }

  return {
    // Idempotent per-account preparation. One account's failure never aborts
    // the others; a persistence failure aborts the whole run (state unchanged).
    async prepare({ accounts, shouldStop = () => false }) {
      const results = [];
      for (const account of accounts) {
        if (await shouldStop()) { results.push({ account, status: 'stopped' }); break; }
        try {
          const user = source.users.get(account);
          if (!user) throw new Error('not_in_source');
          const eligibility = validateLegacyUser(account, user);
          if (!eligibility.eligible && !eligibility.rotation) throw new Error(eligibility.reason);
          const rotation = eligibility.rotation === true;
          const root = legacyRoot(user.publicKey);
          const fingerprint = sha256hex(Buffer.from(root, 'base64'));
          let outcome;
          await registry.updateState(async next => {
            sections(next);
            const existing = next.accounts[account];
            const hadRecord = Boolean(next.migration.accounts[account]?.preparedAt);
            if (existing) {
              if (existing.legacy !== true) throw new Error('not_legacy');
              // Rotated accounts anchor a NEW root; the old root lives only in
              // the attestation. Direct accounts must keep the exact v1 root.
              if (rotation ? !existing.rotation : existing.root !== root) throw new Error('root_mismatch');
            } else if (!rotation) {
              next.accounts[account] = { root, legacy: true,
                googleSub: user.googleSub || null, genesis: null, history: [], retired: [] };
            }
            // Profile import needs an account root; rotation defers it until
            // the new identity is enrolled (avatarOwner rebinds to the new root).
            const imported = await importQueue(next, account, { overwriteProfile: Boolean(next.accounts[account]) });
            const record = next.migration.accounts[account];
            record.status = next.accounts[account]?.history.length ? 'enrolled'
              : (rotation ? 'rotation_required' : 'prepared');
            if (rotation) { record.rotation = true; record.oldRootFingerprint = fingerprint; }
            else record.rootFingerprint = fingerprint;
            record.preparedAt ||= clock();
            record.attempts = (record.attempts || 0) + 1;
            record.lastError = null;
            outcome = { account, status: record.status, imported,
              alreadyPresent: Boolean(existing) || hadRecord };
          });
          results.push(outcome);
        } catch (error) {
          const code = codeOf(error);
          // Record the failure without touching account data. If persistence
          // itself is broken this rethrow aborts the run (fail closed).
          await registry.updateState(next => {
            sections(next);
            const record = next.migration.accounts[account] ||= { attempts: 0, acked: [] };
            record.status = next.accounts[account]?.history?.length ? 'enrolled' : 'failed';
            record.attempts = (record.attempts || 0) + 1;
            record.lastError = code;
            record.failedAt = clock();
          });
          results.push({ account, status: 'failed', error: code });
        }
      }
      return results;
    },

    // Called after the client's legacy enrollment committed on the server:
    // drain any v1 messages that arrived between prepare and enrollment.
    async finalizeEnrollment(account) {
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        check(next.accounts[account]?.history?.length, 'Account not enrolled');
        let imported = 0;
        try { imported = await importQueue(next, account, { overwriteProfile: true }); }
        catch (e) { next.migration.accounts[account].inboxError = codeOf(e); }
        const record = next.migration.accounts[account] ||= { attempts: 0, acked: [] };
        record.status = 'enrolled';
        record.enrolledAt ||= clock();
        record.lastError = null;
        outcome = { imported };
      });
      return outcome;
    },

    // One-way bridge fetch: tops up from the live v1 queue (dedup by digest,
    // acked tombstones) so messages enqueued right before the guard activated
    // are never lost, then returns the pending ciphertext envelopes.
    async syncInbox(account) {
      await registry.updateState(async next => {
        sections(next);
        check(next.accounts[account]?.history?.length, 'Account not enrolled');
        try { await importQueue(next, account); }
        catch (e) { next.migration.accounts[account].inboxError = codeOf(e); }
      });
      const snapshot = registry.exportSnapshot();
      return (snapshot.legacyInbox?.[account] || []).map(e => ({
        id: e.id, from: e.from, timestamp: e.timestamp, data: e.data }));
    },

    // ACK by full ref `from:id` (never bare id: two senders can reuse an id).
    // Tombstones are persisted in the SAME snapshot transaction as the inbox
    // removal, so a crash before the bridge-ack file export is repaired by
    // re-exporting from durable state on startup.
    async ackInbox(account, refs) {
      check(Array.isArray(refs) && refs.length <= MAX_INBOX_ENTRIES &&
        refs.every(r => typeof r === 'string' && /^[a-z0-9_]{3,32}:[a-zA-Z0-9_-]{16,80}$/.test(r)), 'Invalid inbox ack');
      let outcome;
      await registry.updateState(next => {
        sections(next);
        const inbox = next.legacyInbox[account] || [];
        const wanted = new Set(refs);
        const refOf = e => `${e.from}:${e.id}`;
        const removed = inbox.filter(e => wanted.has(refOf(e)));
        next.legacyInbox[account] = inbox.filter(e => !wanted.has(refOf(e)));
        const record = next.migration.accounts[account] ||= { attempts: 0, acked: [] };
        record.acked ||= [];
        for (const e of removed) {
          const ref = refOf(e);
          if (!record.acked.includes(ref)) record.acked.push(ref);
        }
        if (record.acked.length > MAX_ACKED) record.acked = record.acked.slice(-MAX_ACKED);
        outcome = { acknowledged: removed.length };
      });
      return outcome;
    },

    // Rollback is limited to PREPARED accounts (no genesis, no directory).
    // Enrolled accounts must be restored from a verified snapshot backup:
    // deleting a live directory would orphan device trust and queued messages.
    async rollbackPrepared(accounts) {
      const snapshot = registry.exportSnapshot();
      for (const account of accounts) {
        const record = snapshot.accounts[account];
        if (record && (record.genesis || record.history.length)) {
          throw new Error('rollback_refused_enrolled');
        }
      }
      let outcome;
      await registry.updateState(next => {
        sections(next);
        const removed = [];
        for (const account of accounts) {
          if (!next.accounts[account]) continue;
          delete next.accounts[account];
          delete next.migration.accounts[account];
          delete next.legacyInbox[account];
          if (next.stickers) delete next.stickers[account];
          removed.push(account);
        }
        outcome = { removed };
      });
      return outcome;
    },

    status() {
      const snapshot = registry.exportSnapshot();
      const accounts = {};
      for (const [account, record] of Object.entries(snapshot.accounts)) {
        if (!record.legacy) continue;
        const migration = snapshot.migration?.accounts?.[account] || {};
        accounts[account] = {
          status: record.history.length ? 'enrolled' : (migration.status || 'prepared'),
          rootFingerprint: migration.rootFingerprint || null,
          rotation: Boolean(migration.rotation),
          oldRootFingerprint: migration.oldRootFingerprint || null,
          preparedAt: migration.preparedAt || null,
          enrolledAt: migration.enrolledAt || null,
          attempts: migration.attempts || 0,
          lastError: migration.lastError || null,
          revision: record.history.at(-1)?.revision || 0,
          devices: record.history.at(-1)?.devices?.length || 0,
          inboxPending: (snapshot.legacyInbox?.[account] || []).length,
          inboxImported: migration.inboxImported || 0,
          googleLinked: Boolean(record.googleSub),
        };
      }
      // Rotation-required accounts have no registry entry until the device
      // proves old-key possession and enrolls a fresh RSA-4096 identity.
      for (const [account, record] of Object.entries(snapshot.migration?.accounts || {})) {
        if (record.status !== 'rotation_required' || snapshot.accounts[account]) continue;
        accounts[account] = {
          status: 'rotation_required', rootFingerprint: null, rotation: true,
          oldRootFingerprint: record.oldRootFingerprint || null,
          preparedAt: record.preparedAt || null, enrolledAt: null,
          attempts: record.attempts || 0, lastError: record.lastError || null,
          revision: 0, devices: 0,
          inboxPending: (snapshot.legacyInbox?.[account] || []).length,
          inboxImported: record.inboxImported || 0, googleLinked: false,
        };
      }
      return { format: MIGRATION_FORMAT, accounts };
    },

    // Integrity verification against the read-only source and the snapshot.
    async verify() {
      const snapshot = registry.exportSnapshot();
      const problems = [];
      const status = this.status();
      for (const [account, info] of Object.entries(status.accounts)) {
        const user = source.users.get(account);
        if (!user) { problems.push({ account, problem: 'missing_in_source' }); continue; }
        const eligibility = validateLegacyUser(account, user);
        const migrationRecord = snapshot.migration?.accounts?.[account] || {};
        if (info.rotation) {
          // Rotated identity: the anchor is the NEW root bound by an old-key
          // attestation. Re-verify the whole chain against the read-only source.
          if (!eligibility.rotation) problems.push({ account, problem: 'rotation_not_required' });
          const oldRoot = legacyRoot(user.publicKey);
          const oldFingerprint = sha256hex(Buffer.from(oldRoot, 'base64'));
          if (migrationRecord.oldRootFingerprint !== oldFingerprint) {
            problems.push({ account, problem: 'rotation_old_root_mismatch' });
          }
          if (info.status === 'enrolled') {
            const record = snapshot.accounts[account];
            const rotatedFrom = migrationRecord.rotatedFrom;
            if (!rotatedFrom || record.root !== rotatedFrom.newRoot) {
              problems.push({ account, problem: 'rotation_root_mismatch' });
            } else if (record.rotation?.attestation) {
              const a = record.rotation.attestation;
              if (a.newRoot !== record.root || a.oldRootFingerprint !== oldFingerprint ||
                !(await verifyRotation(a, oldRoot))) {
                problems.push({ account, problem: 'rotation_attestation_invalid' });
              }
            } else problems.push({ account, problem: 'rotation_attestation_missing' });
          }
        } else if (!eligibility.eligible) problems.push({ account, problem: eligibility.reason });
        else {
          const root = legacyRoot(user.publicKey);
          if (snapshot.accounts[account].root !== root) problems.push({ account, problem: 'root_mismatch' });
        }
        const inbox = snapshot.legacyInbox?.[account] || [];
        const digests = new Set();
        for (const e of inbox) {
          if (digests.has(e.digest)) problems.push({ account, problem: 'inbox_duplicate' });
          digests.add(e.digest);
          if (sha256hex(e.data) !== e.digest) problems.push({ account, problem: 'inbox_digest_mismatch' });
        }
        if (info.status === 'enrolled' && !snapshot.accounts[account].genesis) {
          problems.push({ account, problem: 'enrolled_without_genesis' });
        }
      }
      // Every prepared/enrolled tracked account must exist; failure records
      // for ineligible accounts and rotation-required accounts (no registry
      // entry until the device enrolls a new root) legitimately have none.
      for (const [account, record] of Object.entries(snapshot.migration?.accounts || {})) {
        if (!snapshot.accounts[account] && record.status !== 'failed' && record.status !== 'rotation_required') {
          problems.push({ account, problem: 'tracked_account_missing' });
        }
      }
      return { ok: problems.length === 0, problems, counts: {
        legacyAccounts: Object.keys(status.accounts).length,
        enrolled: Object.values(status.accounts).filter(a => a.status === 'enrolled').length,
        prepared: Object.values(status.accounts).filter(a => a.status === 'prepared').length,
        rotationRequired: Object.values(status.accounts).filter(a => a.status === 'rotation_required').length,
        failed: Object.values(status.accounts).filter(a => a.status === 'failed').length,
        inboxPending: Object.values(snapshot.legacyInbox || {}).reduce((n, q) => n + q.length, 0),
      } };
    },

    // Guard payload for the v1 server: enrolled accounts must no longer use
    // v1 auth/send routes. Written atomically by the caller.
    guard() {
      const snapshot = registry.exportSnapshot();
      const accounts = {};
      for (const [account, record] of Object.entries(snapshot.accounts)) {
        if (record.history.length) accounts[account] = sha256hex(Buffer.from(record.root, 'base64'));
      }
      return { version: 1, updatedAt: clock(), accounts };
    },

    // Bridge-ack payload for the v1 server: ACK tombstones of enrolled
    // accounts. v1 prunes confirmed ciphertext from its queue and advances
    // receipts to delivered, so the one-way bridge never fills the v1 queue.
    // Additive export owned by the v2 process; v1 storage stays v1-written.
    bridgeAck() {
      const snapshot = registry.exportSnapshot();
      const accounts = {};
      for (const [account, record] of Object.entries(snapshot.migration?.accounts || {})) {
        if (!snapshot.accounts[account]?.history?.length) continue;
        if (record.acked?.length) accounts[account] = { acked: record.acked.slice(-MAX_ACKED) };
      }
      return { version: 1, updatedAt: clock(), accounts };
    },
  };
}