-- לוח סלוטי מיקוד: טבלאות ופונקציות.
-- הדפדפן לא ניגש לטבלאות ישירות. כל קריאה עוברת דרך פונקציה שבודקת את קוד הכניסה.
-- הרצה: Supabase → SQL Editor → להדביק את כל הקובץ → Run. אפשר להריץ שוב בלי נזק.

create table if not exists public.fs_settings (
  id int primary key default 1 check (id = 1),
  team_code text not null,
  admin_code text not null,
  config jsonb not null default '{}'::jsonb
);

create table if not exists public.fs_slots (
  id text primary key,
  date date not null,
  time text not null check (time ~ '^\d{2}:\d{2}$'),
  consultant_id text not null,
  consultant_name text not null default '',
  location text not null default '',
  status text not null default 'open' check (status in ('open', 'booked')),
  client_name text not null default '',
  client_phone text not null default '',
  client_notes text not null default '',
  booked_by text,
  booked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists fs_slots_date_idx on public.fs_slots (date);

alter table public.fs_settings enable row level security;
alter table public.fs_slots enable row level security;
revoke all on public.fs_settings, public.fs_slots from anon, authenticated;

-- ---------- access ----------
create or replace function public.fs_role(p_code text) returns text
language sql stable security definer set search_path = public as $$
  select case when p_code = admin_code then 'admin' when p_code = team_code then 'team' end
  from fs_settings where id = 1
$$;

create or replace function public.fs_require(p_code text, p_admin boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare r text := fs_role(p_code);
begin
  if r is null or (p_admin and r <> 'admin') then
    perform pg_sleep(1);
    raise exception 'bad_code' using errcode = '28000';
  end if;
  return r;
end $$;

create or replace function public.fs_login(p_code text) returns json
language plpgsql security definer set search_path = public as $$
begin
  return json_build_object('role', fs_require(p_code));
end $$;

-- ---------- reads ----------
create or replace function public.fs_load(p_code text, p_from date, p_to date) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform fs_require(p_code);
  if p_to - p_from > 62 then raise exception 'range_too_long'; end if;
  return json_build_object(
    'config', (select config from fs_settings where id = 1),
    'slots', coalesce((
      select json_agg(json_build_object(
        'id', id, 'date', to_char(date, 'YYYY-MM-DD'), 'time', time,
        'consultantId', consultant_id, 'consultantName', consultant_name, 'location', location,
        'status', status,
        'client', json_build_object('name', client_name, 'phone', client_phone, 'notes', client_notes),
        'bookedBy', booked_by, 'bookedAt', booked_at))
      from fs_slots where date between p_from and p_to), '[]'::json));
end $$;

-- ---------- writes ----------
create or replace function public.fs_add_slots(p_code text, p_slots jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform fs_require(p_code);
  if jsonb_array_length(p_slots) > 300 then raise exception 'too_many'; end if;
  insert into fs_slots (id, date, time, consultant_id, consultant_name, location)
  select (s->>'date') || '_' || replace(s->>'time', ':', '') || '_' || (s->>'consultantId'),
         (s->>'date')::date, s->>'time', s->>'consultantId',
         left(coalesce(s->>'consultantName', ''), 80), left(coalesce(s->>'location', ''), 80)
  from jsonb_array_elements(p_slots) s
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.fs_remove_slots(p_code text, p_ids text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform fs_require(p_code);
  delete from fs_slots where id = any (p_ids) and status = 'open';
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.fs_book(p_code text, p_id text, p_by text, p_name text, p_phone text,
                                          p_notes text, p_location text, p_edit boolean) returns json
language plpgsql security definer set search_path = public as $$
declare v_by text;
begin
  perform fs_require(p_code);
  update fs_slots set
    status = 'booked',
    client_name = left(coalesce(p_name, ''), 120),
    client_phone = left(coalesce(p_phone, ''), 40),
    client_notes = left(coalesce(p_notes, ''), 1000),
    location = coalesce(left(p_location, 80), location),
    booked_by = case when status = 'booked' then booked_by else left(coalesce(p_by, ''), 80) end,
    booked_at = case when status = 'booked' then booked_at else now() end,
    updated_at = now()
  where id = p_id and (status = 'open' or p_edit);
  if found then return json_build_object('ok', true); end if;
  select booked_by into v_by from fs_slots where id = p_id;
  if not found then return json_build_object('ok', false, 'reason', 'gone'); end if;
  return json_build_object('ok', false, 'reason', 'taken', 'by', v_by);
end $$;

create or replace function public.fs_unbook(p_code text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fs_require(p_code);
  update fs_slots set status = 'open', client_name = '', client_phone = '', client_notes = '',
    booked_by = null, booked_at = null, updated_at = now()
  where id = p_id;
end $$;

create or replace function public.fs_save_config(p_code text, p_config jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fs_require(p_code, true);
  update fs_settings set config = p_config where id = 1;
end $$;

-- only the API functions are callable from the browser
revoke execute on function public.fs_role(text), public.fs_require(text, boolean) from public, anon, authenticated;
revoke execute on function public.fs_login(text), public.fs_load(text, date, date), public.fs_add_slots(text, jsonb),
  public.fs_remove_slots(text, text[]), public.fs_book(text, text, text, text, text, text, text, boolean),
  public.fs_unbook(text, text), public.fs_save_config(text, jsonb) from public;
grant execute on function public.fs_login(text), public.fs_load(text, date, date), public.fs_add_slots(text, jsonb),
  public.fs_remove_slots(text, text[]), public.fs_book(text, text, text, text, text, text, text, boolean),
  public.fs_unbook(text, text), public.fs_save_config(text, jsonb) to anon, authenticated;
