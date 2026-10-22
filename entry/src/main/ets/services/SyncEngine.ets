import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Note } from '../models/Note';
import { NoteStore } from './NoteStore';
import { FrontmatterCodec, ParsedNote } from './Frontmatter';
import { SettingsStore } from './SettingsStore';
import { DavConfig, DavEntry, DavListResult, WebDavClient } from './WebDav';

const DOMAIN = 0x0000;
const TAG = 'ZhijianSync';

/** Folder under the WebDAV base that holds the notes. Created on first sync. */
const REMOTE_DIR = 'zhijian';
/**
 * Server-side 回收站, created lazily the first time a note is deleted here.
 *
 * It lives *inside* `zhijian/` rather than beside it so the vault stays one
 * self-contained folder, and it is safe from the listing loops because they run
 * at `Depth: 1` and skip directory entries — nothing in `.trash` is ever
 * re-imported as a note.
 */
const REMOTE_TRASH_DIR = `${REMOTE_DIR}/.trash`;
/** Same retention as the local 回收站 (`NoteStore.purgeExpiredTrash`). */
const TRASH_RETENTION_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * One note as this device last saw the *server*.
 *
 * Stored as a flat `id \t updatedAt \t relPath` line per note so the baseline
 * survives a process restart without JSON and without index signatures, both of
 * which ArkTS strict mode makes awkward.
 */
export class BaselineEntry {
  id: string = '';
  updatedAt: number = 0;
  relPath: string = '';
}

/** Aggregated result of a sync run, shaped for direct display. */
export class SyncOutcome {
  ok: boolean = false;
  uploaded: number = 0;
  downloaded: number = 0;
  conflicts: number = 0;
  skipped: number = 0;
  /** Notes moved into the *local* 回收站 because the server no longer had them. */
  trashedLocal: number = 0;
  /** Notes whose server copy was moved into `zhijian/.trash` because they were deleted here. */
  trashedRemote: number = 0;
  message: string = '';
  finishedAt: number = 0;
}

/** A note fetched from the server, plus the metadata PROPFIND reported. */
class RemoteNote {
  note: Note = new Note();
  etag: string = '';
  remotePath: string = '';
}

/**
 * Two-way sync between the flat `notes/` directory and one WebDAV folder.
 *
 * ### Identity is the frontmatter `id`, never the filename
 * Every device names untouched notes `无标题.md`, `无标题 (1).md`, …, so pairing
 * by name would merge two unrelated notes the moment both devices create one.
 * The id is minted once in `createNote()` and survives renames, which is the
 * stable key a merge needs.
 *
 * ### Decisions come from three-way comparison, not timestamps
 * For each id the engine looks at three things: the local note, the remote note,
 * and `BaselineEntry` — what the server held at the end of the previous run.
 * `local != base && remote != base` is a genuine concurrent edit and becomes a
 * conflict copy; anything else has exactly one true author and can be applied
 * directly. Comparing only `local.updatedAt` vs `remote.updatedAt` cannot make
 * that distinction, so it silently discards whichever edit was typed first.
 *
 * ### The baseline is also the tombstone, so deletions propagate
 * "Missing on the server" is ambiguous on its own: it means either *never
 * uploaded* or *deleted on another device*, and guessing wrong either resurrects
 * a deleted note or destroys a real one. A baseline row resolves it without a
 * separate tombstone file, because the row already says "the server held this id
 * at the end of the last run":
 *
 * | local | remote | baseline | verdict |
 * |---|---|---|---|
 * | yes | yes | — | three-way merge as above |
 * | yes | no | yes | deleted remotely → local file moves to 回收站 |
 * | no | yes | yes | deleted locally → server file moves to `zhijian/.trash` |
 * | yes | no | no | never uploaded → upload |
 * | no | yes | no | new elsewhere → download |
 *
 * A deletion always beats an edit on the other side, and it is never final: the
 * local side lands in `.trash` (30 days, restored from 回收站) and the server side
 * in `zhijian/.trash` (30 days, purged by this engine). Nothing is destroyed
 * outright — that is what makes propagating deletions safe at all.
 *
 * An id that exists on neither side simply loses its row, which is the "both
 * sides agree it is gone" state.
 *
 * ### A refused delete keeps its row
 * Only an operation that actually reached the server may advance or drop the
 * baseline. If the `MOVE` into `zhijian/.trash` fails, the row is carried forward
 * verbatim — otherwise the next run would see a remote file with no baseline,
 * call it "new from another device", and download the note the user just deleted.
 *
 * ### Conflict copies keep both bodies
 * A conflict writes the loser as `<title> (冲突 <time>).md` with a fresh id, and
 * the mark goes into the body's H1 so the list can distinguish the two cards.
 */
export class SyncEngine {
  /** Base URL + credentials. Password is hydrated from Asset Store per run. */
  static config: DavConfig = new DavConfig();

  /**
   * Monotonic disambiguator for remote-trash names.
   *
   * Two notes archived inside the same millisecond would otherwise produce the
   * same `zhijian/.trash/<millis>-<name>` target and the second `MOVE` would
   * overwrite the first — silent data loss in exactly the folder that exists to
   * prevent it.
   */
  private static archiveSeq: number = 0;

  static get configured(): boolean {
    return SyncEngine.config.baseUrl.length > 0 && SyncEngine.config.username.length > 0;
  }

