/**
 * Duck Hunt — Google Sheets ⇄ Supabase sync
 *
 * Paste into the spreadsheet's Extensions → Apps Script editor.
 * Setup steps are in backend/README.md.
 *
 * Script properties (Project Settings → Script properties):
 *   SUPABASE_URL         https://<project-ref>.supabase.co
 *   SUPABASE_SECRET_KEY  secret key (sb_secret_…) or legacy service_role key
 *   WEBHOOK_SECRET       any long random string; must match private.sheet_sync.secret
 *
 * Direction of sync:
 *   Master Ducks  ⇄  ducks     (edit in the sheet or in Supabase)
 *   Player        ⇄  players   (edit in the sheet or in Supabase)
 *   Duck Log      ⇄  duck_log  (written by the app; deleting a row undoes that scan)
 */

// Tab names in the spreadsheet
const SHEET_NAMES = {
  ducks: 'Master Ducks',
  log: 'Duck Log',
  players: 'Player'
};

// Sheet header → Supabase column, per tab. Headers are matched by name
// (trimmed, case-insensitive), so column order doesn't matter.
const COLUMNS = {
  ducks: {
    'Duck ID': 'duck_id',
    'Duck Type': 'duck_type',
    'Points': 'points',
    'QR Code': 'qr_code',
    'Location': 'location',
    'Claimed': 'claimed'
  },
  log: {
    'Duck ID': 'duck_id',
    'Student ID': 'student_id',
    'Timestamp': 'scanned_at',
    'Type': 'duck_type',
    'Log ID': 'id'
  },
  players: {
    'First Name': 'first_name',
    'Last Name': 'last_name',
    'Student ID': 'student_id',
    'Email': 'email',
    'Points': 'points',
    'Codes Scanned': 'codes_scanned'
  }
};

const TABLES = { ducks: 'ducks', log: 'duck_log', players: 'players' };
const KEYS = { ducks: 'duck_id', players: 'student_id', log: 'id' };
const ORDER = { ducks: 'duck_id.asc', log: 'scanned_at.asc', players: 'points.desc,created_at.asc' };
const NUMBER_FIELDS = ['points', 'codes_scanned'];
const BOOLEAN_FIELDS = ['claimed'];
const DATE_FIELDS = ['scanned_at'];
const NOT_NULL_TEXT_FIELDS = ['first_name', 'last_name'];

// Erasing more Duck Log rows than this at once won't delete them in
// Supabase automatically; use the menu item to confirm instead.
const MAX_AUTO_DELETE = 10;


// ---------------------------------------------------------------------
// Menu & triggers
// ---------------------------------------------------------------------

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Duck Hunt')
    .addItem('Pull everything from Supabase', 'pullAllFromSupabase')
    .addItem('Push Master Ducks & Players to Supabase', 'pushAllToSupabase')
    .addItem('Sync erased Duck Log rows to Supabase', 'syncErasedScansFromMenu')
    .addSeparator()
    .addItem('Set up sync triggers', 'setupTriggers')
    .addToUi();
}

/** Run once (from the menu or the editor) to install the sync triggers. */
function setupTriggers() {
  const ss = SpreadsheetApp.getActive();
  ScriptApp.getProjectTriggers().forEach(t => {
    if (['handleEdit', 'handleChange', 'pullAllFromSupabase'].indexOf(t.getHandlerFunction()) !== -1) {
      ScriptApp.deleteTrigger(t);
    }
  });
  // Installable (not simple) onEdit, because simple triggers can't call UrlFetchApp
  ScriptApp.newTrigger('handleEdit').forSpreadsheet(ss).onEdit().create();
  // Row deletions don't fire onEdit
  ScriptApp.newTrigger('handleChange').forSpreadsheet(ss).onChange().create();
  // Safety net in case a live update from Supabase is missed
  ScriptApp.newTrigger('pullAllFromSupabase').timeBased().everyMinutes(10).create();
  ss.toast('Sync triggers installed.', 'Duck Hunt');
}


