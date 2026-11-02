-- =====================================================================
-- Duck Hunt — bans for devices and Student IDs
--
-- Run this whole file in Supabase Dashboard → SQL Editor, after
-- supabase.sql. Safe to re-run. It only adds things, so it doesn't
-- touch claim_duck, get_player or the other game functions.
--
--   bans  every device and Student ID that's been blocked, active or not
--
-- How a ban happens:
--   * The app (index.html) catches someone opening dev tools, viewing the
--     source, or sending requests the app itself never sends. It calls
--     report_tamper(), which bans the device and, if they're signed in,
--     their Student ID.
--   * A banned Student ID signing in on another device bans that device
--     too, and a banned device signing in with a Student ID bans that ID.
--   * Admins can also ban by hand (admin_ban).
--
-- How a ban is enforced:
--   * Every request from the app carries x-device-id and x-student-id
--     headers. duckhunt_pre_request() runs before every API request and
--     refuses anything from a banned device or Student ID.
--   * Triggers on players, duck_log and code_reports refuse to register,
--     award ducks to, or take reports from a banned Student ID, whatever
--     the request looks like.
--
-- Admins see the log with admin_list_bans() and lift a ban with
-- admin_unban(). Unbanning keeps the row, marked lifted.
-- =====================================================================

create schema if not exists private;

create table if not exists public.bans (
    id          bigserial primary key,
    kind        text not null check (kind in ('device', 'student')),
    value       text not null,           -- the device ID or Student ID
    reason      text not null default '',
    details     text not null default '',
    student_id  text,                    -- who was signed in when it happened
    device_id   text,                    -- the device it happened on
    user_agent  text,
    active      boolean not null default true,
    created_at  timestamptz not null default now(),
    created_by  uuid,                    -- admin who banned by hand, if any
    unbanned_at timestamptz,
    unbanned_by uuid
);
create unique index if not exists bans_active_uniq on public.bans (kind, value) where active;
create index if not exists bans_created_idx on public.bans (created_at desc);

alter table public.bans enable row level security;
revoke all on public.bans from anon, authenticated;
grant all on public.bans to service_role;
grant usage, select on sequence public.bans_id_seq to service_role;

-- Admins can read it so Realtime can push new bans to the admin page
grant select on public.bans to authenticated;
drop policy if exists admins_read on public.bans;
create policy admins_read on public.bans for select to authenticated using (public.is_admin());

do $$
begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
       and not exists (
           select 1 from pg_publication_tables
           where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bans'
       ) then
        alter publication supabase_realtime add table public.bans;
    end if;
end;
$$;


-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- A request header from the app ('' if missing)
create or replace function private.request_header(p_name text)
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
    return coalesce(trim(nullif(current_setting('request.headers', true), '')::json ->> p_name), '');
exception when others then
    return '';
end;
$$;

