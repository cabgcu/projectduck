# Duck Hunt backend

Everything runs on Supabase. There's no Google Sheet anymore.

```
 index.html  (students)  ──┐
                           ├──  Supabase  (ducks, players, duck_log)
 admin.html  (admins)    ──┘
```

- **`index.html`** is the student app: register, sign in, scan ducks, leaderboard and history.
- **`admin.html`** is a plain admin page with three tables:
  - **Ducks:** the master list. Click a column header to sort.
    - Edit **Points** right in the table: type a number and press Enter.
    - **Add duck** for one duck, or **Bulk create** for many at once (for example 50 "Rubber" ducks worth 10 points, D-001 to D-050), each with its own random QR code.
    - Tick rows to **set points**, **print QR codes**, **download CSV** or **delete** them all at once.
    - **QR** shows a single duck's code and downloads it as a PNG. **Re-open** makes a claimed duck findable again and takes its points back.
  - **Rescuers:** edit Points in the table, edit names and email, delete a rescuer (their ducks re-open), and download CSV.
  - **Scans:** live as students scan. **Undo** removes a scan; the player loses the points and the duck can be found again. Download CSV gets every scan.
  - Changing a duck's points only affects future scans. Points already awarded stay the same.
- **`supabase.sql`** creates the whole database. It's safe to re-run, and also removes the old Google Sheet sync if it was installed.

## Game rules

- **New ducks start inactive.** Rescuers can't claim a duck until an admin activates it, usually by scanning it on the admin page's **Scanner** tab while hiding it. Ducks that existed before this feature stay active.
- **Location tags** are created on the Scanner tab. Switch the scanner to **Assign location**, pick a tag, and scan ducks to tag them. Deleting a tag clears it from its ducks.
- **Messages** sent from the admin page's Messages tab pop up full screen as a hologram on every player's app the moment they're sent, interrupting whatever the player is on. Each device shows a new message once; the antenna button on the home screen opens past messages any time.
- **The Hunt on / off switch** at the top of the admin page pauses the whole game. Turning it off asks for a title and text, and every player's app cuts to the galaxy for a Star Wars-style opening crawl ("A long time ago in a galaxy far, far away…", the Duck Hunt title, then your text scrolling into space). It plays once per shutdown, live or the next time they open the app. While it's off nobody can claim ducks; points and ducks are kept.
- **Golden duck alerts:** when someone rescues a Golden duck (or any duck worth 1000+ points), every other player gets a gold "Golden duck found! … was rescued by …" banner instantly.
- **Special ducks** get their own animation when claimed, matched on the Duck ID or type: **Vader** (black screen, red lightsaber), **Luke / Duckwalker** (green lightsaber), **Leia** (hologram message), **Solo / Han** (jump to lightspeed) and **Duckbacca / Chewie** (Wookiee roar).
- **Hologram codes** (type Virtual, Hologram or Holo) are capped at 10 per rescuer per day, resetting at midnight Arizona time. Hitting the cap freezes the rescuer's screen with a message. Regular (Rebel) ducks have no cap. The limit is `private.hologram_daily_limit()` in `supabase.sql`. The Rescuers tab shows each rescuer's hologram scans today and who's frozen; **Unfreeze** gives them a fresh set for the rest of the day.
- **Broken code reports** are resolved automatically. A rescuer reports a code that won't scan (Info page, or the link under the scanner) and gets the duck they name by ID or code, or else the standard points for that kind of duck (the most common value among regular ducks of that kind), without using up any other duck. Golden ducks are only awarded by exact ID, and hologram codes still count toward the daily hologram limit. Each rescuer can have **5 Rebel duck** and **10 hologram code** reports honored automatically (players aren't told these caps). After that, reports show as **Under review** and wait in the admin Reports tab for you to **Approve** (they get the duck they named if it's still available, otherwise the standard points) or **Deny**. Ducks named in honored reports are flagged on the admin page for reprinting. The admin **Reports** tab lists every report, and **Undo** takes the points back.
- **Each duck can be claimed once**, by the first rescuer to scan it.
- **QR codes are links** (`https://<your-site>/?duck=<code>`). Scanning one with the phone's normal camera opens the site and claims the duck; if the rescuer isn't signed in yet, it's claimed right after they sign in or register. The in-app scanner reads these links and older plain-code labels.
- **The leaderboard ranks by points.** Players with equal points share a place.
- **Undoing a scan, or re-opening a duck,** takes the points back and lets anyone claim the duck again.
- **Deleting a duck** retires it: its QR code stops working, but rescuers keep the points they already earned from it.
- **Deleting a rescuer** removes their scans and re-opens the ducks they found.

## Setup

### 1. Create or update the database

In the Supabase dashboard, open **SQL Editor**, paste all of [`supabase.sql`](./supabase.sql) and click **Run**. Re-run it whenever this file changes.

### 2. Create your admin account

1. Go to **Authentication → Users → Add user → Create new user**. Enter your email and a strong password, and tick **Auto Confirm User**.
2. In the **SQL Editor**, make that account an admin (use your email):

   ```sql
   insert into private.admins (user_id)
   select id from auth.users where email = 'you@example.com'
   on conflict do nothing;
   ```

3. Recommended: go to **Authentication → Sign In / Providers** and turn off **Allow new users to sign up**. Admins are the only people who need Supabase accounts; students don't use Supabase Auth.

Repeat step 2 for each extra admin. To remove one:

```sql
delete from private.admins
where user_id = (select id from auth.users where email = 'them@example.com');
```

### 3. Open the admin page

Open `admin.html` from the same place you host `index.html` (for example `https://<your-site>/admin.html`) and sign in. The green **Live** dot at the top means real-time updates are connected. If they drop, the page still refreshes every 30 seconds.

### 4. Add ducks and print QR codes

1. **Ducks → Bulk create** (or **Add duck**). The new ducks stay selected afterwards.
2. **Print QR codes** prints a label for each duck, with its ID, type and points. Stick each label on its duck. **Download CSV** includes every duck's QR code text, if you'd rather make labels elsewhere.

## Security notes

- The page only contains the **publishable** key. Admin powers come from signing in with an account listed in `private.admins`; every admin action is checked in the database. Never put the secret key in a page.
- **Students sign in with their Student ID only**, with no password, so anyone who knows another student's ID can sign in as them. Before a real launch, add verification, for example an email code sent to their `@my.gcu.edu` address.
- **Keep QR codes random**, as generated by the admin page, so nobody can guess them.
- **Change your secret key.** It was pasted into a chat earlier, and nothing in this project needs it anymore. Create a new one in **Project Settings → API Keys** and delete the old one.
