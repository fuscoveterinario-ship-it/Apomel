-- Teste do fluxo completo: estoque → ativação → movimento → escalonamento → resposta.
-- Rodar com: tests/run_db_tests.sh
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.check(cond boolean, msg text) returns void language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FALHOU: %', msg; end if;
  raise notice 'ok: %', msg;
end $$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'apicultor@teste'),
  ('00000000-0000-0000-0000-00000000000b', 'outro@teste');

-- Fábrica: cadastra o rastreador no estoque.
select public.colmeia_provision_device('CS-0001', 'segredo-de-teste', 'ABCD-2345');

-- 1) Primeira mensagem antes da ativação (teste de bancada) só registra.
select pg_temp.check(
  (public.colmeia_ingest_event('CS-0001', 1, 'online', -25.4, -49.2, 4100, 20, '4g')->>'mode') = 'normal',
  'rastreador em estoque responde configuração');
select pg_temp.check((select count(*) from public.colmeia_alerts) = 0, 'estoque não gera alerta');

-- 2) Ativação com código errado falha; com o certo funciona.
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
do $$ begin
  perform public.colmeia_activate_device('CS-0001', 'ERRADO', 'Sítio Santa Rita', 'Caixa 12', '+5541999990001');
  raise exception 'FALHOU: aceitou código errado';
exception when sqlstate 'P0002' then raise notice 'ok: código errado recusado';
end $$;
select public.colmeia_activate_device('cs-0001', 'abcd-2345', 'Sítio Santa Rita', 'Caixa 12',
                              '+5541999990001', '+5541999990002');
select pg_temp.check((select count(*) from public.colmeia_devices where id = 'CS-0001') = 1, 'dono enxerga o rastreador (RLS)');
reset role;

-- Outro usuário não vê nem consegue ativar o mesmo rastreador.
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select pg_temp.check((select count(*) from public.colmeia_devices) = 0, 'outro usuário não enxerga (RLS)');
do $$ begin
  perform public.colmeia_activate_device('CS-0001', 'ABCD-2345', 'Meu', 'Caixa 1', '+5541999990009');
  raise exception 'FALHOU: outro usuário ativou';
exception when sqlstate '42501' then raise notice 'ok: outro usuário recusado';
end $$;
do $$ begin
  perform token from public.colmeia_alerts;
  raise exception 'FALHOU: token do alerta legível';
exception when insufficient_privilege then raise notice 'ok: token do alerta protegido';
end $$;
reset role;

-- 3) Movimento abre alerta e coloca WhatsApp + SMS na fila para o principal.
select public.colmeia_ingest_event('CS-0001', 2, 'movimento', -25.4, -49.2, 4000, 18, '4g');
select pg_temp.check((select count(*) from public.colmeia_alerts where kind = 'movimento' and status = 'pendente') = 1,
  'movimento abre alerta pendente');
select pg_temp.check((public.colmeia_ingest_event('CS-0001', 2, 'movimento')->>'alert_open')::boolean,
  'rastreador sabe que há alerta aberto');
select pg_temp.check((public.colmeia_ingest_event('CS-0001', 2, 'movimento')->>'caixa') = 'Caixa 12'
                     and (public.colmeia_ingest_event('CS-0001', 2, 'movimento')->>'theft_sms_interval_s')::int = 300,
  'rastreador recebe o nome da caixa e o intervalo do SMS de roubo');
select pg_temp.check((select count(*) from public.colmeia_notifications
                      where to_phone = '+5541999990001' and template = 'alerta_movimento') = 2,
  'WhatsApp e SMS na fila para o principal');
select pg_temp.check((select body from public.colmeia_notifications where channel = 'sms' limit 1)
                     like '%Caixa 12 foi movimentada no Sítio Santa Rita%', 'texto da mensagem');

-- Movimento repetido e reenvio (mesmo seq) não duplicam alerta.
select public.colmeia_ingest_event('CS-0001', 3, 'movimento');
select pg_temp.check((public.colmeia_ingest_event('CS-0001', 3, 'movimento')->>'duplicate')::boolean, 'reenvio detectado');
select pg_temp.check((select count(*) from public.colmeia_alerts where kind = 'movimento') = 1, 'sem alerta duplicado');

-- 4) Antes de 5 minutos nada escala; depois, escala e ativa modo roubo.
select pg_temp.check(public.colmeia_escalate_alerts() = 0, 'não escala antes do prazo');
update public.colmeia_alerts set escalate_at = now() - interval '1 second';
select pg_temp.check(public.colmeia_escalate_alerts() = 1, 'escala após o prazo');
select pg_temp.check((select mode from public.colmeia_devices where id = 'CS-0001') = 'roubo', 'modo roubo ativado');
select pg_temp.check((select count(*) from public.colmeia_notifications
                      where to_phone = '+5541999990002' and template = 'alerta_escalado') = 2,
  'contato secundário avisado');