  /** Normalises user input: assumes https, strips duplicate trailing slashes. */
  static normaliseBase(input: string): string {
    let base = input.trim();
    if (base.length === 0) {
      return '';
    }
    if (!/^https?:\/\/[^/]/i.test(base)) {
      base = `https://${base}`;
    }
    base = base.replace(/\/+$/, '');
    return `${base}/`;
  }

  /** Extracts the hostname from a base URL, for the static DNS rule. */
  static hostOf(baseUrl: string): string {
    const match = /^https?:\/\/([^/:]+)/i.exec(baseUrl);
    if (match === null) {
      return '';
    }
    return match[1];
  }

  /**
   * Identity of the server the baseline describes: `baseUrl<TAB>username`.
   *
   * Included in every baseline write and checked before every read. Without it,
   * switching the URL makes the old baseline look authoritative and every note
   * looks "deleted on the server" — one tap away from trashing the whole vault.
   */
  static scopeOf(): string {
    return `${SyncEngine.config.baseUrl}\t${SyncEngine.config.username}`;
  }

  /**
   * Applies the stored settings to `config`, including the optional name→IP pin.
   *
   * The pin is only armed when both halves are present and the host in the URL
   * actually matches — a stale rule for a different server would otherwise send
   * the request to the wrong machine while TLS still validated the right name.
   */
  static applySettings(settings: SettingsStore, password: string): void {
    const base = SyncEngine.normaliseBase(settings.davUrl);
    SyncEngine.config.baseUrl = base;
    SyncEngine.config.username = settings.davUser;
    SyncEngine.config.password = password;
    const host = SyncEngine.hostOf(base);
    if (settings.davDnsIp.length > 0 && settings.davDnsHost.length > 0 &&
      settings.davDnsHost.toLowerCase() === host.toLowerCase()) {
      SyncEngine.config.dnsHost = settings.davDnsHost;
      SyncEngine.config.dnsIp = settings.davDnsIp;
    } else {
      SyncEngine.config.dnsHost = '';
      SyncEngine.config.dnsIp = '';
    }
    SyncEngine.config.proxyUrl = settings.davProxy.trim();
  }

  /** Validates URL + credentials by listing (and creating) the notes folder. */
  static async testConnection(): Promise<SyncOutcome> {
    const outcome = new SyncOutcome();
    if (!SyncEngine.configured) {
      outcome.message = '请先填写服务器地址和用户名';
      return outcome;
    }
    const listing = await SyncEngine.listOrCreate(REMOTE_DIR);
    if (!listing.ok) {
      outcome.message = SyncEngine.friendly(listing.status, listing.message);
      return outcome;
    }
    let files = 0;
    for (const entry of listing.entries) {
      if (!entry.isDir && entry.relPath.endsWith('.md')) {
        files++;
      }
    }
    outcome.ok = true;
    outcome.message = `连接成功 · 远端 ${files} 篇笔记`;
    return outcome;
  }

