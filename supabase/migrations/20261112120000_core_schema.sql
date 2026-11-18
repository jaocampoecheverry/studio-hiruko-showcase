-- Studio Hiruko engine: core multi-tenant schema.
--
-- One Supabase project serves every client. Every row carries client_id
-- (on `clients` the id itself is the client id). Child tables reference
-- leads through a composite (client_id, lead_id) foreign key, so a row can
-- never point at another client's lead.
--
-- Access model (see the next migration for RLS):
--   * n8n uses the service_role key and bypasses RLS. It does all writes.
--   * The future client dashboard signs users in through Supabase Auth.
--     client_users maps each user to the client(s) they may READ.
--     Clients never write: logic and config stay ours (n8n licence rule 3).
--   * anon gets nothing. Enquiry forms post to n8n webhooks, not to Supabase.
--
-- No secrets in this database. API keys and OAuth tokens live in n8n
-- credentials; client_config.integrations holds identifiers only.

create extension if not exists citext with schema extensions;

-- ---------------------------------------------------------------------------
-- updated_at helper
-- ---------------------------------------------------------------------------
create schema if not exists private;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- clients: one row per studio (including the fictional demo studio)
-- ---------------------------------------------------------------------------
create table public.clients (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name         text not null,
  package      text not null check (package in ('starter', 'growth', 'full_studio')),
  status       text not null default 'onboarding'
               check (status in ('onboarding', 'active', 'paused', 'churned')),
  is_demo      boolean not null default false,
  is_founding  boolean not null default false,
  timezone     text not null default 'Europe/London',
  launched_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.clients is 'One row per client studio. id is the tenant key (client_id elsewhere).';

-- ---------------------------------------------------------------------------
-- client_config: the single per-client personalisation record
-- ---------------------------------------------------------------------------
create table public.client_config (
  client_id             uuid primary key references public.clients (id) on delete cascade,

  -- Brand and voice
  brand                 jsonb not null default '{}'::jsonb,  -- logo_url, colours, fonts
  brand_voice_prompt    text,
  qualifying_rules      jsonb not null default '{}'::jsonb,  -- min budget, areas, project types, weights

  -- Modules (Report is in every package)
  module_capture        boolean not null default true,
  module_qualify        boolean not null default true,
  module_book           boolean not null default true,
  module_nurture        boolean not null default false,
  module_retain         boolean not null default false,
  module_report         boolean not null default true check (module_report),

  -- Replies: approval mode for the first 30 days, then auto-send.
  -- Effective mode is 'approval' while reply_mode = 'approval'
  -- OR current_date < approval_until.
  reply_mode            text not null default 'approval' check (reply_mode in ('approval', 'auto')),
  approval_until        date,

  -- Email and links
  notify_email          extensions.citext,  -- where drafts and alerts go at the studio
  reply_from_name       text,
  reply_from_email      extensions.citext,  -- on the client's own domain, verified in Resend
  booking_url           text,               -- Cal.com event link
  review_url            text,               -- Google review link (Retain)

  -- Identifiers only, never secrets (e.g. Cal.com event type id, Resend domain id)
  integrations          jsonb not null default '{}'::jsonb,

  -- Fair-use cap on AI-generated messages per calendar month
  monthly_ai_message_cap integer not null default 500 check (monthly_ai_message_cap >= 0),

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table public.client_config is 'Per-client config read by every shared n8n workflow. Written by Studio Hiruko only.';
comment on column public.client_config.integrations is 'Identifiers only. Never store API keys or tokens here; they live in n8n credentials.';

-- ---------------------------------------------------------------------------
-- client_users: which Supabase Auth users may read which client (dashboard)
-- ---------------------------------------------------------------------------
create table public.client_users (
  client_id   uuid not null references public.clients (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        text not null default 'viewer' check (role in ('owner', 'viewer')),
  created_at  timestamptz not null default now(),
  primary key (client_id, user_id)
);

create index client_users_user_id_idx on public.client_users (user_id);

-- ---------------------------------------------------------------------------
-- leads: every enquiry, from any channel
-- ---------------------------------------------------------------------------
create table public.leads (
  id                 uuid primary key default gen_random_uuid(),
  client_id          uuid not null references public.clients (id) on delete cascade,

  source             text not null check (source in ('web_form', 'email', 'instagram', 'whatsapp', 'manual')),
  external_ref       text,  -- e.g. email Message-ID or form submission id, for de-duplication
  status             text not null default 'new'
                     check (status in ('new', 'qualified', 'unqualified', 'spam',
                                       'booked', 'nurturing', 'won', 'lost')),

  name               text,
  email              extensions.citext,
  phone              text,
  company            text,
  project_type       text,
  location           text,
  budget_text        text,           -- as the lead wrote it
  budget_min_gbp     integer check (budget_min_gbp >= 0),
  timeline           text,
  message            text,
  raw                jsonb not null default '{}'::jsonb,  -- original payload

  score              smallint check (score between 0 and 100),
  score_reasons      jsonb,
  scored_at          timestamptz,

  first_response_at  timestamptz,  -- for response-time reporting
  won_value_gbp      numeric(12, 2) check (won_value_gbp >= 0),
  won_at             timestamptz,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  unique (client_id, id)  -- target for composite foreign keys
);

create unique index leads_dedupe_idx
  on public.leads (client_id, source, external_ref)
  where external_ref is not null;
create index leads_client_created_idx on public.leads (client_id, created_at desc);
create index leads_client_status_idx  on public.leads (client_id, status);

-- ---------------------------------------------------------------------------
-- messages: inbound enquiries and outbound replies, follow-ups, reminders
-- ---------------------------------------------------------------------------
create table public.messages (
  id                   uuid primary key default gen_random_uuid(),
  client_id            uuid not null,
  lead_id              uuid not null,

  direction            text not null check (direction in ('inbound', 'outbound')),
  channel              text not null check (channel in ('email', 'web_form', 'whatsapp', 'instagram')),
  kind                 text not null default 'reply'
                       check (kind in ('enquiry', 'reply', 'follow_up', 'reminder', 'review_request', 'other')),
  status               text not null
                       check (status in ('received', 'draft', 'pending_approval', 'approved',
                                         'rejected', 'scheduled', 'sent', 'failed')),

  subject              text,
  body                 text not null,
  ai_generated         boolean not null default false,
  model                text,

  scheduled_for        timestamptz,
  approved_at          timestamptz,
  sent_at              timestamptz,
  provider_message_id  text,  -- Resend id or WhatsApp message id
  error                text,

  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  foreign key (client_id, lead_id) references public.leads (client_id, id) on delete cascade
);

create index messages_client_lead_idx    on public.messages (client_id, lead_id, created_at);
create index messages_client_status_idx  on public.messages (client_id, status);
create index messages_scheduled_idx      on public.messages (scheduled_for)
  where status = 'scheduled';

-- ---------------------------------------------------------------------------
-- bookings: Cal.com bookings tied to a lead
-- ---------------------------------------------------------------------------
create table public.bookings (
  id                   uuid primary key default gen_random_uuid(),
  client_id            uuid not null,
  lead_id              uuid not null,

  provider             text not null default 'calcom' check (provider in ('calcom', 'manual')),
  provider_booking_id  text,
  status               text not null default 'scheduled'
                       check (status in ('scheduled', 'rescheduled', 'cancelled', 'completed', 'no_show')),
  starts_at            timestamptz not null,
  ends_at              timestamptz,

  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  check (ends_at is null or ends_at > starts_at),
  foreign key (client_id, lead_id) references public.leads (client_id, id) on delete cascade
);

create unique index bookings_provider_idx
  on public.bookings (client_id, provider, provider_booking_id)
  where provider_booking_id is not null;
create index bookings_client_starts_idx on public.bookings (client_id, starts_at);

-- ---------------------------------------------------------------------------
-- events: append-only log for reporting and debugging
-- ---------------------------------------------------------------------------
create table public.events (
  id           bigint generated always as identity primary key,
  client_id    uuid not null references public.clients (id) on delete cascade,
  lead_id      uuid,  -- optional; if set it must belong to the same client
  type         text not null check (type ~ '^[a-z_]+(\.[a-z_]+)+$'),  -- e.g. lead.created, reply.sent, workflow.failed
  payload      jsonb not null default '{}'::jsonb,
  occurred_at  timestamptz not null default now(),

  foreign key (client_id, lead_id) references public.leads (client_id, id) on delete cascade
);

create index events_client_occurred_idx on public.events (client_id, occurred_at desc);
create index events_client_type_idx     on public.events (client_id, type, occurred_at desc);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------
create trigger clients_set_updated_at       before update on public.clients
  for each row execute function private.set_updated_at();
create trigger client_config_set_updated_at before update on public.client_config
  for each row execute function private.set_updated_at();
create trigger leads_set_updated_at         before update on public.leads
  for each row execute function private.set_updated_at();
create trigger messages_set_updated_at      before update on public.messages
  for each row execute function private.set_updated_at();
create trigger bookings_set_updated_at      before update on public.bookings
  for each row execute function private.set_updated_at();
