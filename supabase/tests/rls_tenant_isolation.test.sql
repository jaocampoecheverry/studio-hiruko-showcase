-- RLS tenant isolation test: client A's users can never see or change
-- client B's data, anon sees nothing, and cross-tenant links are rejected.
--
-- Runs inside a transaction and rolls back, so it leaves no data behind.
-- Run with:   supabase test db --linked
-- or paste the whole file into the Supabase SQL Editor (results show as rows).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

-- ---------------------------------------------------------------------------
-- Fixtures (as the migration owner, which bypasses RLS)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000a1', 'user-a@test.invalid'),
  ('00000000-0000-4000-8000-0000000000b1', 'user-b@test.invalid'),
  ('00000000-0000-4000-8000-0000000000c1', 'nobody@test.invalid');

insert into public.clients (id, slug, name, package) values
  ('00000000-0000-4000-8000-00000000000a', 'test-studio-a', 'Test Studio A', 'growth'),
  ('00000000-0000-4000-8000-00000000000b', 'test-studio-b', 'Test Studio B', 'starter');

insert into public.client_config (client_id) values
  ('00000000-0000-4000-8000-00000000000a'),
  ('00000000-0000-4000-8000-00000000000b');

insert into public.client_users (client_id, user_id) values
  ('00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-0000000000a1'),
  ('00000000-0000-4000-8000-00000000000b', '00000000-0000-4000-8000-0000000000b1');

insert into public.leads (id, client_id, source, name, email) values
  ('00000000-0000-4000-8000-0000000001a0', '00000000-0000-4000-8000-00000000000a', 'web_form', 'Lead A', 'lead-a@test.invalid'),
  ('00000000-0000-4000-8000-0000000001b0', '00000000-0000-4000-8000-00000000000b', 'email',    'Lead B', 'lead-b@test.invalid');

insert into public.messages (client_id, lead_id, direction, channel, kind, status, body) values
  ('00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-0000000001a0', 'inbound', 'web_form', 'enquiry', 'received', 'Hello from A'),
  ('00000000-0000-4000-8000-00000000000b', '00000000-0000-4000-8000-0000000001b0', 'inbound', 'email',    'enquiry', 'received', 'Hello from B');

insert into public.bookings (client_id, lead_id, starts_at) values
  ('00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-0000000001a0', now() + interval '2 days'),
  ('00000000-0000-4000-8000-00000000000b', '00000000-0000-4000-8000-0000000001b0', now() + interval '3 days');

insert into public.events (client_id, lead_id, type) values
  ('00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-0000000001a0', 'lead.created'),
  ('00000000-0000-4000-8000-00000000000b', '00000000-0000-4000-8000-0000000001b0', 'lead.created');

-- ---------------------------------------------------------------------------
-- As user A: sees only client A, can change nothing
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
set local role authenticated;

select results_eq('select id from public.clients',
  $$values ('00000000-0000-4000-8000-00000000000a'::uuid)$$,
  'user A sees only client A');
select results_eq('select client_id from public.client_config',
  $$values ('00000000-0000-4000-8000-00000000000a'::uuid)$$,
  'user A sees only client A config');
select results_eq('select client_id from public.client_users',
  $$values ('00000000-0000-4000-8000-00000000000a'::uuid)$$,
  'user A sees only their own membership');
select results_eq('select client_id from public.leads',
  $$values ('00000000-0000-4000-8000-00000000000a'::uuid)$$,
  'user A sees only client A leads');
select results_eq('select client_id from public.messages',
  $$values ('00000000-0000-4000-8000-00000000000a'::uuid)$$,
  'user A sees only client A messages');
select results_eq('select client_id from public.bookings',
  $$values ('00000000-0000-4000-8000-00000000000a'::uuid)$$,
  'user A sees only client A bookings');
select results_eq('select client_id from public.events',
  $$values ('00000000-0000-4000-8000-00000000000a'::uuid)$$,
  'user A sees only client A events');
select is_empty($$select 1 from public.leads where id = '00000000-0000-4000-8000-0000000001b0'$$,
  'user A cannot fetch client B lead by id');

select throws_ok($$insert into public.leads (client_id, source) values ('00000000-0000-4000-8000-00000000000a', 'manual')$$,
  '42501', null, 'user A cannot insert leads');
select throws_ok($$update public.client_config set reply_mode = 'auto'$$,
  '42501', null, 'user A cannot change config (workflow logic stays ours)');
select throws_ok($$delete from public.leads$$,
  '42501', null, 'user A cannot delete leads');

-- ---------------------------------------------------------------------------
-- As user B: mirror check
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-0000000000b1","role":"authenticated"}', true);
set local role authenticated;

select results_eq('select client_id from public.leads',
  $$values ('00000000-0000-4000-8000-00000000000b'::uuid)$$,
  'user B sees only client B leads');

-- ---------------------------------------------------------------------------
-- Signed-in user with no membership: sees nothing
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-0000000000c1","role":"authenticated"}', true);
set local role authenticated;

select is_empty('select 1 from public.leads', 'user with no client sees no leads');
select is_empty('select 1 from public.clients', 'user with no client sees no clients');

-- ---------------------------------------------------------------------------
-- anon: no access at all
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;

select throws_ok('select 1 from public.leads', '42501', null, 'anon cannot read leads');

-- ---------------------------------------------------------------------------
-- service_role (n8n): full access
-- ---------------------------------------------------------------------------
reset role;
set local role service_role;

select lives_ok($$insert into public.leads (client_id, source, name) values ('00000000-0000-4000-8000-00000000000b', 'manual', 'From n8n')$$,
  'service_role can insert leads for any client');

-- ---------------------------------------------------------------------------
-- Integrity: cross-tenant links and Report-always-on
-- ---------------------------------------------------------------------------
reset role;

select throws_ok($$insert into public.messages (client_id, lead_id, direction, channel, status, body)
                   values ('00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-0000000001b0',
                           'outbound', 'email', 'draft', 'cross-tenant')$$,
  '23503', null, 'a message cannot link client A to client B''s lead');
select throws_ok($$update public.client_config set module_report = false
                   where client_id = '00000000-0000-4000-8000-00000000000a'$$,
  '23514', null, 'Report module cannot be switched off');

select * from finish();
rollback;
