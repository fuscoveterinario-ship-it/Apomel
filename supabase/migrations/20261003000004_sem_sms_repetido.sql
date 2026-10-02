-- Bee Guard — não manda o mesmo aviso duas vezes para o mesmo número (secundário = principal).

create or replace function public.colmeia_enqueue_alert_messages(p_alert_id uuid, p_phone text, p_template text,
                                                                 p_extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  a public.colmeia_alerts;
  d public.colmeia_devices;
  params jsonb;
begin
  if p_phone is null then return; end if;
  -- Mesmo aviso do mesmo alerta para o mesmo número (ex.: secundário igual ao principal): manda uma vez só.
  if exists (select 1 from public.colmeia_notifications
             where alert_id = p_alert_id and template = p_template
               and regexp_replace(to_phone, '\D', '', 'g') = regexp_replace(p_phone, '\D', '', 'g')) then
    return;
  end if;
  select * into a from public.colmeia_alerts where id = p_alert_id;
  select * into d from public.colmeia_devices where id = a.device_id;
  params := jsonb_build_object(
    'caixa',   coalesce(d.hive_label, d.id),
    'apiario', coalesce((select name from public.colmeia_apiaries where id = d.apiary_id), 'apiário'),
    'link',    public.colmeia_setting('site_url') || '/alerta.html?t=' || a.token,
    'hora',    to_char(d.last_seen_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    'quando',  to_char(a.opened_at at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'mapa',    case when d.last_lat is not null then
                 'https://maps.google.com/?q=' || round(d.last_lat::numeric, 5) || ',' || round(d.last_lon::numeric, 5) end
  ) || coalesce(p_extra, '{}'::jsonb);
  insert into public.colmeia_notifications (alert_id, device_id, to_phone, channel, template, body, params)
  select a.id, d.id, p_phone, ch, p_template, public.colmeia_render_message(p_template, params), params
  from unnest(array['whatsapp', 'sms']) as ch;
end $$;
