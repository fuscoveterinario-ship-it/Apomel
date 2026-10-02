-- Bee Guard — celular como rastreador de teste sem código nem segredo:
-- o apicultor entra com o e-mail, informa o telefone que recebe o alerta e o sistema cria
-- (ou reaproveita) um rastreador de teste só dele, no apiário "Teste (celular)".

create or replace function public.colmeia_my_test_device(p_phone text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  ph  text := nullif(trim(coalesce(p_phone, '')), '');
  did text;
  ap  uuid;
  hv  uuid;
  s   text;
begin
  if uid is null then raise exception 'faça login' using errcode = '42501'; end if;
  if ph is null or ph !~ '^\+[0-9]{10,15}$' then
    raise exception 'Informe o telefone com DDD, ex.: (41) 99999-0001.' using errcode = '22023';
  end if;

  select id into did from public.colmeia_devices where owner_id = uid and id like 'TESTE-%' order by id limit 1;
  if did is null then
    did := 'TESTE-' || upper(encode(gen_random_bytes(4), 'hex'));
    perform public.colmeia_provision_device(did, encode(gen_random_bytes(24), 'hex'), encode(gen_random_bytes(8), 'hex'));
  end if;

  insert into public.colmeia_apiaries (owner_id, name) values (uid, 'Teste (celular)')
  on conflict (owner_id, name) do update set name = excluded.name
  returning id into ap;
  insert into public.colmeia_hives (owner_id, apiary_id, label) values (uid, ap, 'Celular de teste')
  on conflict (apiary_id, label) do nothing;
  select id into hv from public.colmeia_hives where apiary_id = ap and label = 'Celular de teste';

  update public.colmeia_devices set
    owner_id = uid, apiary_id = ap, hive_id = hv, hive_label = 'Celular de teste',
    primary_phone = ph, secondary_phone = null, phones_from_apiary = false,
    status = 'ativo', activated_at = coalesce(activated_at, now())
  where id = did;

  select secret into s from public.colmeia_device_secrets where device_id = did;
  return jsonb_build_object('id', did, 'secret', s);
end $$;

revoke execute on function public.colmeia_my_test_device(text) from public, anon, authenticated;
grant execute on function public.colmeia_my_test_device(text) to authenticated;
