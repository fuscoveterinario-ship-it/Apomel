-- Bee Guard — balança (colmeia sentinela)
-- A placa pesa a caixa a cada 3 h e manda as pesagens 1 vez por dia. A plataforma
-- converte em kg (calibração feita pelo painel) e avisa: hora da colheita, peso baixo
-- (falta de alimento) e queda brusca durante o dia (possível enxameação).
-- No alerta de movimento, mostra o peso antes e na hora (caixa tirada da balança).

-- ---------------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------------
alter table public.colmeia_devices
  add column scale_offset        double precision,   -- valor bruto com a balança vazia
  add column scale_factor        double precision,   -- valor bruto por kg (pode ser negativo)
  add column last_scale_raw      integer,
  add column last_scale_raw_at   timestamptz,
  add column last_weight_kg      numeric(6,2),
  add column last_weight_at      timestamptz,
  add column harvest_gain_kg     numeric(5,1) not null default 15 check (harvest_gain_kg between 1 and 100),
  add column harvest_base_at     timestamptz,        -- quando a melgueira foi colocada
  add column harvest_base_kg     numeric(6,2),       -- primeira pesagem depois disso
  add column harvest_notified_at timestamptz,
  add column hunger_kg           numeric(5,1) check (hunger_kg between 1 and 200);

create table public.colmeia_weights (
  id           bigint generated always as identity primary key,
  device_id    text not null references public.colmeia_devices (id) on delete cascade,
  measured_at  timestamptz not null,
  raw          integer not null,
  kg           numeric(6,2),          -- vazio enquanto a balança não foi calibrada
  received_at  timestamptz not null default now()
);
create index colmeia_weights_device_time on public.colmeia_weights (device_id, measured_at desc);

alter table public.colmeia_weights enable row level security;
create policy "dono lê pesagens" on public.colmeia_weights
  for select to authenticated
  using (exists (select 1 from public.colmeia_devices d where d.id = device_id and d.owner_id = auth.uid()));
revoke insert, update, delete on public.colmeia_weights from anon, authenticated;

alter table public.colmeia_alerts drop constraint colmeia_alerts_kind_check;
alter table public.colmeia_alerts add constraint colmeia_alerts_kind_check
  check (kind in ('movimento', 'offline', 'bateria_baixa', 'colheita', 'peso_baixo', 'enxame'));

insert into public.colmeia_settings (key, value) values ('swarm_drop_kg', '1.5')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Auxiliares
-- ---------------------------------------------------------------------------
create or replace function public.colmeia_raw_to_kg(p_raw integer, p_offset double precision, p_factor double precision)
returns numeric language sql immutable set search_path = public as $$
  select case when p_raw is null or p_offset is null or p_factor is null or p_factor = 0 then null
              else round(greatest(-9999, least(9999, (p_raw - p_offset) / p_factor))::numeric, 2) end
$$;

-- 12.345 → "12,3"
create or replace function public.colmeia_fmt_kg(p_kg numeric)
returns text language sql immutable set search_path = public as $$
  select replace(round(p_kg, 1)::text, '.', ',')
$$;

create or replace function public.colmeia_render_message(p_template text, p_params jsonb)
returns text language plpgsql immutable set search_path = public as $$
declare
  caixa   text := coalesce(p_params->>'caixa', 'caixa');
  apiario text := coalesce(p_params->>'apiario', 'apiário');
  link    text := coalesce(p_params->>'link', '');
  hora    text := coalesce(p_params->>'hora', '');
  kg      text := coalesce(p_params->>'kg', '');
