-- Bee Guard — esquema principal
-- Rastreadores de colmeias com alerta de movimento, escalonamento e modo roubo.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------------

-- Apiário: local onde as caixas ficam instaladas.
create table public.colmeia_apiaries (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users (id) on delete cascade,
  name        text not null,
  created_at  timestamptz not null default now(),
  unique (owner_id, name)
);

-- Rastreador. O id é o que vai impresso no QR Code (ex.: CS-0001).
-- Nasce com status 'estoque' e passa a 'ativo' quando o apicultor faz a ativação.
create table public.colmeia_devices (
  id                 text primary key check (id ~ '^[A-Z0-9-]{3,20}$'),
  owner_id           uuid references auth.users (id) on delete set null,
  apiary_id          uuid references public.colmeia_apiaries (id) on delete set null,
  hive_label         text,
  status             text not null default 'estoque'
                     check (status in ('estoque', 'ativo', 'desativado')),
  -- 'normal' = economia de bateria; 'roubo' = envia posição em intervalo curto
  mode               text not null default 'normal' check (mode in ('normal', 'roubo')),
  primary_phone      text check (primary_phone ~ '^\+[1-9][0-9]{7,14}$'),
  secondary_phone    text check (secondary_phone ~ '^\+[1-9][0-9]{7,14}$'),
  maintenance_until  timestamptz,
  heartbeat_min      integer not null default 1440 check (heartbeat_min between 15 and 1440),
  theft_interval_s   integer not null default 60 check (theft_interval_s between 30 and 3600),
  last_seen_at       timestamptz,
  last_lat           double precision,
  last_lon           double precision,
  last_battery_mv    integer,
  last_signal        integer,
  last_seq           bigint not null default 0,
  activated_at       timestamptz,
  created_at         timestamptz not null default now()
);

-- Segredos ficam separados e nunca são expostos pela API (sem política RLS).
create table public.colmeia_device_secrets (
  device_id         text primary key references public.colmeia_devices (id) on delete cascade,
  secret            text not null,           -- chave HMAC gravada no firmware
  claim_code_hash   text not null            -- sha256 do código de ativação do QR Code
);

-- Tudo o que o rastreador envia.
create table public.colmeia_events (
  id           bigint generated always as identity primary key,
  device_id    text not null references public.colmeia_devices (id) on delete cascade,
  seq          bigint not null,
  type         text not null check (type in ('online', 'vida', 'movimento', 'posicao', 'bateria_baixa')),
  lat          double precision,
  lon          double precision,
  battery_mv   integer,
  signal       integer,
  channel      text not null default '4g' check (channel in ('4g', 'sms', 'satelite', 'teste')),
  payload      jsonb not null default '{}'::jsonb,
  received_at  timestamptz not null default now(),
  unique (device_id, seq)
);
create index colmeia_events_device_time on public.colmeia_events (device_id, received_at desc);

-- Alerta aberto por movimento, rastreador sem sinal ou bateria baixa.
create table public.colmeia_alerts (
  id              uuid primary key default gen_random_uuid(),
  device_id       text not null references public.colmeia_devices (id) on delete cascade,
  kind            text not null check (kind in ('movimento', 'offline', 'bateria_baixa')),
  status          text not null default 'pendente'
                  check (status in ('pendente', 'escalado', 'roubo_confirmado', 'manutencao', 'encerrado')),
  token           text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  opened_at       timestamptz not null default now(),
  escalate_at     timestamptz,
  escalated_at    timestamptz,
  resolved_at     timestamptz,
  resolution      text
);
create index colmeia_alerts_open on public.colmeia_alerts (device_id) where status in ('pendente', 'escalado', 'roubo_confirmado');
create index colmeia_alerts_to_escalate on public.colmeia_alerts (escalate_at) where status = 'pendente';

-- Fila de mensagens (WhatsApp / SMS). Uma função externa envia e marca o resultado.
create table public.colmeia_notifications (
  id          bigint generated always as identity primary key,
  alert_id    uuid references public.colmeia_alerts (id) on delete cascade,
  device_id   text references public.colmeia_devices (id) on delete cascade,
  to_phone    text not null,
  channel     text not null check (channel in ('whatsapp', 'sms')),
  template    text not null,
  body        text not null,
  params      jsonb not null default '{}'::jsonb,
  status      text not null default 'fila' check (status in ('fila', 'enviando', 'enviado', 'falhou', 'simulado')),
  attempts    integer not null default 0,
  error       text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index colmeia_notifications_queue on public.colmeia_notifications (created_at) where status = 'fila';

-- Configurações gerais (endereço público do site usado nos links das mensagens).
create table public.colmeia_settings (
  key    text primary key,
  value  text not null
);
insert into public.colmeia_settings (key, value) values
  ('site_url', 'https://beeguard.example'),
  ('escalation_minutes', '5'),
  ('low_battery_mv', '3450');

-- ---------------------------------------------------------------------------
-- Segurança (RLS): cada apicultor só vê o que é dele.
-- Escritas passam pelas funções abaixo, nunca direto nas tabelas.
-- ---------------------------------------------------------------------------
alter table public.colmeia_apiaries       enable row level security;
alter table public.colmeia_devices        enable row level security;
alter table public.colmeia_device_secrets enable row level security;
alter table public.colmeia_events         enable row level security;
alter table public.colmeia_alerts         enable row level security;
alter table public.colmeia_notifications  enable row level security;
alter table public.colmeia_settings       enable row level security;

create policy "dono lê apiários" on public.colmeia_apiaries
  for select to authenticated using (owner_id = auth.uid());
create policy "dono lê rastreadores" on public.colmeia_devices
  for select to authenticated using (owner_id = auth.uid());
create policy "dono lê eventos" on public.colmeia_events
  for select to authenticated
  using (exists (select 1 from public.colmeia_devices d where d.id = device_id and d.owner_id = auth.uid()));
create policy "dono lê alertas" on public.colmeia_alerts
  for select to authenticated
  using (exists (select 1 from public.colmeia_devices d where d.id = device_id and d.owner_id = auth.uid()));

revoke all on public.colmeia_device_secrets, public.colmeia_notifications, public.colmeia_settings from anon, authenticated;
revoke insert, update, delete on public.colmeia_apiaries, public.colmeia_devices, public.colmeia_events, public.colmeia_alerts from anon, authenticated;
-- O token do alerta (usado no link da mensagem) nunca é lido por select direto.
revoke select on public.colmeia_alerts from anon, authenticated;
grant select (id, device_id, kind, status, opened_at, escalate_at, escalated_at, resolved_at, resolution)
  on public.colmeia_alerts to authenticated;