  /**
   * Runs a full two-way sync.
   *
   * Only one `PROPFIND` and one `GET` per remote note: the vault is Markdown, so
   * reading it whole is cheap and it is the only way to see each note's `id`.
   * Unchanged notes cause no writes at all, so repeated runs are free once the
   * baseline exists.
   */
  static async sync(settings: SettingsStore): Promise<SyncOutcome> {
    const outcome = new SyncOutcome();
    const store = NoteStore.instance;
    if (!SyncEngine.configured) {
      outcome.message = '请先配置 WebDAV';
      return outcome;
    }

    const listing = await SyncEngine.listOrCreate(REMOTE_DIR);
    if (!listing.ok) {
      outcome.message = SyncEngine.friendly(listing.status, listing.message);
      return outcome;
    }

    const baseById: Map<string, BaselineEntry> = SyncEngine.parseBase(
      settings.syncBaseScope === SyncEngine.scopeOf() ? settings.syncBase : '');
    if (settings.syncBase.length > 0 && settings.syncBaseScope !== SyncEngine.scopeOf()) {
      // A baseline from a *different* server is not evidence about this one: its
      // rows would make every note look deleted remotely and file the whole
      // vault into 回收站. Treat it as absent — the run re-uploads instead.
      hilog.warn(DOMAIN, TAG, 'baseline belongs to another server, ignoring it');
    }
    // The baseline is also the record of which path belongs to which id, which is
    // what lets a file that lost its `id:` line still be recognised. Parsed
    // before the remote listing so the fetch loop below can use it.
    const baseByPath: Map<string, BaselineEntry> = SyncEngine.pathIndex(baseById);

    const remoteById: Map<string, RemoteNote> = new Map<string, RemoteNote>();
    // Every remote path that carries a given id. A note renamed after upload
    // leaves its old file behind, so an id can legitimately map to several
    // files; `remoteById` keeps only the last one read, which is arbitrary.
    const remotePathsById: Map<string, string[]> = new Map<string, string[]>();
    const remoteFiles: DavEntry[] = [];
    for (const entry of listing.entries) {
      if (!entry.isDir && entry.relPath.endsWith('.md')) {
        remoteFiles.push(entry);
      }
    }
    for (const entry of remoteFiles) {
      const got = await WebDavClient.get(SyncEngine.config, SyncEngine.encodePath(entry.relPath));
      if (!got.ok) {
        // A partial listing is worse than no sync at all: an id that failed to
        // load is *missing* from `remoteById`, so the merge would conclude "the
        // server deleted it" and either re-upload over a newer remote edit or
        // pull a stale sibling. Both happened in practice — one `GET` returned
        // 500 while the baseline still advanced, and the next run rolled the
        // local note back to an older body. Abort instead.
        hilog.error(DOMAIN, TAG, 'abort: GET %{public}s failed: %{public}s',
          entry.relPath, got.message);
        outcome.message = `读取远端失败：${entry.relPath}`;
        return outcome;
      }
      const parsed: ParsedNote = FrontmatterCodec.parse(got.message);
      const localPath = SyncEngine.localRel(entry.relPath);
      // A file that keeps its path but lost its `id:` line is the *same note*, not
      // a deletion and not a new one. The baseline knows which id owned this
      // path, so adopt it and let the normal merge run. Deciding by id alone
      // would either trash the local copy (remote "missing") or import a
      // duplicate (this file "new"). Never overwrite the body to repair it —
      // the remote text may be the newer one.
      const owner = parsed.hasId ? undefined : baseByPath.get(localPath);
      const effectiveId = parsed.hasId ? parsed.id : (owner?.id ?? '');
      if (!parsed.hasId && owner !== undefined) {
        hilog.warn(DOMAIN, TAG, 'remote %{public}s lost its id; recovering %{public}s from baseline',
          localPath, owner.id);
      }
      const remote = new RemoteNote();
      remote.remotePath = entry.relPath;
      remote.etag = entry.etag;
      remote.note.id = effectiveId;
      remote.note.title = parsed.title;
      remote.note.body = parsed.body;
      remote.note.tags = parsed.tags;
      remote.note.pinned = parsed.pinned;
      remote.note.favorite = parsed.favorite;
      remote.note.createdAt = parsed.createdAt;
      // A file with no `updated:` never wins on merit. `entry.modifiedAt` is
      // the server's own mtime and is the honest fallback there.
      remote.note.updatedAt = parsed.hasUpdatedAt ? parsed.updatedAt : entry.modifiedAt;
      // Normalise to the *local* shape: a path relative to the notes folder,
      // with no `zhijian/` prefix. Keeping the server-side path here made the
      // rename check below compare `zhijian/a.md` against `a.md`, so every note
      // looked renamed on every run and the whole vault was re-uploaded each
      // time — 16 PUTs per sync, forever. Prefixes are re-added only when a
      // request is built.
      remote.note.relPath = localPath;
      remote.note.excerpt = parsed.excerpt;
      // No id and no baseline row for this path: genuinely a new, hand-written
      // file. Key it by path so several such files stay distinct; the
      // remote-only pass below mints a real id for each.
      const key = effectiveId.length > 0 ? effectiveId : `path:${entry.relPath}`;
      // An id may appear at several paths (a note renamed after upload leaves
      // its old file behind). Picking "whichever was read last" is arbitrary —
      // the loop order is the server's, not time's — so an older sibling could
      // shadow a newer one. Keep the newest by `updatedAt`, and remember every
      // path so the stale duplicates can be cleaned up after the merge.
      const previous = remoteById.get(key);
      if (previous === undefined || remote.note.updatedAt > previous.note.updatedAt) {
        remoteById.set(key, remote);
      }
      if (effectiveId.length > 0) {
        const paths = remotePathsById.get(effectiveId) ?? [];
        paths.push(localPath);
        remotePathsById.set(effectiveId, paths);
      }
    }

    store.reload();
    // Paths the local vault occupies, independent of the frontmatter id. Mirrors
    // `baseByPath`: a note that lost its `id:` line still has a file on disk,
    // and that must not be read as "the user deleted it".
    const localPaths: Set<string> = new Set<string>();
    for (const note of store.notes) {
      localPaths.add(note.relPath);
    }
    // What the server is *confirmed* to hold once this run ends, per id.
    //
    // Only an operation that actually reached the server may record an entry:
    // a successful PUT records the local `updatedAt`, a successful GET records
    // the remote one. A failed PUT records nothing, so the id falls back to its
    // previous baseline row (see `buildBase`) and the next run still sees
    // "local changed, remote unchanged" and retries the upload.
    //
    // This is the difference between a sync and a data-loss bug. The earlier
    // code wrote the local `updatedAt` into the baseline unconditionally, so
    // after one throttled PUT the baseline claimed the server already held the
    // new body. The next run then read the *old* remote file, saw it differ
    // from that baseline, called it "the remote changed", and overwrote the
    // newer local note with it. Verified the hard way on the emulator.
    const confirmed: Map<string, number> = new Map<string, number>();
    // Ids this run actually wrote to the server. Feeds the stale-path cleanup
    // below, which must know which id's local filename is authoritative.
    const pushed: Set<string> = new Set<string>();

    // ---- per-id three-way decision ----------------------------------------
    const handledLocal: Set<string> = new Set<string>();
    // Notes whose server copy is gone, collected here and removed from the
    // store after the loop: `deleteNote()` reassigns `store.notes`, so mutating
    // it while iterating it is asking for a skipped note.
    const locallyDeleted: Note[] = [];
    // Ids whose baseline row must *not* survive this run: both sides are now
    // known to be gone (or the note was just archived on both).
    const dropped: Set<string> = new Set<string>();
    for (const note of store.notes) {
      handledLocal.add(note.id);
      const remote = remoteById.get(note.id);
      const base = baseById.get(note.id);

      if (remote === undefined) {
        if (base !== undefined) {
          // The baseline says the server held this id at the end of the last
          // run, and the listing above was complete (any failed GET aborts the
          // whole run), so its absence is a deletion — not "never uploaded".
          // Moving it to 回收站 rather than unlinking keeps it recoverable for
          // 30 days, which is the whole reason propagating deletions is safe.
          //
          // A remote file that merely lost its `id:` line does *not* land here:
          // the fetch loop recovers its identity from the baseline path, so it
          // is present in `remoteById` under the right key.
          hilog.info(DOMAIN, TAG, 'remote deleted %{public}s, moving local copy to trash',
            note.relPath);
          locallyDeleted.push(note);
          continue;
        }
        // Never seen on the server: upload.
        if (await SyncEngine.push(note, pushed)) {
          outcome.uploaded++;
          confirmed.set(note.id, note.updatedAt);
        }
        continue;
      }

      // A name mismatch with matching content is a rename on one side. The
      // remote file is the stale copy of the *same* note: upload under the new
      // name first, then drop the old one. Doing it the other way round would
      // leave the note missing from the server in between. Skipping it entirely
      // is not an option either — the next run would list two files carrying
      // one id and keep whichever it happened to read last, so the two silently
      // fight over the note. That is exactly what the emulator run produced
      // after a note was renamed post-upload.
      if (note.updatedAt === remote.note.updatedAt && note.relPath !== remote.note.relPath) {
        if (!await SyncEngine.push(note, pushed)) {
          continue;
        }
        const stale = await WebDavClient.remove(SyncEngine.config,
          SyncEngine.encodePath(`${REMOTE_DIR}/${remote.note.relPath}`));
        if (!stale.ok && stale.status !== 404) {
          hilog.warn(DOMAIN, TAG, 'stale %{public}s not removed: %{public}s',
            remote.note.relPath, stale.message);
        }
        confirmed.set(note.id, note.updatedAt);
        outcome.uploaded++;
        continue;
      }

      const localChanged = base === undefined || note.updatedAt !== base.updatedAt;
      const remoteChanged = base === undefined || remote.note.updatedAt !== base.updatedAt;

      if (!localChanged && !remoteChanged) {
        // Both sides match the baseline. Record it so an id that was already in
        // sync does not lose its baseline row when the run is aborted later.
        confirmed.set(note.id, remote.note.updatedAt);
        outcome.skipped++;
        continue;
      }

      if (localChanged && !remoteChanged) {
        if (await SyncEngine.push(note, pushed)) {
          outcome.uploaded++;
          confirmed.set(note.id, note.updatedAt);
        }
        continue;
      }

      if (!localChanged && remoteChanged) {
        // A remote note must never roll the local one backwards. `updatedAt` is
        // monotonic within a note, so a remote copy that is *older* than the
        // local file means the server went back in time — a stale duplicate, a
        // restore from backup, or a sibling file left behind by a rename. The
        // baseline alone cannot tell that from a real remote edit, and honouring
        // it deletes the user's newer text (verified on the emulator: it did).
        // Local is the newer copy, so put it back on the server instead.
        if (remote.note.updatedAt < note.updatedAt) {
          hilog.warn(DOMAIN, TAG, 'remote %{public}s older than local (%{public}d < %{public}d), keeping local',
            note.relPath, remote.note.updatedAt, note.updatedAt);
          if (await SyncEngine.push(note, pushed)) {
            outcome.uploaded++;
            confirmed.set(note.id, note.updatedAt);
          }
          continue;
        }
        if (SyncEngine.applyRemote(store, note, remote.note)) {
          outcome.downloaded++;
          confirmed.set(note.id, remote.note.updatedAt);
        }
        continue;
      }

      // Both sides moved since the last sync.
      if (Math.abs(note.updatedAt - remote.note.updatedAt) <= 1000 &&
        note.body === remote.note.body) {
        // Same edit applied on both devices (or a re-upload after a failed
        // baseline write). Nothing to decide.
        confirmed.set(note.id, remote.note.updatedAt);
        outcome.skipped++;
        continue;
      }
      if (note.updatedAt >= remote.note.updatedAt) {
        // Local edit is newer: keep it on the local side, but preserve the
        // remote text as a sibling file instead of overwriting it. The sibling
        // is a *new* note with its own id, so it must be uploaded too — leaving
        // it local-only would make it a fresh upload on the next run and add a
        // spurious "上传 1" to a run the user already saw finish.
        const copy = SyncEngine.importConflictCopy(store, remote.note);
        outcome.conflicts++;
        if (copy !== undefined && await SyncEngine.push(copy, pushed)) {
          confirmed.set(copy.id, copy.updatedAt);
        }
        if (await SyncEngine.push(note, pushed)) {
          outcome.uploaded++;
          confirmed.set(note.id, note.updatedAt);
        }
      } else {
        const copy = SyncEngine.keepLocalAsConflict(store, note);
        outcome.conflicts++;
        if (copy !== undefined && await SyncEngine.push(copy, pushed)) {
          confirmed.set(copy.id, copy.updatedAt);
        }
        if (SyncEngine.applyRemote(store, note, remote.note)) {
          outcome.downloaded++;
          confirmed.set(note.id, remote.note.updatedAt);
        }
      }
    }

    // ---- remote-only notes -------------------------------------------------
    for (const key of Array.from(remoteById.keys())) {
      const remote = remoteById.get(key);
      if (remote === undefined) {
        continue;
      }
      const knownId = remote.note.id;
      if (knownId.length > 0 && handledLocal.has(knownId)) {
        continue;
      }
      if (knownId.length > 0 && baseById.get(knownId) !== undefined) {
        // Local deletion. The baseline proves this device had the note last run
        // and it is gone from `notes/` now — the user deleted it, so the server
        // copy follows it into `zhijian/.trash` instead of being pulled back.
        //
        // The mirror image of the remote case: a *local* file may still sit at
        // the baseline path because it lost its `id:` line, not because the user
        // deleted anything. `NoteStore.reload()` falls back to the filename as
        // the id in that case, so the note is here under a foreign key. Restore
        // the id and leave the remote copy alone — archiving it would delete a
        // note that is still on this device.
        const row = baseById.get(knownId);
        if (row !== undefined && localPaths.has(row.relPath)) {
          const damaged = SyncEngine.noteAtPath(store, row.relPath);
          if (damaged !== undefined && damaged.id !== knownId) {
            hilog.warn(DOMAIN, TAG,
              'local %{public}s lost its id; restoring %{public}s from baseline',
              row.relPath, knownId);
            damaged.id = knownId;
            store.overwriteFromSync(damaged);
            confirmed.set(knownId, damaged.updatedAt);
          }
          continue;
        }
        // Every path carrying the id is archived: a note renamed after upload
        // can leave a sibling behind, and leaving one of them would resurrect
        // the note on the next run as "new from another device".
        const paths = remotePathsById.get(knownId) ?? [remote.note.relPath];
        if (await SyncEngine.archiveRemote(paths)) {
          outcome.trashedRemote++;
          dropped.add(knownId);
        }
        continue;
      }
      // Either a note from another device, or a hand-written file with no
      // frontmatter. Both are new here, so import under a generated id when the
      // file carried none.
      if (knownId.length === 0) {
        remote.note.id = SyncEngine.mintId();
      }
      if (SyncEngine.applyRemote(store, undefined, remote.note)) {
        outcome.downloaded++;
        confirmed.set(remote.note.id, remote.note.updatedAt);
      }
    }

    // Apply the local deletions only now: `deleteNote()` reassigns `store.notes`,
    // so doing it inside the loop above would skip whichever note shifted into
    // the current index. The baseline row is dropped only when the file provably
    // reached `.trash` — a failed rename keeps the row, so the next run sees the
    // same "remote deleted, local present, baseline present" state and retries
    // instead of silently uploading the note back to the server.
    for (const note of locallyDeleted) {
      if (store.deleteNote(note)) {
        dropped.add(note.id);
        outcome.trashedLocal++;
      }
    }

    store.reload();

    // ---- stale duplicates ---------------------------------------------------
    // Every id must end up at exactly one remote path, and that path must be the
    // one this device now uses. A rename after upload otherwise leaves the old
    // file on the server, and from then on the id names two bodies: the merge
    // picks one arbitrarily and the note appears to flip between versions on
    // every sync. This is not hypothetical — the emulator produced exactly that
    // when a note was renamed in the editor between two syncs.
    //
    // The `pushed` set is what makes this generic: any id this run wrote to the
    // server under a name is authoritative, and *every* other remote file
    // carrying that id is by definition the stale one. `remotePathsById` also
    // has to be re-read after the run, because a note renamed by the editor has
    // a path that was never in the pre-run listing at all.
    const pathsById: Map<string, string[]> = new Map<string, string[]>();
    for (const path of Array.from(remotePathsById.keys())) {
      pathsById.set(path, remotePathsById.get(path) ?? []);
    }
    if (pushed.size > 0) {
      const after = await SyncEngine.listOrCreate(REMOTE_DIR);
      if (after.ok) {
        for (const entry of after.entries) {
          if (entry.isDir || !entry.relPath.endsWith('.md')) {
            continue;
          }
          const got = await WebDavClient.get(SyncEngine.config,
            SyncEngine.encodePath(entry.relPath));
          if (!got.ok) {
            continue;
          }
          const parsed: ParsedNote = FrontmatterCodec.parse(got.message);
          if (!parsed.hasId || !pushed.has(parsed.id)) {
            continue;
          }
          const local = SyncEngine.localRel(entry.relPath);
          const list = pathsById.get(parsed.id) ?? [];
          if (list.indexOf(local) < 0) {
            list.push(local);
          }
          pathsById.set(parsed.id, list);
        }
      }
    }
    for (const id of Array.from(confirmed.keys())) {
      const paths = pathsById.get(id);
      const note = store.find(id);
      if (paths === undefined || note === undefined || paths.length < 2) {
        continue;
      }
      // Only touch ids whose *current* local filename provably exists on the
      // server. That is the signature of a push this run: the note owns that
      // path, so every other file carrying the id is the leftover. A note that
      // was only downloaded keeps the server's filename while its local file may
      // be named differently — deleting "everything but the local name" would
      // remove the file the note was just read from.
      if (paths.indexOf(note.relPath) < 0) {
        continue;
      }
      for (const path of paths) {
        if (path === note.relPath) {
          continue;
        }
        const removed = await WebDavClient.remove(SyncEngine.config,
          SyncEngine.encodePath(`${REMOTE_DIR}/${path}`));
        if (!removed.ok && removed.status !== 404) {
          hilog.warn(DOMAIN, TAG, 'duplicate %{public}s not removed: %{public}s',
            path, removed.message);
        } else {
          hilog.info(DOMAIN, TAG, 'removed stale duplicate %{public}s', path);
        }
      }
    }

    settings.setSyncState(SyncEngine.buildBase(baseById, store.notes, remoteById, confirmed, dropped),
      SyncEngine.scopeOf());
    outcome.ok = true;
    outcome.finishedAt = systemDateTime.getTime();
    settings.setSyncFinishedAt(outcome.finishedAt);
    // Runs after the baseline is settled, and never affects `ok`: a vault whose
    // notes all synced must not read as failed because an expired trash entry
    // refused to unlink.
    await SyncEngine.purgeRemoteTrash();
    outcome.message = SyncEngine.summary(outcome);
    hilog.info(DOMAIN, TAG,
      'sync upload=%{public}d download=%{public}d conflict=%{public}d trashLocal=%{public}d trashRemote=%{public}d',
      outcome.uploaded, outcome.downloaded, outcome.conflicts,
      outcome.trashedLocal, outcome.trashedRemote);
    return outcome;
  }