begin
  return case p_template
    when 'alerta_movimento' then
      format('ALERTA BEE GUARD: a %s foi movimentada no %s. Foi você fazendo manutenção? Responda em até 5 minutos: %s', caixa, apiario, link)
    when 'alerta_escalado' then
      format('ALERTA BEE GUARD: a %s (%s) foi movimentada e ninguém confirmou em 5 minutos. POSSÍVEL ROUBO. Rastreamento intensivo ativado. Mapa: %s', caixa, apiario, link)
    when 'roubo_confirmado' then
      format('ALERTA BEE GUARD: ROUBO CONFIRMADO da %s (%s). Rastreamento intensivo ativado. Mapa: %s', caixa, apiario, link)
    when 'offline' then
      format('AVISO BEE GUARD: o rastreador da %s (%s) está sem comunicação desde %s. Verifique: %s', caixa, apiario, hora, link)
    when 'bateria_baixa' then
      format('AVISO BEE GUARD: bateria baixa no rastreador da %s (%s). Recarregue em breve: %s', caixa, apiario, link)
    when 'colheita' then
      format('BEE GUARD: a %s (%s) ganhou %s kg desde que a melgueira foi colocada. Pode estar na hora da colheita. Veja: %s', caixa, apiario, kg, link)
    when 'peso_baixo' then
      format('AVISO BEE GUARD: a %s (%s) está com %s kg, abaixo do limite que você definiu. Pode estar faltando alimento. Veja: %s', caixa, apiario, kg, link)
    when 'enxame' then
      format('AVISO BEE GUARD: a %s (%s) perdeu %s kg de repente perto das %s. Pode ter enxameado. Veja: %s', caixa, apiario, kg, hora, link)
    else format('BEE GUARD: aviso sobre a %s (%s): %s', caixa, apiario, link)
  end;
end $$;

