-- =============================================================
-- ROYALE REWARDS - Supabase schema (accounts + card redemption)
-- Run in the Supabase SQL editor, enable Email auth in
-- Authentication settings, then put the project URL + anon key
-- into CFG at the top of loyalty.html.
-- =============================================================

-- ---------- profiles: one row per member account ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  created_at  timestamptz not null default now()
);

-- auto-create a profile whenever someone signs up
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone');
  return new;
end $$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- cards: the physical Royale cards (QR = code) ----------
create table public.cards (
  code        text primary key,              -- e.g. ROYALE-8412 (printed in the QR)
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- discount_entries: the stack history ----------
create type public.discount_source as enum ('card_scan', 'video_review', 'manual');

create table public.discount_entries (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  source       public.discount_source not null,
  card_code    text references public.cards(code),
  pct          numeric not null check (pct > 0),
  granted_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '90 days',
  consumed_booking_id uuid,
  created_at   timestamptz not null default now()
);
create index on public.discount_entries (user_id);

-- ---------- bookings ----------
create type public.booking_status as enum ('requested','confirmed','completed','cancelled');
create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  car           text,
  status        public.booking_status not null default 'requested',
  discount_pct  numeric not null default 0,
  completed_at  timestamptz,
  created_at    timestamptz not null default now()
);

-- ---------- RLS ----------
alter table public.profiles         enable row level security;
alter table public.cards            enable row level security;
alter table public.discount_entries enable row level security;
alter table public.bookings         enable row level security;

create policy "own profile"  on public.profiles for select using (auth.uid() = id);
create policy "own entries"  on public.discount_entries for select using (auth.uid() = user_id);
create policy "own bookings" on public.bookings for select using (auth.uid() = user_id);
-- cards: no public policies (validated inside the RPC only)

-- ---------- RPC: my rewards (dashboard) ----------
create or replace function public.get_my_rewards()
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'name', p.full_name, 'phone', p.phone, 'email', u.email,
    'created_at', p.created_at,
    'entries', coalesce((
      select json_agg(json_build_object(
        'source', case e.source when 'card_scan' then 'Card scan bonus'
                                when 'video_review' then 'Video review' else 'Bonus' end,
        'pct', e.pct, 'granted_at', e.granted_at, 'expires_at', e.expires_at,
        'consumed', e.consumed_booking_id is not null
      ) order by e.granted_at desc)
      from discount_entries e where e.user_id = p.id), '[]'::json)
  )
  from profiles p join auth.users u on u.id = p.id
  where p.id = auth.uid();
$$;

