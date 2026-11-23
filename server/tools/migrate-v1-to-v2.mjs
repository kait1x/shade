#!/usr/bin/env node
// Shade v1 -> v2 migration control tool.
//
//   node tools/migrate-v1-to-v2.mjs <command> [options]
//
// Commands:
//   audit        Read-only validation + inventory of a v1 data directory.
//   prepare      Seed selected legacy accounts into a v2 target store
//                (idempotent; --dry-run writes nothing).
//   status       Per-account migration state from the target store.
//   verify       Integrity check of the target against the read-only source.
//   retry        Re-prepare accounts whose last attempt failed.
//   rollback     Remove PREPARED (never enrolled) accounts; backs up first.
//   checkpoint   Export the current target snapshot as a verified backup.
//   replay-restore  Restore an OLDER backup into the target while replaying
//                the newer live state (messages/ACKs/retracts/directory
//                revisions created after the backup point survive). The live
//                snapshot is backed up first; conflicts fail closed.
//   guard-export Write the enrolled-account guard file for the v1 server.
//   stop|resume  Create/remove the cooperative stop flag in the target.
//
// Safety model:
//   - The v1 source directory is opened READ-ONLY. Nothing here ever writes,
//     renames or deletes v1 files.
//   - The target must be a separate v2 data directory (alpha-store refuses
//     legacy/production directories outright).
//   - Secrets come from environment variables or the v1 session_secret file;
//     they are never printed. Reports contain account names and counts only.
//   - Enrollment (genesis signed by the original RSA) happens on the user's
//     device; this tool only prepares server-side state and drains queues.
//   - Production rollout requires the owner's explicit approval; this tool
//     never switches traffic or touches systemd/Caddy by itself.
import { parseArgs } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createPublicKey, randomBytes } from 'node:crypto';
import { alphaStore, readAlphaSnapshot } from '../multidevice/alpha-store.mjs';
import { createDeviceRegistry } from '../multidevice/registry.mjs';
import { createMigration } from '../multidevice/migration.mjs';
import { mergeRollbackSnapshots } from '../multidevice/rollback-journal.mjs';
import { openV1Source } from '../multidevice/v1-source.mjs';

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    source: { type: 'string' },
    target: { type: 'string' },
    accounts: { type: 'string' },
    all: { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
    out: { type: 'string' },
    backup: { type: 'string' },
    'secret-env': { type: 'string', default: 'ALPHA_STORAGE_SECRET' },
    'source-secret-env': { type: 'string' },
    confirm: { type: 'boolean', default: false },
  },
});
const command = positionals[0];
const fail = message => { console.error(JSON.stringify({ ok: false, error: message })); process.exit(1); };
const report = value => console.log(JSON.stringify(value, null, 2));

function targetSecret() {
  const secret = process.env[opts['secret-env']];
  if (!secret || secret.length < 32) fail(`Set ${opts['secret-env']} (32+ chars) for the target store`);
  return secret;
}

async function openSource() {
  if (!opts.source) fail('--source <v1-data-dir> required');
  const secret = opts['source-secret-env'] ? process.env[opts['source-secret-env']] : undefined;
  if (opts['source-secret-env'] && !secret) fail(`Set ${opts['source-secret-env']}`);
  return openV1Source(opts.source, { secret });
}

// Read-only snapshot loader for dry-run/status/verify: never creates files.
const readSnapshot = readAlphaSnapshot;

async function openTarget({ write }) {
  if (!opts.target) fail('--target <v2-data-dir> required');
  const secret = targetSecret();
  if (!write) {
    const snapshot = await readSnapshot(opts.target, secret);
    return { snapshot, store: null, secret };
  }
  const store = await alphaStore(opts.target, secret);
  try {
    const snapshot = await store.load();
    return { snapshot, store, secret };
  } catch (e) { await store.close(); throw e; }
}

