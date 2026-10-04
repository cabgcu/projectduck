-- =====================================================================
-- Duck Hunt — Supabase schema
--
-- Run this whole file in Supabase Dashboard → SQL Editor. Safe to re-run,
-- including on a project set up with the old Google Sheet sync.
--
--   ducks     the hunt's ducks and their QR codes (managed on admin.html)
--   duck_locations  location tags admins assign ducks to
--   announcements   messages admins send to every player
--   game_settings   one row: whether the hunt is on
--   players   registered rescuers and their points
--   duck_log  every claimed scan
--
-- Students (anon key) never touch these tables directly: RLS is on and
-- they only call the security-definer functions below, so QR codes and
-- emails can't be read from the public API.
-- Admins (signed in with Supabase Auth and listed in private.admins) use
-- the admin_* functions, and can read the tables for live updates.
-- =====================================================================

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
    duck_id    text,
    student_id text not null references public.players (student_id) on delete cascade,
    scanned_at timestamptz not null default now(),
    duck_type  text,
    points     integer not null default 0
);

-- Ducks only count once an admin activates them (by scanning them on the
-- admin page). Ducks that existed before this column are left active.
alter table public.ducks add column if not exists active boolean not null default true;
alter table public.ducks alter column active set default false;

create table if not exists public.duck_locations (
    name       text primary key,
    created_at timestamptz not null default now()
);

create table if not exists public.announcements (
    id         bigint generated always as identity primary key,
    title      text not null default '',
    message    text not null,
    created_at timestamptz not null default now()
);

-- A single row. While hunt_open is false nobody can claim ducks.
create table if not exists public.game_settings (
    id         boolean primary key default true check (id),
    hunt_open  boolean not null default true,
    updated_at timestamptz not null default now()
);
insert into public.game_settings (id) values (true) on conflict (id) do nothing;

-- Deleting a duck keeps the scans (and the points they earned); renaming
-- a duck's ID carries its scans along
alter table public.duck_log alter column duck_id drop not null;
alter table public.duck_log drop constraint if exists duck_log_duck_id_fkey;
alter table public.duck_log add constraint duck_log_duck_id_fkey
    foreign key (duck_id) references public.ducks (duck_id) on delete set null on update cascade;

create index if not exists duck_log_student_idx on public.duck_log (student_id, scanned_at desc);
create index if not exists players_points_idx on public.players (points desc);

alter table public.players  enable row level security;
alter table public.ducks    enable row level security;
alter table public.duck_log enable row level security;
alter table public.duck_locations enable row level security;
alter table public.announcements enable row level security;
alter table public.game_settings enable row level security;

revoke all on public.players, public.ducks, public.duck_log, public.duck_locations, public.announcements, public.game_settings from anon, authenticated;
grant all on public.players, public.ducks, public.duck_log, public.duck_locations, public.announcements, public.game_settings to service_role;
grant usage, select on all sequences in schema public to service_role;

-- Remove the old Google Sheet sync, if it was installed
drop function if exists private.notify_sheet() cascade;
drop table if exists private.sheet_sync;


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
    -- Setting claimed = false re-opens the duck
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


-- Deleting a scan undoes it: the duck is un-claimed and the player loses
-- its points.
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


-- Virtual / hologram codes: duck type "Virtual", "Hologram" or "Holo",
-- optionally followed by "duck" or "code". They aren't hidden anywhere
-- physical, so they're left off Rebel Coordinates and capped per day.
create or replace function private.is_hologram(p_duck_type text)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select lower(trim(coalesce(p_duck_type, ''))) ~ '^(virtual|hologram|holo)( (duck|code))?$';
$$;

-- Hologram codes each rescuer can claim per day. The day resets at
-- midnight Arizona time (GCU).
create or replace function private.hologram_daily_limit()
returns integer language sql immutable set search_path = '' as $$ select 10 $$;