  /**
   * Moves every server path carrying one id into `zhijian/.trash`.
   *
   * Returns true only when *all* paths were archived, so the caller drops the
   * baseline row only for a deletion that provably happened. A partial success
   * keeps the row: the next run finds the surviving path, still sees "local gone,
   * baseline says the server had it", and retries — which is exactly the
   * behaviour a half-finished archive needs.
   */
  private static async archiveRemote(paths: string[]): Promise<boolean> {
    if (paths.length === 0) {
      return false;
    }
    const made = await WebDavClient.makeCollection(SyncEngine.config, `${REMOTE_TRASH_DIR}/`);
    if (!made.ok && made.status !== 405) {
      hilog.error(DOMAIN, TAG, 'remote trash unavailable: %{public}s', made.message);
      return false;
    }
    let all = true;
    for (const path of paths) {
      // The timestamp prefix is what the retention sweep reads, exactly like the
      // local 回收站 reads `<millis>-name.md`. `now + seq` keeps two notes
      // trashed in the same millisecond from colliding, and lands inside the
      // same second so the recorded time is still honest.
      const stamp = systemDateTime.getTime() + SyncEngine.archiveSeq;
      SyncEngine.archiveSeq++;
      const base = path.substring(path.lastIndexOf('/') + 1);
      const target = `${REMOTE_TRASH_DIR}/${stamp}-${base}`;
      const moved = await WebDavClient.moveTo(SyncEngine.config,
        SyncEngine.encodePath(`${REMOTE_DIR}/${path}`), SyncEngine.encodePath(target));
      if (!moved.ok) {
        all = false;
        hilog.error(DOMAIN, TAG, 'archive %{public}s failed: %{public}s', path, moved.message);
        continue;
      }
      hilog.info(DOMAIN, TAG, 'archived remote %{public}s -> %{public}s', path, target);
    }
    return all;
  }

