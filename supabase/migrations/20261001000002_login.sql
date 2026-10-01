-- Bee Guard — limite de pedidos de código de acesso (função colmeia-login).
-- Guarda só o hash do e-mail; registros com mais de 1 dia são apagados.

create table public.colmeia_login_requests (
  id          bigint generated always as identity primary key,
  email_hash  text not null,
  created_at  timestamptz not null default now()
);
create index colmeia_login_requests_email on public.colmeia_login_requests (email_hash, created_at);
alter table public.colmeia_login_requests enable row level security;
revoke all on public.colmeia_login_requests from anon, authenticated;

-- Até 3 códigos por e-mail a cada 15 minutos e 200 por hora no total.
create or replace function public.colmeia_login_allowed(p_email text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  h text := encode(digest(lower(trim(p_email)), 'sha256'), 'hex');
begin
  delete from public.colmeia_login_requests where created_at < now() - interval '1 day';
  if (select count(*) from public.colmeia_login_requests
      where email_hash = h and created_at > now() - interval '15 minutes') >= 3 then
    return false;
  end if;
  if (select count(*) from public.colmeia_login_requests where created_at > now() - interval '1 hour') >= 200 then
    return false;
  end if;
  insert into public.colmeia_login_requests (email_hash) values (h);
  return true;
end $$;

revoke execute on function public.colmeia_login_allowed(text) from public, anon, authenticated;