create or replace function private.today_start()
returns timestamptz
language sql
stable
set search_path = ''
as $$
    select date_trunc('day', now() at time zone 'America/Phoenix') at time zone 'America/Phoenix';
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
-- status: claimed | already_yours | already_claimed | inactive | invalid | unknown_player | closed
--         | hologram_limit (10 hologram codes a day; regular ducks have no cap)
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
    -- The hunt is switched off on the admin page
    if not coalesce((select g.hunt_open from public.game_settings g where g.id), true) then
        return jsonb_build_object('status', 'closed');
    end if;

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

    -- Not placed yet: an admin hasn't scanned it to activate it
    if not v_duck.active then
        return jsonb_build_object('status', 'inactive', 'duck_id', v_duck.duck_id, 'duck_type', v_duck.duck_type);
    end if;

    -- Daily cap on hologram codes (the player row is locked above, so two
    -- scans at once can't both slip under the limit)
    if private.is_hologram(v_duck.duck_type) and (
        select count(*) from public.duck_log l
        where l.student_id = v_player.student_id
          and l.scanned_at >= private.today_start()
          and private.is_hologram(l.duck_type)
    ) >= private.hologram_daily_limit() then
        return jsonb_build_object(
            'status', 'hologram_limit',
            'limit', private.hologram_daily_limit(),
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

-- Rebel Coordinates: how many active, unclaimed ducks are at each location.
-- Ducks without a location are grouped as null. Hologram codes are left out.
create or replace function public.get_rebel_coordinates()
returns table (location text, ducks bigint)
language sql
stable
security definer
set search_path = ''
as $$
    select d.location, count(*)
    from public.ducks d
    where d.active and not d.claimed
      and not private.is_hologram(d.duck_type)
    group by d.location
    order by d.location is null, count(*) desc, lower(d.location);
$$;

-- Whether the hunt is on.
create or replace function public.get_game_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object('hunt_open', coalesce((select g.hunt_open from public.game_settings g where g.id), true));
$$;

-- Messages from the admins, newest first.
create or replace function public.get_announcements(p_limit integer default 20)
returns table (id bigint, title text, message text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
    select a.id, a.title, a.message, a.created_at
    from public.announcements a
    order by a.id desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100);
$$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
    public.register_player(text, text, text, text),
    public.get_player(text),
    public.claim_duck(text, text),
    public.get_rescuer_rank(text),
    public.get_leaderboard(text, integer),
    public.get_scan_history(text),
    public.get_rebel_coordinates(),
    public.get_announcements(integer),
    public.get_game_status()
to anon, authenticated;




-- ---------------------------------------------------------------------
-- Admins
--
-- 1. Supabase Dashboard → Authentication → Users → Add user (email +
--    password, tick "Auto Confirm User").
-- 2. Make that account an admin:
--      insert into private.admins (user_id)
--      select id from auth.users where email = 'you@example.com'
--      on conflict do nothing;
-- ---------------------------------------------------------------------

create table if not exists private.admins (
    user_id    uuid primary key references auth.users (id) on delete cascade,
    created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (select 1 from private.admins a where a.user_id = auth.uid());
$$;

create or replace function private.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if not public.is_admin() then
        raise exception 'Admins only' using errcode = '42501';
    end if;
end;
$$;

-- Admins can read the tables, which is what Supabase Realtime needs to
-- stream changes to admin.html. All writes go through admin_* functions.
grant select on public.players, public.ducks, public.duck_log, public.duck_locations, public.announcements to authenticated;

drop policy if exists admins_read on public.players;
create policy admins_read on public.players for select to authenticated using (public.is_admin());
drop policy if exists admins_read on public.ducks;
create policy admins_read on public.ducks for select to authenticated using (public.is_admin());
drop policy if exists admins_read on public.duck_log;
create policy admins_read on public.duck_log for select to authenticated using (public.is_admin());
drop policy if exists admins_read on public.duck_locations;
create policy admins_read on public.duck_locations for select to authenticated using (public.is_admin());
drop policy if exists admins_read on public.announcements;
create policy admins_read on public.announcements for select to authenticated using (public.is_admin());

-- Announcements are public: players may read them so Supabase Realtime can
-- push new ones to the app the moment they're sent.
grant select on public.announcements to anon;
drop policy if exists players_read on public.announcements;
create policy players_read on public.announcements for select to anon using (true);

-- Same for the on/off switch, so players see it flip instantly.
grant select on public.game_settings to anon, authenticated;
drop policy if exists everyone_read on public.game_settings;
create policy everyone_read on public.game_settings for select to anon, authenticated using (true);

do $$
declare
    t text;
begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        foreach t in array array['players', 'ducks', 'duck_log', 'duck_locations', 'announcements', 'game_settings'] loop
            if not exists (
                select 1 from pg_publication_tables
                where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
            ) then
                execute format('alter publication supabase_realtime add table public.%I', t);
            end if;
        end loop;
    end if;
end;
$$;

-- Everything the admin page shows, in one call.
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    return jsonb_build_object(
        'ducks', coalesce((
            select jsonb_agg(to_jsonb(d) order by d.duck_id)
            from (
                select d.*, concat_ws(' ', p.first_name, p.last_name) as claimed_by_name
                from public.ducks d
                left join public.players p on p.student_id = d.claimed_by
            ) d
        ), '[]'::jsonb),
        'players', coalesce((
            select jsonb_agg(to_jsonb(p) order by p.points desc, p.created_at)
            from (
                select p.*, rank() over (order by p.points desc) as place
                from public.players p
            ) p
        ), '[]'::jsonb),
        'scans', coalesce((
            select jsonb_agg(to_jsonb(l) order by l.scanned_at desc, l.id desc)
            from (
                select l.*, concat_ws(' ', p.first_name, p.last_name) as player_name
                from public.duck_log l
                left join public.players p on p.student_id = l.student_id
                order by l.scanned_at desc, l.id desc
                limit 200
            ) l
        ), '[]'::jsonb),
        'total_scans', (select count(*) from public.duck_log),
        'locations', coalesce((
            select jsonb_agg(to_jsonb(l) order by lower(l.name))
            from public.duck_locations l
        ), '[]'::jsonb),
        'hunt_open', coalesce((select g.hunt_open from public.game_settings g where g.id), true),
        'announcements', coalesce((
            select jsonb_agg(to_jsonb(a) order by a.id desc)
            from public.announcements a
        ), '[]'::jsonb)
    );
end;
$$;

-- Add a duck (p_original_id null) or update one, including renaming it.
create or replace function public.admin_save_duck(
    p_original_id text,
    p_duck_id     text,
    p_duck_type   text,
    p_points      integer,
    p_qr_code     text,
    p_location    text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    if coalesce(trim(p_duck_id), '') = '' or coalesce(trim(p_qr_code), '') = '' then
        raise exception 'Duck ID and QR code are required';
    end if;
    if coalesce(p_points, 0) < 0 then
        raise exception 'Points can''t be negative';
    end if;

    if p_original_id is null then
        insert into public.ducks (duck_id, duck_type, points, qr_code, location)
        values (trim(p_duck_id), nullif(trim(p_duck_type), ''), coalesce(p_points, 0), trim(p_qr_code), nullif(trim(p_location), ''));
    else
        update public.ducks
        set duck_id = trim(p_duck_id),
            duck_type = nullif(trim(p_duck_type), ''),
            points = coalesce(p_points, 0),
            qr_code = trim(p_qr_code),
            location = nullif(trim(p_location), '')
        where duck_id = p_original_id;
        if not found then
            raise exception 'Duck % no longer exists', p_original_id;
        end if;
    end if;
exception
    when unique_violation then
        raise exception 'That Duck ID or QR code is already used by another duck';
end;
$$;

-- Retire a duck. Its scans and the points they earned are kept.
create or replace function public.admin_delete_duck(p_duck_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    delete from public.ducks where duck_id = p_duck_id;
end;
$$;

-- Make a claimed duck findable again and take its points back.
create or replace function public.admin_reopen_duck(p_duck_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    -- Deleting the claim's scan runs private.undo_claim
    delete from public.duck_log l
    using public.ducks d
    where d.duck_id = p_duck_id and l.duck_id = d.duck_id and l.student_id = d.claimed_by;
    update public.ducks set claimed = false where duck_id = p_duck_id;
end;
$$;

-- Undo one scan: re-opens the duck and takes the points back.
create or replace function public.admin_undo_scan(p_scan_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    delete from public.duck_log where id = p_scan_id;
end;
$$;

create or replace function public.admin_save_player(
    p_student_id text,
    p_first_name text,
    p_last_name  text,
    p_email      text,
    p_points     integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    if coalesce(trim(p_first_name), '') = '' then
        raise exception 'First name is required';
    end if;
    update public.players
    set first_name = trim(p_first_name),
        last_name = coalesce(trim(p_last_name), ''),
        email = nullif(lower(trim(p_email)), ''),
        points = greatest(coalesce(p_points, 0), 0)
    where student_id = p_student_id;
    if not found then
        raise exception 'Rescuer % no longer exists', p_student_id;
    end if;
end;
$$;

-- Remove a rescuer. Their ducks become findable again.
create or replace function public.admin_delete_player(p_student_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    delete from public.duck_log where student_id = p_student_id;
    update public.ducks set claimed = false where claimed_by = p_student_id;
    delete from public.players where student_id = p_student_id;
end;
$$;

-- Create many ducks at once. p_ducks is a JSON array of
-- {duck_id, duck_type, points, qr_code, location}. All or nothing.
create or replace function public.admin_bulk_create_ducks(p_ducks jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    perform private.require_admin();
    if jsonb_typeof(p_ducks) <> 'array' or jsonb_array_length(p_ducks) = 0 then
        raise exception 'No ducks to create';
    end if;
    if jsonb_array_length(p_ducks) > 1000 then
        raise exception 'Create at most 1000 ducks at a time';
    end if;
    if exists (
        select 1 from jsonb_array_elements(p_ducks) d
        where coalesce(trim(d->>'duck_id'), '') = '' or coalesce(trim(d->>'qr_code'), '') = ''
           or coalesce((d->>'points')::integer, 0) < 0
    ) then
        raise exception 'Every duck needs a Duck ID, a QR code and non-negative points';
    end if;

    insert into public.ducks (duck_id, duck_type, points, qr_code, location)
    select trim(d->>'duck_id'),
           nullif(trim(d->>'duck_type'), ''),
           coalesce((d->>'points')::integer, 0),
           trim(d->>'qr_code'),
           nullif(trim(d->>'location'), '')
    from jsonb_array_elements(p_ducks) d;
    get diagnostics v_count = row_count;
    return v_count;
exception
    when unique_violation then
        raise exception 'Some of those Duck IDs or QR codes already exist';
end;
$$;

-- Set the points for several ducks. Points already awarded for past
-- scans don't change.
create or replace function public.admin_set_duck_points(p_duck_ids text[], p_points integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    perform private.require_admin();
    if coalesce(p_points, -1) < 0 then
        raise exception 'Points can''t be negative';
    end if;
    update public.ducks set points = p_points where duck_id = any (p_duck_ids);
    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- Retire several ducks. Their scans and the points they earned are kept.
create or replace function public.admin_delete_ducks(p_duck_ids text[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    perform private.require_admin();
    delete from public.ducks where duck_id = any (p_duck_ids);
    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- Activate or deactivate several ducks. Inactive ducks can't be claimed.
create or replace function public.admin_set_ducks_active(p_duck_ids text[], p_active boolean)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    perform private.require_admin();
    update public.ducks set active = coalesce(p_active, false) where duck_id = any (p_duck_ids);
    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- Put several ducks at a location (empty clears it).
create or replace function public.admin_set_ducks_location(p_duck_ids text[], p_location text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    perform private.require_admin();
    update public.ducks set location = nullif(trim(p_location), '') where duck_id = any (p_duck_ids);
    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- What the admin scanner does with one QR code.
--   p_mode 'activate': make the duck claimable
--   p_mode 'locate':   tag the duck with p_location
-- status: activated | already_active | located | already_there | unknown
create or replace function public.admin_scan_duck(p_qr_code text, p_mode text, p_location text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_duck   public.ducks;
    v_status text;
    v_before text;
begin
    perform private.require_admin();
    select * into v_duck from public.ducks where qr_code = trim(p_qr_code) for update;
    if not found then
        return jsonb_build_object('status', 'unknown');
    end if;
    v_before := v_duck.location;

    if p_mode = 'activate' then
        if v_duck.active then
            v_status := 'already_active';
        else
            update public.ducks set active = true where duck_id = v_duck.duck_id returning * into v_duck;
            v_status := 'activated';
        end if;
    elsif p_mode = 'locate' then
        if coalesce(trim(p_location), '') = '' then
            raise exception 'Pick a location first';
        end if;
        if v_duck.location is not distinct from trim(p_location) then
            v_status := 'already_there';
        else
            update public.ducks set location = trim(p_location) where duck_id = v_duck.duck_id returning * into v_duck;
            v_status := 'located';
        end if;
    else
        raise exception 'Unknown scan mode %', p_mode;
    end if;

    return jsonb_build_object(
        'status', v_status,
        'duck_id', v_duck.duck_id,
        'duck_type', v_duck.duck_type,
        'active', v_duck.active,
        'claimed', v_duck.claimed,
        'location', v_duck.location,
        'previous_location', v_before
    );
end;
$$;

-- Turn the hunt on or off for everyone.
create or replace function public.admin_set_hunt_open(p_open boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    insert into public.game_settings (id, hunt_open, updated_at)
    values (true, coalesce(p_open, false), now())
    on conflict (id) do update set hunt_open = excluded.hunt_open, updated_at = now();
    return coalesce(p_open, false);
end;
$$;

-- Send a message to every player. They see it as a pop-up next time the
-- app checks in (within 30 seconds while it's open).
create or replace function public.admin_post_announcement(p_title text, p_message text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_id bigint;
begin
    perform private.require_admin();
    if coalesce(trim(p_message), '') = '' then
        raise exception 'Write a message first';
    end if;
    insert into public.announcements (title, message)
    values (coalesce(trim(p_title), ''), trim(p_message))
    returning id into v_id;
    return v_id;
end;
$$;

create or replace function public.admin_delete_announcement(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    delete from public.announcements where id = p_id;
end;
$$;

-- Location tags.
create or replace function public.admin_add_location(p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    if coalesce(trim(p_name), '') = '' then
        raise exception 'Enter a location name';
    end if;
    insert into public.duck_locations (name) values (trim(p_name))
    on conflict (name) do nothing;
end;
$$;

-- Removing a tag also clears it from the ducks that had it.
create or replace function public.admin_delete_location(p_name text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    perform private.require_admin();
    update public.ducks set location = null where location = p_name;
    get diagnostics v_count = row_count;
    delete from public.duck_locations where name = p_name;
    return v_count;
end;
$$;

revoke execute on function
    public.admin_overview(),
    public.admin_save_duck(text, text, text, integer, text, text),
    public.admin_delete_duck(text),
    public.admin_reopen_duck(text),
    public.admin_undo_scan(bigint),
    public.admin_save_player(text, text, text, text, integer),
    public.admin_delete_player(text),
    public.admin_bulk_create_ducks(jsonb),
    public.admin_set_duck_points(text[], integer),
    public.admin_delete_ducks(text[]),
    public.admin_set_ducks_active(text[], boolean),
    public.admin_set_ducks_location(text[], text),
    public.admin_scan_duck(text, text, text),
    public.admin_add_location(text),
    public.admin_delete_location(text),
    public.admin_post_announcement(text, text),
    public.admin_delete_announcement(bigint),
    public.admin_set_hunt_open(boolean)
from public, anon;
grant execute on function
    public.is_admin(),
    public.admin_overview(),
    public.admin_save_duck(text, text, text, integer, text, text),
    public.admin_delete_duck(text),
    public.admin_reopen_duck(text),
    public.admin_undo_scan(bigint),
    public.admin_save_player(text, text, text, text, integer),
    public.admin_delete_player(text),
    public.admin_bulk_create_ducks(jsonb),
    public.admin_set_duck_points(text[], integer),
    public.admin_delete_ducks(text[]),
    public.admin_set_ducks_active(text[], boolean),
    public.admin_set_ducks_location(text[], text),
    public.admin_scan_duck(text, text, text),
    public.admin_add_location(text),
    public.admin_delete_location(text),
    public.admin_post_announcement(text, text),
    public.admin_delete_announcement(bigint),
    public.admin_set_hunt_open(boolean)
to authenticated;
