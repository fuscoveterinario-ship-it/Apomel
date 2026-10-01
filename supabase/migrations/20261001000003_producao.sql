-- Bee Guard — produção de mel por apiário
-- Colheitas registradas pelo apicultor (manual) ou estimadas pela balança da colmeia sentinela.

create table public.colmeia_harvests (
  id            bigint generated always as identity primary key,
  owner_id      uuid not null references auth.users (id) on delete cascade,
  apiary_id     uuid not null references public.colmeia_apiaries (id) on delete cascade,
  device_id     text references public.colmeia_devices (id) on delete set null,  -- vazio = apiário todo
  harvested_on  date not null,
  kg            numeric(7,2) not null check (kg > 0 and kg <= 10000),
  source        text not null default 'manual' check (source in ('manual', 'balanca')),
  note          text check (char_length(note) <= 200),
  created_at    timestamptz not null default now()
);
create index colmeia_harvests_apiary on public.colmeia_harvests (apiary_id, harvested_on desc);

alter table public.colmeia_harvests enable row level security;
create policy "dono lê colheitas" on public.colmeia_harvests
  for select to authenticated using (owner_id = auth.uid());
revoke insert, update, delete on public.colmeia_harvests from anon, authenticated;

-- Registrar colheita (p_device_id vazio = apiário todo ou caixa sem rastreador).
create or replace function public.colmeia_add_harvest(p_apiary_id uuid, p_device_id text, p_date date,
                                                      p_kg numeric, p_note text default null)
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
  if p_date is null or p_date > current_date + 1 or p_date < date '2000-01-01' then
    raise exception 'Data da colheita inválida.' using errcode = '22023';
  end if;
  if p_kg is null or p_kg <= 0 or p_kg > 10000 then
    raise exception 'Informe a quantidade de mel em kg (maior que zero).' using errcode = '22023';
  end if;
  insert into public.colmeia_harvests (owner_id, apiary_id, device_id, harvested_on, kg, source, note)
  values (uid, p_apiary_id, nullif(p_device_id, ''), p_date, round(p_kg, 2), 'manual',
          nullif(left(trim(coalesce(p_note, '')), 200), ''))
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.colmeia_delete_harvest(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.colmeia_harvests where id = p_id and owner_id = auth.uid();
  if not found then
    raise exception 'colheita não encontrada' using errcode = 'P0002';
  end if;
end $$;

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

  -- 4) Colheita pela balança: queda de 5 a 60 kg entre duas pesagens seguidas (melgueiras
  --    retiradas), com a caixa ainda pesando 10 kg ou mais (não é roubo). O mel colhido é o
  --    peso ganho desde que a melgueira foi colocada; sem essa referência, usa a queda de peso.
  select * into s from (
    select w.measured_at, w.kg, lag(w.kg) over win as prev_kg, lag(w.measured_at) over win as prev_at
    from public.colmeia_weights w
    where w.device_id = d.id and w.kg is not null and w.measured_at > now() - interval '30 hours'
    window win as (order by w.measured_at)) t
  where t.prev_kg - t.kg between 5 and 60
    and t.kg >= 10
    and t.measured_at - t.prev_at <= interval '12 hours'
  order by t.measured_at desc limit 1;
  if found and d.apiary_id is not null and d.owner_id is not null
     and not exists (select 1 from public.colmeia_harvests h
                     where h.device_id = d.id and h.source = 'balanca' and h.created_at > now() - interval '2 days') then
    insert into public.colmeia_harvests (owner_id, apiary_id, device_id, harvested_on, kg, source, note)
    values (d.owner_id, d.apiary_id, d.id, (s.measured_at at time zone 'America/Sao_Paulo')::date,
            case when d.harvest_base_kg is not null and s.prev_kg - d.harvest_base_kg > 0
                 then s.prev_kg - d.harvest_base_kg else s.prev_kg - s.kg end,
            'balanca', null);
    -- Nova safra: o apicultor marca de novo quando recolocar a melgueira.
    update public.colmeia_devices set harvest_base_at = null, harvest_base_kg = null, harvest_notified_at = null
    where id = d.id;
  end if;
end $$;

revoke execute on function
  public.colmeia_add_harvest(uuid, text, date, numeric, text),
  public.colmeia_delete_harvest(bigint)
  from public, anon, authenticated;
grant execute on function public.colmeia_add_harvest(uuid, text, date, numeric, text) to authenticated;
grant execute on function public.colmeia_delete_harvest(bigint) to authenticated;