// The registry requires every seeded legacy user to be present in the saved
// snapshot ("Incomplete migration snapshot" fails closed). Seed from the
// snapshot's OWN immutable roots: the source is consulted only for per-account
// validation inside the migration engine, so a changed source key surfaces as
// a per-account root_mismatch instead of aborting the whole run.
async function buildRegistry({ source, snapshot, persist }) {
  const users = new Map();
  for (const [account, record] of Object.entries(snapshot?.accounts || {})) {
    if (!record.legacy) continue;
    const pem = createPublicKey({ key: Buffer.from(record.root, 'base64'), format: 'der', type: 'spki' })
      .export({ type: 'spki', format: 'pem' });
    users.set(account, { publicKey: pem, googleSub: record.googleSub || null });
  }
  return createDeviceRegistry({ users, snapshot, persist,
    verifyGoogle: async () => { throw new Error('Google verification is not available in the migration CLI'); } });
}

function selection(source, snapshot) {
  if (opts.accounts) {
    return opts.accounts.split(',').map(a => a.trim().toLowerCase()).filter(Boolean);
  }
  if (opts.all) {
    return [...source.users.keys()].filter(a => {
      const e = source.eligibility.get(a);
      return e?.eligible || e?.rotation;
    });
  }
  fail('Select --accounts a,b,c or --all');
}

const stopFlag = () => path.join(path.resolve(opts.target), 'migration.stop');
async function shouldStop() {
  try { await fs.access(stopFlag()); return true; } catch { return false; }
}