-- Agora aceita parâmetros extras (kg, hora, link próprio) para os avisos da balança.
drop function public.colmeia_enqueue_alert_messages(uuid, text, text);
create function public.colmeia_enqueue_alert_messages(p_alert_id uuid, p_phone text, p_template text,
                                                      p_extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  a public.colmeia_alerts;
  d public.colmeia_devices;
  params jsonb;
begin
  if p_phone is null then return; end if;
  select * into a from public.colmeia_alerts where id = p_alert_id;
  select * into d from public.colmeia_devices where id = a.device_id;
  params := jsonb_build_object(
    'caixa',   coalesce(d.hive_label, d.id),
    'apiario', coalesce((select name from public.colmeia_apiaries where id = d.apiary_id), 'apiário'),
    'link',    public.colmeia_setting('site_url') || '/alerta.html?t=' || a.token,
    'hora',    to_char(d.last_seen_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
  ) || coalesce(p_extra, '{}'::jsonb);
  insert into public.colmeia_notifications (alert_id, device_id, to_phone, channel, template, body, params)
  select a.id, d.id, p_phone, ch, p_template, public.colmeia_render_message(p_template, params), params
  from unnest(array['whatsapp', 'sms']) as ch;
end $$;

-- Atualiza "último peso" do rastreador a partir da pesagem mais recente.
create or replace function public.colmeia_refresh_last_weight(p_device_id text)
returns void language sql security definer set search_path = public as $$
  update public.colmeia_devices dv
  set (last_scale_raw, last_scale_raw_at, last_weight_kg, last_weight_at) =
      (select w.raw, w.measured_at, w.kg, w.measured_at from public.colmeia_weights w
       where w.device_id = dv.id order by w.measured_at desc limit 1)
  where dv.id = p_device_id
$$;

-- ---------------------------------------------------------------------------
-- Pesagens recebidas: "ws" = [[segundos atrás, valor bruto], ...]
-- ---------------------------------------------------------------------------
create or replace function public.colmeia_record_weights(p_device_id text, p_ws jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  d public.colmeia_devices;
  r record;
  n integer := 0;
begin
  if jsonb_typeof(p_ws) is distinct from 'array' then return 0; end if;
  select * into d from public.colmeia_devices where id = p_device_id;
  for r in
    select now() - make_interval(secs => (x->>0)::integer) as at, (x->>1)::integer as raw
    from jsonb_array_elements(p_ws) x
    where jsonb_typeof(x) = 'array' and jsonb_array_length(x) = 2
      and jsonb_typeof(x->0) = 'number' and jsonb_typeof(x->1) = 'number'
  loop
    -- Mesma pesagem reenviada (resposta perdida no caminho): ignora.
    continue when exists (select 1 from public.colmeia_weights w
                          where w.device_id = d.id and w.raw = r.raw
                            and w.measured_at between r.at - interval '3 minutes' and r.at + interval '3 minutes');
    insert into public.colmeia_weights (device_id, measured_at, raw, kg)
    values (d.id, r.at, r.raw, public.colmeia_raw_to_kg(r.raw, d.scale_offset, d.scale_factor));
    n := n + 1;
  end loop;
  if n > 0 then perform public.colmeia_refresh_last_weight(d.id); end if;
  return n;
end $$;

-- Avisos da balança (só para rastreador ativo e balança calibrada).
create or replace function public.colmeia_check_weight_alerts(p_device_id text)
returns void language plpgsql security definer set search_path = public as $$
declare
  d        public.colmeia_devices;
  lo       numeric;
  hi       numeric;
  n        integer;
  s        record;
  alert_id uuid;
  drop_min numeric := coalesce(public.colmeia_setting('swarm_drop_kg'), '1.5')::numeric;
  panel    jsonb := jsonb_build_object('link', public.colmeia_setting('site_url') || '/painel.html');
begin
  select * into d from public.colmeia_devices where id = p_device_id for update;
  if d.status <> 'ativo' or d.scale_factor is null then return; end if;

  -- Melgueira colocada: o peso de referência é a primeira pesagem 30 min depois
  -- (assim a melgueira vazia não conta como mel).
  if d.harvest_base_at is not null and d.harvest_base_kg is null then
    update public.colmeia_devices set harvest_base_kg = (
      select w.kg from public.colmeia_weights w
      where w.device_id = d.id and w.kg is not null and w.measured_at >= d.harvest_base_at + interval '30 minutes'
      order by w.measured_at limit 1)
    where id = d.id returning * into d;
  end if;

  -- Últimas 2 pesagens: o aviso só sai quando as duas concordam (evita leitura solta).
  select min(kg), max(kg), count(*) into lo, hi, n from (
    select w.kg from public.colmeia_weights w
    where w.device_id = d.id and w.kg is not null
    order by w.measured_at desc limit 2) t;
  if n < 2 then return; end if;

  -- 1) Hora da colheita: ganhou o peso combinado desde que a melgueira foi colocada.
  if d.harvest_base_kg is not null and d.harvest_notified_at is null
     and lo >= d.harvest_base_kg + d.harvest_gain_kg then
    insert into public.colmeia_alerts (device_id, kind, status, resolved_at, resolution)
    values (d.id, 'colheita', 'encerrado', now(), 'aviso enviado') returning id into alert_id;
    update public.colmeia_devices set harvest_notified_at = now() where id = d.id;
    perform public.colmeia_enqueue_alert_messages(alert_id, d.primary_phone, 'colheita',
      panel || jsonb_build_object('kg', public.colmeia_fmt_kg(lo - d.harvest_base_kg)));
  end if;

  -- 2) Peso baixo (fome): no máximo um aviso por semana.
  if d.hunger_kg is not null and hi < d.hunger_kg
     and not exists (select 1 from public.colmeia_alerts
                     where device_id = d.id and kind = 'peso_baixo' and opened_at > now() - interval '7 days') then
    insert into public.colmeia_alerts (device_id, kind, status, resolved_at, resolution)
    values (d.id, 'peso_baixo', 'encerrado', now(), 'aviso enviado') returning id into alert_id;
    perform public.colmeia_enqueue_alert_messages(alert_id, d.primary_phone, 'peso_baixo',
      panel || jsonb_build_object('kg', public.colmeia_fmt_kg(hi)));
  end if;

  -- 3) Possível enxameação: queda de 1,5 a 5 kg entre duas pesagens seguidas durante o dia,
  --    sem manutenção nem alerta de movimento no período (colheita tira bem mais que 5 kg).
  select * into s from (
    select w.measured_at, w.kg, lag(w.kg) over win as prev_kg, lag(w.measured_at) over win as prev_at
    from public.colmeia_weights w
    where w.device_id = d.id and w.kg is not null and w.measured_at > now() - interval '30 hours'
    window win as (order by w.measured_at)) t
  where t.prev_kg - t.kg between drop_min and 5
    and t.measured_at - t.prev_at <= interval '4 hours 30 minutes'
    and extract(hour from t.measured_at at time zone 'America/Sao_Paulo') between 10 and 18
    and (d.maintenance_until is null or d.maintenance_until < t.prev_at)
    and not exists (select 1 from public.colmeia_alerts a
                    where a.device_id = d.id and a.kind = 'movimento'
                      and a.opened_at between t.prev_at - interval '1 hour' and t.measured_at)
  order by t.measured_at desc limit 1;
  if found and not exists (select 1 from public.colmeia_alerts
                           where device_id = d.id and kind = 'enxame' and opened_at > now() - interval '3 days') then
    insert into public.colmeia_alerts (device_id, kind, status, resolved_at, resolution)
    values (d.id, 'enxame', 'encerrado', now(), 'aviso enviado') returning id into alert_id;
    perform public.colmeia_enqueue_alert_messages(alert_id, d.primary_phone, 'enxame',
      panel || jsonb_build_object('kg', public.colmeia_fmt_kg(s.prev_kg - s.kg),
                                  'hora', to_char(s.measured_at at time zone 'America/Sao_Paulo', 'HH24:MI')));
  end if;
