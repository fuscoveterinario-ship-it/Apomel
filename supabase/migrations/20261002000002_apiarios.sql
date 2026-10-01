-- Bee Guard — apiários e colmeias
-- Estrutura: apiário (nome, município, telefones padrão) → colmeias (todas as caixas, com ou
-- sem rastreador) → rastreador vinculado a uma colmeia. Produção por apiário ou por colmeia.
-- Duas ou mais caixas do mesmo apiário mexidas em 10 minutos = ATAQUE AO APIÁRIO:
-- avisa principal e secundário na hora, numa única mensagem, e liga o rastreamento intensivo.

alter table public.colmeia_apiaries
  add column city            text check (char_length(city) <= 80),
  add column primary_phone   text check (primary_phone ~ '^\+[1-9][0-9]{7,14}$'),
  add column secondary_phone text check (secondary_phone ~ '^\+[1-9][0-9]{7,14}$');

create table public.colmeia_hives (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users (id) on delete cascade,
  apiary_id   uuid not null references public.colmeia_apiaries (id) on delete cascade,
  label       text not null check (char_length(trim(label)) between 1 and 40),
  created_at  timestamptz not null default now(),
  unique (apiary_id, label)
);
alter table public.colmeia_hives enable row level security;
create policy "dono lê colmeias" on public.colmeia_hives
  for select to authenticated using (owner_id = auth.uid());
revoke insert, update, delete on public.colmeia_hives from anon, authenticated;

alter table public.colmeia_devices
  add column hive_id uuid references public.colmeia_hives (id) on delete set null,
  -- true = usa os telefones do apiário (atualizados junto quando o apiário muda)
  add column phones_from_apiary boolean not null default false;
alter table public.colmeia_harvests add column hive_id uuid references public.colmeia_hives (id) on delete set null;

-- Dados que já existem: cria as colmeias a partir dos rastreadores ativados.
insert into public.colmeia_hives (owner_id, apiary_id, label)
select distinct owner_id, apiary_id, hive_label from public.colmeia_devices
where owner_id is not null and apiary_id is not null and hive_label is not null
on conflict (apiary_id, label) do nothing;
update public.colmeia_devices d set hive_id = h.id
from public.colmeia_hives h where h.apiary_id = d.apiary_id and h.label = d.hive_label;
update public.colmeia_harvests hv set hive_id = d.hive_id from public.colmeia_devices d where d.id = hv.device_id;
update public.colmeia_apiaries a set primary_phone = x.p1, secondary_phone = x.p2
from (select distinct on (apiary_id) apiary_id, primary_phone as p1, secondary_phone as p2
      from public.colmeia_devices where apiary_id is not null order by apiary_id, activated_at) x
where x.apiary_id = a.id and a.primary_phone is null;

-- Colheita com rastreador: a colmeia vem do rastreador (inclusive as registradas pela balança).
create or replace function public.colmeia_harvest_fill_hive()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.hive_id is null and new.device_id is not null then
    select hive_id into new.hive_id from public.colmeia_devices where id = new.device_id;
  end if;
  return new;
end $$;
create trigger colmeia_harvest_fill_hive before insert on public.colmeia_harvests
  for each row execute function public.colmeia_harvest_fill_hive();

