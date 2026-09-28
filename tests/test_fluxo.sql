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

\echo 'TODOS OS TESTES PASSARAM'
