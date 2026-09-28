-- Agenda o escalonamento para rodar a cada minuto (pg_cron do Supabase).
-- O envio das mensagens (função "dispatch") é agendado em docs/INSTALACAO.md,
-- porque precisa do endereço do projeto e de uma chave.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('colmeia-escalonamento', '* * * * *', 'select public.escalate_alerts()');
  else
    raise notice 'pg_cron indisponível: agende public.escalate_alerts() manualmente';
  end if;
end $$;
