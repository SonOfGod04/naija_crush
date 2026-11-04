-- Naija Crush: run this once in Supabase > SQL Editor 

create table if not exists players (
  id text primary key,
  name text not null check (char_length(name) between 1 and 14),
  tot int not null default 0,
  m int not null default 0,
  don int not null default 0,
  vp int not null default 0,
  ts timestamptz not null default now()
);
alter table players add column if not exists save jsonb;
alter table players add column if not exists sid text;
-- nicknames are unique, ignoring upper/lower case
create unique index if not exists players_name_unique on players (lower(name));

create table if not exists help_requests (
  id uuid primary key default gen_random_uuid(),
  pid text not null,
  name text not null check (char_length(name) between 1 and 14),
  reason text not null check (char_length(reason) <= 60),
  need int not null check (need between 50 and 500),
  open boolean not null default true,
  ts timestamptz not null default now()
);
create unique index if not exists one_open_request on help_requests (pid) where open;

create table if not exists gifts (
  id uuid primary key default gen_random_uuid(),
  req_id uuid not null references help_requests(id) on delete cascade,
  to_pid text not null,
  from_name text not null check (char_length(from_name) between 1 and 14),
  amount int not null check (amount between 10 and 500),
  claimed boolean not null default false,
  ts timestamptz not null default now()
);
alter table gifts add column if not exists from_pid text;

alter table players enable row level security;
alter table help_requests enable row level security;
alter table gifts enable row level security;

-- remove the older open policies if they exist
drop policy if exists "players read" on players;
drop policy if exists "players insert" on players;
drop policy if exists "players update" on players;
drop policy if exists "requests read" on help_requests;
drop policy if exists "requests insert" on help_requests;
drop policy if exists "requests update" on help_requests;
drop policy if exists "gifts read" on gifts;
drop policy if exists "gifts insert" on gifts;
drop policy if exists "gifts update" on gifts;
drop policy if exists "players insert own" on players;
drop policy if exists "players update own" on players;
drop policy if exists "requests insert own" on help_requests;
drop policy if exists "requests update own" on help_requests;
drop policy if exists "gifts insert own" on gifts;
drop policy if exists "gifts claim own" on gifts;

-- everyone can read; only a signed-in player can write their own rows
create policy "players read" on players for select using (true);
create policy "players insert own" on players for insert to authenticated
  with check (id = auth.uid()::text);
create policy "players update own" on players for update to authenticated
  using (id = auth.uid()::text) with check (id = auth.uid()::text);

create policy "requests read" on help_requests for select using (true);
create policy "requests insert own" on help_requests for insert to authenticated
  with check (pid = auth.uid()::text);
create policy "requests update own" on help_requests for update to authenticated
  using (pid = auth.uid()::text) with check (pid = auth.uid()::text);

create policy "gifts read" on gifts for select using (true);
create policy "gifts insert own" on gifts for insert to authenticated
  with check (from_pid = auth.uid()::text and to_pid <> auth.uid()::text);
create policy "gifts claim own" on gifts for update to authenticated
  using (to_pid = auth.uid()::text) with check (to_pid = auth.uid()::text);

-- receivers may only flip "claimed", requesters may only close their request
revoke update on gifts from authenticated;
grant update (claimed) on gifts to authenticated;
revoke update on help_requests from authenticated;
grant update (open) on help_requests to authenticated;

-- ===== Fireside chat =====
create table if not exists chat (
  id bigint generated always as identity primary key,
  uid text not null,
  name text not null check (char_length(name) between 1 and 14),
  body text not null check (char_length(body) between 1 and 140),
  hidden boolean not null default false,
  ts timestamptz not null default now()
);
create table if not exists chat_reports (
  id bigint generated always as identity primary key,
  msg_id bigint not null references chat(id) on delete cascade,
  reporter text not null,
  ts timestamptz not null default now(),
  unique (msg_id, reporter)
);
alter table chat enable row level security;
alter table chat_reports enable row level security;
drop policy if exists "chat read" on chat;
drop policy if exists "chat insert own" on chat;
drop policy if exists "reports insert own" on chat_reports;
create policy "chat read" on chat for select using (true);
create policy "chat insert own" on chat for insert to authenticated with check (uid = auth.uid()::text);
create policy "reports insert own" on chat_reports for insert to authenticated with check (reporter = auth.uid()::text);
-- a message reported by 3 different players is hidden automatically
create or replace function hide_reported() returns trigger language plpgsql security definer as $$
begin
  update chat set hidden = true
  where id = new.msg_id and (select count(*) from chat_reports where msg_id = new.msg_id) >= 3;
  return new;