  /**
   * Deletes expired entries from the server-side 回收站.
   *
   * Best-effort by design: a vault whose notes all synced fine must not be
   * reported as failed because an old trash entry could not be unlinked. A
   * missing `.trash` (404) simply means nothing was ever deleted here.
   */
  private static async purgeRemoteTrash(): Promise<number> {
    const listing = await WebDavClient.list(SyncEngine.config, `${REMOTE_TRASH_DIR}/`);
    if (!listing.ok) {
      return 0;
    }
    const cutoff = systemDateTime.getTime() - TRASH_RETENTION_DAYS * DAY_MS;
    let removed = 0;
    for (const entry of listing.entries) {
      if (entry.isDir || !entry.relPath.endsWith('.md')) {
        continue;
      }
      const name = entry.relPath.substring(entry.relPath.lastIndexOf('/') + 1);
      // Trust the name's stamp first — it records when the note was trashed,
      // while `getlastmodified` may still be the note's own last edit if the
      // server preserved it across the MOVE.
      const stamped = SyncEngine.trashStampOf(name);
      const when = stamped > 0 ? stamped : entry.modifiedAt;
      if (when <= 0 || when >= cutoff) {
        continue;
      }
      const gone = await WebDavClient.remove(SyncEngine.config,
        SyncEngine.encodePath(entry.relPath));
      if (gone.ok) {
        removed++;
      }
    }
    if (removed > 0) {
      hilog.info(DOMAIN, TAG, 'remote trash purge removed=%{public}d', removed);
    }
    return removed;
  }

