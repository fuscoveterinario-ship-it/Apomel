-- Bee Guard — teste com o celular sem gasto à toa: alerta de teste vale 20 minutos, sem aviso
-- de "sem comunicação" e no máximo 12 SMS por dia por rastreador de teste.

create or replace function public.colmeia_is_test_device(p_device_id text)
returns boolean language sql immutable as $$
  select p_device_id like 'TESTE-%' or p_device_id = 'CS-CELULAR'
$$;

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

  -- Rastreador de teste (celular): sem "sem comunicação" (fechar a página não é roubo), alerta
  -- vale por 20 minutos (depois é encerrado sem mandar nada) e no máximo 12 SMS por dia.
  if public.colmeia_is_test_device(d.id) then
    if p_template = 'offline' then return; end if;
    if a.opened_at < now() - interval '20 minutes' then
      update public.colmeia_alerts set status = 'encerrado', resolved_at = now(), resolution = 'teste encerrado (20 min)'
      where id = a.id and status in ('pendente', 'escalado', 'roubo_confirmado');
      update public.colmeia_devices set mode = 'normal' where id = d.id;
      return;
    end if;
    if (select count(*) from public.colmeia_notifications
        where device_id = d.id and channel = 'sms' and created_at > now() - interval '24 hours') >= 12 then
      return;
    end if;
  end if;
  params := jsonb_build_object(
    'caixa',   coalesce(d.hive_label, d.id),
    'apiario', coalesce((select name from public.colmeia_apiaries where id = d.apiary_id), 'apiário'),
    'link',    public.colmeia_setting('site_url') || '/alerta.html?t=' || a.token,
    'hora',    to_char(d.last_seen_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    'quando',  to_char(a.opened_at at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'mapa',    case when d.last_lat is not null then
                 'https://maps.google.com/?q=' || round(d.last_lat::numeric, 5) || ',' || round(d.last_lon::numeric, 5) end
  ) || coalesce(p_extra, '{}'::jsonb);
  -- Alerta de segurança por SMS sai em 2 mensagens: primeiro a curta, sem link (chega na hora),
  -- depois a completa, com o link para responder e o mapa.
  if p_template in ('alerta_movimento', 'alerta_escalado', 'roubo_confirmado', 'ataque_apiario', 'fora_da_cerca') then
    insert into public.colmeia_notifications (alert_id, device_id, to_phone, channel, template, body, params)
    values (a.id, d.id, p_phone, 'sms', p_template || '_curto',
            public.colmeia_render_message(p_template || '_curto', params), params);
  end if;
  insert into public.colmeia_notifications (alert_id, device_id, to_phone, channel, template, body, params)
  select a.id, d.id, p_phone, ch, p_template, public.colmeia_render_message(p_template, params), params
  from unnest(array['whatsapp', 'sms']) as ch;
end $$;