end $$;
drop trigger if exists t_hide on chat_reports;
create trigger t_hide after insert on chat_reports for each row execute function hide_reported();

-- ===== Certificates (for verification) =====
create table if not exists certificates (
  id uuid primary key default gen_random_uuid(),
  uid text not null,
  name text not null check (char_length(name) between 1 and 14),
  award text not null check (award in ('heart','leader','morals')),
  serial text not null unique,
  ts timestamptz not null default now(),
  unique (uid, award)
);
alter table certificates enable row level security;
drop policy if exists "certs read" on certificates;
drop policy if exists "certs insert own" on certificates;
create policy "certs read" on certificates for select using (true);
create policy "certs insert own" on certificates for insert to authenticated with check (uid = auth.uid()::text);

-- =====================================================================
-- ===== Server-side scoring (the database owns points and progress) ====
-- =====================================================================
alter table players add column if not exists hp int not null default 0;
alter table players add column if not exists u int not null default 0;
alter table players add column if not exists stars smallint[] not null default array_fill(0::smallint, array[250]);
alter table players add column if not exists ch jsonb not null default '{}'::jsonb;
alter table players add column if not exists quests jsonb not null default '{}'::jsonb;
alter table players add column if not exists helped int not null default 0;
alter table players add column if not exists cur_mission int;
alter table players add column if not exists started_at timestamptz;

-- Clients can no longer write these tables directly. Everything goes through the functions below.
drop policy if exists "players insert own" on players;
drop policy if exists "players update own" on players;
drop policy if exists "requests insert own" on help_requests;
drop policy if exists "requests update own" on help_requests;
drop policy if exists "gifts insert own" on gifts;
drop policy if exists "gifts claim own" on gifts;
drop policy if exists "certs insert own" on certificates;
revoke insert, update, delete on players, help_requests, gifts, certificates from anon, authenticated;
-- the leaderboard may read only these public columns of players
revoke select on players from anon, authenticated;
grant select (id, name, tot, m, don, vp) on players to anon, authenticated;
grant select on help_requests, gifts, certificates to anon, authenticated;

create or replace function mission_mv(i int) returns int language sql immutable as $$
  select 22 + (i / 31) + case when i % 5 = 4 then 2 else 0 end
$$;
create or replace function mission_sc(i int) returns int language sql immutable as $$
  select case when i % 5 = 4 then (round((mission_mv(i) * (55 + 35 * (i / 249.0))) / 50.0) * 50)::int else 0 end
$$;

create or replace function state_of(p_uid text) returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'name', name, 'hp', hp, 'tot', tot, 'u', u, 's', to_jsonb(stars), 'vp', vp,
    'don', quests || jsonb_build_object('h', helped), 'ch', ch,
    'cert', coalesce((select jsonb_object_agg(c.award, c.serial) from certificates c where c.uid = p_uid), '{}'::jsonb))
  from players where id = p_uid
$$;

create or replace function ensure_player(p_name text) returns void language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text;
begin
  if me is null then raise exception 'not_signed_in'; end if;
  if exists (select 1 from players where id = me) then return; end if;
  if p_name !~ '^[A-Za-z0-9 .-]{2,14}$' then raise exception 'bad_name'; end if;
  begin
    insert into players (id, name) values (me, p_name);
  exception when unique_violation then
    raise exception 'nickname_taken';
  end;
end $$;