  /** Leading `<milliseconds>-` of a trash file name; 0 when there is none. */
  private static trashStampOf(fileName: string): number {
    const dash = fileName.indexOf('-');
    if (dash <= 0) {
      return 0;
    }
    const raw = fileName.substring(0, dash);
    for (let i = 0; i < raw.length; i++) {
      const code = raw.charCodeAt(i);
      if (code < 48 || code > 57) {
        return 0;
      }
    }
    const value = Number.parseInt(raw, 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /**
   * The post-run baseline: what the server is *confirmed* to hold.
   *
   * Starts from the previous rows and applies this run's outcomes, rather than
   * rebuilding from `confirmed` alone. That distinction is load-bearing twice
   * over:
   *
   * - A PUT that failed must keep its old row, so the next run still sees
   *   "local changed, remote unchanged" and retries the upload. Dropping it
   *   would make the id look never-synced and re-upload — harmless. But for a
   *   *deletion* it is the difference between retrying and resurrecting: a
   *   failed `MOVE` to `.trash` that also lost its row makes the next run treat
   *   the still-present remote file as "new from another device" and download
   *   the note the user just deleted.
   * - An id whose row is `dropped` must not be carried forward, or it would be
   *   archived again on every subsequent run.
   */
  private static buildBase(previous: Map<string, BaselineEntry>, localNotes: Note[],
    remoteById: Map<string, RemoteNote>, confirmed: Map<string, number>,
    dropped: Set<string>): string {
    const pathById: Map<string, string> = new Map<string, string>();
    for (const note of localNotes) {
      pathById.set(note.id, note.relPath);
    }
    for (const key of Array.from(remoteById.keys())) {
      const remote = remoteById.get(key);
      if (remote === undefined || remote.note.id.length === 0) {
        continue;
      }
      if (!pathById.has(remote.note.id)) {
        pathById.set(remote.note.id, remote.note.relPath);
      }
    }
    const lines: string[] = [];
    const written: Set<string> = new Set<string>();
    for (const id of Array.from(confirmed.keys())) {
      const updatedAt = confirmed.get(id);
      if (updatedAt === undefined || dropped.has(id)) {
        continue;
      }
      const relPath = pathById.get(id) ?? '';
      lines.push(`${id}\t${updatedAt}\t${relPath}`);
      written.add(id);
    }
    for (const id of Array.from(previous.keys())) {
      if (written.has(id) || dropped.has(id)) {
        continue;
      }
      const row = previous.get(id);
      if (row === undefined) {
        continue;
      }
      // Carry a row forward only while the id still exists on at least one side.
      // An id gone from both is the "both devices agree" state and needs no
      // tombstone, which is what keeps this file from growing forever.
      if (!pathById.has(id) && remoteById.get(id) === undefined) {
        continue;
      }
      lines.push(`${id}\t${row.updatedAt}\t${row.relPath}`);
    }
    return lines.join('\n');
  }

  /** Index of the baseline by the *local* path it last recorded per id. */
  private static pathIndex(base: Map<string, BaselineEntry>): Map<string, BaselineEntry> {
    const index: Map<string, BaselineEntry> = new Map<string, BaselineEntry>();
    for (const id of Array.from(base.keys())) {
      const entry = base.get(id);
      if (entry === undefined || entry.relPath.length === 0) {
        continue;
      }
      index.set(entry.relPath, entry);
    }
    return index;
  }

  private static parseBase(text: string): Map<string, BaselineEntry> {
    const map: Map<string, BaselineEntry> = new Map<string, BaselineEntry>();
    if (text.length === 0) {
      return map;
    }
    const lines = text.split('\n');
    for (const line of lines) {
      const parts = line.split('\t');
      if (parts.length < 2) {
        continue;
      }
      const entry = new BaselineEntry();
      entry.id = parts[0];
      const updated = parseInt(parts[1], 10);
      entry.updatedAt = Number.isNaN(updated) ? 0 : updated;
      entry.relPath = parts.length > 2 ? parts[2] : '';
      if (entry.id.length > 0) {
        map.set(entry.id, entry);
      }
    }
    return map;
  }

  /** Finds the note that currently occupies a path (id-independent). */
  private static noteAtPath(store: NoteStore, relPath: string): Note | undefined {
    for (const note of store.notes) {
      if (note.relPath === relPath) {
        return note;
      }
    }
    return undefined;
  }

  /** Writes a remote note locally: over `existing` when given, else as new. */
  private static applyRemote(store: NoteStore, existing: Note | undefined, remote: Note): boolean {
    const merged = new Note();
    merged.id = remote.id;
    merged.title = remote.title;
    merged.body = remote.body;
    merged.tags = remote.tags.length > 0 ? remote.tags : (existing?.tags ?? []);
    merged.pinned = remote.pinned;
    merged.favorite = remote.favorite;
    merged.createdAt = remote.createdAt > 0 ? remote.createdAt :
      (existing?.createdAt ?? remote.createdAt);
    merged.updatedAt = remote.updatedAt;
    merged.folder = '';
    merged.excerpt = remote.excerpt;
    if (existing !== undefined) {
      // Keep the local filename: `saveNote()` derives it from the H1, so a
      // renamed file would just be renamed back on the next edit, churning the
      // list and the `ForEach` key for no reason.
      merged.relPath = existing.relPath;
      return store.overwriteFromSync(merged);
    }
    return store.importFromSync(merged);
  }

  /**
   * Keeps the local text as a conflict sibling before the remote overwrites it.
   * Returns the copy so the caller can upload it, or `undefined` when the write
   * failed.
   */
  private static keepLocalAsConflict(store: NoteStore, note: Note): Note | undefined {
    const copy = new Note();
    copy.id = SyncEngine.mintId();
    const marked = SyncEngine.conflictTitle(note.title);
    copy.title = marked;
    copy.body = SyncEngine.markConflictBody(note.body, marked);
    copy.tags = note.tags;
    copy.pinned = false;
    copy.favorite = false;
    copy.createdAt = note.createdAt;
    copy.updatedAt = note.updatedAt;
    copy.folder = '';
    copy.excerpt = note.excerpt;
    return store.importFromSync(copy) ? copy : undefined;
  }

  /**
   * Keeps the remote text as a conflict sibling while the local note stays.
   * Returns the copy so the caller can upload it, or `undefined` on failure.
   */
  private static importConflictCopy(store: NoteStore, remote: Note): Note | undefined {
    const copy = new Note();
    copy.id = SyncEngine.mintId();
    const marked = SyncEngine.conflictTitle(remote.title);
    copy.title = marked;
    copy.body = SyncEngine.markConflictBody(remote.body, marked);
    copy.tags = remote.tags;
    copy.pinned = false;
    copy.favorite = false;
    copy.createdAt = remote.createdAt;
    copy.updatedAt = remote.updatedAt;
    copy.folder = '';
    copy.excerpt = remote.excerpt;
    return store.importFromSync(copy) ? copy : undefined;
  }

  private static conflictTitle(title: string): string {
    const stamp = new Date(systemDateTime.getTime());
    const hh = stamp.getHours().toString().padStart(2, '0');
    const mm = stamp.getMinutes().toString().padStart(2, '0');
    return `${title} (冲突 ${hh}${mm})`;
  }

  /**
   * Rewrites the H1 so the conflict copy is distinguishable in the note list.
   *
   * The list renders `note.title`, and `NoteStore.reload()` re-derives that from
   * the body's H1 — *not* from the filename. Stamping only the filename leaves
   * two cards reading 「服务器新建的笔记」 side by side with no way to tell which
   * one the sync produced, which is exactly what the emulator run showed. The
   * mark has to live in the body to survive a reload.
   */
  private static markConflictBody(body: string, marked: string): string {
    const lines = body.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim().startsWith('# ')) {
        lines[i] = `# ${marked}`;
        return lines.join('\n');
      }
    }
    return `# ${marked}\n\n${body}`;
  }

