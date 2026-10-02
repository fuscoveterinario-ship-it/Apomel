-- Bee Guard — cerca virtual do apiário
-- O rastreador NÃO usa a posição da ativação (feita em casa). Ele aprende o local sozinho:
-- quando as posições ficam no mesmo lugar (até 100 m) por 12 horas ou mais, esse ponto vira o
-- "local do apiário". Depois disso, se a caixa aparecer a mais de 200 m de lá, abre um alerta
-- (mesmo fluxo do movimento: "foi você?", escalada e rastreamento).
-- Em manutenção (apicultor mudando as caixas de lugar), sair da cerca apaga o local para
-- aprender o novo.

alter table public.colmeia_devices
  add column home_lat    double precision,
  add column home_lon    double precision,
  add column home_set_at timestamptz,
  add column fence_m     integer not null default 200 check (fence_m between 100 and 5000);

create or replace function public.colmeia_dist_m(p_lat1 double precision, p_lon1 double precision,
                                                 p_lat2 double precision, p_lon2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(p_lat2 - p_lat1) / 2), 2) +
    cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lon2 - p_lon1) / 2), 2)))
$$;

create or replace function public.colmeia_fmt_dist(p_m double precision)
returns text language sql immutable as $$
  select case when p_m >= 1000 then replace(to_char(round((p_m / 1000)::numeric, 1), 'FM999990.0'), '.', ',') || ' km'
              else round(p_m)::text || ' m' end
$$;

create or replace function public.colmeia_check_fence(p_device_id text)
returns void language plpgsql security definer set search_path = public as $$
declare
  d        public.colmeia_devices;
  r        record;
  dist     double precision;
  alert_id uuid;
  params   jsonb;
begin
  select * into d from public.colmeia_devices where id = p_device_id;
  if d.status <> 'ativo' or d.last_lat is null then return; end if;

  if d.home_lat is null then
    -- Aprende: últimas posições seguidas (pela ordem do rastreador), todas a até 100 m da última.
    select count(*) as n, avg(lat) as lat, avg(lon) as lon, max(received_at) - min(received_at) as span into r
    from (
      select lat, lon, received_at,
             sum(case when public.colmeia_dist_m(lat, lon, d.last_lat, d.last_lon) > 100 then 1 else 0 end)
               over (order by seq desc) as fora
      from (select e.seq, e.lat, e.lon, e.received_at from public.colmeia_events e
            where e.device_id = d.id and e.lat is not null
            order by e.seq desc limit 100) ult
    ) t
    where fora = 0;
    if r.n >= 2 and r.span >= interval '12 hours' and not coalesce(d.maintenance_until > now(), false) then
      update public.colmeia_devices set home_lat = r.lat, home_lon = r.lon, home_set_at = now()
      where id = d.id;
      params := jsonb_build_object('caixa', coalesce(d.hive_label, d.id),
        'apiario', coalesce((select name from public.colmeia_apiaries where id = d.apiary_id), 'apiário'));
      if d.primary_phone is not null then
        insert into public.colmeia_notifications (device_id, to_phone, channel, template, body, params)
        values (d.id, d.primary_phone, 'sms', 'cerca_ativa', public.colmeia_render_message('cerca_ativa', params), params);
      end if;
    end if;
    return;
  end if;

  dist := public.colmeia_dist_m(d.home_lat, d.home_lon, d.last_lat, d.last_lon);
  if dist <= d.fence_m then return; end if;

  if coalesce(d.maintenance_until > now(), false) then
    -- Mudando o apiário de lugar: esquece o local antigo e aprende o novo.
    update public.colmeia_devices set home_lat = null, home_lon = null, home_set_at = null where id = d.id;
    return;
  end if;

  if d.mode = 'roubo' or exists (select 1 from public.colmeia_alerts
                                 where device_id = d.id and kind = 'movimento'
                                   and status in ('pendente', 'escalado', 'roubo_confirmado')) then
    return;  -- já está sendo tratado
  end if;

  insert into public.colmeia_alerts (device_id, kind, escalate_at)
  values (d.id, 'movimento', now() + make_interval(mins => public.colmeia_setting('escalation_minutes')::integer))
  returning id into alert_id;
  perform public.colmeia_enqueue_alert_messages(alert_id, d.primary_phone, 'fora_da_cerca',
    jsonb_build_object('distancia', public.colmeia_fmt_dist(dist)));
end $$;

revoke execute on function public.colmeia_check_fence(text) from public, anon, authenticated;

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
    when 'ataque_apiario' then
      format('ALERTA BEE GUARD: ATAQUE AO APIÁRIO %s. %s foram movimentadas ao mesmo tempo. POSSÍVEL ROUBO. Todos os contatos foram avisados e o rastreamento intensivo foi ativado. Veja: %s', apiario, coalesce(p_params->>'caixas', 'Várias caixas'), link)
    when 'teste_alerta' then
      format('BEE GUARD: teste do alerta OK. O rastreador da %s (%s) detectou o movimento. Quando a caixa for mexida de verdade, você recebe uma mensagem como esta com um link para responder.', caixa, apiario)
    when 'fora_da_cerca' then
      format('ALERTA BEE GUARD: a %s está a %s do local do %s. Foi você? Responda em até 5 minutos: %s', caixa, coalesce(p_params->>'distancia', 'longe'), apiario, link)
    when 'cerca_ativa' then
      format('BEE GUARD: local da %s (%s) registrado. A proteção por distância está ativa: se a caixa sair de lá, você é avisado.', caixa, apiario)
    else format('BEE GUARD: aviso sobre a %s (%s): %s', caixa, apiario, link)
  end;
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

  -- Teste do alerta (tela de ativação): confirma o movimento por SMS e não abre alerta.
  if p_type = 'movimento' and coalesce(d.test_alert_until > now(), false) then
    update public.colmeia_devices set test_alert_until = null, test_alert_ok_at = now()
    where id = d.id returning * into d;
    insert into public.colmeia_notifications (device_id, to_phone, channel, template, body, params)
    select d.id, d.primary_phone, 'sms', 'teste_alerta', public.colmeia_render_message('teste_alerta', x.p), x.p
    from (select jsonb_build_object('caixa', coalesce(d.hive_label, d.id),
            'apiario', coalesce((select name from public.colmeia_apiaries where id = d.apiary_id), 'apiário')) p) x
    where d.primary_phone is not null;
  -- Movimento: pergunta primeiro ao responsável principal.
  elsif p_type = 'movimento'
     and not coalesce(d.maintenance_until > now(), false)
     and not exists (select 1 from public.colmeia_alerts
                     where device_id = d.id and kind = 'movimento'
                       and status in ('pendente', 'escalado', 'roubo_confirmado')) then
    insert into public.colmeia_alerts (device_id, kind, escalate_at)
    values (d.id, 'movimento', now() + make_interval(mins => public.colmeia_setting('escalation_minutes')::integer))
    returning id into alert_id;
    -- Duas ou mais caixas do mesmo apiário mexidas juntas: ataque ao apiário (avisa todos na hora).
    if not public.colmeia_check_apiary_attack(alert_id) then
      perform public.colmeia_enqueue_alert_messages(alert_id, d.primary_phone, 'alerta_movimento');
    end if;
  end if;

  -- Cerca virtual: aprende o local do apiário e avisa se a caixa sair de lá.
  if p_lat is not null then
    perform public.colmeia_check_fence(d.id);
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