create or replace function get_state() returns jsonb language sql security definer set search_path = public as $$
  select state_of(auth.uid()::text)
$$;

create or replace function set_session(p_sid text) returns void language sql security definer set search_path = public as $$
  update players set sid = p_sid where id = auth.uid()::text
$$;

create or replace function session_ok(p_sid text) returns boolean language sql security definer set search_path = public as $$
  select coalesce((select sid is null or sid = p_sid from players where id = auth.uid()::text), true)
$$;

create or replace function start_mission(p_i int) returns void language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; pu int;
begin
  select u into pu from players where id = me;
  if pu is null then raise exception 'no_player'; end if;
  if p_i < 0 or p_i > 249 or p_i > pu then raise exception 'locked'; end if;
  update players set cur_mission = p_i, started_at = now() where id = me;
end $$;

create or replace function complete_mission(p_i int, p_score int, p_left int) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me text := auth.uid()::text; p players%rowtype;
  mv int; sc int; used int; el numeric; st int; old int; earn int;
begin
  select * into p from players where id = me for update;
  if not found then raise exception 'no_player'; end if;
  if p.cur_mission is distinct from p_i or p.started_at is null then raise exception 'not_started'; end if;
  if p_i < 0 or p_i > 249 or p_i > p.u then raise exception 'locked'; end if;
  mv := mission_mv(p_i); sc := mission_sc(p_i);
  if p_left < 0 or p_left > mv + 7 then raise exception 'bad_moves'; end if;
  if p_score < 0 or p_score > (mv + 2) * 1200 then raise exception 'bad_score'; end if;
  if sc > 0 and p_score < sc * 0.9 then raise exception 'score_short'; end if;
  used := greatest(1, mv - p_left);
  el := extract(epoch from now() - p.started_at);
  if el < used * 2 then raise exception 'too_fast'; end if;
  st := case when p_left >= 8 then 3 when p_left >= 4 then 2 else 1 end;
  old := coalesce(p.stars[p_i + 1], 0);
  earn := least(p_score / 10, mv * 20) + st * 25;
  if old > 0 then earn := round(earn * 0.1)::int + greatest(st - old, 0) * 25; end if;
  update players
     set stars[p_i + 1] = greatest(old, st)::smallint,
         u = greatest(u, least(p_i + 1, 249)),
         hp = hp + earn, tot = tot + earn,
         cur_mission = null, started_at = null
   where id = me;
  update players set m = (select count(*) from unnest(stars) x where x > 0) where id = me;
  return jsonb_build_object('earn', earn, 'state', state_of(me));
end $$;