  private static mintId(): string {
    return `${systemDateTime.getTime().toString(36)}-${Math.floor(Math.random() * 100000)}`;
  }

  /** PUTs a note and records its id when the server accepted the write. */
  private static async push(note: Note, pushed: Set<string>): Promise<boolean> {
    const path = `${REMOTE_DIR}/${SyncEngine.encodePath(note.relPath)}`;
    const content = FrontmatterCodec.build(note);
    const result = await WebDavClient.put(SyncEngine.config, path, content);
    if (!result.ok) {
      hilog.error(DOMAIN, TAG, 'upload %{public}s failed: %{public}s',
        note.relPath, result.message);
      return false;
    }
    pushed.add(note.id);
    return true;
  }

  private static async listOrCreate(dir: string): Promise<DavListResult> {
    const path = `${dir}/`;
    let listing = await WebDavClient.list(SyncEngine.config, path);
    if (!listing.ok && listing.status === 404) {
      // 405 from MKCOL means it already exists, which is success for our purpose.
      const made = await WebDavClient.makeCollection(SyncEngine.config, path);
      if (!made.ok && made.status !== 405) {
        return listing;
      }
      listing = await WebDavClient.list(SyncEngine.config, path);
    }
    return listing;
  }

  /**
   * Server path → local path shape: drops the `zhijian/` folder prefix.
   *
   * Everything inside a merge decision must speak one dialect. `WebDavClient`
   * reports paths relative to the base URL (`zhijian/a.md`), while `Note.relPath`
   * is a bare filename (`a.md`). Comparing the two directly made every note look
   * renamed on every run, so the whole vault was re-uploaded each sync.
   */
  private static localRel(remotePath: string): string {
    const prefix = `${REMOTE_DIR}/`;
    if (remotePath.startsWith(prefix)) {
      return remotePath.substring(prefix.length);
    }
    return remotePath;
  }

