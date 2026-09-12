-- profiles: one row per authenticated user, auto-created on first login.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
-- No policies: profiles is never queried directly from client code.
-- It is only read/written through the security-definer functions below,
-- which bypass RLS as their owning role. The operator sets is_admin
-- by hand in the Supabase table editor (see README.md).

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

grant execute on function public.is_admin() to authenticated;

-- requests: one row per wizard submission.
create table public.requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references auth.users(id),
  email text not null,
  name text not null,
  service text not null,
  urgency text not null,
  details text not null,
  status text not null default 'submitted'
    check (status in ('submitted','quoted','in_progress','delivered','declined')),
  quote_price numeric,
  quote_date date,
  admin_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.requests enable row level security;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger requests_set_updated_at
  before update on public.requests
  for each row execute function public.set_updated_at();

-- Anyone (anon or authenticated) can submit a request — this is the public wizard.
create policy "requests_insert_public"
  on public.requests for insert
  with check (true);

-- A row is visible to: its claimed client, its email owner pre-claim, or an admin.
create policy "requests_select_own_or_admin"
  on public.requests for select
  using (
    client_id = auth.uid()
    or email = (auth.jwt() ->> 'email')
    or public.is_admin()
  );

-- Only admins may update requests directly (status, quote, notes, etc).
create policy "requests_update_admin"
  on public.requests for update
  using (public.is_admin())
  with check (public.is_admin());

-- Claiming (attaching unclaimed past requests to the logged-in client) happens
-- only through this function, which touches client_id alone.
create or replace function public.claim_requests()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.requests
  set client_id = auth.uid()
  where client_id is null
    and email = (auth.jwt() ->> 'email');
end;
$$;

grant execute on function public.claim_requests() to authenticated;
