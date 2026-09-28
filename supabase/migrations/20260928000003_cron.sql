-- Agenda o escalonamento para rodar a cada minuto (pg_cron do Supabase).
-- O envio das mensagens (função "colmeia-dispatch") é agendado em docs/INSTALACAO.md (passo 4),
-- porque precisa do endereço do projeto e de uma chave.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('colmeia-escalonamento', '* * * * *', 'select public.colmeia_escalate_alerts()');
  else
    raise notice 'pg_cron indisponível: agende public.colmeia_escalate_alerts() manualmente';
  end if;
end $$;

-- No projeto instalado, o envio a cada minuto foi agendado assim (endereço e chave anon
-- do projeto; ver docs/INSTALACAO.md, passo 4):
--   select cron.schedule('colmeia-envio', '* * * * *', $$ select net.http_post(
--     url := 'https://<projeto>.supabase.co/functions/v1/colmeia-dispatch', ...) $$);