  /** Percent-encodes each path segment; the base URL already ends with `/`. */
  private static encodePath(relPath: string): string {
    const segments = relPath.split('/');
    const encoded: string[] = [];
    for (const segment of segments) {
      encoded.push(encodeURIComponent(segment));
    }
    return encoded.join('/');
  }

  private static summary(outcome: SyncOutcome): string {
    const parts: string[] = [];
    if (outcome.uploaded > 0) {
      parts.push(`上传 ${outcome.uploaded}`);
    }
    if (outcome.downloaded > 0) {
      parts.push(`下载 ${outcome.downloaded}`);
    }
    if (outcome.conflicts > 0) {
      parts.push(`冲突 ${outcome.conflicts}`);
    }
    // Reported as 回收站 rather than 删除: the note is recoverable for 30 days on
    // whichever side it left, so "deleted" would overstate what happened.
    if (outcome.trashedLocal > 0) {
      parts.push(`远端删除 ${outcome.trashedLocal} · 已进回收站`);
    }
    if (outcome.trashedRemote > 0) {
      parts.push(`本地删除 ${outcome.trashedRemote} · 已归档到远端`);
    }
    if (parts.length === 0) {
      return '已是最新';
    }
    return parts.join(' · ');
  }

  /**
   * Turns a transport failure into something actionable. A bare `401` in a
   * dialog tells the user nothing; "用户名或密码不正确" tells them what to fix.
   */
  private static friendly(status: number, detail: string): string {
    if (status === 401) {
      return '用户名或密码不正确';
    }
    if (status === 403) {
      return '没有访问权限';
    }
    if (status === 404) {
      return '服务器地址不存在，请检查 URL';
    }
    if (status === 405) {
      return '服务器不允许该操作';
    }
    if (status >= 500) {
      return `服务器错误（${status}）`;
    }
    // Transport failures never reach `status` — RCP rejects instead. The name
    // lookup failure is by far the most actionable one, so it gets its own text
    // instead of a bare `[1007900006] Couldn't resolve host name`.
    if (detail.indexOf('resolve') >= 0 || detail.indexOf('1007900006') >= 0) {
      return '无法解析服务器域名。若网络没有可用 DNS，请填写「直连 IP」';
    }
    if (detail.indexOf('1007900001') >= 0 || detail.indexOf('timeout') >= 0) {
      return '连接超时。若网络需要代理才能上网，请填写「代理服务器」';
    }
    if (detail.indexOf('certificate') >= 0 || detail.indexOf('SSL') >= 0) {
      return '证书校验失败，请确认服务器证书有效';
    }
    return detail.length > 0 ? detail : '网络请求失败，请检查网络或证书';
  }
}
