-- Studio Hiruko engine: row-level security and grants.
--
--   service_role   n8n. Full access, bypasses RLS.
--   authenticated  future dashboard users. SELECT only, and only rows whose
--                  client_id is one of theirs (via client_users).
--   anon           nothing.
--
-- "Automatically expose new tables" is off on this project, so every grant
-- is explicit here. Any new table must be added to this pattern in its own
-- migration, with RLS enabled and a client_id policy.

-- ---------------------------------------------------------------------------
-- Membership lookup. SECURITY DEFINER so policies can read client_users
-- without recursing into client_users' own policy. Lives in the private
-- schema, which the Data API does not expose.
-- ---------------------------------------------------------------------------
create or replace function private.my_client_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select cu.client_id
  from public.client_users cu
  where cu.user_id = (select auth.uid());
$$;

revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;
revoke all on function private.my_client_ids() from public, anon;
grant execute on function private.my_client_ids() to authenticated, service_role;
revoke all on function private.set_updated_at() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Enable RLS. Not FORCEd: the table owner (postgres) is used only for
-- migrations and admin work; every API role is subject to these policies.
-- ---------------------------------------------------------------------------
alter table public.clients       enable row level security;
alter table public.client_config enable row level security;
alter table public.client_users  enable row level security;
alter table public.leads         enable row level security;
alter table public.messages      enable row level security;
alter table public.bookings      enable row level security;
alter table public.events        enable row level security;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.clients, public.client_config, public.client_users,
              public.leads, public.messages, public.bookings, public.events
  from anon, authenticated;

grant select on public.clients, public.client_config, public.client_users,
                public.leads, public.messages, public.bookings, public.events
  to authenticated;

grant all on public.clients, public.client_config, public.client_users,
             public.leads, public.messages, public.bookings, public.events
  to service_role;
grant usage, select on sequence public.events_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- Policies: authenticated users read their own clients' rows only.
-- No INSERT/UPDATE/DELETE policies exist for authenticated, and no grants
-- either: clients can never change data or workflow logic.
-- ---------------------------------------------------------------------------
create policy clients_select_own on public.clients
  for select to authenticated
  using (id in (select private.my_client_ids()));

create policy client_config_select_own on public.client_config
  for select to authenticated
  using (client_id in (select private.my_client_ids()));

create policy client_users_select_self on public.client_users
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy leads_select_own on public.leads
  for select to authenticated
  using (client_id in (select private.my_client_ids()));

create policy messages_select_own on public.messages
  for select to authenticated
  using (client_id in (select private.my_client_ids()));

create policy bookings_select_own on public.bookings
  for select to authenticated
  using (client_id in (select private.my_client_ids()));

create policy events_select_own on public.events
  for select to authenticated
  using (client_id in (select private.my_client_ids()));
