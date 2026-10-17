-- לוח סלוטי מיקוד: טבלאות ופונקציות. גרסה 2: קישור אישי לכל אחד.
-- הדפדפן לא ניגש לטבלאות ישירות. כל קריאה עוברת דרך פונקציה שבודקת את הקוד שבקישור.
-- שלושה סוגי כניסה:
--   מנהל הלוח  (קוד המנהל ב־fs_settings): רואה הכול, מנהל אנשים, קישורים, מיקומים ושעות.
--   צוות       (קישור אישי ב־fs_people, role = team): רואה את כל היועצות ומסמן סלוטים כנתפסו. השם שלו נרשם על כל שריון.
--   יועצת      (קישור אישי ב־fs_people, role = consultant): רואה ומעדכנת רק את הסלוטים שלה.
-- הרצה: Supabase → SQL Editor → להדביק את כל הקובץ → Run. אפשר להריץ שוב בלי נזק.

create table if not exists public.fs_settings (
  id int primary key default 1 check (id = 1),
  admin_code text not null,
  admin_name text not null default 'איציק',
  config jsonb not null default '{}'::jsonb
);

create table if not exists public.fs_people (
  id text primary key,
  role text not null check (role in ('consultant', 'team')),
  name text not null,
  color int not null default 0,
  sort int not null default 0,
  token text not null unique default encode(extensions.gen_random_bytes(12), 'hex'),
  active boolean not null default true,
  created_at timestamptz not null default now()
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
  booked_by_id text,
  booked_at timestamptz,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists fs_slots_date_idx on public.fs_slots (date);
create index if not exists fs_slots_consultant_idx on public.fs_slots (consultant_id, date);

alter table public.fs_settings enable row level security;
alter table public.fs_people enable row level security;
alter table public.fs_slots enable row level security;
revoke all on public.fs_settings, public.fs_people, public.fs_slots from anon, authenticated;

-- ---------- מי נכנס ----------
create or replace function public.fs_who(p_code text) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select json_build_object('role', 'admin', 'id', 'admin', 'name', admin_name) from fs_settings where id = 1 and p_code = admin_code),
    (select json_build_object('role', role, 'id', id, 'name', name) from fs_people where active and token = p_code))
$$;