// ---------------------------------------------------------------------
// Sheet → Supabase
// ---------------------------------------------------------------------

/** Installable onEdit trigger: push edited Master Ducks / Player rows. */
function handleEdit(e) {
  const sheet = e.range.getSheet();
  const kind = kindForSheet(sheet.getName());
  if (kind === 'log') return syncErasedScans(false);
  if (kind !== 'ducks' && kind !== 'players') return;

  const firstRow = Math.max(e.range.getRow(), 2);
  const lastRow = e.range.getLastRow();
  if (lastRow < firstRow) return;

  const headers = readHeaders(sheet, kind);
  const values = sheet.getRange(firstRow, 1, lastRow - firstRow + 1, sheet.getLastColumn()).getValues();
  let records = values
    .map(row => rowToRecord(kind, row, headers))
    .filter(r => r[KEYS[kind]]);

  if (kind === 'ducks') {
    const missing = records.filter(r => !r.qr_code);
    if (missing.length) {
      SpreadsheetApp.getActive().toast('Add a QR Code to sync duck ' + missing.map(r => r.duck_id).join(', '), 'Duck Hunt');
    }
    records = records.filter(r => r.qr_code);
  }
  if (!records.length) return;

  try {
    upsert(kind, records);
  } catch (err) {
    SpreadsheetApp.getActive().toast(String(err.message || err).slice(0, 200), 'Duck Hunt sync failed', 10);
    throw err;
  }
}

/** Menu: push every Master Ducks and Player row (use once to seed Supabase). */
function pushAllToSupabase() {
  // Players first: ducks.claimed_by references players
  ['players', 'ducks'].forEach(kind => {
    const sheet = getSheet(kind);
    if (sheet.getLastRow() < 2) return;
    const headers = readHeaders(sheet, kind);
    const values = sheet.getRange(2, 1, sheet.getLastRow() - 1, sheet.getLastColumn()).getValues();
    const records = values
      .map(row => rowToRecord(kind, row, headers))
      .filter(r => r[KEYS[kind]] && (kind !== 'ducks' || r.qr_code));
    for (let i = 0; i < records.length; i += 500) {
      upsert(kind, records.slice(i, i + 500));
    }
  });
  SpreadsheetApp.getActive().toast('Master Ducks and Player pushed to Supabase.', 'Duck Hunt');
}

function upsert(kind, records) {
  supabaseRequest('post', `/rest/v1/${TABLES[kind]}?on_conflict=${KEYS[kind]}`, records, {
    Prefer: 'resolution=merge-duplicates,return=minimal'
  });
}


/** Installable onChange trigger: catch deleted Duck Log rows. */
function handleChange(e) {
  if (e && e.changeType === 'REMOVE_ROW') syncErasedScans(false);
}

function syncErasedScansFromMenu() {
  syncErasedScans(true);
}

/**
 * Delete scans from Supabase whose Duck Log row was erased. Supabase then
 * un-claims the duck and takes the points back (see private.undo_claim).
 *
 * Only scans the sheet has already shown (Log ID <= LOG_MAX_ID) count as
 * erased, so newer scans that haven't reached the sheet yet are safe.
 */
