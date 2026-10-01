-- Bee Guard — nome do apicultor responsável no apiário (aparece no link compartilhado).
alter table public.colmeia_apiaries
  add column keeper_name text check (char_length(keeper_name) <= 80);

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
    'apiario', (select jsonb_build_object('id', a.id, 'name', a.name, 'city', a.city, 'apicultor', a.keeper_name) from public.colmeia_apiaries a where a.id = l.apiary_id),
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