select pg_temp.check((public.colmeia_ingest_event('CS-0001', 4, 'posicao', -25.5, -49.3)->>'mode') = 'roubo',
  'rastreador recebe ordem de modo roubo');

-- 5) Resposta pelo link: "Sou eu" encerra e volta ao normal.
select pg_temp.check(
  (public.colmeia_respond_alert((select token from public.colmeia_alerts where kind = 'movimento'), 'manutencao')
     #>> '{alert,status}') = 'manutencao', 'resposta "sou eu" encerra o alerta');
select pg_temp.check((select mode from public.colmeia_devices where id = 'CS-0001') = 'normal', 'volta ao modo normal');
select public.colmeia_ingest_event('CS-0001', 5, 'movimento');
select pg_temp.check((select count(*) from public.colmeia_alerts where kind = 'movimento') = 1,
  'durante manutenção não abre novo alerta');

-- 6) Resposta "possível roubo" avisa o secundário na hora.
update public.colmeia_devices set maintenance_until = null;
select public.colmeia_ingest_event('CS-0001', 6, 'movimento');
select pg_temp.check(
  (public.colmeia_respond_alert((select token from public.colmeia_alerts where kind = 'movimento' and status = 'pendente'), 'roubo')
     #>> '{alert,status}') = 'roubo_confirmado', 'resposta "roubo" confirma');
select pg_temp.check((select count(*) from public.colmeia_notifications where template = 'roubo_confirmado') = 2,
  'secundário avisado do roubo confirmado');
do $$ begin
  perform public.colmeia_respond_alert('token-que-nao-existe', 'ver');
  raise exception 'FALHOU: token inválido aceito';
exception when sqlstate 'P0002' then raise notice 'ok: token inválido recusado';
end $$;

-- 7) Rastreador em silêncio gera aviso "sem comunicação"; voltar a falar encerra.
select pg_temp.check((select heartbeat_min from public.colmeia_devices where id = 'CS-0001') = 1440,
  'mensagem de vida 1 vez por dia por padrão');
update public.colmeia_devices set mode = 'normal', last_seen_at = now() - interval '47 hours';
select pg_temp.check(public.colmeia_escalate_alerts() = 0, 'um dia sem mensagem ainda não é aviso');
update public.colmeia_devices set last_seen_at = now() - interval '49 hours';
select pg_temp.check(public.colmeia_escalate_alerts() = 1, 'aviso de rastreador sem comunicação');
select pg_temp.check(public.colmeia_escalate_alerts() = 0, 'aviso sem comunicação não repete');
select public.colmeia_ingest_event('CS-0001', 7, 'vida', null, null, 3900);
select pg_temp.check((select status from public.colmeia_alerts where kind = 'offline') = 'encerrado',
  'voltou a comunicar encerra aviso');

-- 8) Bateria baixa avisa uma vez por dia.
select public.colmeia_ingest_event('CS-0001', 8, 'vida', null, null, 3300);
select public.colmeia_ingest_event('CS-0001', 9, 'vida', null, null, 3300);
select pg_temp.check((select count(*) from public.colmeia_alerts where kind = 'bateria_baixa') = 1, 'bateria baixa avisa 1x');

-- 9) Balança (colmeia sentinela)
-- Antes da calibração guarda só o valor bruto.
select public.colmeia_ingest_event('CS-0001', 10, 'online', null, null, 4000, 20, '4g', '{"ws":[[0,100000]]}');
select pg_temp.check((select last_scale_raw = 100000 and last_weight_kg is null from public.colmeia_devices where id = 'CS-0001'),
  'pesagem sem calibração guarda o valor bruto');
select public.colmeia_ingest_event('CS-0001', 10, 'online', null, null, 4000, 20, '4g', '{"ws":[[0,100000]]}');
select pg_temp.check((select count(*) from public.colmeia_weights) = 1, 'pesagem reenviada não duplica');

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select public.colmeia_scale_calibrate('CS-0001', 'zero');
do $$ begin
  perform public.colmeia_scale_calibrate('CS-0001', 'peso', 5);
  raise exception 'FALHOU: calibrou sem nova pesagem';
exception when sqlstate 'P0001' then raise notice 'ok: calibração pede nova pesagem com o peso em cima';
end $$;
reset role;
select public.colmeia_ingest_event('CS-0001', 11, 'online', null, null, 4000, 20, '4g', '{"ws":[[0,150000]]}');
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select pg_temp.check((public.colmeia_scale_calibrate('CS-0001', 'peso', 5)->>'kg')::numeric = 5, 'calibração com 5 kg');
select public.colmeia_set_harvest('CS-0001', 15, null, true);
reset role;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$ begin
  perform public.colmeia_scale_calibrate('CS-0001', 'zero');
  raise exception 'FALHOU: outro usuário calibrou';