function syncErasedScans(fromMenu) {
  const ss = SpreadsheetApp.getActive();
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  let deleted;
  try {
    const maxSeen = Number(PropertiesService.getDocumentProperties().getProperty('LOG_MAX_ID')) || 0;
    if (!maxSeen) return;

    const sheet = getSheet('log');
    const headers = readHeaders(sheet, 'log');
    const present = {};
    if (sheet.getLastRow() > 1) {
      sheet.getRange(2, headers.id + 1, sheet.getLastRow() - 1, 1).getValues()
        .forEach(r => { present[cellText(r[0])] = true; });
    }

    let known = [];
    for (let offset = 0; ; offset += 1000) {
      const page = supabaseRequest('get', `/rest/v1/duck_log?select=id&id=lte.${maxSeen}&order=id.asc&limit=1000&offset=${offset}`);
      known = known.concat(page);
      if (page.length < 1000) break;
    }
    const erased = known.map(r => r.id).filter(id => !present[String(id)]);
    if (!erased.length) {
      if (fromMenu) ss.toast('No erased scans to sync.', 'Duck Hunt');
      return;
    }

    if (erased.length > MAX_AUTO_DELETE) {
      if (!fromMenu) {
        ss.toast(`${erased.length} Duck Log rows were erased. To remove these scans from Supabase, use Duck Hunt → Sync erased Duck Log rows. Otherwise they come back on the next pull.`, 'Duck Hunt', 15);
        return;
      }
      const answer = SpreadsheetApp.getUi().alert('Duck Hunt',
        `Delete ${erased.length} scans from Supabase? Their ducks will be un-claimed and the points taken back.`,
        SpreadsheetApp.getUi().ButtonSet.YES_NO);
      if (answer !== SpreadsheetApp.getUi().Button.YES) return;
    }

    deleted = [];
    for (let i = 0; i < erased.length; i += 100) {
      deleted = deleted.concat(supabaseRequest('delete',
        `/rest/v1/duck_log?id=in.(${erased.slice(i, i + 100).join(',')})`,
        undefined, { Prefer: 'return=representation' }) || []);
    }

    // Show the un-claimed ducks and new point totals right away
    refreshRows('ducks', deleted.map(r => r.duck_id));
    refreshRows('players', deleted.map(r => r.student_id));
  } finally {
    lock.releaseLock();
  }

  const points = deleted.reduce((sum, r) => sum + (r.points || 0), 0);
  ss.toast(`Removed ${deleted.length} scan${deleted.length === 1 ? '' : 's'} (${points} pts taken back).`, 'Duck Hunt');
}

/** Re-read specific rows from Supabase and write them into the sheet. */
function refreshRows(kind, ids) {
  const unique = ids.filter((id, i) => id && ids.indexOf(id) === i);
  if (!unique.length) return;
  const list = unique.map(id => '"' + String(id).replace(/"/g, '\\"') + '"').join(',');
  const columns = Object.values(COLUMNS[kind]).join(',');
  supabaseRequest('get', `/rest/v1/${TABLES[kind]}?select=${columns}&${KEYS[kind]}=in.(${encodeURIComponent(list)})`)
    .forEach(record => upsertRecord(kind, record));
}


// ---------------------------------------------------------------------
// Supabase → Sheet
// ---------------------------------------------------------------------

/**
 * Web app health check. Open the /exec URL in a private browser window:
 * you should see this text, not a Google sign-in page.
 */
function doGet() {
  return textResponse('Duck Hunt sync is running.');
}

/** Web app endpoint: Supabase POSTs every change here (see private.notify_sheet). */
function doPost(e) {
  let payload;
  try {
    payload = JSON.parse(e.postData.contents);
  } catch (err) {
    console.warn('Live update rejected: body is not JSON');
    return textResponse('bad request');
  }
  if (!payload || payload.secret !== getProp('WEBHOOK_SECRET')) {
    console.warn('Live update rejected: secret does not match WEBHOOK_SECRET');
    return textResponse('forbidden');
  }

  const kind = Object.keys(TABLES).find(k => TABLES[k] === payload.table);
  if (!kind || !payload.record) return textResponse('ignored');

  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    if (kind === 'log' && payload.op === 'INSERT') {
      appendRecord(kind, payload.record);
    } else if (payload.op === 'DELETE') {
      deleteRecord(kind, payload.record);
    } else {
      upsertRecord(kind, payload.record);
    }
    console.log(`Live update applied: ${payload.table} ${payload.op}`);
  } catch (err) {
    console.error(`Live update failed: ${payload.table} ${payload.op}: ${err.message || err}`);
    throw err;
  } finally {
    lock.releaseLock();
  }
  return textResponse('ok');
}

/** Rewrite every tab from Supabase. Runs every 10 minutes and from the menu. */
function pullAllFromSupabase() {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    Object.keys(TABLES).forEach(kind => {
      const records = fetchAll(kind);
      const sheet = getSheet(kind);
      const headers = readHeaders(sheet, kind);
      const width = sheet.getLastColumn();
      const key = KEYS[kind];

      // Keep any extra (unmapped) columns by carrying them over per key
      const existing = {};
      if (key && sheet.getLastRow() > 1) {
        sheet.getRange(2, 1, sheet.getLastRow() - 1, width).getValues().forEach(row => {
          const id = cellText(row[headers[key]]);
          if (id) existing[id] = row;
        });
      }

      const rows = records.map(record => {
        const base = (key && existing[String(record[key])]) || new Array(width).fill('');
        return recordToRow(kind, record, headers, base.slice());
      });

      if (sheet.getLastRow() > 1) {
        sheet.getRange(2, 1, sheet.getLastRow() - 1, width).clearContent();
      }
      if (rows.length) {
        sheet.getRange(2, 1, rows.length, width).setValues(rows);
      }
      if (kind === 'log') {
        setMaxLogId(records.reduce((max, r) => Math.max(max, Number(r.id) || 0), 0), true);
      }
    });
  } finally {
    lock.releaseLock();
  }
}