create or replace function record_choice(p_i int, p_pick int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; pu int; good boolean;
begin
  select u into pu from players where id = me;
  if pu is null then raise exception 'no_player'; end if;
  if p_i < 0 or p_i > 249 or p_pick not in (0, 1) or p_i > pu then raise exception 'bad_input'; end if;
  good := (p_pick = p_i % 2);
  update players
     set ch = ch || jsonb_build_object(p_i::text, case when good then 1 else 0 end),
         vp = vp + case when good then 1 else 0 end
   where id = me and not (ch ? (p_i::text));
  return state_of(me);
end $$;

create or replace function donate(p_k int, p_amt int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; goals int[] := array[2000, 3000, 2500, 2500, 3500]; p players%rowtype; have int; x int;
begin
  if p_k < 0 or p_k > 4 or p_amt < 1 then raise exception 'bad_input'; end if;
  select * into p from players where id = me for update;
  if not found then raise exception 'no_player'; end if;
  have := coalesce((p.quests ->> (p_k::text))::int, 0);
  x := least(p_amt, p.hp, goals[p_k + 1] - have);
  if x <= 0 then raise exception 'nothing_to_give'; end if;
  update players set hp = hp - x, don = don + x, quests = quests || jsonb_build_object(p_k::text, have + x) where id = me;
  return state_of(me);
end $$;

create or replace function ask_help(p_reason text, p_need int) returns void language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; nm text;
begin
  if not (p_reason = any (array['School books and supplies','Food for my family','Transport fare to school','Medicine for a parent','Exam registration fee'])) then
    raise exception 'bad_reason';
  end if;
  if p_need not in (100, 250, 500) then raise exception 'bad_need'; end if;
  select name into nm from players where id = me;
  if nm is null then raise exception 'no_player'; end if;
  begin
    insert into help_requests (pid, name, reason, need) values (me, nm, p_reason, p_need);
  exception when unique_violation then
    raise exception 'already_open';
  end;
end $$;

create or replace function give_help(p_req uuid, p_amt int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; r help_requests%rowtype; g players%rowtype; got int;
begin
  if p_amt not in (50, 100) then raise exception 'bad_amount'; end if;
  select * into r from help_requests where id = p_req and open for update;
  if not found then raise exception 'closed'; end if;
  if r.pid = me then raise exception 'own_request'; end if;
  select * into g from players where id = me for update;
  if not found then raise exception 'no_player'; end if;
  if g.hp < p_amt then raise exception 'not_enough'; end if;
  update players set hp = hp - p_amt, don = don + p_amt, helped = helped + p_amt where id = me;
  update players set hp = hp + p_amt where id = r.pid;
  insert into gifts (req_id, to_pid, from_pid, from_name, amount, claimed) values (r.id, r.pid, me, g.name, p_amt, true);
  select coalesce(sum(amount), 0) into got from gifts where req_id = r.id;
  if got >= r.need then update help_requests set open = false where id = r.id; end if;
  return state_of(me);
end $$;

create or replace function cancel_help() returns void language sql security definer set search_path = public as $$
  update help_requests set open = false where pid = auth.uid()::text and open
$$;

create or replace function claim_award(p_award text) returns text language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; p players%rowtype; cnt int; sm int; gd int; qn int; ok boolean; ser text;
begin
  select * into p from players where id = me;
  if not found then raise exception 'no_player'; end if;
  select count(*) into cnt from unnest(p.stars) x where x > 0;
  if cnt < 250 then raise exception 'not_finished'; end if;
  select coalesce(sum(x), 0) into sm from unnest(p.stars) x;
  select count(*) into gd from jsonb_each_text(p.ch) e where e.value = '1';
  qn := (case when coalesce((p.quests ->> '0')::int, 0) >= 2000 then 1 else 0 end)
      + (case when coalesce((p.quests ->> '1')::int, 0) >= 3000 then 1 else 0 end)
      + (case when coalesce((p.quests ->> '2')::int, 0) >= 2500 then 1 else 0 end)
      + (case when coalesce((p.quests ->> '3')::int, 0) >= 2500 then 1 else 0 end)
      + (case when coalesce((p.quests ->> '4')::int, 0) >= 3500 then 1 else 0 end);
  ok := case p_award
          when 'heart' then (qn >= 3 or p.helped >= 1000)
          when 'leader' then sm >= 350
          when 'morals' then gd >= 200
          else false end;
  if not ok then raise exception 'not_eligible'; end if;
  ser := 'NC-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4)) || '-' || upper(substr(md5(random()::text || me), 1, 5));
  insert into certificates (uid, name, award, serial) values (me, p.name, p_award, ser) on conflict (uid, award) do nothing;
  select serial into ser from certificates where uid = me and award = p_award;
  return ser;
end $$;

-- helpers stay private; the game functions are for signed-in players only
revoke all on function state_of(text), mission_mv(int), mission_sc(int) from public, anon, authenticated;
revoke all on function ensure_player(text), get_state(), set_session(text), session_ok(text), start_mission(int),
  complete_mission(int, int, int), record_choice(int, int), donate(int, int), ask_help(text, int),
  give_help(uuid, int), cancel_help(), claim_award(text) from public, anon;
grant execute on function ensure_player(text), get_state(), set_session(text), session_ok(text), start_mission(int),
  complete_mission(int, int, int), record_choice(int, int), donate(int, int), ask_help(text, int),
  give_help(uuid, int), cancel_help(), claim_award(text) to authenticated;