exception when sqlstate 'P0002' then raise notice 'ok: outro usuário não mexe na balança';
end $$;
select pg_temp.check((select count(*) from public.colmeia_weights) = 0, 'outro usuário não vê as pesagens (RLS)');
reset role;
select pg_temp.check((select kg from public.colmeia_weights order by measured_at limit 1) = 0, 'pesagens antigas recalculadas');

-- Melgueira colocada há 2 dias; referência = primeira pesagem 30 min depois (40 kg).
update public.colmeia_devices set harvest_base_at = now() - interval '2 days' where id = 'CS-0001';
select public.colmeia_ingest_event('CS-0001', 12, 'vida', null, null, 4000, 20, '4g',
  '{"ws":[[86400,500000],[43200,620000],[0,660000]]}');
select pg_temp.check((select harvest_base_kg from public.colmeia_devices where id = 'CS-0001') = 40, 'peso de referência da melgueira');
select pg_temp.check((select last_weight_kg from public.colmeia_devices where id = 'CS-0001') = 56, 'peso atual em kg');
select pg_temp.check((select count(*) from public.colmeia_alerts where kind = 'colheita') = 0,
  'sem aviso de colheita enquanto as 2 últimas pesagens não chegam ao ganho');
select public.colmeia_ingest_event('CS-0001', 13, 'vida', null, null, 4000, 20, '4g', '{"ws":[[0,665000]]}');
select pg_temp.check((select count(*) from public.colmeia_alerts where kind = 'colheita') = 1, 'aviso de colheita');
select pg_temp.check((select body from public.colmeia_notifications where template = 'colheita' and channel = 'sms')
                     like '%ganhou 16,0 kg%painel.html', 'texto do aviso de colheita');
select public.colmeia_ingest_event('CS-0001', 14, 'vida', null, null, 4000, 20, '4g', '{"ws":[[0,670000]]}');
select pg_temp.check((select count(*) from public.colmeia_alerts where kind = 'colheita') = 1, 'aviso de colheita não repete');

-- Peso baixo (fome).
update public.colmeia_devices set hunger_kg = 70 where id = 'CS-0001';
select public.colmeia_ingest_event('CS-0001', 15, 'vida', null, null, 4000, 20, '4g', '{"ws":[[0,671000]]}');
select pg_temp.check((select body from public.colmeia_notifications where template = 'peso_baixo' and channel = 'sms')
                     like '%57,1 kg%', 'aviso de peso baixo');

-- Queda de 2 kg entre duas pesagens durante o dia: possível enxameação.
delete from public.colmeia_weights;
insert into public.colmeia_weights (device_id, measured_at, raw, kg)
select 'CS-0001', (dia + h) at time zone 'America/Sao_Paulo', 0, kg
from (select date_trunc('day', now() at time zone 'America/Sao_Paulo')
             - case when extract(hour from now() at time zone 'America/Sao_Paulo') >= 14 then interval '0' else interval '1 day' end as dia) x,
     (values (interval '11 hours', 56.6), (interval '13 hours', 54.6)) v(h, kg);
select public.colmeia_check_weight_alerts('CS-0001');
select pg_temp.check((select body from public.colmeia_notifications where template = 'enxame' and channel = 'sms')
                     like '%perdeu 2,0 kg de repente perto das 13:00%', 'aviso de possível enxameação');

-- Alerta de movimento mostra o peso antes e na hora (caixa tirada da balança).
update public.colmeia_alerts set status = 'encerrado' where kind = 'movimento';
update public.colmeia_devices set mode = 'normal', maintenance_until = null where id = 'CS-0001';
select public.colmeia_ingest_event('CS-0001', 16, 'movimento', null, null, 4000, 20, '4g', '{"w":100000}');
select pg_temp.check(
  (select (r #>> '{balanca,antes}')::numeric = 54.6 and (r #>> '{balanca,no_alerta}')::numeric = 0
   from (select public.colmeia_respond_alert(token, 'ver') r from public.colmeia_alerts
         where kind = 'movimento' and status = 'pendente') t),
  'alerta mostra o peso antes e na hora do movimento');

-- 10) Limite de pedidos de código de acesso: 3 por e-mail a cada 15 min.
select pg_temp.check(public.colmeia_login_allowed('Teste@Exemplo.com') and public.colmeia_login_allowed('teste@exemplo.com ')
                     and public.colmeia_login_allowed('teste@exemplo.com'), 'três pedidos de código passam');
select pg_temp.check(not public.colmeia_login_allowed('TESTE@exemplo.com'), 'quarto pedido em 15 min é recusado');
select pg_temp.check(public.colmeia_login_allowed('outro@exemplo.com'), 'outro e-mail não é afetado');
select pg_temp.check((select count(*) from public.colmeia_login_requests where email_hash like '%@%') = 0, 'guarda só o hash do e-mail');

\echo 'TODOS OS TESTES PASSARAM'