function fetchAll(kind) {
  const columns = Object.values(COLUMNS[kind]).join(',');
  const pageSize = 1000;
  let all = [];
  for (let offset = 0; ; offset += pageSize) {
    const page = supabaseRequest('get',
      `/rest/v1/${TABLES[kind]}?select=${columns}&order=${ORDER[kind]}&limit=${pageSize}&offset=${offset}`);
    all = all.concat(page);
    if (page.length < pageSize) return all;
  }
}

function upsertRecord(kind, record) {
  const sheet = getSheet(kind);
  const headers = readHeaders(sheet, kind);
  const rowIndex = findRow(sheet, headers[KEYS[kind]], record[KEYS[kind]]);
  const width = sheet.getLastColumn();
  if (rowIndex) {
    const range = sheet.getRange(rowIndex, 1, 1, width);
    range.setValues([recordToRow(kind, record, headers, range.getValues()[0])]);
  } else {
    sheet.appendRow(recordToRow(kind, record, headers, new Array(width).fill('')));
  }
}

function appendRecord(kind, record) {
  const sheet = getSheet(kind);
  const headers = readHeaders(sheet, kind);
  if (findRow(sheet, headers.id, record.id)) return;
  sheet.appendRow(recordToRow(kind, record, headers, new Array(sheet.getLastColumn()).fill('')));
  setMaxLogId(Number(record.id) || 0, false);
}

/** Highest Log ID the sheet has shown; scans above it are never treated as erased. */
function setMaxLogId(id, replace) {
  const props = PropertiesService.getDocumentProperties();
  const current = Number(props.getProperty('LOG_MAX_ID')) || 0;
  props.setProperty('LOG_MAX_ID', String(replace ? id : Math.max(current, id)));
}

function deleteRecord(kind, record) {
  const sheet = getSheet(kind);
  const headers = readHeaders(sheet, kind);
  const rowIndex = findRow(sheet, headers[KEYS[kind]], record[KEYS[kind]]);
  if (rowIndex) sheet.deleteRow(rowIndex);
}


// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

function supabaseRequest(method, path, payload, extraHeaders) {
  const key = getProp('SUPABASE_SECRET_KEY');
  const headers = Object.assign({ apikey: key }, extraHeaders || {});
  // Legacy service_role keys are JWTs and also go in Authorization;
  // new sb_secret_ keys must only be sent as apikey
  if (key.indexOf('sb_') !== 0) headers.Authorization = 'Bearer ' + key;

  const options = { method: method, headers: headers, muteHttpExceptions: true };
  if (payload !== undefined) {
    options.contentType = 'application/json';
    options.payload = JSON.stringify(payload);
  }
  const res = UrlFetchApp.fetch(getProp('SUPABASE_URL').replace(/\/+$/, '') + path, options);
  const code = res.getResponseCode();
  if (code >= 300) {
    throw new Error(`Supabase ${method.toUpperCase()} ${path.split('?')[0]} failed (${code}): ${res.getContentText()}`);
  }
  const text = res.getContentText();
  return text ? JSON.parse(text) : null;
}