-- ---------------------------------------------------------------------------
-- Cadastro de apiários e colmeias (apicultor logado)
-- ---------------------------------------------------------------------------
-- Cria (p_id nulo) ou altera um apiário. Os rastreadores que usam os telefones do apiário
-- passam a usar os novos.
create or replace function public.colmeia_save_apiary(p_id uuid, p_name text, p_city text,
                                                      p_primary_phone text, p_secondary_phone text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  aid uuid;
begin
  if uid is null then raise exception 'faça login' using errcode = '42501'; end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Informe o nome do apiário.' using errcode = '22023';
  end if;
  if p_id is null then
    insert into public.colmeia_apiaries (owner_id, name, city, primary_phone, secondary_phone)
    values (uid, trim(p_name), nullif(trim(coalesce(p_city, '')), ''), nullif(p_primary_phone, ''), nullif(p_secondary_phone, ''))
    returning id into aid;
  else
    update public.colmeia_apiaries set name = trim(p_name), city = nullif(trim(coalesce(p_city, '')), ''),
      primary_phone = nullif(p_primary_phone, ''), secondary_phone = nullif(p_secondary_phone, '')
    where id = p_id and owner_id = uid returning id into aid;
    if aid is null then raise exception 'apiário não encontrado' using errcode = 'P0002'; end if;
    update public.colmeia_devices set primary_phone = nullif(p_primary_phone, ''), secondary_phone = nullif(p_secondary_phone, '')
    where apiary_id = aid and owner_id = uid and phones_from_apiary;
  end if;
  return aid;
exception when unique_violation then
  raise exception 'Você já tem um apiário com esse nome.' using errcode = '23505';
end $$;

-- Cadastra colmeias (ignora nomes que já existem). Devolve quantas foram criadas.
create or replace function public.colmeia_add_hives(p_apiary_id uuid, p_labels text[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  n integer;
begin
  if not exists (select 1 from public.colmeia_apiaries where id = p_apiary_id and owner_id = uid) then
    raise exception 'apiário não encontrado' using errcode = 'P0002';
  end if;
  if coalesce(array_length(p_labels, 1), 0) = 0 or array_length(p_labels, 1) > 500 then
    raise exception 'Informe de 1 a 500 colmeias.' using errcode = '22023';
  end if;
  insert into public.colmeia_hives (owner_id, apiary_id, label)
  select distinct uid, p_apiary_id, left(trim(l), 40) from unnest(p_labels) l where trim(coalesce(l, '')) <> ''
  on conflict (apiary_id, label) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Apaga uma colmeia sem rastreador (as colheitas dela ficam como "apiário").
create or replace function public.colmeia_delete_hive(p_hive_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.colmeia_devices where hive_id = p_hive_id) then
    raise exception 'Esta colmeia tem rastreador. Desvincule o rastreador antes.' using errcode = '22023';
  end if;
  delete from public.colmeia_hives where id = p_hive_id and owner_id = auth.uid();
  if not found then raise exception 'colmeia não encontrada' using errcode = 'P0002'; end if;
end $$;

-- Ativação pelo QR Code escolhendo apiário e colmeia já cadastrados.
-- Telefones vazios = usa os do apiário.
create or replace function public.colmeia_activate_device_hive(
  p_device_id text, p_claim_code text, p_hive_id uuid,
  p_primary_phone text default null, p_secondary_phone text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  d   public.colmeia_devices;
  s   public.colmeia_device_secrets;
  h   public.colmeia_hives;
  a   public.colmeia_apiaries;
  own boolean := nullif(p_primary_phone, '') is not null;
begin
  if uid is null then raise exception 'faça login para ativar' using errcode = '42501'; end if;
  select * into d from public.colmeia_devices where id = upper(trim(p_device_id)) for update;
  select * into s from public.colmeia_device_secrets where device_id = d.id;
  if d.id is null or s.claim_code_hash is distinct from encode(digest(upper(trim(p_claim_code)), 'sha256'), 'hex') then
    raise exception 'rastreador ou código de ativação inválido' using errcode = 'P0002';
  end if;
  if d.owner_id is not null and d.owner_id <> uid then
    raise exception 'este rastreador já está ativado por outra pessoa' using errcode = '42501';
  end if;
  select * into h from public.colmeia_hives where id = p_hive_id and owner_id = uid;
  if h.id is null then raise exception 'colmeia não encontrada' using errcode = 'P0002'; end if;
  if exists (select 1 from public.colmeia_devices where hive_id = h.id and id <> d.id) then
    raise exception 'Esta colmeia já tem um rastreador.' using errcode = '22023';
  end if;
  select * into a from public.colmeia_apiaries where id = h.apiary_id;
  if not own and a.primary_phone is null then
    raise exception 'Informe o telefone principal (o apiário ainda não tem telefone cadastrado).' using errcode = '22023';
  end if;

  update public.colmeia_devices set
    owner_id = uid, apiary_id = h.apiary_id, hive_id = h.id, hive_label = h.label,
    phones_from_apiary = not own,
    primary_phone   = case when own then p_primary_phone else a.primary_phone end,
    secondary_phone = case when own then nullif(trim(coalesce(p_secondary_phone, '')), '') else a.secondary_phone end,
    status = 'ativo', mode = 'normal', activated_at = coalesce(activated_at, now())
  where id = d.id
  returning * into d;

  return jsonb_build_object('id', d.id, 'caixa', d.hive_label, 'apiario', a.name, 'last_seen_at', d.last_seen_at);
end $$;

-- ---------------------------------------------------------------------------
-- Apiário inteiro: manutenção e falso alarme
-- ---------------------------------------------------------------------------
create or replace function public.colmeia_set_apiary_maintenance(p_apiary_id uuid, p_minutes integer)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  until timestamptz := case when p_minutes = 0 then null else now() + make_interval(mins => p_minutes) end;
begin
  if p_minutes < 0 or p_minutes > 24 * 60 then
    raise exception 'tempo de manutenção inválido' using errcode = '22023';
  end if;
  if not exists (select 1 from public.colmeia_apiaries where id = p_apiary_id and owner_id = auth.uid()) then
    raise exception 'apiário não encontrado' using errcode = 'P0002';
  end if;
  update public.colmeia_devices set maintenance_until = until where apiary_id = p_apiary_id and owner_id = auth.uid();
  return until;
end $$;

create or replace function public.colmeia_end_apiary_alarm(p_apiary_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if not exists (select 1 from public.colmeia_apiaries where id = p_apiary_id and owner_id = auth.uid()) then
    raise exception 'apiário não encontrado' using errcode = 'P0002';
  end if;
  update public.colmeia_devices set mode = 'normal' where apiary_id = p_apiary_id and owner_id = auth.uid();
  update public.colmeia_alerts al set status = 'encerrado', resolved_at = now(), resolution = 'encerrado pelo dono (apiário)'
  from public.colmeia_devices d
  where d.id = al.device_id and d.apiary_id = p_apiary_id and d.owner_id = auth.uid()
    and al.status in ('pendente', 'escalado', 'roubo_confirmado');
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Ataque ao apiário
-- ---------------------------------------------------------------------------
-- Chamada ao abrir um alerta de movimento. Se outra caixa do mesmo apiário também foi mexida
-- nos últimos 10 minutos: escala todos os alertas, liga o modo roubo e avisa principal e
-- secundário numa única mensagem (no máximo uma a cada 30 minutos por apiário).
-- Devolve true quando é ataque (aí o aviso individual "foi você?" não é enviado).
create or replace function public.colmeia_check_apiary_attack(p_alert_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  d       public.colmeia_devices;
  a       public.colmeia_apiaries;
  n       integer;
  caixas  text;
  link    jsonb;
begin
  select dv.* into d from public.colmeia_devices dv join public.colmeia_alerts al on al.device_id = dv.id
  where al.id = p_alert_id;
  if d.apiary_id is null then return false; end if;
  select * into a from public.colmeia_apiaries where id = d.apiary_id;

  select count(distinct al.device_id) into n
  from public.colmeia_alerts al join public.colmeia_devices dv on dv.id = al.device_id
  where dv.apiary_id = d.apiary_id and al.kind = 'movimento'
    and al.status in ('pendente', 'escalado', 'roubo_confirmado') and al.opened_at > now() - interval '10 minutes';
  if n < 2 then return false; end if;

  update public.colmeia_alerts al set status = 'escalado', escalated_at = now()
  from public.colmeia_devices dv
  where dv.id = al.device_id and dv.apiary_id = d.apiary_id and al.kind = 'movimento' and al.status = 'pendente';
  update public.colmeia_devices dv set mode = 'roubo'
  where dv.apiary_id = d.apiary_id and exists (
    select 1 from public.colmeia_alerts al where al.device_id = dv.id and al.kind = 'movimento'
      and al.status in ('escalado', 'roubo_confirmado') and al.opened_at > now() - interval '10 minutes');

  if exists (select 1 from public.colmeia_notifications nt join public.colmeia_devices dv on dv.id = nt.device_id
             where dv.apiary_id = d.apiary_id and nt.template = 'ataque_apiario'
               and nt.created_at > now() - interval '30 minutes') then
    return true;
  end if;

  select string_agg(distinct coalesce(dv.hive_label, dv.id), ', ') into caixas
  from public.colmeia_alerts al join public.colmeia_devices dv on dv.id = al.device_id
  where dv.apiary_id = d.apiary_id and al.kind = 'movimento'
    and al.status in ('escalado', 'roubo_confirmado') and al.opened_at > now() - interval '10 minutes';
  link := jsonb_build_object('link', public.colmeia_setting('site_url') || '/painel.html', 'caixas', caixas);
  perform public.colmeia_enqueue_alert_messages(p_alert_id, coalesce(a.primary_phone, d.primary_phone), 'ataque_apiario', link);
  if coalesce(a.secondary_phone, d.secondary_phone) is distinct from coalesce(a.primary_phone, d.primary_phone) then
    perform public.colmeia_enqueue_alert_messages(p_alert_id, coalesce(a.secondary_phone, d.secondary_phone), 'ataque_apiario', link);
  end if;
  return true;
end $$;

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

  -- Movimento: pergunta primeiro ao responsável principal.
  if p_type = 'movimento'
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

create or replace function public.colmeia_activate_device(
  p_device_id       text,
  p_claim_code      text,
  p_apiary_name     text,
  p_hive_label      text,
  p_primary_phone   text,
  p_secondary_phone text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  uid       uuid := auth.uid();
  d         public.colmeia_devices;
  s         public.colmeia_device_secrets;
  apiary    uuid;
begin
  if uid is null then
    raise exception 'faça login para ativar' using errcode = '42501';
  end if;

  select * into d from public.colmeia_devices where id = upper(trim(p_device_id)) for update;
  select * into s from public.colmeia_device_secrets where device_id = d.id;
  if d.id is null or s.claim_code_hash is distinct from encode(digest(upper(trim(p_claim_code)), 'sha256'), 'hex') then
    raise exception 'rastreador ou código de ativação inválido' using errcode = 'P0002';
  end if;
  if d.owner_id is not null and d.owner_id <> uid then
    raise exception 'este rastreador já está ativado por outra pessoa' using errcode = '42501';
  end if;
  if coalesce(trim(p_apiary_name), '') = '' or coalesce(trim(p_hive_label), '') = '' then
    raise exception 'informe o apiário e a caixa' using errcode = '22023';
  end if;

  insert into public.colmeia_apiaries (owner_id, name) values (uid, trim(p_apiary_name))
  on conflict (owner_id, name) do update set name = excluded.name
  returning id into apiary;

  insert into public.colmeia_hives (owner_id, apiary_id, label) values (uid, apiary, trim(p_hive_label))
  on conflict (apiary_id, label) do nothing;

  update public.colmeia_devices set
    owner_id        = uid,
    apiary_id       = apiary,
    hive_id         = (select id from public.colmeia_hives where apiary_id = apiary and label = trim(p_hive_label)),
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

-- Colheita: agora por colmeia (p_hive_id). p_device_id continua aceito.
drop function public.colmeia_add_harvest(uuid, text, date, numeric, text);
create function public.colmeia_add_harvest(p_apiary_id uuid, p_device_id text, p_date date,
                                           p_kg numeric, p_note text default null, p_hive_id uuid default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  new_id bigint;
begin
  if not exists (select 1 from public.colmeia_apiaries where id = p_apiary_id and owner_id = uid) then
    raise exception 'apiário não encontrado' using errcode = 'P0002';
  end if;
  if nullif(p_device_id, '') is not null and not exists (
       select 1 from public.colmeia_devices where id = p_device_id and owner_id = uid and apiary_id = p_apiary_id) then
    raise exception 'caixa não encontrada neste apiário' using errcode = 'P0002';
  end if;
  if p_hive_id is not null and not exists (
       select 1 from public.colmeia_hives where id = p_hive_id and owner_id = uid and apiary_id = p_apiary_id) then
    raise exception 'colmeia não encontrada neste apiário' using errcode = 'P0002';
  end if;
  if p_date is null or p_date > current_date + 1 or p_date < date '2000-01-01' then
    raise exception 'Data da colheita inválida.' using errcode = '22023';
  end if;
  if p_kg is null or p_kg <= 0 or p_kg > 10000 then
    raise exception 'Informe a quantidade de mel em kg (maior que zero).' using errcode = '22023';
  end if;
  insert into public.colmeia_harvests (owner_id, apiary_id, device_id, hive_id, harvested_on, kg, source, note)
  values (uid, p_apiary_id, nullif(p_device_id, ''), p_hive_id, p_date, round(p_kg, 2), 'manual',
          nullif(left(trim(coalesce(p_note, '')), 200), ''))
  returning id into new_id;
  return new_id;
end $$;

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
    'apiario', (select jsonb_build_object('id', a.id, 'name', a.name, 'city', a.city) from public.colmeia_apiaries a where a.id = l.apiary_id),
    'colmeias', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'apiary_id', h.apiary_id, 'label', h.label) order by h.label)
      from public.colmeia_hives h where h.apiary_id = l.apiary_id), '[]'::jsonb),
    'devices', coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'hive_label', d.hive_label, 'hive_id', d.hive_id, 'apiary_id', d.apiary_id, 'mode', d.mode,
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
        'hive_id', h.hive_id,
        'harvested_on', h.harvested_on, 'kg', h.kg, 'source', h.source, 'note', h.note) order by h.harvested_on desc)
      from public.colmeia_harvests h where h.apiary_id = l.apiary_id), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------------
revoke execute on function
  public.colmeia_harvest_fill_hive(),
  public.colmeia_save_apiary(uuid, text, text, text, text),
  public.colmeia_add_hives(uuid, text[]),
  public.colmeia_delete_hive(uuid),
  public.colmeia_activate_device_hive(text, text, uuid, text, text),
  public.colmeia_set_apiary_maintenance(uuid, integer),
  public.colmeia_end_apiary_alarm(uuid),
  public.colmeia_check_apiary_attack(uuid),
  public.colmeia_add_harvest(uuid, text, date, numeric, text, uuid)
  from public, anon, authenticated;
grant execute on function
  public.colmeia_save_apiary(uuid, text, text, text, text),
  public.colmeia_add_hives(uuid, text[]),
  public.colmeia_delete_hive(uuid),
  public.colmeia_activate_device_hive(text, text, uuid, text, text),
  public.colmeia_set_apiary_maintenance(uuid, integer),
  public.colmeia_end_apiary_alarm(uuid),
  public.colmeia_add_harvest(uuid, text, date, numeric, text, uuid)
  to authenticated;
