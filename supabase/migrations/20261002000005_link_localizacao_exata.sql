-- Bee Guard — o apicultor escolhe, ao gerar o link, se mostra a localização exata das caixas
-- (alfinete no mapa e botão "Ver no Google Maps") ou só a região (cerca de 1 km).

alter table public.colmeia_share_links add column exact_location boolean not null default false;

-- p_apiary_id vazio = todos os apiários. Reaproveita um link igual que ainda valha 30 dias ou mais.
create or replace function public.colmeia_share_link(p_apiary_id uuid, p_exact boolean)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  t   text;
begin
  if uid is null then raise exception 'faça login' using errcode = '42501'; end if;
  if p_apiary_id is not null
     and not exists (select 1 from public.colmeia_apiaries where id = p_apiary_id and owner_id = uid) then
    raise exception 'apiário não encontrado' using errcode = 'P0002';
  end if;
  select token into t from public.colmeia_share_links
  where apiary_id is not distinct from p_apiary_id and owner_id = uid
    and exact_location = coalesce(p_exact, false) and expires_at > now() + interval '30 days'
  order by created_at desc limit 1;
  if t is null then
    insert into public.colmeia_share_links (owner_id, apiary_id, exact_location)
    values (uid, p_apiary_id, coalesce(p_exact, false)) returning token into t;
  end if;
  return t;
end $$;

revoke execute on function public.colmeia_share_link(uuid, boolean) from public, anon, authenticated;
grant execute on function public.colmeia_share_link(uuid, boolean) to authenticated;

create or replace function public.colmeia_shared_view(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l   public.colmeia_share_links;
  aps uuid[];
begin
  select * into l from public.colmeia_share_links where token = p_token and expires_at > now();
  if not found then
    raise exception 'link inválido ou expirado' using errcode = 'P0002';
  end if;
  select coalesce(array_agg(a.id order by a.name), '{}') into aps from public.colmeia_apiaries a
  where a.owner_id = l.owner_id and (l.apiary_id is null or a.id = l.apiary_id);
  return jsonb_build_object(
    'todos', l.apiary_id is null,
    'exata', l.exact_location,
    'apiarios', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'city', a.city,
        'apicultor', a.keeper_name) order by a.name)
      from public.colmeia_apiaries a where a.id = any (aps)), '[]'::jsonb),
    'apiario', (select jsonb_build_object('id', a.id, 'name', a.name, 'city', a.city, 'apicultor', a.keeper_name)
      from public.colmeia_apiaries a where a.id = aps[1]),
    'colmeias', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'apiary_id', h.apiary_id, 'label', h.label) order by h.label)
      from public.colmeia_hives h where h.apiary_id = any (aps)), '[]'::jsonb),
    'devices', coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'hive_label', d.hive_label, 'hive_id', d.hive_id, 'apiary_id', d.apiary_id, 'mode', d.mode,
        'maintenance_until', d.maintenance_until, 'last_seen_at', d.last_seen_at, 'last_battery_mv', d.last_battery_mv,
        'last_scale_raw', d.last_scale_raw, 'last_scale_raw_at', d.last_scale_raw_at, 'scale_factor', d.scale_factor,
        'last_weight_kg', d.last_weight_kg, 'harvest_base_kg', d.harvest_base_kg, 'harvest_base_at', d.harvest_base_at,
        'harvest_gain_kg', d.harvest_gain_kg,
        'regiao_lat', round(d.last_lat::numeric, 2), 'regiao_lon', round(d.last_lon::numeric, 2),
        'lat', case when l.exact_location then d.last_lat end, 'lon', case when l.exact_location then d.last_lon end) order by d.id)
      from public.colmeia_devices d where d.apiary_id = any (aps) and d.status = 'ativo'), '[]'::jsonb),
    'alertas', coalesce((select jsonb_agg(jsonb_build_object('device_id', a.device_id, 'kind', a.kind, 'status', a.status))
      from public.colmeia_alerts a join public.colmeia_devices d on d.id = a.device_id
      where d.apiary_id = any (aps) and a.status in ('pendente', 'escalado', 'roubo_confirmado')), '[]'::jsonb),
    'pesos', coalesce((select jsonb_agg(jsonb_build_object('device_id', w.device_id, 'measured_at', w.measured_at, 'kg', w.kg)
        order by w.measured_at)
      from public.colmeia_weights w join public.colmeia_devices d on d.id = w.device_id
      where d.apiary_id = any (aps) and w.kg is not null and w.measured_at > now() - interval '14 days'), '[]'::jsonb),
    'colheitas', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'apiary_id', h.apiary_id, 'device_id', h.device_id,
        'hive_id', h.hive_id,
        'harvested_on', h.harvested_on, 'kg', h.kg, 'source', h.source, 'note', h.note) order by h.harvested_on desc)
      from public.colmeia_harvests h where h.apiary_id = any (aps)), '[]'::jsonb)
  );
end $$;