function getProp(name) {
  const value = PropertiesService.getScriptProperties().getProperty(name);
  if (!value) throw new Error(`Missing script property ${name}`);
  return value;
}

function getSheet(kind) {
  const sheet = SpreadsheetApp.getActive().getSheetByName(SHEET_NAMES[kind]);
  if (!sheet) throw new Error(`Sheet "${SHEET_NAMES[kind]}" not found`);
  return sheet;
}

function kindForSheet(name) {
  return Object.keys(SHEET_NAMES).find(k => SHEET_NAMES[k] === name) || null;
}

/** Returns { supabaseColumn: zeroBasedColumnIndex } from the header row. */
function readHeaders(sheet, kind) {
  const row = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  const lookup = {};
  Object.keys(COLUMNS[kind]).forEach(h => { lookup[h.toLowerCase()] = COLUMNS[kind][h]; });
  const headers = {};
  row.forEach((h, i) => {
    const field = lookup[String(h).trim().toLowerCase()];
    if (field && headers[field] === undefined) headers[field] = i;
  });
  const missing = Object.keys(COLUMNS[kind]).filter(h => headers[COLUMNS[kind][h]] === undefined);
  if (missing.length === 1 && missing[0] === 'Log ID') {
    // Added by this script; create it instead of making the user do it
    sheet.getRange(1, row.length + 1).setValue('Log ID');
    return readHeaders(sheet, kind);
  }
  if (missing.length) throw new Error(`"${sheet.getName()}" is missing columns: ${missing.join(', ')}`);
  return headers;
}

function rowToRecord(kind, row, headers) {
  const record = {};
  Object.keys(headers).forEach(field => {
    const value = row[headers[field]];
    if (NUMBER_FIELDS.indexOf(field) !== -1) {
      record[field] = Number(value) || 0;
    } else if (BOOLEAN_FIELDS.indexOf(field) !== -1) {
      record[field] = value === true || /^(true|yes|y|1|x)$/i.test(String(value).trim());
    } else if (DATE_FIELDS.indexOf(field) !== -1) {
      record[field] = value instanceof Date ? value.toISOString() : (value || null);
    } else {
      const text = cellText(value);
      record[field] = text || (NOT_NULL_TEXT_FIELDS.indexOf(field) !== -1 ? '' : null);
    }
  });
  return record;
}

function recordToRow(kind, record, headers, row) {
  Object.keys(headers).forEach(field => {
    if (!(field in record)) return;
    let value = record[field];
    if (DATE_FIELDS.indexOf(field) !== -1 && value) value = new Date(value);
    // Keep IDs like "0123" as text so Sheets doesn't drop the leading zero
    if (typeof value === 'string' && /^0\d+$/.test(value)) value = "'" + value;
    row[headers[field]] = value === null || value === undefined ? '' : value;
  });
  return row;
}

function findRow(sheet, columnIndex, key) {
  if (sheet.getLastRow() < 2) return null;
  const target = String(key).trim();
  const values = sheet.getRange(2, columnIndex + 1, sheet.getLastRow() - 1, 1).getValues();
  for (let i = 0; i < values.length; i++) {
    if (cellText(values[i][0]) === target) return i + 2;
  }
  return null;
}

function cellText(value) {
  return value === null || value === undefined ? '' : String(value).trim();
}

function textResponse(text) {
  return ContentService.createTextOutput(text).setMimeType(ContentService.MimeType.TEXT);
}