-- ---------- RPC: redeem a scanned/typed card code (must be logged in) ----------
create or replace function public.redeem_card(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_code text := upper(trim(p_code));
  v_live numeric;
begin
  if auth.uid() is null then return 'Please log in first.'; end if;
  if not exists (select 1 from cards where code = v_code and active) then
    return 'Card not recognised - check the code or message us on WhatsApp.';
  end if;
  if exists (select 1 from discount_entries
             where user_id = auth.uid() and card_code = v_code
               and consumed_booking_id is null and expires_at > now()) then
    return 'This card''s discount is already active on your account.';
  end if;
  select coalesce(sum(pct),0) into v_live from discount_entries
    where user_id = auth.uid() and consumed_booking_id is null and expires_at > now();
  if v_live + 5 > 15 then return 'You have reached the maximum active discount for now.'; end if;
  insert into discount_entries (user_id, source, card_code, pct)
    values (auth.uid(), 'card_scan', v_code, 5);
  return 'ok';
end $$;

-- ---------- staff helpers (Supabase dashboard only) ----------
create or replace function public.grant_video_bonus(p_email text)
returns text language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_live numeric;
begin
  select u.id into v_user from auth.users u where lower(u.email) = lower(p_email);
  if v_user is null then return 'member not found'; end if;
  select coalesce(sum(pct),0) into v_live from discount_entries
    where user_id = v_user and consumed_booking_id is null and expires_at > now();
  if v_live >= 15 then return 'already at maximum'; end if;
  insert into discount_entries (user_id, source, pct)
    values (v_user, 'video_review', least(5, 15 - v_live));
  return 'granted';
end $$;

create or replace function public.complete_booking(p_booking uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  update bookings set status = 'completed', completed_at = now()
    where id = p_booking returning user_id into v_user;
  update discount_entries set consumed_booking_id = p_booking
    where user_id = v_user and consumed_booking_id is null and expires_at > now();
end $$;

revoke execute on function public.grant_video_bonus(text) from anon, authenticated;
revoke execute on function public.complete_booking(uuid) from anon, authenticated;

-- ---------- seed some cards (add one row per printed card) ----------
insert into public.cards (code) values ('ROYALE-8412'), ('ROYALE-3157'), ('ROYALE-9926');


-- =============================================================
-- REFERRAL FRAMEWORK - "Refer & both ride free"
-- Both the referrer and the referred friend receive one
-- complimentary chauffeured V-Class trip when the friend's
-- FIRST booking is completed (min qualifying value AED 1,500).
-- =============================================================

-- personal referral code on every profile
alter table public.profiles add column ref_code text unique;

-- regenerate ref codes for signups: FIRSTNAME-4 digits
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  loop
    v_code := upper(regexp_replace(split_part(coalesce(new.raw_user_meta_data->>'full_name','ROYALE'),' ',1),'[^A-Za-z]','','g'))
              || '-' || lpad(floor(random()*10000)::text, 4, '0');
    exit when not exists (select 1 from public.profiles where ref_code = v_code);
  end loop;
  insert into public.profiles (id, full_name, phone, ref_code)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone', v_code);
  return new;
end $$;

-- bookings need a value for the qualifying floor
alter table public.bookings add column amount_aed numeric;

-- referrals: recorded when the friend's first booking request arrives
create type public.referral_status as enum ('pending','completed','rewarded');
create table public.referrals (
  id            uuid primary key default gen_random_uuid(),
  referrer_id   uuid not null references public.profiles(id) on delete cascade,
  friend_id     uuid references public.profiles(id),   -- once the friend has an account
  friend_contact text,                                  -- phone/email before they sign up
  booking_id    uuid references public.bookings(id),
  status        public.referral_status not null default 'pending',
  created_at    timestamptz not null default now(),
  completed_at  timestamptz,
  unique (referrer_id, friend_id)                      -- one reward per unique friend
);
alter table public.referrals enable row level security;
create policy "own referrals" on public.referrals for select using (auth.uid() = referrer_id);

-- free V-Class trips earned through referrals
create type public.trip_status as enum ('available','booked','used','expired');
create table public.trip_rewards (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  source      text not null,                            -- 'referral_referrer' | 'referral_friend'
  referral_id uuid references public.referrals(id),
  status      public.trip_status not null default 'available',
  granted_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '90 days',
  created_at  timestamptz not null default now()
);
alter table public.trip_rewards enable row level security;
create policy "own trips" on public.trip_rewards for select using (auth.uid() = user_id);

-- staff: log a referral when the friend's first booking message arrives
-- (the WhatsApp message contains "referred by CODE")
create or replace function public.log_referral(p_ref_code text, p_friend_email text)
returns text language plpgsql security definer set search_path = public as $$
declare v_referrer uuid; v_friend uuid;
begin
  select id into v_referrer from profiles where upper(ref_code) = upper(trim(p_ref_code));
  if v_referrer is null then return 'referral code not found'; end if;
  select u.id into v_friend from auth.users u where lower(u.email) = lower(p_friend_email);
  if v_friend = v_referrer then return 'self-referrals do not count'; end if;
  insert into referrals (referrer_id, friend_id, friend_contact)
    values (v_referrer, v_friend, p_friend_email)
    on conflict (referrer_id, friend_id) do nothing;
  return 'logged';
end $$;

-- staff: when the friend's qualifying first booking completes -> reward BOTH sides
create or replace function public.complete_referral(p_referral uuid, p_booking uuid)
returns text language plpgsql security definer set search_path = public as $$
declare r record; v_amount numeric;
begin
  select * into r from referrals where id = p_referral;
  if r is null then return 'referral not found'; end if;
  if r.status <> 'pending' then return 'already processed'; end if;
  select amount_aed into v_amount from bookings where id = p_booking;
  if coalesce(v_amount,0) < 1500 then return 'booking below AED 1,500 qualifying floor'; end if;

  update referrals set status='rewarded', booking_id=p_booking, completed_at=now() where id=p_referral;
  insert into trip_rewards (user_id, source, referral_id) values (r.referrer_id, 'referral_referrer', p_referral);
  if r.friend_id is not null then
    insert into trip_rewards (user_id, source, referral_id) values (r.friend_id, 'referral_friend', p_referral);
  end if;
  return 'both rewarded';
end $$;

revoke execute on function public.log_referral(text, text) from anon, authenticated;
revoke execute on function public.complete_referral(uuid, uuid) from anon, authenticated;

-- dashboard payload now includes referral data
create or replace function public.get_my_rewards()
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'name', p.full_name, 'phone', p.phone, 'email', u.email,
    'created_at', p.created_at,
    'ref_code', p.ref_code,
    'referrals', coalesce((select json_agg(json_build_object('status', r.status, 'created_at', r.created_at))
                           from referrals r where r.referrer_id = p.id), '[]'::json),
    'trips', coalesce((select json_agg(json_build_object('status', t.status, 'source', t.source, 'expires_at', t.expires_at))
                       from trip_rewards t where t.user_id = p.id), '[]'::json),
    'entries', coalesce((
      select json_agg(json_build_object(
        'source', case e.source when 'card_scan' then 'Card scan bonus'
                                when 'video_review' then 'Video review' else 'Bonus' end,
        'pct', e.pct, 'granted_at', e.granted_at, 'expires_at', e.expires_at,
        'consumed', e.consumed_booking_id is not null
      ) order by e.granted_at desc)
      from discount_entries e where e.user_id = p.id), '[]'::json)
  )
  from profiles p join auth.users u on u.id = p.id
  where p.id = auth.uid();
$$;
