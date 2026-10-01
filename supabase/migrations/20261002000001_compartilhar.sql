-- Bee Guard — link de visualização do apiário (só leitura, sem login).
-- Mostra caixas, balança e produção de mel. NUNCA mostra a localização (GPS) das caixas,
-- porque o link pode ser repassado. Vale 90 dias.

create table public.colmeia_share_links (
  token       text primary key default encode(extensions.gen_random_bytes(16), 'hex'),
  owner_id    uuid not null references auth.users (id) on delete cascade,
  apiary_id   uuid not null references public.colmeia_apiaries (id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '90 days'
);
alter table public.colmeia_share_links enable row level security;
revoke all on public.colmeia_share_links from anon, authenticated;

-- Gera (ou reaproveita) o link de um apiário do apicultor logado.
create or replace function public.colmeia_create_share_link(p_apiary_id uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  t   text;
begin
  if not exists (select 1 from public.colmeia_apiaries where id = p_apiary_id and owner_id = uid) then
    raise exception 'apiário não encontrado' using errcode = 'P0002';
  end if;
  select token into t from public.colmeia_share_links
  where apiary_id = p_apiary_id and owner_id = uid and expires_at > now() + interval '30 days'
  order by created_at desc limit 1;
  if t is null then
    insert into public.colmeia_share_links (owner_id, apiary_id) values (uid, p_apiary_id) returning token into t;
  end if;
  return t;
end $$;

-- Dados da página ver.html. Sem coordenadas, sem telefones, sem códigos.
create or replace function public.colmeia_shared_view(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l public.colmeia_share_links;
begin
  select * into l from public.colmeia_share_links where token = p_token and expires_at > now();
  if not found then
    raise exception 'link inválido ou expirado' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'apiario', (select jsonb_build_object('id', a.id, 'name', a.name) from public.colmeia_apiaries a where a.id = l.apiary_id),
    'devices', coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'hive_label', d.hive_label, 'apiary_id', d.apiary_id, 'mode', d.mode,
        'maintenance_until', d.maintenance_until, 'last_seen_at', d.last_seen_at, 'last_battery_mv', d.last_battery_mv,
        'last_scale_raw', d.last_scale_raw, 'last_scale_raw_at', d.last_scale_raw_at, 'scale_factor', d.scale_factor,
        'last_weight_kg', d.last_weight_kg, 'harvest_base_kg', d.harvest_base_kg, 'harvest_base_at', d.harvest_base_at,
        'harvest_gain_kg', d.harvest_gain_kg) order by d.id)
      from public.colmeia_devices d where d.apiary_id = l.apiary_id and d.status = 'ativo'), '[]'::jsonb),
    'alertas', coalesce((select jsonb_agg(jsonb_build_object('device_id', a.device_id, 'kind', a.kind, 'status', a.status))
      from public.colmeia_alerts a join public.colmeia_devices d on d.id = a.device_id
      where d.apiary_id = l.apiary_id and a.status in ('pendente', 'escalado', 'roubo_confirmado')), '[]'::jsonb),
    'pesos', coalesce((select jsonb_agg(jsonb_build_object('device_id', w.device_id, 'measured_at', w.measured_at, 'kg', w.kg)
        order by w.measured_at)
      from public.colmeia_weights w join public.colmeia_devices d on d.id = w.device_id
      where d.apiary_id = l.apiary_id and w.kg is not null and w.measured_at > now() - interval '14 days'), '[]'::jsonb),
    'colheitas', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'apiary_id', h.apiary_id, 'device_id', h.device_id,
        'harvested_on', h.harvested_on, 'kg', h.kg, 'source', h.source, 'note', h.note) order by h.harvested_on desc)
      from public.colmeia_harvests h where h.apiary_id = l.apiary_id), '[]'::jsonb)
  );
end $$;

-- Link da página de alerta (mapa do trajeto) do alerta de movimento aberto, para o dono.
create or replace function public.colmeia_open_alert_token(p_device_id text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  t text;
begin
  select a.token into t
  from public.colmeia_alerts a join public.colmeia_devices d on d.id = a.device_id
  where a.device_id = p_device_id and d.owner_id = auth.uid() and a.kind = 'movimento'
    and a.status in ('pendente', 'escalado', 'roubo_confirmado')
  order by a.opened_at desc limit 1;
  if t is null then
    raise exception 'Nenhum alerta aberto para esta caixa.' using errcode = 'P0002';
  end if;
  return t;
end $$;

revoke execute on function public.colmeia_open_alert_token(text) from public, anon, authenticated;
grant execute on function public.colmeia_open_alert_token(text) to authenticated;

revoke execute on function public.colmeia_create_share_link(uuid), public.colmeia_shared_view(text)
  from public, anon, authenticated;
grant execute on function public.colmeia_create_share_link(uuid) to authenticated;
grant execute on function public.colmeia_shared_view(text) to anon, authenticated;