create or replace function private.is_banned(p_kind text, p_value text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(p_value, '') <> '' and exists (
        select 1 from public.bans b
        where b.active and b.kind = p_kind and b.value = trim(p_value)
    );
$$;

-- Add an active ban unless one already exists. Returns true if new.
create or replace function private.add_ban(
    p_kind text, p_value text, p_reason text, p_details text,
    p_student_id text, p_device_id text, p_created_by uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_id bigint;
begin
    if coalesce(trim(p_value), '') = '' then
        return false;
    end if;
    insert into public.bans (kind, value, reason, details, student_id, device_id, user_agent, created_by)
    values (
        p_kind, left(trim(p_value), 100),
        left(coalesce(nullif(trim(p_reason), ''), 'Tampering detected'), 200),
        left(coalesce(p_details, ''), 1000),
        nullif(left(trim(coalesce(p_student_id, '')), 100), ''),
        nullif(left(trim(coalesce(p_device_id, '')), 100), ''),
        nullif(left(private.request_header('user-agent'), 300), ''),
        p_created_by
    )
    on conflict (kind, value) where active do nothing
    returning id into v_id;
    return v_id is not null;
end;
$$;


-- ---------------------------------------------------------------------
-- Enforcement
-- ---------------------------------------------------------------------

-- Runs before every API request (PostgREST pre-request hook). Requests
-- from a banned device or Student ID are refused. Only the app sends these
-- headers, so other sites on this Supabase project are unaffected, and
-- signed-in admins are never blocked.
create or replace function public.duckhunt_pre_request()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_path text := coalesce(current_setting('request.path', true), '');
begin
    if coalesce(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'role', 'anon') <> 'anon' then
        return;
    end if;
    -- The app needs these two to find out it's banned and to report
    if v_path like '%/rpc/check_ban' or v_path like '%/rpc/report_tamper' then
        return;
    end if;
    if private.is_banned('device', private.request_header('x-device-id'))
       or private.is_banned('student', private.request_header('x-student-id')) then
        raise exception 'DUCKHUNT_BANNED' using errcode = 'P0001',
            hint = 'This device or Student ID is banned from Duck Hunt.';
    end if;
exception
    when raise_exception then raise;
    when others then return;   -- never let a bug here take the whole API down
end;
$$;
grant execute on function public.duckhunt_pre_request() to anon, authenticated;

-- Turn the hook on, unless another hook is already installed
do $$
declare
    v_current text;
begin
    select substring(c from 'pgrst.db_pre_request=(.*)') into v_current
    from pg_roles r, unnest(r.rolconfig) c
    where r.rolname = 'authenticator' and c like 'pgrst.db_pre_request=%';

    if v_current is null or v_current = 'public.duckhunt_pre_request' then
        alter role authenticator set pgrst.db_pre_request = 'public.duckhunt_pre_request';
    else
        raise warning 'Another pre-request hook (%) is installed, so device bans aren''t enforced on every request. Call public.duckhunt_pre_request() from it.', v_current;
    end if;
end;
$$;
notify pgrst, 'reload config';

-- Banned Student IDs can't register, earn ducks or file reports, however
-- the request is made. Admin actions are let through.
create or replace function private.refuse_banned_student()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if public.is_admin() then
        return new;
    end if;
    if private.is_banned('student', new.student_id)
       or (tg_table_name = 'players' and private.is_banned('device', private.request_header('x-device-id'))) then
        raise exception 'DUCKHUNT_BANNED' using errcode = 'P0001';
    end if;
    return new;
end;
$$;

drop trigger if exists refuse_banned on public.players;
create trigger refuse_banned before insert on public.players
    for each row execute function private.refuse_banned_student();
drop trigger if exists refuse_banned on public.duck_log;
create trigger refuse_banned before insert on public.duck_log
    for each row execute function private.refuse_banned_student();
drop trigger if exists refuse_banned on public.code_reports;
create trigger refuse_banned before insert on public.code_reports
    for each row execute function private.refuse_banned_student();


-- ---------------------------------------------------------------------
-- API used by the app
-- ---------------------------------------------------------------------

-- The app caught tampering: ban the device, and the Student ID if they're
-- signed in (only real rescuers' IDs are banned).
create or replace function public.report_tamper(
    p_device_id  text,
    p_student_id text,
    p_reason     text,
    p_details    text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_device  text := nullif(trim(coalesce(p_device_id, '')), '');
    v_student text := nullif(trim(coalesce(p_student_id, '')), '');
begin
    if v_student is not null and not exists (select 1 from public.players p where p.student_id = v_student) then
        v_student := null;
    end if;

    perform private.add_ban('device', v_device, p_reason, p_details, v_student, v_device);
    perform private.add_ban('student', v_student, p_reason, p_details, v_student, v_device);

    return jsonb_build_object('banned', v_device is not null or v_student is not null);
end;
$$;

-- Is this device or Student ID banned? Bans spread between the two: a
-- banned rescuer's new device is banned, and a banned device's rescuer is.
create or replace function public.check_ban(p_device_id text, p_student_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_device  text := nullif(trim(coalesce(p_device_id, '')), '');
    v_student text := nullif(trim(coalesce(p_student_id, '')), '');
    v_device_banned  boolean;
    v_student_banned boolean;
begin
    if v_student is not null and not exists (select 1 from public.players p where p.student_id = v_student) then
        v_student := null;
    end if;

    v_device_banned := private.is_banned('device', v_device);
    v_student_banned := private.is_banned('student', v_student);

    if v_student_banned and not v_device_banned and v_device is not null then
        perform private.add_ban('device', v_device, 'Banned rescuer signed in on this device', '', v_student, v_device);
        v_device_banned := true;
    elsif v_device_banned and not v_student_banned and v_student is not null then
        perform private.add_ban('student', v_student, 'Signed in on a banned device', '', v_student, v_device);
        v_student_banned := true;
    end if;

    return jsonb_build_object(
        'banned', v_device_banned or v_student_banned,
        'device', v_device_banned,
        'student', v_student_banned
    );
end;
$$;

grant execute on function public.report_tamper(text, text, text, text), public.check_ban(text, text) to anon, authenticated;


-- ---------------------------------------------------------------------
-- Admin API
-- ---------------------------------------------------------------------

-- The ban log, newest first, with the rescuer's name
create or replace function public.admin_list_bans()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    return coalesce((
        select jsonb_agg(to_jsonb(b) order by b.active desc, b.created_at desc, b.id desc)
        from (
            select b.*,
                   concat_ws(' ', p.first_name, p.last_name) as player_name,
                   p.email as player_email
            from public.bans b
            left join public.players p on p.student_id = coalesce(b.student_id, case when b.kind = 'student' then b.value end)
        ) b
    ), '[]'::jsonb);
end;
$$;

-- Lift a ban. The row stays in the log, marked lifted.
create or replace function public.admin_unban(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    update public.bans
    set active = false, unbanned_at = now(), unbanned_by = auth.uid()
    where id = p_id and active;
    if not found then
        raise exception 'That ban was already lifted.';
    end if;
end;
$$;

-- Ban a Student ID or device by hand
create or replace function public.admin_ban(p_kind text, p_value text, p_reason text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_admin();
    if p_kind not in ('device', 'student') or coalesce(trim(p_value), '') = '' then
        raise exception 'Enter a Student ID or device code.';
    end if;
    if not private.add_ban(
        p_kind, p_value, coalesce(nullif(trim(p_reason), ''), 'Banned by an admin'), '',
        case when p_kind = 'student' then p_value end,
        case when p_kind = 'device' then p_value end,
        auth.uid()
    ) then
        raise exception 'That % is already banned.', case when p_kind = 'student' then 'Student ID' else 'device' end;
    end if;
end;
$$;

revoke execute on function public.admin_list_bans(), public.admin_unban(bigint), public.admin_ban(text, text, text) from public, anon;
grant execute on function public.admin_list_bans(), public.admin_unban(bigint), public.admin_ban(text, text, text) to authenticated;