async function main() {
  switch (command) {
    case 'audit': {
      const source = await openSource();
      const reasons = {};
      const rotationRequired = [];
      for (const [account, e] of source.eligibility) {
        if (e.rotation) rotationRequired.push(account);
        else if (!e.eligible) (reasons[e.reason] ||= []).push(account);
      }
      const counts = await source.counts();
      report({ ok: true, command, source: source.dir,
        counts, rotationRequired,
        ineligible: reasons,
        warnings: [counts.messagingError, source.stickersError].filter(Boolean) });
      break;
    }
    case 'prepare': {
      const source = await openSource();
      const dryRun = opts['dry-run'];
      const { snapshot, store } = await openTarget({ write: !dryRun });
      try {
        const accounts = selection(source, snapshot);
        const persisted = [];
        const registry = await buildRegistry({ source, snapshot,
          persist: dryRun ? async s => { persisted.push(s); return true; } : s => store.save(s) });
        const migration = createMigration({ registry, source });
        const results = await migration.prepare({ accounts, shouldStop });
        const after = migration.status();
        report({ ok: true, command, dryRun,
          requested: accounts.length, results,
          before: { accounts: Object.keys(snapshot?.accounts || {}).length },
          after: { accounts: Object.keys(after.accounts).length,
            enrolled: Object.values(after.accounts).filter(a => a.status === 'enrolled').length,
            prepared: Object.values(after.accounts).filter(a => a.status === 'prepared').length,
            failed: Object.values(after.accounts).filter(a => a.status === 'failed').length },
          stopped: await shouldStop() });
      } finally { await store?.close(); }
      break;
    }
    case 'status': {
      const source = opts.source ? await openSource() : null;
      const { snapshot } = await openTarget({ write: false });
      const registry = await buildRegistry({ source, snapshot, persist: async () => true });
      const migration = createMigration({ registry, source: source || { users: new Map(), queueFor: () => [] } });
      report({ ok: true, command, ...(migration.status()),
        sourceCounts: source ? await source.counts() : null });
      break;
    }
    case 'verify': {
      const source = await openSource();
      const { snapshot } = await openTarget({ write: false });
      // Registry construction re-verifies every saved directory chain.
      const registry = await buildRegistry({ source, snapshot, persist: async () => true });
      const migration = createMigration({ registry, source });
      const result = await migration.verify();
      report({ ok: result.ok, command, ...result });
      if (!result.ok) process.exitCode = 2;
      break;
    }
    case 'retry': {
      const source = await openSource();
      const { snapshot, store } = await openTarget({ write: true });
      try {
        const registry = await buildRegistry({ source, snapshot, persist: s => store.save(s) });
        const migration = createMigration({ registry, source });
        const failed = Object.entries(migration.status().accounts)
          .filter(([, a]) => a.status === 'failed').map(([name]) => name);
        const results = failed.length ? await migration.prepare({ accounts: failed, shouldStop }) : [];
        report({ ok: true, command, retried: failed, results });
      } finally { await store?.close(); }
      break;
    }
    case 'rollback': {
      if (!opts.accounts) fail('--accounts required for rollback');
      if (!opts.confirm) fail('Rollback changes the target store; pass --confirm');
      const accounts = opts.accounts.split(',').map(a => a.trim().toLowerCase()).filter(Boolean);
      const { snapshot, store, secret } = await openTarget({ write: true });
      try {
        const registry = await buildRegistry({ source: null, snapshot, persist: s => store.save(s) });
        const migration = createMigration({ registry, source: { users: new Map(), queueFor: () => [] } });
        // Verified backup BEFORE any change; restore = copy this file back.
        const stamp = new Date().toISOString().replace(/[:.]/g, '-');
        const backupDir = path.join(path.resolve(opts.target), 'rollback-backups', stamp);
        const backup = await alphaStore(backupDir, secret);
        try { await backup.save(registry.exportSnapshot()); } finally { await backup.close(); }
        const result = await migration.rollbackPrepared(accounts);
        report({ ok: true, command, backup: path.join(backupDir, 'device-v2.enc'), ...result });
      } finally { await store?.close(); }
      break;
    }
    case 'checkpoint': {
      if (!opts.out) fail('--out <checkpoint-dir> required');
      const { snapshot } = await openTarget({ write: false });
      if (!snapshot) fail('Target store is empty; nothing to checkpoint');
      const outStore = await alphaStore(opts.out, targetSecret());
      try { await outStore.save(snapshot); } finally { await outStore.close(); }
      report({ ok: true, command, out: path.join(path.resolve(opts.out), 'device-v2.enc'),
        accounts: Object.keys(snapshot.accounts || {}).length });
      break;
    }
    case 'replay-restore': {
      if (!opts.backup) fail('--backup <older device-v2.enc file or dir> required');
      if (!opts.confirm) fail('replay-restore changes the target store; pass --confirm');
      const secret = targetSecret();
      const backupPath = path.resolve(opts.backup);
      const backupDir = backupPath.endsWith('.enc') ? path.dirname(backupPath) : backupPath;
      const restored = await readSnapshot(backupDir, secret);
      if (!restored) fail('Backup snapshot not found');
      const { snapshot: live, store } = await openTarget({ write: true });
      if (!live) fail('Target store is empty; use snapshot-restore instead of replay');
      try {
        // Pure merge first: any conflict aborts before anything is written.
        const { snapshot: merged, stats } = mergeRollbackSnapshots({ restored, live });
        // Full cryptographic re-verification of the merged directory chains.
        await buildRegistry({ source: null, snapshot: merged, persist: async () => true });
        const stamp = new Date().toISOString().replace(/[:.]/g, '-');
        const safetyDir = path.join(path.resolve(opts.target), 'rollback-backups', `${stamp}-pre-replay`);
        const safety = await alphaStore(safetyDir, secret);
        try { await safety.save(live); } finally { await safety.close(); }
        await store.save(merged);
        report({ ok: true, command, stats,
          liveBackup: path.join(safetyDir, 'device-v2.enc'),
          restoredFrom: path.join(backupDir, 'device-v2.enc') });
      } finally { await store?.close(); }
      break;
    }
    case 'guard-export': {
      if (!opts.out) fail('--out <guard-file> required');
      const { snapshot } = await openTarget({ write: false });
      const registry = await buildRegistry({ source: null, snapshot, persist: async () => true });
      const migration = createMigration({ registry, source: { users: new Map(), queueFor: () => [] } });
      const guard = migration.guard();
      const out = path.resolve(opts.out);
      const tmp = `${out}.${randomBytes(6).toString('hex')}.tmp`;
      await fs.writeFile(tmp, JSON.stringify(guard), { mode: 0o600 });
      await fs.rename(tmp, out);
      report({ ok: true, command, out, enrolled: Object.keys(guard.accounts).length });
      break;
    }
    case 'stop': {
      if (!opts.target) fail('--target required');
      await fs.writeFile(stopFlag(), `stopped at ${new Date().toISOString()}\n`, { mode: 0o600 });
      report({ ok: true, command, flag: stopFlag() });
      break;
    }
    case 'resume': {
      if (!opts.target) fail('--target required');
      await fs.rm(stopFlag(), { force: true });
      report({ ok: true, command, flag: stopFlag() });
      break;
    }
    default:
      fail(`Unknown command: ${command || '(none)'}; see the header of this file`);
  }
}

main().catch(e => fail(e?.message || 'migration command failed'));
