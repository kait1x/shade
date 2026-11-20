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
// Когортная миграция целыми диалогами (D1, V2_COHORT_MIGRATION.md). Единица
// маршрутизации — диалог (отсортированная пара аккаунтов) со ВСЕМИ устройствами
// обоих участников. Journal аддитивен к снапшоту format 2; v1-формат сообщений
// и криптопротокол не меняются, ciphertext сервер не расшифровывает.
export const DIALOG_ROUTING_FORMAT = 1;
export const dialogKey = (a, b) => [a, b].sort().join('|');
const ACCOUNT_RE = /^[a-z0-9_]{3,32}$/;
const MAX_JOURNAL_ENTRIES = 10000;
const ROLLBACK_GRACE_MS = 14 * 24 * 60 * 60 * 1000;
// Статические коды честных отказов диалоговых операций (без сырых текстов ошибок).
export const DIALOG_ERROR_CODES = new Set([
  'invalid_dialog', 'dialog_not_found', 'account_not_enrolled', 'peer_not_enrolled',
  'dialog_already_v2', 'use_rollback', 'not_v2_active', 'rollback_grace_expired',
  'invalid_ready_devices', 'journal_full', 'transfer_id_conflict',
]);
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
    next.dialogRouting ||= { format: DIALOG_ROUTING_FORMAT, dialogs: {} };
    check(next.migration.format === MIGRATION_FORMAT, 'Unsupported migration format');
    check(next.dialogRouting.format === DIALOG_ROUTING_FORMAT, 'Unsupported dialog routing format');
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

  // ── Когортный journal диалога (D1) ────────────────────────────────────────
  // Состояния: v1_active → migration_pending → transferring → v2_active,
  // abort (до flip) и rollback (после flip, grace 14 дней) → v1_active.
  // Все мутации — внутри сериализованных транзакций registry (persist-before-
  // visible); flip атомарен (CAS по revision внутри транзакции).
  const enrolledIn = (s, account) => Boolean(s.accounts[account]?.history?.length);
  const rosterOf = (s, account) => s.accounts[account]?.history.at(-1)?.devices.map(d => d.id) || [];
  const sameSet = (a, b) => Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every(x => b.includes(x));
  // Legacy-устройство: ключ устройства совпадает с ИСХОДНЫМ v1 root аккаунта.
  // У rotated-аккаунтов root новый → v1-клиент такие конверты не читает (честное
  // ограничение rollback replay, spec §4).
  const legacyDevicesOf = (s, account) => {
    const record = s.accounts[account];
    if (!record || record.legacy !== true || record.rotation || !record.history.length) return [];
    return record.history.at(-1).devices.filter(d => d.encryptionKey === record.root).map(d => d.id);
  };
  const newDialogRecord = () => ({
    state: 'v1_active', revision: 0, seq: 0, ready: {}, transferred: { count: 0, lastSeq: 0 },
    journal: [], outboxEmpty: {}, flippedAt: null, rolledBackAt: null, abortedAt: null,
    startedAt: null, gate: null, reverseReplay: null,
  });
  const validPair = (account, peer) => ACCOUNT_RE.test(account) && ACCOUNT_RE.test(peer) && account !== peer;
  // Проекция для UI: метаданные journal БЕЗ ciphertext (доставка — legacy.inbox/fetch).
  const projectDialog = (key, record, extra = {}) => ({
    key, state: record.state, revision: record.revision, seq: record.seq,
    ready: Object.fromEntries(Object.entries(record.ready).map(([a, r]) => [a, { devices: [...r.devices], at: r.at }])),
    outboxEmpty: Object.fromEntries(Object.entries(record.outboxEmpty).map(([a, r]) => [a, { at: r.at, by: r.by }])),
    transferred: { ...record.transferred }, journalLength: record.journal.length,
    flippedAt: record.flippedAt, rolledBackAt: record.rolledBackAt, abortedAt: record.abortedAt,
    gate: record.gate, ...extra,
  });

  // Scoped-перенос v1→v2 ТОЛЬКО для пакетов этого диалога (from = собеседник).
  // Идемпотентен: дедуп по from:id, digest и acked-тумбстоунам; повторный перенос
  // (краш между transfer и flip) не плодит дублей. Seq присваивается origin-мостом
  // при постановке в journal; доставка клиенту сортируется по seq.
  async function transferDialogIn(next, key, record) {
    const [a, b] = key.split('|');
    let imported = 0;
    for (const account of [a, b]) {
      const peer = account === a ? b : a;
      const queue = await source.queueFor(account); // throws messaging_unreadable
      const inbox = next.legacyInbox[account] ||= [];
      const mig = next.migration.accounts[account] ||= { attempts: 0, acked: [] };
      mig.acked ||= [];
      const acked = new Set(mig.acked);
      const byRef = new Map(record.journal.map(e => [`${e.from}:${e.id}`, e]));
      const digests = new Set(record.journal.map(e => e.digest));
      const inboxRefs = new Set(inbox.map(e => `${e.from}:${e.id}`));
      const inboxDigests = new Set(inbox.map(e => e.digest));
      let bytes = inbox.reduce((n, e) => n + Buffer.byteLength(JSON.stringify(e)), 0);
      for (const env of queue) {
        if (env.from !== peer) continue; // только пакеты этого диалога
        const ref = `${env.from}:${env.id}`;
        const digest = sha256hex(env.data);
        const prior = byRef.get(ref);
        // Конфликт id/digest = отказ (не ретрай): ciphertext неприкосновенен.
        if (prior) { if (prior.digest !== digest) throw new Error('transfer_id_conflict'); continue; }
        if (acked.has(ref) || digests.has(digest)) continue; // ретрай тем же id/ciphertext
        const entry = { id: env.id, from: env.from, timestamp: env.timestamp, data: env.data, digest };
        const size = Buffer.byteLength(JSON.stringify(entry));
        const inInbox = inboxRefs.has(ref) || inboxDigests.has(digest);
        // Переполнение inbox честно оставляет пакеты в pending (gate закрыт).
        if (!inInbox && (inbox.length >= MAX_INBOX_ENTRIES || bytes + size > MAX_INBOX_BYTES)) {
          record.inboxTruncated = true; break;
        }
        check(record.journal.length < MAX_JOURNAL_ENTRIES, 'journal_full');
        const seq = ++record.seq;
        record.journal.push({ seq, id: env.id, from: env.from, to: account,
          at: env.timestamp || clock(), acked: false, origin: 'v1', digest, data: env.data });
        byRef.set(ref, record.journal.at(-1)); digests.add(digest);
        record.transferred.count++; record.transferred.lastSeq = seq;
        if (!inInbox) {
          inbox.push(entry); inboxRefs.add(ref); inboxDigests.add(digest); bytes += size;
          mig.inboxImported = (mig.inboxImported || 0) + 1;
        }
        imported++;
      }
    }
    return imported;
  }

  // Неснесённые v1-пакеты диалога (pending). null = источник нечитаем.
  async function pendingDialogIn(next, key, record) {
    const [a, b] = key.split('|');
    const refs = new Set(record.journal.map(e => `${e.from}:${e.id}`));
    const digests = new Set(record.journal.map(e => e.digest));
    let pending = 0;
    for (const account of [a, b]) {
      const peer = account === a ? b : a;
      const acked = new Set(next.migration.accounts[account]?.acked || []);
      let queue;
      try { queue = await source.queueFor(account); } catch { return null; }
      for (const env of queue) {
        if (env.from !== peer) continue;
        const ref = `${env.from}:${env.id}`;
        if (refs.has(ref) || acked.has(ref) || digests.has(sha256hex(env.data))) continue;
        pending++;
      }
    }
    return pending;
  }

  // Gate переключения (spec §2, все условия обязательны, fail-closed).
  // Невыполнение любого → остаёмся в transferring, честные причины в record.gate.
  async function maybeFlipIn(next, key, record) {
    if (record.state !== 'transferring') return { flipped: false };
    const [a, b] = key.split('|');
    const reasons = [];
    for (const account of [a, b]) {
      if (!enrolledIn(next, account)) reasons.push(`not_enrolled:${account}`);
      const roster = rosterOf(next, account);
      const ready = record.ready[account];
      // Readiness ВСЕХ устройств по ТЕКУЩЕМУ каталогу: ростер вырос после ack →
      // ждём новый ack, без таймаут-форса (offline-устройство не форсируется).
      if (!ready || !roster.length || !sameSet(ready.devices, roster)) reasons.push(`devices_not_ready:${account}`);
      if (!record.outboxEmpty[account]) reasons.push(`outbox_not_empty:${account}`);
    }
    try { await transferDialogIn(next, key, record); }
    catch (e) { reasons.push(DIALOG_ERROR_CODES.has(e?.message) ? e.message : 'transfer_failed'); }
    const pending = await pendingDialogIn(next, key, record);
    if (pending === null) reasons.push('v1_source_unreadable');
    else if (pending > 0) reasons.push(`v1_pending:${pending}`);
    const v1Count = record.journal.filter(e => e.origin === 'v1').length;
    if (record.transferred.count !== v1Count) reasons.push('transfer_counter_mismatch');
    if (!record.journal.every((e, i) => e.seq === i + 1)) reasons.push('journal_seq_gap');
    record.gate = { ok: reasons.length === 0, reasons, at: clock(), pending };
    if (reasons.length) return { flipped: false, reasons };
    // Атомарный flip: CAS по revision journal внутри сериализованной транзакции.
    // Повторный вызов после коммита видит v2_active и ничего не меняет.
    record.state = 'v2_active'; record.revision++; record.flippedAt = clock();
    return { flipped: true, revision: record.revision };
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
        // Ack отмечается и в per-dialog journal (аддитивно): пакет хранится до
        // ack, повторная доставка тем же id/ciphertext идемпотентна.
        const removedRefs = new Set(removed.map(refOf));
        for (const dialog of Object.values(next.dialogRouting.dialogs)) {
          for (const e of dialog.journal) {
            if (!e.acked && removedRefs.has(`${e.from}:${e.id}`)) e.acked = true;
          }
        }
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
    // Per-dialog расширение (D1): аддитивная секция `dialogs` несёт routing-флаг
    // каждого диалога через мост. Аккаунт, ВСЕ диалоги которого откатаны
    // (rollback → v1_active), снимается с guard — сервис возвращается на v1
    // (обратимость как у существующего guard-механизма). Аккаунты без journal
    // остаются под guard (поведение enrollment не меняется). Ограничение:
    // гранулярность v1-guard — аккаунт; смешанные диалоги (v2_active + rollback)
    // держат аккаунт под guard до отдельной per-dialog проводки v1.
    guard() {
      const snapshot = registry.exportSnapshot();
      const accounts = {};
      for (const [account, record] of Object.entries(snapshot.accounts)) {
        if (record.history.length) accounts[account] = sha256hex(Buffer.from(record.root, 'base64'));
      }
      const dialogs = {};
      const byAccount = {};
      for (const [key, record] of Object.entries(snapshot.dialogRouting?.dialogs || {})) {
        dialogs[key] = { state: record.state, revision: record.revision,
          flippedAt: record.flippedAt || null, rolledBackAt: record.rolledBackAt || null };
        for (const account of key.split('|')) (byAccount[account] ||= []).push(record);
      }
      for (const account of Object.keys(accounts)) {
        const list = byAccount[account];
        if (list?.length && list.every(r => r.state === 'v1_active' && r.rolledBackAt)) delete accounts[account];
      }
      return { version: 1, updatedAt: clock(), accounts, dialogs };
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

    // ── Диалоговые операции когортной миграции (D1) ─────────────────────────
    // Авторизация участника (device-proof) выполняется адаптером до вызова.
    // Routing-проекция для send-gate: null = диалог без journal (обычный v2).
    dialogRoutingFor(a, b) {
      if (!validPair(a, b)) return null;
      const record = registry.exportSnapshot().dialogRouting?.dialogs?.[dialogKey(a, b)];
      return record ? { state: record.state, revision: record.revision,
        rolledBackAt: record.rolledBackAt || null, flippedAt: record.flippedAt || null } : null;
    },

    // Старт только если ОБА аккаунта enrolled в v2; иначе честный отказ.
    // Повторный старт после abort/rollback сохраняет journal (resume без дублей).
    async startDialog({ account, peer }) {
      check(validPair(account, peer), 'invalid_dialog');
      check(source, 'transfer_failed');
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        check(enrolledIn(next, account), 'account_not_enrolled');
        check(enrolledIn(next, peer), 'peer_not_enrolled');
        const key = dialogKey(account, peer);
        const record = next.dialogRouting.dialogs[key] ||= newDialogRecord();
        if (record.state === 'v2_active') throw new Error('dialog_already_v2');
        if (record.state !== 'v1_active') { outcome = projectDialog(key, record, { already: true }); return; }
        record.state = 'migration_pending'; record.revision++;
        record.ready = {}; record.outboxEmpty = {}; record.gate = null;
        record.startedAt = clock(); record.rolledBackAt = null; record.abortedAt = null;
        outcome = projectDialog(key, record);
      });
      return outcome;
    },

    // Устройство подтверждает готовность ВСЕХ устройств своего аккаунта по
    // каталогу (список обязан совпасть с текущим ростером). Когда обе стороны
    // ready → transferring + scoped-перенос очередей v1→v2 с подтверждением
    // счётчиков. Offline-участник не форсируется: ждём его ack честно.
    async readyDialog({ account, peer, devices }) {
      check(validPair(account, peer), 'invalid_dialog');
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        const key = dialogKey(account, peer);
        const record = next.dialogRouting.dialogs[key];
        check(record, 'dialog_not_found');
        if (record.state === 'v2_active' || record.state === 'v1_active') {
          outcome = projectDialog(key, record, { already: true }); return;
        }
        const roster = rosterOf(next, account);
        check(Array.isArray(devices) && devices.every(d => typeof d === 'string') &&
          new Set(devices).size === devices.length && sameSet(devices, roster), 'invalid_ready_devices');
        record.ready[account] = { devices: [...roster], at: clock() };
        if (record.state === 'migration_pending' && record.ready[peer]) {
          record.state = 'transferring'; record.revision++;
        }
        const flip = await maybeFlipIn(next, key, record);
        outcome = projectDialog(key, record, { flipped: flip.flipped === true });
      });
      return outcome;
    },

    // Подписанный ack пустого клиентского outbox диалога (gate-условие 4).
    async outboxEmptyDialog({ account, peer, device }) {
      check(validPair(account, peer), 'invalid_dialog');
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        const key = dialogKey(account, peer);
        const record = next.dialogRouting.dialogs[key];
        check(record, 'dialog_not_found');
        if (record.state === 'v2_active' || record.state === 'v1_active') {
          outcome = projectDialog(key, record, { already: true }); return;
        }
        record.outboxEmpty[account] = { at: clock(), by: device, devices: rosterOf(next, account) };
        const flip = await maybeFlipIn(next, key, record);
        outcome = projectDialog(key, record, { flipped: flip.flipped === true });
      });
      return outcome;
    },

    // Проекция состояния для UI. В transferring дополнительно самовосстановление
    // после краша: идемпотентный добор переноса + gate (resume без дублей).
    async statusDialog({ account, peer }) {
      check(validPair(account, peer), 'invalid_dialog');
      const key = dialogKey(account, peer);
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        const record = next.dialogRouting.dialogs[key];
        check(record, 'dialog_not_found');
        if (record.state === 'transferring') await maybeFlipIn(next, key, record);
        const waitingFor = [account, peer].filter(acc => {
          const ready = record.ready[acc];
          return !ready || !sameSet(ready.devices, rosterOf(next, acc)) || !record.outboxEmpty[acc];
        });
        outcome = projectDialog(key, record, { waitingFor,
          journal: record.journal.map(({ data, replay, digest, ...meta }) => meta) });
      });
      return outcome;
    },

    // Abort до flip → v1_active; journal и счётчики сохраняются для аудита/resume.
    async abortDialog({ account, peer }) {
      check(validPair(account, peer), 'invalid_dialog');
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        const key = dialogKey(account, peer);
        const record = next.dialogRouting.dialogs[key];
        check(record, 'dialog_not_found');
        if (record.state === 'v2_active') throw new Error('use_rollback');
        if (record.state === 'v1_active') { outcome = projectDialog(key, record, { already: true }); return; }
        record.state = 'v1_active'; record.revision++; record.abortedAt = clock();
        record.ready = {}; record.outboxEmpty = {}; record.gate = null;
        outcome = projectDialog(key, record);
      });
      return outcome;
    },

    // Rollback после flip в grace-окне 14 дней: routing назад в v1 + reverse-
    // journal replay v2-origine сообщений в v1-очереди legacy-устройств.
    // Ciphertext ({k,d}, RSA-OAEP-SHA256 + AES-GCM) структурно совместим с
    // decryptData v1 для legacy-ключей (interop: alpha_http_interop_test.dart).
    // Новые не-legacy устройства replay честно не получают (spec §4).
    async rollbackDialog({ account, peer }) {
      check(validPair(account, peer), 'invalid_dialog');
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        const key = dialogKey(account, peer);
        const record = next.dialogRouting.dialogs[key];
        check(record, 'dialog_not_found');
        check(record.state === 'v2_active', 'not_v2_active');
        check(record.flippedAt && clock() - record.flippedAt <= ROLLBACK_GRACE_MS, 'rollback_grace_expired');
        const accounts = {}; const skipped = [];
        for (const e of record.journal) {
          if (e.origin !== 'v2' || e.replayed) continue;
          if (!e.replay?.length) { skipped.push({ id: e.id, to: e.to, reason: 'no_legacy_device' }); continue; }
          for (const r of e.replay) {
            const list = accounts[r.account] ||= [];
            if (!list.some(x => x.id === e.id && x.from === e.from)) {
              list.push({ id: e.id, from: e.from, timestamp: e.at, data: r.data });
            }
          }
          e.replayed = true; // повторный rollback не дублирует уже слитые пакеты
        }
        record.reverseReplay = { at: clock(), accounts, skipped };
        record.state = 'v1_active'; record.revision++; record.rolledBackAt = clock();
        record.ready = {}; record.outboxEmpty = {}; record.gate = null;
        outcome = projectDialog(key, record, {
          replayed: Object.fromEntries(Object.entries(accounts).map(([a, l]) => [a, l.length])),
          skipped: skipped.length });
      });
      return outcome;
    },

    // Фиксация v2-origine сообщения в journal диалога (после принятого send).
    // Replay-конверты извлекаются для legacy-устройств получателя; пакет хранится
    // до ack и переживает prune очередей — rollback читает его из journal.
    async journalV2Send(message) {
      if (!validPair(message?.from, message?.to)) return null;
      const key = dialogKey(message.from, message.to);
      let outcome = null;
      await registry.updateState(async next => {
        sections(next);
        const record = next.dialogRouting.dialogs[key];
        if (!record || record.state !== 'v2_active') return;
        if (record.journal.some(e => e.id === message.id && e.from === message.from)) {
          outcome = { duplicate: true }; return;
        }
        if (record.journal.length >= MAX_JOURNAL_ENTRIES) {
          // После grace-окна rollback невозможен: компактим только acked v2-записи
          // (v1-аудит и счётчики переноса не трогаются; gate до flip уже не запустится).
          check(record.flippedAt && clock() - record.flippedAt > ROLLBACK_GRACE_MS, 'journal_full');
          let toDrop = record.journal.length - MAX_JOURNAL_ENTRIES + 1;
          record.journal = record.journal.filter(e => {
            if (toDrop > 0 && e.origin === 'v2' && e.acked) { toDrop--; return false; }
            return true;
          });
          check(record.journal.length < MAX_JOURNAL_ENTRIES, 'journal_full');
        }
        const legacy = legacyDevicesOf(next, message.to);
        const replay = message.envelopes
          .filter(e => e.account === message.to && legacy.includes(e.deviceId))
          .map(e => ({ account: e.account, deviceId: e.deviceId, data: JSON.stringify(e.payload) }));
        const seq = ++record.seq;
        record.journal.push({ seq, id: message.id, from: message.from, to: message.to,
          at: message.createdAt, acked: false, origin: 'v2',
          digest: sha256hex(JSON.stringify(message)), replay });
        outcome = { seq };
      });
      return outcome;
    },

    // Ack v2-сообщений отмечается в journal диалога (аддитивно к registry.acknowledge).
    async ackDialogRefs(account, refs) {
      if (!Array.isArray(refs) || !refs.length) return { acked: 0 };
      const keys = Object.keys(registry.exportSnapshot().dialogRouting?.dialogs || {})
        .filter(key => key.split('|').includes(account));
      if (!keys.length) return { acked: 0 };
      const wanted = new Set(refs.map(r => { const p = String(r).split(':'); return `${p[0]}:${p[2]}`; }));
      let outcome;
      await registry.updateState(async next => {
        sections(next);
        let acked = 0;
        for (const key of keys) {
          const record = next.dialogRouting.dialogs[key];
          if (!record) continue;
          for (const e of record.journal) {
            if (!e.acked && wanted.has(`${e.from}:${e.id}`)) { e.acked = true; acked++; }
          }
        }
        outcome = { acked };
      });
      return outcome;
    },

    // Additive reverse-replay export для v1-моста (по образцу guard/bridgeAck):
    // v1-очереди legacy-устройств пополняются этими конвертами как есть.
    // Запись файла атомарна и принадлежит v2-процессу; v1 storage не переписывается.
    reverseReplay() {
      const snapshot = registry.exportSnapshot();
      const accounts = {};
      for (const record of Object.values(snapshot.dialogRouting?.dialogs || {})) {
        for (const [account, entries] of Object.entries(record.reverseReplay?.accounts || {})) {
          const list = accounts[account] ||= [];
          for (const e of entries) {
            if (!list.some(x => x.id === e.id && x.from === e.from)) list.push(e);
          }
        }
      }
      return { version: 1, updatedAt: clock(), accounts };
    },
  };
}