end $$;

create or replace function public.colmeia_ingest_event(
  p_device_id  text,
  p_seq        bigint,
  p_type       text,
  p_lat        double precision default null,
  p_lon        double precision default null,
  p_battery_mv integer default null,
  p_signal     integer default null,
  p_channel    text default '4g',
  p_payload    jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d        public.colmeia_devices;
  alert_id uuid;
  low_mv   integer := public.colmeia_setting('low_battery_mv')::integer;
  weighed  boolean := false;
begin
  select * into d from public.colmeia_devices where id = p_device_id for update;
  if not found then
    raise exception 'rastreador desconhecido: %', p_device_id using errcode = 'P0002';
  end if;

  -- Reenvio da mesma mensagem (ou mensagem antiga): não processa de novo.
  if p_seq <= d.last_seq then
    return public.colmeia_device_config(d, d.last_seq) || jsonb_build_object('duplicate', true);
  end if;

  insert into public.colmeia_events (device_id, seq, type, lat, lon, battery_mv, signal, channel, payload)
  values (p_device_id, p_seq, p_type, p_lat, p_lon, p_battery_mv, p_signal, p_channel, coalesce(p_payload, '{}'::jsonb));

  update public.colmeia_devices set
    last_seq        = p_seq,
    last_seen_at    = now(),
    last_lat        = coalesce(p_lat, last_lat),
    last_lon        = coalesce(p_lon, last_lon),
    last_battery_mv = coalesce(p_battery_mv, last_battery_mv),
    last_signal     = coalesce(p_signal, last_signal)
  where id = p_device_id
  returning * into d;

  -- Pesagens da balança (também antes da ativação: servem para a calibração na bancada).
  if p_payload ? 'ws' then
    weighed := public.colmeia_record_weights(d.id, p_payload->'ws') > 0;
  end if;

  if d.status <> 'ativo' then
    return public.colmeia_device_config(d, p_seq);
  end if;

  if weighed then
    perform public.colmeia_check_weight_alerts(d.id);
  end if;

  -- Voltou a comunicar: encerra aviso de "sem comunicação".
  update public.colmeia_alerts set status = 'encerrado', resolved_at = now(), resolution = 'voltou a comunicar'
  where device_id = d.id and kind = 'offline' and status = 'pendente';

  -- Movimento: pergunta primeiro ao responsável principal.
  if p_type = 'movimento'
     and not coalesce(d.maintenance_until > now(), false)
     and not exists (select 1 from public.colmeia_alerts
                     where device_id = d.id and kind = 'movimento'
                       and status in ('pendente', 'escalado', 'roubo_confirmado')) then
    insert into public.colmeia_alerts (device_id, kind, escalate_at)
    values (d.id, 'movimento', now() + make_interval(mins => public.colmeia_setting('escalation_minutes')::integer))
    returning id into alert_id;
    perform public.colmeia_enqueue_alert_messages(alert_id, d.primary_phone, 'alerta_movimento');
  end if;

  -- Bateria baixa: no máximo um aviso por dia.
  if (p_type = 'bateria_baixa' or p_battery_mv < low_mv)
     and not exists (select 1 from public.colmeia_alerts
                     where device_id = d.id and kind = 'bateria_baixa'
                       and opened_at > now() - interval '24 hours') then
    insert into public.colmeia_alerts (device_id, kind, status, resolved_at, resolution)
    values (d.id, 'bateria_baixa', 'encerrado', now(), 'aviso enviado')
    returning id into alert_id;
    perform public.colmeia_enqueue_alert_messages(alert_id, d.primary_phone, 'bateria_baixa');
  end if;

  return public.colmeia_device_config(d, p_seq);
end $$;

create or replace function public.colmeia_respond_alert(p_token text, p_action text default 'ver')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a public.colmeia_alerts;
  d public.colmeia_devices;
begin
  select * into a from public.colmeia_alerts
  where token = p_token and opened_at > now() - interval '7 days'
  for update;
  if not found then
    raise exception 'link inválido ou expirado' using errcode = 'P0002';
  end if;

  if p_action = 'manutencao' and a.kind = 'movimento'
     and a.status in ('pendente', 'escalado', 'roubo_confirmado') then
    update public.colmeia_alerts set status = 'manutencao', resolved_at = now(),
      resolution = 'responsável confirmou manutenção'
    where id = a.id returning * into a;
    -- Evita novo alerta enquanto o apicultor ainda está mexendo nas caixas.
    update public.colmeia_devices set mode = 'normal', maintenance_until = now() + interval '2 hours'
    where id = a.device_id;

  elsif p_action = 'roubo' and a.kind = 'movimento'
        and a.status in ('pendente', 'escalado') then
    update public.colmeia_alerts set status = 'roubo_confirmado', resolved_at = null,
      resolution = 'responsável confirmou possível roubo'
    where id = a.id returning * into a;
    update public.colmeia_devices set mode = 'roubo' where id = a.device_id;
    perform public.colmeia_enqueue_alert_messages(a.id, (select secondary_phone from public.colmeia_devices where id = a.device_id), 'roubo_confirmado');

  elsif p_action not in ('ver', 'manutencao', 'roubo') then
    raise exception 'ação inválida: %', p_action using errcode = '22023';
  end if;

  select * into d from public.colmeia_devices where id = a.device_id;

  return jsonb_build_object(
    'alert', jsonb_build_object('kind', a.kind, 'status', a.status, 'opened_at', a.opened_at,
                                'escalate_at', a.escalate_at, 'resolution', a.resolution),
    'device', jsonb_build_object(
      'id', d.id, 'caixa', coalesce(d.hive_label, d.id),
      'apiario', (select name from public.colmeia_apiaries where id = d.apiary_id),
      'mode', d.mode, 'last_seen_at', d.last_seen_at,
      'lat', d.last_lat, 'lon', d.last_lon, 'battery_mv', d.last_battery_mv),
    -- Balança: peso antes do alerta e na hora (perto de zero = caixa tirada da balança).
    'balanca', case when d.scale_factor is null then null else jsonb_build_object(
      'antes', (select w.kg from public.colmeia_weights w
                where w.device_id = d.id and w.measured_at < a.opened_at
                order by w.measured_at desc limit 1),
      'no_alerta', (select public.colmeia_raw_to_kg((e.payload->>'w')::integer, d.scale_offset, d.scale_factor)
                    from public.colmeia_events e
                    where e.device_id = d.id and e.type = 'movimento' and e.payload ? 'w'
                      and e.received_at between a.opened_at - interval '2 minutes' and a.opened_at + interval '2 minutes'
                    order by e.received_at limit 1)) end,
    'track', coalesce((
      select jsonb_agg(jsonb_build_object('lat', e.lat, 'lon', e.lon, 'at', e.received_at) order by e.received_at)
      from (select * from public.colmeia_events
            where device_id = d.id and lat is not null and received_at >= a.opened_at - interval '1 hour'
            order by received_at desc limit 200) e
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- Painel: calibração e ajustes da balança (apicultor logado, só no que é dele)
-- ---------------------------------------------------------------------------
-- p_step 'zero': balança vazia. 'peso': com um peso conhecido de p_kg em cima.
-- Usa a pesagem mais recente (a placa pesa e envia ao apertar o botão RST).
create or replace function public.colmeia_scale_calibrate(p_device_id text, p_step text, p_kg numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d     public.colmeia_devices;
  delta double precision;
begin
  select * into d from public.colmeia_devices where id = p_device_id and owner_id = auth.uid() for update;
  if not found then
    raise exception 'rastreador não encontrado' using errcode = 'P0002';
  end if;
  if d.last_scale_raw is null or d.last_scale_raw_at < now() - interval '20 minutes' then
    raise exception 'Nenhuma pesagem recente. Aperte o botão RST da placa, espere 2 minutos e tente de novo.'
      using errcode = 'P0001';
  end if;

  if p_step = 'zero' then
    update public.colmeia_devices set scale_offset = d.last_scale_raw where id = d.id returning * into d;
  elsif p_step = 'peso' then
    if d.scale_offset is null then
      raise exception 'Faça primeiro o passo 1 (balança vazia).' using errcode = 'P0001';
    end if;
    if p_kg is null or p_kg < 1 or p_kg > 200 then
      raise exception 'Informe o peso usado, de 1 a 200 kg.' using errcode = '22023';
    end if;
    delta := d.last_scale_raw - d.scale_offset;
    if abs(delta) < 200 then
      raise exception 'A balança não mudou com o peso. Com o peso em cima, aperte RST, espere 2 minutos e tente de novo. Se continuar, confira os fios das células.'
        using errcode = 'P0001';
    end if;
    update public.colmeia_devices set scale_factor = delta / p_kg where id = d.id returning * into d;
  else
    raise exception 'passo inválido: %', p_step using errcode = '22023';
  end if;

  -- Recalcula todas as pesagens (e o peso de referência da melgueira) com a nova calibração.
  update public.colmeia_weights set kg = public.colmeia_raw_to_kg(raw, d.scale_offset, d.scale_factor)
  where device_id = d.id;
  perform public.colmeia_refresh_last_weight(d.id);
  update public.colmeia_devices set harvest_base_kg = (
    select w.kg from public.colmeia_weights w
    where w.device_id = d.id and w.kg is not null and w.measured_at >= d.harvest_base_at + interval '30 minutes'
    order by w.measured_at limit 1)
  where id = d.id and harvest_base_at is not null;
  select * into d from public.colmeia_devices where id = p_device_id;

  return jsonb_build_object('calibrada', d.scale_factor is not null, 'kg', d.last_weight_kg);
end $$;

-- Ajustes da colheita e do aviso de fome. p_mark_super = acabei de colocar a melgueira.
create or replace function public.colmeia_set_harvest(p_device_id text, p_gain_kg numeric, p_hunger_kg numeric default null,
                                                      p_mark_super boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_gain_kg is null or p_gain_kg < 1 or p_gain_kg > 100 then
    raise exception 'O ganho para a colheita deve ser de 1 a 100 kg.' using errcode = '22023';
  end if;
  if p_hunger_kg is not null and (p_hunger_kg < 1 or p_hunger_kg > 200) then
    raise exception 'O peso mínimo deve ser de 1 a 200 kg (ou deixe em branco).' using errcode = '22023';
  end if;
  update public.colmeia_devices set
    harvest_gain_kg     = p_gain_kg,
    hunger_kg           = p_hunger_kg,
    harvest_base_at     = case when p_mark_super then now() else harvest_base_at end,
    harvest_base_kg     = case when p_mark_super then null else harvest_base_kg end,
    harvest_notified_at = case when p_mark_super then null else harvest_notified_at end
  where id = p_device_id and owner_id = auth.uid();
  if not found then
    raise exception 'rastreador não encontrado' using errcode = 'P0002';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Permissões das funções novas
-- ---------------------------------------------------------------------------
revoke execute on function
  public.colmeia_raw_to_kg(integer, double precision, double precision),
  public.colmeia_fmt_kg(numeric),
  public.colmeia_enqueue_alert_messages(uuid, text, text, jsonb),
  public.colmeia_refresh_last_weight(text),
  public.colmeia_record_weights(text, jsonb),
  public.colmeia_check_weight_alerts(text),
  public.colmeia_scale_calibrate(text, text, numeric),
  public.colmeia_set_harvest(text, numeric, numeric, boolean)
  from public, anon, authenticated;
grant execute on function public.colmeia_scale_calibrate(text, text, numeric) to authenticated;
grant execute on function public.colmeia_set_harvest(text, numeric, numeric, boolean) to authenticated;