create or replace function public.fs_require(p_code text, p_admin boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare v json := fs_who(p_code);
begin
  if v is null or (p_admin and v->>'role' <> 'admin') then
    perform pg_sleep(1);
    raise exception 'bad_code' using errcode = '28000';
  end if;
  return v;
end $$;

-- מזהה היועצת כשהנכנס הוא יועצת, אחרת null (רואה הכול)
create or replace function public.fs_mine(v json) returns text
language sql immutable as $$ select case when v->>'role' = 'consultant' then v->>'id' end $$;

create or replace function public.fs_login(p_code text) returns json
language plpgsql security definer set search_path = public as $$
begin
  return fs_require(p_code);
end $$;

-- ---------- קריאה ----------
create or replace function public.fs_load(p_code text, p_from date, p_to date) returns json
language plpgsql security definer set search_path = public as $$
declare me json := fs_require(p_code); mine text := fs_mine(me);
begin
  if p_to - p_from > 62 then raise exception 'range_too_long'; end if;
  return json_build_object(
    'me', me,
    'config', (select config - 'consultants' from fs_settings where id = 1),
    'consultants', coalesce((
      select json_agg(json_build_object('id', id, 'name', name, 'color', color) order by sort, created_at)
      from fs_people where role = 'consultant' and active and (mine is null or id = mine)), '[]'::json),
    'slots', coalesce((
      select json_agg(json_build_object(
        'id', id, 'date', to_char(date, 'YYYY-MM-DD'), 'time', time,
        'consultantId', consultant_id, 'consultantName', consultant_name, 'location', location,
        'status', status,
        'client', json_build_object('name', client_name, 'phone', client_phone, 'notes', client_notes),
        'bookedBy', booked_by, 'bookedById', booked_by_id, 'bookedAt', booked_at))
      from fs_slots where date between p_from and p_to and (mine is null or consultant_id = mine)), '[]'::json));
end $$;

-- ---------- כתיבה ----------
-- יועצת יכולה לפתוח סלוטים רק לעצמה. צוות ומנהל יכולים לפתוח לכל יועצת.
create or replace function public.fs_add_slots(p_code text, p_slots jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare me json := fs_require(p_code); mine text := fs_mine(me); n int;
begin
  if jsonb_array_length(p_slots) > 300 then raise exception 'too_many'; end if;
  insert into fs_slots (id, date, time, consultant_id, consultant_name, location, created_by)
  select (s->>'date') || '_' || replace(s->>'time', ':', '') || '_' || p.id,
         (s->>'date')::date, s->>'time', p.id, p.name, left(coalesce(s->>'location', ''), 80), me->>'name'
  from jsonb_array_elements(p_slots) s
  join fs_people p on p.id = s->>'consultantId' and p.role = 'consultant' and p.active
  where mine is null or p.id = mine
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.fs_remove_slots(p_code text, p_ids text[]) returns int
language plpgsql security definer set search_path = public as $$
declare me json := fs_require(p_code); mine text := fs_mine(me); n int;
begin
  delete from fs_slots where id = any (p_ids) and status = 'open' and (mine is null or consultant_id = mine);
  get diagnostics n = row_count;
  return n;
end $$;

-- השם של מי ששריין נלקח מהקישור שלו, לא ממה שהדפדפן שולח
create or replace function public.fs_book(p_code text, p_id text, p_name text, p_phone text,
                                          p_notes text, p_location text, p_edit boolean) returns json
language plpgsql security definer set search_path = public as $$
declare me json := fs_require(p_code); mine text := fs_mine(me); v_by text;
begin
  update fs_slots set
    status = 'booked',
    client_name = left(coalesce(p_name, ''), 120),
    client_phone = left(coalesce(p_phone, ''), 40),
    client_notes = left(coalesce(p_notes, ''), 1000),
    location = coalesce(left(p_location, 80), location),
    booked_by = case when status = 'booked' then booked_by else me->>'name' end,
    booked_by_id = case when status = 'booked' then booked_by_id else me->>'id' end,
    booked_at = case when status = 'booked' then booked_at else now() end,
    updated_at = now()
  where id = p_id and (status = 'open' or p_edit) and (mine is null or consultant_id = mine);
  if found then return json_build_object('ok', true); end if;
  select booked_by into v_by from fs_slots where id = p_id and (mine is null or consultant_id = mine);
  if not found then return json_build_object('ok', false, 'reason', 'gone'); end if;
  return json_build_object('ok', false, 'reason', 'taken', 'by', v_by);
end $$;

create or replace function public.fs_unbook(p_code text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare me json := fs_require(p_code); mine text := fs_mine(me);
begin
  update fs_slots set status = 'open', client_name = '', client_phone = '', client_notes = '',
    booked_by = null, booked_by_id = null, booked_at = null, updated_at = now()
  where id = p_id and (mine is null or consultant_id = mine);
end $$;

-- ---------- ניהול (מנהל הלוח בלבד) ----------
create or replace function public.fs_save_config(p_code text, p_config jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fs_require(p_code, true);
  update fs_settings set config = p_config - 'consultants' where id = 1;
end $$;

create or replace function public.fs_people_admin(p_code text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform fs_require(p_code, true);
  return coalesce((
    select json_agg(json_build_object('id', id, 'role', role, 'name', name, 'color', color, 'sort', sort, 'token', token)
                    order by role, sort, created_at)
    from fs_people where active), '[]'::json);
end $$;

-- שומר את רשימת האנשים: חדשים מקבלים קישור, מי שהוסר מהרשימה מושבת (הקישור שלו מפסיק לעבוד, הסלוטים שלו נשארים)
create or replace function public.fs_save_people(p_code text, p_people jsonb) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform fs_require(p_code, true);
  update fs_people set active = false
  where active and id not in (select x->>'id' from jsonb_array_elements(p_people) x where coalesce(x->>'id', '') <> '');
  update fs_people p set name = left(trim(x->>'name'), 60), color = coalesce((x->>'color')::int, p.color),
    sort = coalesce((x->>'sort')::int, p.sort)
  from jsonb_array_elements(p_people) x
  where p.id = x->>'id' and p.active and trim(coalesce(x->>'name', '')) <> '';
  insert into fs_people (id, role, name, color, sort)
  select left(x->>'role', 1) || encode(extensions.gen_random_bytes(4), 'hex'), x->>'role', left(trim(x->>'name'), 60),
         coalesce((x->>'color')::int, 0), coalesce((x->>'sort')::int, 0)
  from jsonb_array_elements(p_people) x
  where coalesce(x->>'id', '') = '' and x->>'role' in ('consultant', 'team') and trim(coalesce(x->>'name', '')) <> '';
  return fs_people_admin(p_code);
end $$;

-- קישור חדש לאדם אחד. הקישור הקודם שלו מפסיק לעבוד מיד
create or replace function public.fs_reset_token(p_code text, p_id text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform fs_require(p_code, true);
  update fs_people set token = encode(extensions.gen_random_bytes(12), 'hex') where id = p_id and active;
  return fs_people_admin(p_code);
end $$;

-- ---------- הרשאות: רק פונקציות ה־API פתוחות לדפדפן ----------
revoke execute on function public.fs_who(text), public.fs_require(text, boolean), public.fs_mine(json) from public, anon, authenticated;
revoke execute on function public.fs_login(text), public.fs_load(text, date, date), public.fs_add_slots(text, jsonb),
  public.fs_remove_slots(text, text[]), public.fs_book(text, text, text, text, text, text, boolean),
  public.fs_unbook(text, text), public.fs_save_config(text, jsonb), public.fs_people_admin(text),
  public.fs_save_people(text, jsonb), public.fs_reset_token(text, text) from public;
grant execute on function public.fs_login(text), public.fs_load(text, date, date), public.fs_add_slots(text, jsonb),
  public.fs_remove_slots(text, text[]), public.fs_book(text, text, text, text, text, text, boolean),
  public.fs_unbook(text, text), public.fs_save_config(text, jsonb), public.fs_people_admin(text),
  public.fs_save_people(text, jsonb), public.fs_reset_token(text, text) to anon, authenticated;
