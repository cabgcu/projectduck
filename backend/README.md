# Duck Hunt backend: Google Sheet ⇄ Supabase ⇄ App

```
 Google Sheet  ⇄  Apps Script  ⇄  Supabase  ⇄  App (index.html)
 (master list)    (sync)          (database)    (players scan here)
```

- **Supabase** is the live database. The app talks only to Supabase.
- **The Google Sheet** is your master view. Scans and points show up there within seconds. Edits you make to **Master Ducks** or **Player** are pushed to Supabase.
- **Duck Log** is written by the app. Treat it as read-only, because edits there are overwritten.
- As a safety net, the sheet is fully refreshed from Supabase every 10 minutes.

| Sheet tab      | Supabase table | Direction | Columns |
|----------------|----------------|-----------|---------|
| `Master Ducks` | `ducks`        | ⇄ both    | Duck ID, Duck Type, Points, QR Code, Location, Claimed |
| `Duck Log`     | `duck_log`     | → sheet   | Duck ID, Student ID, Timestamp, Type |
| `Player`       | `players`      | ⇄ both    | First Name, Last Name, Student ID, Email, Points, Codes Scanned |

Headers are matched by name, so column order doesn't matter, and extra columns (like a Notes column) are left alone. If your tabs are named differently, change `SHEET_NAMES` at the top of `google-apps-script.gs`.

## Game rules (as built)

- **Each duck can be claimed once**: the first rescuer to scan it gets its points, and the duck is marked **Claimed**. Anyone who scans it later sees "already claimed".
- **Unchecking Claimed** in the sheet re-opens the duck so it can be found again. Points already awarded are **not** taken back. To take them back, edit that player's Points in the Player tab.
- **The leaderboard ranks by Points.** Players with the same points share a place.

To let *every* rescuer claim *every* duck once instead, change the `if v_duck.claimed` check in `claim_duck` in `supabase.sql`.

---

## Setup

### 1. Supabase: create the database

1. Create a project at [supabase.com](https://supabase.com).
2. Open **SQL Editor**, paste all of [`supabase.sql`](./supabase.sql), and click **Run**.
3. Open **Project Settings → API Keys** and note three values:
   - **Project URL**: `https://<ref>.supabase.co`
   - **Publishable key** (`sb_publishable_…`, or the legacy `anon` key). This goes in the app.
   - **Secret key** (`sb_secret_…`, or the legacy `service_role` key). This goes in Apps Script **only**.

### 2. App: connect to Supabase

In `index.html`, set:

```js
const SUPABASE_URL = 'https://<ref>.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_…';
```

The publishable key is safe to put in the page. **Never put the secret key in `index.html`.**

### 3. Google Sheet: add the sync script

1. In the spreadsheet, open **Extensions → Apps Script**.
2. Replace `Code.gs` with the contents of [`google-apps-script.gs`](./google-apps-script.gs) and save.
3. Open **Project Settings (⚙) → Script properties** and add:

   | Property              | Value |
   |-----------------------|-------|
   | `SUPABASE_URL`        | your Project URL |
   | `SUPABASE_SECRET_KEY` | your Secret key |
   | `WEBHOOK_SECRET`      | a long random string you make up (e.g. 40 random letters/numbers) |

4. Back in the editor, pick **`setupTriggers`** in the function dropdown and click **Run**. Approve the permissions prompt. This installs the on-edit push and the 10-minute refresh.
5. Click **Deploy → New deployment → Select type: Web app**, then:
   - **Execute as:** Me
   - **Who has access:** Anyone

   Click **Deploy** and copy the **Web app URL** (ends in `/exec`).

### 4. Supabase: send live updates to the sheet

In the Supabase **SQL Editor**, run this with your values filled in:

```sql
insert into private.sheet_sync (webhook_url, secret)
values ('https://script.google.com/macros/s/XXXX/exec', 'the same WEBHOOK_SECRET')
on conflict (id) do update set webhook_url = excluded.webhook_url, secret = excluded.secret;
```

### 5. Load your existing data

Reload the spreadsheet so the **Duck Hunt** menu appears, then:

1. **Duck Hunt → Push Master Ducks & Players to Supabase**. This copies your current ducks and players up. Rows without a Duck ID or QR Code are skipped.
2. **Duck Hunt → Pull everything from Supabase**. This rewrites the tabs from Supabase so everything matches.

Existing rows in **Duck Log** are not pushed. Supabase becomes the record of scans from this point on.

### 6. Test it

1. Register in the app. A row should appear in **Player** within a few seconds.
2. Scan a duck's QR code. **Duck Log** gets a row, the duck shows **Claimed**, and the player's **Points** and **Codes Scanned** go up.
3. Change a duck's **Points** in the sheet. The change shows in Supabase's Table Editor (`ducks`).

---

## Good to know

- **QR codes:** the **QR Code** column must contain exactly the text encoded in the printed QR code. Use long random codes (for example `DUCK-7f3k9q2x`), not guessable ones like `1`, `2`, `3`.
- **Deleting a duck:** delete it in Supabase (Table Editor → `ducks`) and the sheet row is removed automatically. Deleting a row in the sheet does **not** delete it in Supabase.
- **Updating the script:** after editing the Apps Script, use **Deploy → Manage deployments → Edit → Version: New version** so the web app URL keeps working with the new code.
- **Security:** sign-in is by Student ID only, with no password, so anyone who knows another student's ID could sign in as them. Before a real launch, add Supabase Auth (for example an email code sent to `@my.gcu.edu`).
- **Troubleshooting live updates:** see below.

## Live updates not showing up?

If the sheet only changes when you run **Pull everything**, Supabase's live updates aren't reaching the sheet. Run this in the Supabase **SQL Editor**:

```sql
select * from private.sheet_sync;

select created, status_code, error_msg, left(content::text, 120) as response
from net._http_response
order by created desc
limit 10;
```

| What you see | Cause | Fix |
|---|---|---|
| First query returns **no rows** | Supabase doesn't know where to send updates | Run setup step 4 |
| Second query returns **no rows**, even right after a scan | The triggers aren't installed | Re-run `supabase.sql` |
| `error_msg` mentions **timeout** | The script took longer than Supabase waited | Re-run `supabase.sql`; it now waits 30 seconds |
| **401 / 403**, or a response mentioning **Sign in** | The web app isn't public | Deploy → Manage deployments → Edit → **Who has access: Anyone** |
| **404** | Wrong or deleted web app URL | Copy the current `/exec` URL into step 4 again |
| **302** | Google received the update (this is normal) | Check **Apps Script → Executions** for `doPost` runs. The log says why an update was rejected, e.g. *secret does not match WEBHOOK_SECRET* |

**Quick check:** open the `/exec` URL in a private or incognito window. You should see *"Duck Hunt sync is running."* If you get a Google sign-in page instead, the web app isn't set to **Anyone**.

**After changing the script**, always use **Deploy → Manage deployments → Edit → Version: New version → Deploy**. Saving the code alone doesn't update the live web app.
