-- ============================================================
--  apologynote  ·  Supabase schema  (v3: photos, wishes, flower, song, background)
--  Run this whole file once in: Supabase -> SQL Editor -> New query
--  Safe to run again on top of v1 / v2 (it upgrades them).
--
--  Design: no accounts. Tables are fully locked (RLS on, no policies,
--  no table grants). The website talks ONLY to the functions below.
--  Each note gets a short public code (e.g. x7k2m9) and a secret
--  edit token that stays in the creator's browser (stored hashed here).
-- ============================================================

-- ---------- tables ----------
create table if not exists public.notes (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  edit_hash     text not null,
  to_name       text not null default ''  check (char_length(to_name)   <= 60),
  from_name     text not null default ''  check (char_length(from_name) <= 60),
  title         text not null default ''  check (char_length(title)     <= 120),
  message       text not null             check (char_length(message) between 10 and 2000),
  theme         text not null default 'rose'
                check (theme in ('rose','midnight','sage','sunset','lavender','paper')),
  emoji         text not null default '♥',   -- a single special character (column kept for upgrades)
  promises      jsonb not null default '[]'::jsonb,
  allow_replies boolean not null default true,
  views         integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.reactions (
  id         uuid primary key default gen_random_uuid(),
  note_id    uuid not null references public.notes(id) on delete cascade,
  kind       text not null check (kind in ('forgive','talk','time')),
  name       text not null default '' check (char_length(name)    <= 60),
  message    text not null default '' check (char_length(message) <= 500),
  created_at timestamptz not null default now()
);

create index if not exists reactions_note_idx on public.reactions(note_id, created_at desc);

-- ---------- v2/v3 columns ----------
alter table public.notes add column if not exists bg      text  not null default '';
alter table public.notes add column if not exists song    text  not null default '';
alter table public.notes add column if not exists photos  jsonb not null default '[]'::jsonb;  -- [{s:"data:image/jpeg;base64,..",c:"caption"}] max 4
alter table public.notes add column if not exists wishes  jsonb not null default '[]'::jsonb;  -- dandelion wishes, max 6
alter table public.notes add column if not exists flower  text  not null default 'rose';

-- no emoji: the mark is one special character from a fixed list
alter table public.notes alter column emoji set default '♥';
alter table public.notes drop constraint if exists notes_emoji_chk;
update public.notes set emoji = '♥' where emoji !~ '^[♡♥✦✧❀✿❁❦❧☾♪♫✎❋✶⚘]$';
alter table public.notes add constraint notes_emoji_chk check (emoji ~ '^[♡♥✦✧❀✿❁❦❧☾♪♫✎❋✶⚘]$');

alter table public.notes drop constraint if exists notes_bg_chk;
alter table public.notes add constraint notes_bg_chk check (
  bg = '' or bg in ('doodle','leaf','flower','ink')
  or (bg like 'data:image/jpeg;base64,%' and char_length(bg) <= 300000)
);

alter table public.notes drop constraint if exists notes_song_chk;
alter table public.notes add constraint notes_song_chk check (
  song ~ '^(|m:(piano|box|calm|rain)|yt:[A-Za-z0-9_-]{11})$'
);

alter table public.notes drop constraint if exists notes_flower_chk;
alter table public.notes add constraint notes_flower_chk check (flower in ('rose','tulip','daisy','sunflower'));

alter table public.notes drop constraint if exists notes_photos_chk;
alter table public.notes add constraint notes_photos_chk check (
  jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 4 and char_length(photos::text) <= 700000);

alter table public.notes drop constraint if exists notes_wishes_chk;
alter table public.notes add constraint notes_wishes_chk check (
  jsonb_typeof(wishes) = 'array' and jsonb_array_length(wishes) <= 6);

-- ---------- lock everything down ----------
alter table public.notes     enable row level security;
alter table public.reactions enable row level security;
revoke all on public.notes     from anon, authenticated;
revoke all on public.reactions from anon, authenticated;
-- (no policies on purpose: only the security-definer functions below can touch data)

-- ---------- helpers ----------
-- 6-char code, no look-alike letters (no 0/o/1/l/i), always contains a digit
create or replace function public.gen_note_code()
returns text
language plpgsql
set search_path = public
as $$
declare
  chars constant text := '23456789abcdefghjkmnpqrstuvwxyz';
  c text;
  i int;
begin
  loop
    c := '';
    for i in 1..6 loop
      c := c || substr(chars, 1 + floor(random() * length(chars))::int, 1);
    end loop;
    if c ~ '[0-9]' and not exists (select 1 from public.notes where code = c) then
      return c;
    end if;
  end loop;
end
$$;

create or replace function public.hash_token(p_token text)
returns text
language sql
immutable
as $$ select encode(sha256(convert_to(p_token, 'utf8')), 'hex') $$;

-- clean a jsonb array of strings: keep non-empty, trim, cut each to p_len, keep first p_max
create or replace function public.clean_list(p jsonb, p_max int, p_len int)
returns jsonb
language sql
immutable
as $$
  select coalesce(
    (select jsonb_agg(left(btrim(v), p_len))
       from (select v from jsonb_array_elements_text(
               case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end
             ) as v
             where btrim(v) <> '' limit p_max) s),
    '[]'::jsonb)
$$;

-- keep only valid jpeg data-urls (<=150k chars each, max 4) with a caption <= 80 chars
create or replace function public.clean_photos(p jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(
    (select jsonb_agg(jsonb_build_object('s', e->>'s', 'c', left(btrim(coalesce(e->>'c','')), 80)))
       from (select e from jsonb_array_elements(
               case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) as e
             where (e->>'s') like 'data:image/jpeg;base64,%' and char_length(e->>'s') <= 150000
             limit 4) s),
    '[]'::jsonb)
$$;

-- ---------- remove older versions of the functions ----------
drop function if exists public.clean_promises(jsonb);
drop function if exists public.create_note(text,text,text,text,text,text,text,jsonb,boolean);
drop function if exists public.update_note(text,text,text,text,text,text,text,text,jsonb,boolean);
drop function if exists public.create_note(text,text,text,text,text,text,text,jsonb,boolean,text,text);
drop function if exists public.update_note(text,text,text,text,text,text,text,text,jsonb,boolean,text,text);

-- ---------- create ----------
create or replace function public.create_note(
  p_token text, p_to text, p_from text, p_title text, p_message text,
  p_theme text, p_mark text, p_promises jsonb, p_allow_replies boolean,
  p_bg text default '', p_song text default '',
  p_photos jsonb default '[]', p_wishes jsonb default '[]', p_flower text default 'rose'
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_code text;
begin
  if p_token is null or char_length(p_token) < 16 then
    raise exception 'Invalid token';
  end if;
  v_code := public.gen_note_code();
  insert into public.notes
    (code, edit_hash, to_name, from_name, title, message, theme, emoji, promises,
     allow_replies, bg, song, photos, wishes, flower)
  values
    (v_code, public.hash_token(p_token),
     left(btrim(coalesce(p_to,'')), 60), left(btrim(coalesce(p_from,'')), 60),
     left(btrim(coalesce(p_title,'')), 120), btrim(p_message),
     coalesce(p_theme,'rose'), coalesce(nullif(p_mark,''),'♥'),
     public.clean_list(p_promises, 4, 140), coalesce(p_allow_replies, true),
     coalesce(p_bg,''), coalesce(p_song,''),
     public.clean_photos(p_photos), public.clean_list(p_wishes, 6, 120),
     coalesce(nullif(p_flower,''),'rose'));
  return v_code;
end
$$;

-- ---------- read (public, counts a view) ----------
create or replace function public.get_note(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare n public.notes;
begin
  update public.notes set views = views + 1
   where code = lower(btrim(p_code))
   returning * into n;
  if not found then return null; end if;
  return jsonb_build_object(
    'code', n.code, 'to', n.to_name, 'from', n.from_name, 'title', n.title,
    'message', n.message, 'theme', n.theme, 'mark', n.emoji,
    'promises', n.promises, 'allow_replies', n.allow_replies,
    'bg', n.bg, 'song', n.song, 'photos', n.photos, 'wishes', n.wishes, 'flower', n.flower,
    'created_at', n.created_at);
end
$$;

-- ---------- owner read (no view counted) so the editor can reload everything ----------
create or replace function public.get_note_owner(p_code text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare n public.notes;
begin
  select * into n from public.notes
   where code = lower(btrim(p_code)) and edit_hash = public.hash_token(p_token);
  if not found then return null; end if;
  return jsonb_build_object(
    'code', n.code, 'to', n.to_name, 'from', n.from_name, 'title', n.title,
    'message', n.message, 'theme', n.theme, 'mark', n.emoji,
    'promises', n.promises, 'allow_replies', n.allow_replies,
    'bg', n.bg, 'song', n.song, 'photos', n.photos, 'wishes', n.wishes, 'flower', n.flower,
    'created_at', n.created_at);
end
$$;

-- ---------- edit (needs the secret token) ----------
create or replace function public.update_note(
  p_code text, p_token text, p_to text, p_from text, p_title text, p_message text,
  p_theme text, p_mark text, p_promises jsonb, p_allow_replies boolean,
  p_bg text default '', p_song text default '',
  p_photos jsonb default '[]', p_wishes jsonb default '[]', p_flower text default 'rose'
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare k int;
begin
  update public.notes set
    to_name = left(btrim(coalesce(p_to,'')), 60),
    from_name = left(btrim(coalesce(p_from,'')), 60),
    title = left(btrim(coalesce(p_title,'')), 120),
    message = btrim(p_message),
    theme = coalesce(p_theme,'rose'),
    emoji = coalesce(nullif(p_mark,''),'♥'),
    promises = public.clean_list(p_promises, 4, 140),
    allow_replies = coalesce(p_allow_replies, true),
    bg = coalesce(p_bg,''),
    song = coalesce(p_song,''),
    photos = public.clean_photos(p_photos),
    wishes = public.clean_list(p_wishes, 6, 120),
    flower = coalesce(nullif(p_flower,''),'rose'),
    updated_at = now()
  where code = lower(btrim(p_code)) and edit_hash = public.hash_token(p_token);
  get diagnostics k = row_count;
  return k > 0;
end
$$;

-- ---------- delete ----------
create or replace function public.delete_note(p_code text, p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare k int;
begin
  delete from public.notes
   where code = lower(btrim(p_code)) and edit_hash = public.hash_token(p_token);
  get diagnostics k = row_count;
  return k > 0;
end
$$;

-- ---------- recipient reply ----------
create or replace function public.add_reaction(
  p_code text, p_kind text, p_name text, p_message text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare n public.notes;
begin
  select * into n from public.notes where code = lower(btrim(p_code));
  if not found or not n.allow_replies then return false; end if;
  if (select count(*) from public.reactions where note_id = n.id) >= 200 then return false; end if;
  insert into public.reactions (note_id, kind, name, message)
  values (n.id, p_kind, left(btrim(coalesce(p_name,'')), 60), left(btrim(coalesce(p_message,'')), 500));
  return true;
end
$$;

-- ---------- owner dashboard: views + replies ----------
create or replace function public.note_stats(p_code text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare n public.notes;
begin
  select * into n from public.notes
   where code = lower(btrim(p_code)) and edit_hash = public.hash_token(p_token);
  if not found then return null; end if;
  return jsonb_build_object(
    'views', n.views,
    'reactions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', r.kind, 'name', r.name, 'message', r.message, 'at', r.created_at)
             order by r.created_at desc)
        from (select * from public.reactions where note_id = n.id
               order by created_at desc limit 100) r), '[]'::jsonb));
end
$$;

-- ---------- permissions: only the public functions are callable ----------
revoke all on function public.gen_note_code()                 from public, anon, authenticated;
revoke all on function public.hash_token(text)                from public, anon, authenticated;
revoke all on function public.clean_list(jsonb,int,int)       from public, anon, authenticated;
revoke all on function public.clean_photos(jsonb)             from public, anon, authenticated;

revoke all on function public.create_note(text,text,text,text,text,text,text,jsonb,boolean,text,text,jsonb,jsonb,text)          from public;
revoke all on function public.get_note(text)                                                                                      from public;
revoke all on function public.get_note_owner(text,text)                                                                           from public;
revoke all on function public.update_note(text,text,text,text,text,text,text,text,jsonb,boolean,text,text,jsonb,jsonb,text)     from public;
revoke all on function public.delete_note(text,text)                                                                              from public;
revoke all on function public.add_reaction(text,text,text,text)                                                                   from public;
revoke all on function public.note_stats(text,text)                                                                               from public;

grant execute on function public.create_note(text,text,text,text,text,text,text,jsonb,boolean,text,text,jsonb,jsonb,text)       to anon, authenticated;
grant execute on function public.get_note(text)                                                                                   to anon, authenticated;
grant execute on function public.get_note_owner(text,text)                                                                        to anon, authenticated;
grant execute on function public.update_note(text,text,text,text,text,text,text,text,jsonb,boolean,text,text,jsonb,jsonb,text)  to anon, authenticated;
grant execute on function public.delete_note(text,text)                                                                           to anon, authenticated;
grant execute on function public.add_reaction(text,text,text,text)                                                                to anon, authenticated;
grant execute on function public.note_stats(text,text)                                                                            to anon, authenticated;

-- Done. Now copy your Project URL + anon/publishable key into index.html (CONFIG at top of the script).
