-- =====================================================================
-- Duck Hunt — Supabase schema
--
-- Run this whole file in Supabase Dashboard → SQL Editor. Safe to re-run.
--
-- Tables mirror the Google Sheet:
--   ducks     ⇄  "Master Ducks"  (Duck ID, Duck Type, Points, QR Code, Location, Claimed)
--   duck_log  ⇄  "Duck Log"      (Duck ID, Student ID, Timestamp, Type, Log ID)
--                                 deleting a Duck Log row undoes that scan
--   players   ⇄  "Player"        (First Name, Last Name, Student ID, Email, Points, Codes Scanned)
--
-- The browser never touches these tables directly (RLS is on with no
-- policies). It only calls the security-definer functions below, so the
-- QR codes and player emails can't be read from the public API.
-- The Apps Script uses the secret (service_role) key, which bypasses RLS.
-- =====================================================================

create extension if not exists pg_net;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table if not exists public.players (
    student_id    text primary key,
    first_name    text not null default '',
    last_name     text not null default '',
    email         text,
    points        integer not null default 0,
    codes_scanned integer not null default 0,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

create table if not exists public.ducks (
    duck_id    text primary key,
    duck_type  text,
    points     integer not null default 0,
    qr_code    text not null unique,
    location   text,
    claimed    boolean not null default false,
    claimed_by text references public.players (student_id) on delete set null,
    claimed_at timestamptz,
    updated_at timestamptz not null default now()
);

create table if not exists public.duck_log (
    id         bigint generated always as identity primary key,
    duck_id    text not null references public.ducks (duck_id) on delete cascade,
    student_id text not null references public.players (student_id) on delete cascade,
    scanned_at timestamptz not null default now(),
    duck_type  text,
    points     integer not null default 0
);

create index if not exists duck_log_student_idx on public.duck_log (student_id, scanned_at desc);
create index if not exists players_points_idx on public.players (points desc);

alter table public.players  enable row level security;
alter table public.ducks    enable row level security;
alter table public.duck_log enable row level security;

revoke all on public.players, public.ducks, public.duck_log from anon, authenticated;
grant all on public.players, public.ducks, public.duck_log to service_role;
grant usage, select on all sequences in schema public to service_role;


-- ---------------------------------------------------------------------
-- Housekeeping triggers
-- ---------------------------------------------------------------------

create or replace function private.touch_row()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create or replace function private.touch_duck()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    -- Unchecking "Claimed" in the sheet re-opens the duck
    if not new.claimed then
        new.claimed_by := null;
        new.claimed_at := null;
    end if;
    return new;
end;
$$;

drop trigger if exists players_touch on public.players;
create trigger players_touch before update on public.players
    for each row execute function private.touch_row();

drop trigger if exists ducks_touch on public.ducks;
create trigger ducks_touch before insert or update on public.ducks
    for each row execute function private.touch_duck();


-- Deleting a scan (from the Duck Log tab or the Table Editor) undoes
-- it: the duck is un-claimed and the player loses its points.
create or replace function private.undo_claim()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.ducks
    set claimed = false
    where duck_id = old.duck_id and claimed_by = old.student_id;

    update public.players
    set points = greatest(points - old.points, 0),
        codes_scanned = greatest(codes_scanned - 1, 0)
    where student_id = old.student_id;
    return old;
end;
$$;

drop trigger if exists duck_log_undo on public.duck_log;
create trigger duck_log_undo after delete on public.duck_log
    for each row execute function private.undo_claim();


-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

create or replace function private.display_name(p_first text, p_last text)
returns text
language sql
immutable
set search_path = ''
as $$
    select case
        when coalesce(trim(p_first), '') = '' then 'Rescuer'
        when coalesce(trim(p_last), '') = '' then trim(p_first)
        else trim(p_first) || ' ' || left(trim(p_last), 1) || '.'
    end;
$$;


-- ---------------------------------------------------------------------
-- API used by the app (callable with the publishable / anon key)
-- ---------------------------------------------------------------------

-- Create a rescuer. If the Student ID already exists, the existing
-- player is returned unchanged.
create or replace function public.register_player(
    p_student_id text,
    p_first_name text,
    p_last_name  text,
    p_email      text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_player public.players;
    v_status text := 'created';
begin
    if coalesce(trim(p_student_id), '') = '' or coalesce(trim(p_first_name), '') = '' then
        return jsonb_build_object('status', 'invalid');
    end if;

    insert into public.players (student_id, first_name, last_name, email)
    values (trim(p_student_id), trim(p_first_name), coalesce(trim(p_last_name), ''), nullif(lower(trim(p_email)), ''))
    on conflict (student_id) do nothing
    returning * into v_player;

    if v_player is null then
        v_status := 'exists';
        select * into v_player from public.players where student_id = trim(p_student_id);
    end if;

    return jsonb_build_object(
        'status', v_status,
        'student_id', v_player.student_id,
        'first_name', v_player.first_name,
        'last_name', v_player.last_name
    );
end;
$$;

-- Sign in: returns the player's public profile, or nothing if unknown.
create or replace function public.get_player(p_student_id text)
returns table (student_id text, first_name text, last_name text, points integer, codes_scanned integer)
language sql
stable
security definer
set search_path = ''
as $$
    select p.student_id, p.first_name, p.last_name, p.points, p.codes_scanned
    from public.players p
    where p.student_id = trim(p_student_id);
$$;

-- Claim a duck by its QR code. Each duck can be claimed once, by the
-- first rescuer to scan it.
--
-- status: claimed | already_yours | already_claimed | invalid | unknown_player
create or replace function public.claim_duck(p_student_id text, p_qr_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_player public.players;
    v_duck   public.ducks;
begin
    select * into v_player from public.players
    where student_id = trim(p_student_id)
    for update;
    if not found then
        return jsonb_build_object('status', 'unknown_player');
    end if;

    select * into v_duck from public.ducks
    where qr_code = trim(p_qr_code)
    for update;
    if not found then
        return jsonb_build_object('status', 'invalid');
    end if;

    if v_duck.claimed then
        return jsonb_build_object(
            'status', case when v_duck.claimed_by = v_player.student_id then 'already_yours' else 'already_claimed' end,
            'duck_id', v_duck.duck_id,
            'duck_type', v_duck.duck_type
        );
    end if;

    update public.ducks
    set claimed = true, claimed_by = v_player.student_id, claimed_at = now()
    where duck_id = v_duck.duck_id;

    insert into public.duck_log (duck_id, student_id, duck_type, points)
    values (v_duck.duck_id, v_player.student_id, v_duck.duck_type, v_duck.points);

    update public.players
    set points = points + v_duck.points, codes_scanned = codes_scanned + 1
    where student_id = v_player.student_id
    returning * into v_player;

    return jsonb_build_object(
        'status', 'claimed',
        'duck_id', v_duck.duck_id,
        'duck_type', v_duck.duck_type,
        'points', v_duck.points,
        'total_points', v_player.points
    );
end;
$$;

-- The player's place on the leaderboard (ties share a place) and the
-- rescuer they need to pass next.
create or replace function public.get_rescuer_rank(p_student_id text)
returns table (
    place          bigint,
    total_rescuers bigint,
    points         integer,
    codes_scanned  integer,
    next_name      text,
    next_points    integer
)
language sql
stable
security definer
set search_path = ''
as $$
    with ranked as (
        select p.student_id, p.first_name, p.last_name, p.points, p.codes_scanned, p.created_at,
               rank() over (order by p.points desc) as place,
               count(*) over () as total
        from public.players p
    ),
    me as (
        select * from ranked where student_id = trim(p_student_id)
    )
    select me.place, me.total, me.points, me.codes_scanned, nxt.name, nxt.points
    from me
    left join lateral (
        select private.display_name(r.first_name, r.last_name) as name, r.points
        from ranked r
        where r.points > me.points
        order by r.points asc, r.created_at asc
        limit 1
    ) nxt on true;
$$;

-- Top rescuers by points.
create or replace function public.get_leaderboard(p_student_id text, p_limit integer default 5)
returns table (place bigint, name text, points integer, codes_scanned integer, is_me boolean)
language sql
stable
security definer
set search_path = ''
as $$
    select rank() over (order by p.points desc),
           private.display_name(p.first_name, p.last_name),
           p.points,
           p.codes_scanned,
           p.student_id = trim(p_student_id)
    from public.players p
    order by p.points desc, p.created_at asc
    limit least(greatest(coalesce(p_limit, 5), 1), 50);
$$;

-- The player's own scans, newest first.
create or replace function public.get_scan_history(p_student_id text)
returns table (duck_id text, duck_type text, points integer, scanned_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
    select l.duck_id, l.duck_type, l.points, l.scanned_at
    from public.duck_log l
    where l.student_id = trim(p_student_id)
    order by l.scanned_at desc
    limit 100;
$$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
    public.register_player(text, text, text, text),
    public.get_player(text),
    public.claim_duck(text, text),
    public.get_rescuer_rank(text),
    public.get_leaderboard(text, integer),
    public.get_scan_history(text)
to anon, authenticated;


-- ---------------------------------------------------------------------
-- Live updates → Google Sheet
--
-- Every change to ducks / players and every new scan is POSTed to the
-- Apps Script web app. Fill in the config row once the web app is
-- deployed (see backend/README.md):
--
--   insert into private.sheet_sync (webhook_url, secret)
--   values ('https://script.google.com/macros/s/XXXX/exec', 'your-webhook-secret')
--   on conflict (id) do update set webhook_url = excluded.webhook_url, secret = excluded.secret;
-- ---------------------------------------------------------------------

create table if not exists private.sheet_sync (
    id          integer primary key default 1 check (id = 1),
    webhook_url text not null,
    secret      text not null
);

create or replace function private.notify_sheet()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_cfg private.sheet_sync;
begin
    select * into v_cfg from private.sheet_sync where id = 1;
    if v_cfg is null then
        return null;
    end if;

    -- Apps Script can't read request headers, so the secret rides in the body
    perform net.http_post(
        url     := v_cfg.webhook_url,
        body    := jsonb_build_object(
            'secret', v_cfg.secret,
            'table',  tg_table_name,
            'op',     tg_op,
            'record', case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end
        ),
        headers := '{"Content-Type": "application/json"}'::jsonb,
        -- pg_net gives up after 5s by default; a cold Apps Script often takes longer
        timeout_milliseconds := 30000
    );
    return null;
end;
$$;

drop trigger if exists ducks_to_sheet on public.ducks;
create trigger ducks_to_sheet after insert or update or delete on public.ducks
    for each row execute function private.notify_sheet();

drop trigger if exists players_to_sheet on public.players;
create trigger players_to_sheet after insert or update or delete on public.players
    for each row execute function private.notify_sheet();

drop trigger if exists duck_log_to_sheet on public.duck_log;
create trigger duck_log_to_sheet after insert or delete on public.duck_log
    for each row execute function private.notify_sheet();
