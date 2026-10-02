-- Bee Guard — SMS de alerta com a hora do movimento e o link do mapa (última posição).

create or replace function public.colmeia_enqueue_alert_messages(p_alert_id uuid, p_phone text, p_template text,
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
    'hora',    to_char(d.last_seen_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    'quando',  to_char(a.opened_at at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'mapa',    case when d.last_lat is not null then
                 'https://maps.google.com/?q=' || round(d.last_lat::numeric, 5) || ',' || round(d.last_lon::numeric, 5) end
  ) || coalesce(p_extra, '{}'::jsonb);
  insert into public.colmeia_notifications (alert_id, device_id, to_phone, channel, template, body, params)
  select a.id, d.id, p_phone, ch, p_template, public.colmeia_render_message(p_template, params), params
  from unnest(array['whatsapp', 'sms']) as ch;
end $$;

create or replace function public.colmeia_render_message(p_template text, p_params jsonb)
returns text language plpgsql immutable set search_path = public as $$
declare
  caixa   text := coalesce(p_params->>'caixa', 'caixa');
  apiario text := coalesce(p_params->>'apiario', 'apiário');
  link    text := coalesce(p_params->>'link', '');
  hora    text := coalesce(p_params->>'hora', '');
  kg      text := coalesce(p_params->>'kg', '');
  -- Hora em que a caixa foi mexida e link do mapa com a última posição (quando houver).
  quando  text := coalesce(' às ' || nullif(p_params->>'quando', ''), '');
  local   text := coalesce(' Local: ' || nullif(p_params->>'mapa', ''), '');
begin
  return case p_template
    when 'alerta_movimento' then
      format('ALERTA BEE GUARD: a %s (%s) foi movimentada%s. Foi você fazendo manutenção? Responda em até 5 minutos: %s', caixa, apiario, quando, link) || local
    when 'alerta_escalado' then
      format('ALERTA BEE GUARD: POSSÍVEL ROUBO da %s (%s), movimentada%s e sem resposta em 5 minutos. Rastreamento ativado. Acompanhe: %s', caixa, apiario, quando, link) || local
    when 'roubo_confirmado' then
      format('ALERTA BEE GUARD: ROUBO CONFIRMADO da %s (%s), movimentada%s. Rastreamento intensivo ativado. Acompanhe: %s', caixa, apiario, quando, link) || local
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
      format('ALERTA BEE GUARD: ATAQUE AO APIÁRIO %s%s. %s foram movimentadas. POSSÍVEL ROUBO. Rastreamento ativado. Veja: %s', apiario, quando, coalesce(p_params->>'caixas', 'Várias caixas'), link) || local
    when 'teste_alerta' then
      format('BEE GUARD: teste do alerta OK. O rastreador da %s (%s) detectou o movimento. Quando a caixa for mexida de verdade, você recebe uma mensagem como esta com um link para responder.', caixa, apiario)
    when 'fora_da_cerca' then
      format('ALERTA BEE GUARD: a %s está a %s do local do %s%s. Foi você? Responda em até 5 minutos: %s', caixa, coalesce(p_params->>'distancia', 'longe'), apiario, quando, link) || local
    when 'cerca_ativa' then
      format('BEE GUARD: local da %s (%s) registrado. A proteção por distância está ativa: se a caixa sair de lá, você é avisado.', caixa, apiario)
    else format('BEE GUARD: aviso sobre a %s (%s): %s', caixa, apiario, link)
  end;
end $$;
