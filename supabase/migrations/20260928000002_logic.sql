-- Colmeia Segura — regras de negócio
-- Recebimento de eventos, abertura de alertas, escalonamento em 5 minutos,
-- resposta do apicultor pelo link e ativação por QR Code.

-- ---------------------------------------------------------------------------
-- Auxiliares
-- ---------------------------------------------------------------------------

create or replace function public.setting(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from public.settings where key = p_key
$$;

-- Texto das mensagens. O mesmo texto vai por SMS; no WhatsApp vira um modelo
-- aprovado pela Meta com os mesmos parâmetros (caixa, apiario, link, hora).
create or replace function public.render_message(p_template text, p_params jsonb)
returns text language plpgsql immutable as $$
declare
  caixa   text := coalesce(p_params->>'caixa', 'caixa');
  apiario text := coalesce(p_params->>'apiario', 'apiário');
  link    text := coalesce(p_params->>'link', '');
  hora    text := coalesce(p_params->>'hora', '');
begin
  return case p_template
    when 'alerta_movimento' then
      format('ALERTA COLMEIA SEGURA: a %s foi movimentada no %s. Foi você fazendo manutenção? Responda em até 5 minutos: %s', caixa, apiario, link)
    when 'alerta_escalado' then
      format('ALERTA COLMEIA SEGURA: a %s (%s) foi movimentada e ninguém confirmou em 5 minutos. POSSÍVEL ROUBO. Rastreamento intensivo ativado. Mapa: %s', caixa, apiario, link)
    when 'roubo_confirmado' then
      format('ALERTA COLMEIA SEGURA: ROUBO CONFIRMADO da %s (%s). Rastreamento intensivo ativado. Mapa: %s', caixa, apiario, link)
    when 'offline' then
      format('AVISO COLMEIA SEGURA: o rastreador da %s (%s) está sem comunicação desde %s. Verifique: %s', caixa, apiario, hora, link)
    when 'bateria_baixa' then
      format('AVISO COLMEIA SEGURA: bateria baixa no rastreador da %s (%s). Recarregue em breve: %s', caixa, apiario, link)
    else format('COLMEIA SEGURA: aviso sobre a %s (%s): %s', caixa, apiario, link)
  end;
end $$;

-- Coloca na fila as mensagens de um alerta para um telefone (WhatsApp + SMS,
-- redundância pedida no projeto).
create or replace function public.enqueue_alert_messages(p_alert_id uuid, p_phone text, p_template text)
returns void language plpgsql security definer set search_path = public as $$
declare
  a public.alerts;
  d public.devices;
  params jsonb;
begin
  if p_phone is null then return; end if;
  select * into a from public.alerts where id = p_alert_id;
  select * into d from public.devices where id = a.device_id;
  params := jsonb_build_object(
    'caixa',   coalesce(d.hive_label, d.id),
    'apiario', coalesce((select name from public.apiaries where id = d.apiary_id), 'apiário'),
    'link',    public.setting('site_url') || '/alerta.html?t=' || a.token,
    'hora',    to_char(d.last_seen_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
  );
  insert into public.notifications (alert_id, device_id, to_phone, channel, template, body, params)
  select a.id, d.id, p_phone, ch, p_template, public.render_message(p_template, params), params
  from unnest(array['whatsapp', 'sms']) as ch;
end $$;

-- Configuração devolvida ao rastreador em toda comunicação.
create or replace function public.device_config(d public.devices, p_ack bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ok', true,
    'ack', p_ack,
    'mode', d.mode,
    'heartbeat_min', d.heartbeat_min,
    'theft_interval_s', d.theft_interval_s,
    'maintenance', coalesce(d.maintenance_until > now(), false),
    -- Enquanto houver alerta de movimento aberto, o rastreador continua vigiando.
    'alert_open', exists (select 1 from public.alerts a
                          where a.device_id = d.id and a.kind = 'movimento'
                            and a.status in ('pendente', 'escalado', 'roubo_confirmado')),
    'sms', to_jsonb(array_remove(array[d.primary_phone, d.secondary_phone], null))
  )
$$;

-- ---------------------------------------------------------------------------
-- Recebe um evento do rastreador (chamada pela função "ingest", já autenticada).
-- ---------------------------------------------------------------------------
create or replace function public.ingest_event(
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
  d        public.devices;
  alert_id uuid;
  low_mv   integer := public.setting('low_battery_mv')::integer;
begin
  select * into d from public.devices where id = p_device_id for update;
  if not found then
    raise exception 'rastreador desconhecido: %', p_device_id using errcode = 'P0002';
  end if;

  -- Reenvio da mesma mensagem (ou mensagem antiga): não processa de novo.
  if p_seq <= d.last_seq then
    return public.device_config(d, d.last_seq) || jsonb_build_object('duplicate', true);
  end if;

  insert into public.events (device_id, seq, type, lat, lon, battery_mv, signal, channel, payload)
  values (p_device_id, p_seq, p_type, p_lat, p_lon, p_battery_mv, p_signal, p_channel, coalesce(p_payload, '{}'::jsonb));

  update public.devices set
    last_seq        = p_seq,
    last_seen_at    = now(),
    last_lat        = coalesce(p_lat, last_lat),
    last_lon        = coalesce(p_lon, last_lon),
    last_battery_mv = coalesce(p_battery_mv, last_battery_mv),
    last_signal     = coalesce(p_signal, last_signal)
  where id = p_device_id
  returning * into d;

  if d.status <> 'ativo' then
    return public.device_config(d, p_seq);
  end if;

  -- Voltou a comunicar: encerra aviso de "sem comunicação".
  update public.alerts set status = 'encerrado', resolved_at = now(), resolution = 'voltou a comunicar'
  where device_id = d.id and kind = 'offline' and status = 'pendente';

  -- Movimento: pergunta primeiro ao responsável principal.
  if p_type = 'movimento'
     and not coalesce(d.maintenance_until > now(), false)
     and not exists (select 1 from public.alerts
                     where device_id = d.id and kind = 'movimento'
                       and status in ('pendente', 'escalado', 'roubo_confirmado')) then
    insert into public.alerts (device_id, kind, escalate_at)
    values (d.id, 'movimento', now() + make_interval(mins => public.setting('escalation_minutes')::integer))
    returning id into alert_id;
    perform public.enqueue_alert_messages(alert_id, d.primary_phone, 'alerta_movimento');
  end if;

  -- Bateria baixa: no máximo um aviso por dia.
  if (p_type = 'bateria_baixa' or p_battery_mv < low_mv)
     and not exists (select 1 from public.alerts
                     where device_id = d.id and kind = 'bateria_baixa'
                       and opened_at > now() - interval '24 hours') then
    insert into public.alerts (device_id, kind, status, resolved_at, resolution)
    values (d.id, 'bateria_baixa', 'encerrado', now(), 'aviso enviado')
    returning id into alert_id;
    perform public.enqueue_alert_messages(alert_id, d.primary_phone, 'bateria_baixa');
  end if;

  return public.device_config(d, p_seq);
end $$;

-- ---------------------------------------------------------------------------
-- Roda a cada minuto (pg_cron): escalonamento e rastreadores sem comunicação.
-- ---------------------------------------------------------------------------
create or replace function public.escalate_alerts()
returns integer language plpgsql security definer set search_path = public as $$
declare
  a     record;
  n     integer := 0;
  new_id uuid;
begin
  -- 1) Ninguém respondeu em 5 minutos: possível roubo.
  for a in
    update public.alerts set status = 'escalado', escalated_at = now()
    where status = 'pendente' and kind = 'movimento' and escalate_at <= now()
    returning id, device_id
  loop
    update public.devices set mode = 'roubo' where id = a.device_id;
    perform public.enqueue_alert_messages(a.id, (select secondary_phone from public.devices where id = a.device_id), 'alerta_escalado');
    perform public.enqueue_alert_messages(a.id, (select primary_phone   from public.devices where id = a.device_id), 'alerta_escalado');
    n := n + 1;
  end loop;

  -- 2) Rastreador em silêncio além do esperado (pode ter sido destruído).
  for a in
    select d.id from public.devices d
    where d.status = 'ativo'
      and d.last_seen_at is not null
      and d.last_seen_at < now() - case
            when d.mode = 'roubo' then make_interval(secs => greatest(d.theft_interval_s * 10, 900))
            else make_interval(mins => d.heartbeat_min * 2 + 30)
          end
      and not exists (select 1 from public.alerts al
                      where al.device_id = d.id and al.kind = 'offline' and al.status = 'pendente')
  loop
    insert into public.alerts (device_id, kind) values (a.id, 'offline') returning id into new_id;
    perform public.enqueue_alert_messages(new_id, (select primary_phone from public.devices where id = a.id), 'offline');
    n := n + 1;
  end loop;

  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Resposta do apicultor pelo link da mensagem (não exige login: o token é a senha).
-- p_action: 'ver' | 'manutencao' (sou eu) | 'roubo' (possível roubo)
-- ---------------------------------------------------------------------------
create or replace function public.respond_alert(p_token text, p_action text default 'ver')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a public.alerts;
  d public.devices;
begin
  select * into a from public.alerts
  where token = p_token and opened_at > now() - interval '7 days'
  for update;
  if not found then
    raise exception 'link inválido ou expirado' using errcode = 'P0002';
  end if;

  if p_action = 'manutencao' and a.kind = 'movimento'
     and a.status in ('pendente', 'escalado', 'roubo_confirmado') then
    update public.alerts set status = 'manutencao', resolved_at = now(),
      resolution = 'responsável confirmou manutenção'
    where id = a.id returning * into a;
    -- Evita novo alerta enquanto o apicultor ainda está mexendo nas caixas.
    update public.devices set mode = 'normal', maintenance_until = now() + interval '2 hours'
    where id = a.device_id;

  elsif p_action = 'roubo' and a.kind = 'movimento'
        and a.status in ('pendente', 'escalado') then
    update public.alerts set status = 'roubo_confirmado', resolved_at = null,
      resolution = 'responsável confirmou possível roubo'
    where id = a.id returning * into a;
    update public.devices set mode = 'roubo' where id = a.device_id;
    perform public.enqueue_alert_messages(a.id, (select secondary_phone from public.devices where id = a.device_id), 'roubo_confirmado');

  elsif p_action not in ('ver', 'manutencao', 'roubo') then
    raise exception 'ação inválida: %', p_action using errcode = '22023';
  end if;

  select * into d from public.devices where id = a.device_id;

  return jsonb_build_object(
    'alert', jsonb_build_object('kind', a.kind, 'status', a.status, 'opened_at', a.opened_at,
                                'escalate_at', a.escalate_at, 'resolution', a.resolution),
    'device', jsonb_build_object(
      'id', d.id, 'caixa', coalesce(d.hive_label, d.id),
      'apiario', (select name from public.apiaries where id = d.apiary_id),
      'mode', d.mode, 'last_seen_at', d.last_seen_at,
      'lat', d.last_lat, 'lon', d.last_lon, 'battery_mv', d.last_battery_mv),
    'track', coalesce((
      select jsonb_agg(jsonb_build_object('lat', e.lat, 'lon', e.lon, 'at', e.received_at) order by e.received_at)
      from (select * from public.events
            where device_id = d.id and lat is not null and received_at >= a.opened_at - interval '1 hour'
            order by received_at desc limit 200) e
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- Ativação pelo QR Code (apicultor logado).
-- ---------------------------------------------------------------------------
create or replace function public.activate_device(
  p_device_id       text,
  p_claim_code      text,
  p_apiary_name     text,
  p_hive_label      text,
  p_primary_phone   text,
  p_secondary_phone text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  uid       uuid := auth.uid();
  d         public.devices;
  s         public.device_secrets;
  apiary    uuid;
begin
  if uid is null then
    raise exception 'faça login para ativar' using errcode = '42501';
  end if;

  select * into d from public.devices where id = upper(trim(p_device_id)) for update;
  select * into s from public.device_secrets where device_id = d.id;
  if d.id is null or s.claim_code_hash is distinct from encode(digest(upper(trim(p_claim_code)), 'sha256'), 'hex') then
    raise exception 'rastreador ou código de ativação inválido' using errcode = 'P0002';
  end if;
  if d.owner_id is not null and d.owner_id <> uid then
    raise exception 'este rastreador já está ativado por outra pessoa' using errcode = '42501';
  end if;
  if coalesce(trim(p_apiary_name), '') = '' or coalesce(trim(p_hive_label), '') = '' then
    raise exception 'informe o apiário e a caixa' using errcode = '22023';
  end if;

  insert into public.apiaries (owner_id, name) values (uid, trim(p_apiary_name))
  on conflict (owner_id, name) do update set name = excluded.name
  returning id into apiary;

  update public.devices set
    owner_id        = uid,
    apiary_id       = apiary,
    hive_label      = trim(p_hive_label),
    primary_phone   = p_primary_phone,
    secondary_phone = nullif(trim(coalesce(p_secondary_phone, '')), ''),
    status          = 'ativo',
    mode            = 'normal',
    activated_at    = coalesce(activated_at, now())
  where id = d.id
  returning * into d;

  return jsonb_build_object('id', d.id, 'caixa', d.hive_label, 'apiario', p_apiary_name,
                            'last_seen_at', d.last_seen_at);
end $$;

-- Modo manutenção: mexer nas caixas sem disparar alerta (p_minutes = 0 encerra).
create or replace function public.set_maintenance(p_device_id text, p_minutes integer)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  until timestamptz;
begin
  if p_minutes < 0 or p_minutes > 24 * 60 then
    raise exception 'tempo de manutenção inválido' using errcode = '22023';
  end if;
  update public.devices
  set maintenance_until = case when p_minutes = 0 then null else now() + make_interval(mins => p_minutes) end
  where id = p_device_id and owner_id = auth.uid()
  returning maintenance_until into until;
  if not found then
    raise exception 'rastreador não encontrado' using errcode = 'P0002';
  end if;
  return until;
end $$;

-- Caixa recuperada / falso alarme: volta ao modo econômico e encerra alertas.
create or replace function public.end_theft_mode(p_device_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.devices set mode = 'normal'
  where id = p_device_id and owner_id = auth.uid();
  if not found then
    raise exception 'rastreador não encontrado' using errcode = 'P0002';
  end if;
  update public.alerts set status = 'encerrado', resolved_at = now(), resolution = 'encerrado pelo dono'
  where device_id = p_device_id and status in ('pendente', 'escalado', 'roubo_confirmado');
end $$;

-- Cadastro de um rastreador novo no estoque (uso administrativo, SQL Editor).
create or replace function public.provision_device(p_device_id text, p_secret text, p_claim_code text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.devices (id) values (upper(p_device_id));
  insert into public.device_secrets (device_id, secret, claim_code_hash)
  values (upper(p_device_id), p_secret, encode(digest(upper(p_claim_code), 'sha256'), 'hex'));
end $$;

-- ---------------------------------------------------------------------------
-- Permissões das funções
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.respond_alert(text, text) to anon, authenticated;
grant execute on function public.activate_device(text, text, text, text, text, text) to authenticated;
grant execute on function public.set_maintenance(text, integer) to authenticated;
grant execute on function public.end_theft_mode(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Fila de envio: a função "dispatch" pega um lote de mensagens de cada vez.
-- (Acrescentada ao final para manter a ordem das permissões acima.)
-- ---------------------------------------------------------------------------
create or replace function public.claim_notifications(p_limit integer default 20)
returns setof public.notifications language sql security definer set search_path = public as $$
  update public.notifications n set status = 'enviando', attempts = n.attempts + 1
  where n.id in (
    select id from public.notifications
    where status = 'fila'
    order by created_at
    limit p_limit
    for update skip locked
  )
  returning n.*
$$;

create or replace function public.finish_notification(p_id bigint, p_status text, p_error text default null)
returns void language sql security definer set search_path = public as $$
  update public.notifications set
    status  = case when p_status = 'falhou' and attempts < 3 then 'fila' else p_status end,
    error   = p_error,
    sent_at = case when p_status in ('enviado', 'simulado') then now() else sent_at end
  where id = p_id
$$;

revoke execute on function public.claim_notifications(integer), public.finish_notification(bigint, text, text)
  from public, anon, authenticated;
