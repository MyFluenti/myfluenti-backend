-- =====================================================================
-- MyFluenti - Testes da migration 006: avatar montavel do usuario
--   private.is_valid_avatar_config, profiles.avatar_config (check),
--   update_my_avatar e avatar_config em get_profile_summary.
-- Autocontido. Roda DEPOIS do 30 (e do 40, se existir), no mesmo banco:
--   (1) Supabase local: db reset -> 10 -> 20 -> 30 -> 50
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> 20 -> 30 -> 50
-- Helpers com prefixo za_. Usuarios: a5a5a5a5 (A), b5b5b5b5 (B), c5c5c5c5 (C).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

create function public.za_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.za_expect_error(p_sql text, p_state text default null, p_msg text default null)
returns void language plpgsql as $$
declare s text; m text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics s = returned_sqlstate, m = message_text;
    if p_state is not null and s <> p_state then
      raise exception 'FAIL (estado errado): % -> %, %', p_sql, s, m;
    end if;
    if p_msg is not null and position(p_msg in m) = 0 then
      raise exception 'FAIL (mensagem errada): % -> %', p_sql, m;
    end if;
    raise notice 'PASS (erro esperado): % [%]', left(p_sql, 70), left(m, 50);
    return;
  end;
  raise exception 'FAIL (era esperado erro): %', p_sql;
end $$;

create function public.za_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

create function public.za_base() returns jsonb language sql immutable as $$
  select '{"v":1,"skin":1,"hair":3,"hairColor":0,"eyes":1,"mouth":0,"acc":2,"outfit":0,"bg":0}'::jsonb
$$;

-- config invalida: 22023 invalid_avatar_config e o valor gravado antes nao muda
create function public.za_bad(p_cfg jsonb, p_label text) returns void
language plpgsql as $$
declare before_v jsonb; after_v jsonb; s text; m text;
begin
  select avatar_config into before_v from public.profiles where id = auth.uid();
  begin
    perform public.update_my_avatar(p_cfg);
  exception when others then
    get stacked diagnostics s = returned_sqlstate, m = message_text;
    if s <> '22023' or m <> 'invalid_avatar_config' then
      raise exception 'FAIL (erro errado) %: % %', p_label, s, m;
    end if;
    select avatar_config into after_v from public.profiles where id = auth.uid();
    if after_v is distinct from before_v then
      raise exception 'FAIL (valor anterior alterado) %', p_label;
    end if;
    raise notice 'PASS: invalida (%): 22023 e valor anterior intacto', p_label;
    return;
  end;
  raise exception 'FAIL (era esperado erro) %', p_label;
end $$;

grant execute on function public.za_assert(boolean, text), public.za_expect_error(text, text, text),
  public.za_as(uuid), public.za_base(), public.za_bad(jsonb, text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Setup (postgres)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a5a5a5a5-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'za-a@teste'),
  ('b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'za-b@teste'),
  ('c5c5c5c5-cccc-cccc-cccc-cccccccccccc', 'za-c@teste');

select public.za_assert((select avatar_config is null from public.profiles
  where id = 'a5a5a5a5-aaaa-aaaa-aaaa-aaaaaaaaaaaa'), 'COLUNA: perfil novo tem avatar_config NULL (avatar padrao)');

-- ---------------------------------------------------------------------
-- Funcao de validacao (direto, como postgres): nunca lanca erro
-- ---------------------------------------------------------------------
select public.za_assert(private.is_valid_avatar_config(public.za_base()), 'VALIDA: config do contrato');
select public.za_assert(private.is_valid_avatar_config('{"v":1,"skin":0,"hair":0,"hairColor":0,"eyes":0,"mouth":0,"acc":0,"outfit":0,"bg":0}'),
  'VALIDA: todos os minimos');
select public.za_assert(private.is_valid_avatar_config('{"v":1,"skin":4,"hair":5,"hairColor":4,"eyes":2,"mouth":1,"acc":2,"outfit":4,"bg":4}'),
  'VALIDA: todos os maximos');
select public.za_assert(not private.is_valid_avatar_config(null), 'VALIDA: SQL null devolve false (sem erro)');
select public.za_assert(not private.is_valid_avatar_config('null'::jsonb), 'VALIDA: JSON null devolve false');
select public.za_assert(not private.is_valid_avatar_config('[]'::jsonb) and not private.is_valid_avatar_config('[1,2,3]'::jsonb),
  'VALIDA: array devolve false');
select public.za_assert(not private.is_valid_avatar_config('1'::jsonb) and not private.is_valid_avatar_config('"x"'::jsonb)
  and not private.is_valid_avatar_config('true'::jsonb), 'VALIDA: escalares devolvem false');
select public.za_assert(not private.is_valid_avatar_config('{}'::jsonb), 'VALIDA: objeto vazio devolve false');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() - 'bg'), 'VALIDA: chave faltando');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() - 'v'), 'VALIDA: sem v');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"extra":1}'), 'VALIDA: chave extra');
select public.za_assert(not private.is_valid_avatar_config((public.za_base() - 'bg') || '{"Bg":0}'), 'VALIDA: chave com outra caixa nao vale');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":1.5}'), 'VALIDA: 1.5 rejeitado');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":1.0}'),
  'VALIDA: 1.0 rejeitado (escolha: so inteiro escrito sem parte decimal)');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":2.0000}'), 'VALIDA: 2.0000 rejeitado');
select public.za_assert(private.is_valid_avatar_config(public.za_base() || '{"hair":2e0}'), 'VALIDA: notacao 2e0 e inteiro canonico (aceito)');
select public.za_assert(private.is_valid_avatar_config(public.za_base() || '{"hair":0.5e1}'), 'VALIDA: 0.5e1 vira 5 (escala normalizada zero, aceito)');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":"1"}'), 'VALIDA: string rejeitada');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":true}'), 'VALIDA: boolean rejeitado');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":null}'), 'VALIDA: null num campo rejeitado');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":[1]}'), 'VALIDA: array num campo rejeitado');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":{"a":1}}'), 'VALIDA: objeto num campo rejeitado');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":99999999999999999999999999999}'),
  'VALIDA: numero enorme (>int8) devolve false sem erro');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":-99999999999999999999999999999}'),
  'VALIDA: numero enorme negativo devolve false sem erro');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"hair":1e400}'), 'VALIDA: 1e400 devolve false sem erro');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || ('{"hair":1' || repeat('0', 5000) || '}')::jsonb),
  'VALIDA: numero com 5000 digitos devolve false sem erro');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"v":2}'), 'VALIDA: v=2 rejeitado');
select public.za_assert(not private.is_valid_avatar_config(public.za_base() || '{"v":0}'), 'VALIDA: v=0 rejeitado');

-- limites de cada campo: -1 e max+1 rejeitados, min e max aceitos
do $$
declare r record;
begin
  for r in select * from (values
      ('skin',0,4),('hair',0,5),('hairColor',0,4),('eyes',0,2),('mouth',0,1),('acc',0,2),('outfit',0,4),('bg',0,4)
    ) t(k, lo, hi)
  loop
    perform public.za_assert(
      private.is_valid_avatar_config(public.za_base() || jsonb_build_object(r.k, r.lo))
      and private.is_valid_avatar_config(public.za_base() || jsonb_build_object(r.k, r.hi))
      and not private.is_valid_avatar_config(public.za_base() || jsonb_build_object(r.k, r.lo - 1))
      and not private.is_valid_avatar_config(public.za_base() || jsonb_build_object(r.k, r.hi + 1)),
      'VALIDA: faixa de ' || r.k || ' (' || r.lo || '..' || r.hi || ')');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Check constraint: barra ate o postgres
-- ---------------------------------------------------------------------
select public.za_expect_error(
  $q$update public.profiles set avatar_config = '{"v":2}' where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc'$q$,
  '23514', 'profiles_avatar_config_valid');
select public.za_expect_error(
  $q$update public.profiles set avatar_config = '[]' where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc'$q$,
  '23514', 'profiles_avatar_config_valid');
select public.za_expect_error(
  $q$update public.profiles set avatar_config = 'null'::jsonb where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc'$q$,
  '23514', 'profiles_avatar_config_valid');
delete from public.profiles where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc';
select public.za_expect_error(
  $q$insert into public.profiles (id, avatar_config) values ('c5c5c5c5-cccc-cccc-cccc-cccccccccccc', '{"v":1}')$q$,
  '23514', 'profiles_avatar_config_valid');
insert into public.profiles (id, avatar_config)
  values ('c5c5c5c5-cccc-cccc-cccc-cccccccccccc', public.za_base());
select public.za_assert((select avatar_config = public.za_base() from public.profiles
  where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc'), 'CHECK: insercao valida passa');

-- ---------------------------------------------------------------------
-- Permissoes estaticas
-- ---------------------------------------------------------------------
select public.za_assert(
  not has_function_privilege('anon', 'public.update_my_avatar(jsonb)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.update_my_avatar(jsonb)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.update_my_avatar(jsonb)', 'EXECUTE'),
  'SEC: update_my_avatar sem execute para anon e service_role, com execute para authenticated');
select public.za_assert(not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'update_my_avatar'
       and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))),
  'SEC: update_my_avatar e security definer com search_path vazio');
select public.za_assert(not has_function_privilege('anon', 'private.is_valid_avatar_config(jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'private.is_valid_avatar_config(jsonb)', 'EXECUTE')
  and has_function_privilege('authenticated', 'private.is_valid_avatar_config(jsonb)', 'EXECUTE'),
  'SEC: validadora executavel por authenticated e service_role (o check roda em todo UPDATE/INSERT); anon sem execute');
select public.za_assert(not has_column_privilege('authenticated', 'public.profiles', 'avatar_config', 'UPDATE')
  and not has_column_privilege('anon', 'public.profiles', 'avatar_config', 'UPDATE'),
  'SEC: authenticated e anon sem UPDATE em profiles.avatar_config');

-- anon: chamada real
set role anon;
select public.za_expect_error($q$select public.update_my_avatar(null)$q$, '42501');
select public.za_expect_error($q$select public.update_my_avatar('{"v":1,"skin":1,"hair":3,"hairColor":0,"eyes":1,"mouth":0,"acc":2,"outfit":0,"bg":0}')$q$, '42501');
reset role;

-- service_role: chamada real
set role service_role;
select public.za_expect_error($q$select public.update_my_avatar(null)$q$, '42501');
update public.profiles set display_name = 'Via service_role', avatar_config = public.za_base()
  where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc';
select public.za_assert((select display_name = 'Via service_role' and avatar_config = public.za_base()
  from public.profiles where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc'),
  'SEC: service_role atualiza display_name e avatar_config direto (check nao o bloqueia)');
select public.za_expect_error($q$update public.profiles set avatar_config = '{"v":2}' where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc'$q$, '23514', 'profiles_avatar_config_valid');
update public.profiles set avatar_config = null where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc';
reset role;

-- sem sessao = 28000
set role authenticated;
select set_config('request.jwt.claim.sub', '', false);
select public.za_expect_error($q$select public.update_my_avatar(null)$q$, '28000');
select public.za_expect_error($q$select public.update_my_avatar(public.za_base())$q$, '28000');
reset role;

-- perfil inexistente (usuario autenticado sem linha em profiles) = P0002 profile_not_found
set role authenticated;
select public.za_as('d5d5d5d5-dddd-dddd-dddd-dddddddddddd');
select public.za_expect_error($q$select public.update_my_avatar(public.za_base())$q$, 'P0002', 'profile_not_found');
reset role;
delete from public.profiles where id = 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc';
insert into public.profiles (id) values ('c5c5c5c5-cccc-cccc-cccc-cccccccccccc');

-- ---------------------------------------------------------------------
-- Aluno A: grava, le, limpa
-- ---------------------------------------------------------------------
set role authenticated;
select public.za_as('a5a5a5a5-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

select public.za_assert(public.update_my_avatar(public.za_base()) = jsonb_build_object('avatar_config', public.za_base()),
  'RPC: config valida devolve {"avatar_config": <gravado>}');
select public.za_assert((select avatar_config = public.za_base() from public.profiles where id = auth.uid()),
  'RPC: config valida gravada na coluna');
select public.za_assert(public.get_profile_summary('UTC') -> 'avatar_config' = public.za_base(),
  'PERFIL: get_profile_summary devolve avatar_config igual ao gravado');
select public.za_assert(public.get_profile_summary('UTC') ? 'display_name' and public.get_profile_summary('UTC') ? 'notes_count'
  and public.get_profile_summary('UTC') ? 'email' and public.get_profile_summary('UTC') ? 'mastery',
  'PERFIL: chaves antigas (display_name, email, mastery, notes_count) continuam no resumo');
select public.za_assert(not (public.get_profile_summary('UTC') ? 'avatar_url'),
  'PERFIL: get_profile_summary nao tem mais a chave avatar_url');

select public.za_assert((public.update_my_avatar(public.za_base() || '{"skin":4,"bg":3}') -> 'avatar_config' ->> 'skin')::int = 4,
  'RPC: segunda config valida devolve o novo valor');
select public.za_assert((select (avatar_config ->> 'skin')::int = 4 and (avatar_config ->> 'bg')::int = 3
         from public.profiles where id = auth.uid()), 'RPC: segunda config valida substitui a anterior');
select public.update_my_avatar(public.za_base());

-- invalidas: todas 22023 e nao alteram o valor
select public.za_bad(public.za_base() - 'bg', 'chave faltando');
select public.za_bad(public.za_base() - 'v', 'sem v');
select public.za_bad('{}'::jsonb, 'objeto vazio');
select public.za_bad(public.za_base() || '{"extra":1}', 'chave extra');
select public.za_bad(public.za_base() || '{"v":2}', 'v=2');
select public.za_bad(public.za_base() || '{"v":0}', 'v=0');
do $$
declare r record;
begin
  for r in select * from (values
      ('skin',0,4),('hair',0,5),('hairColor',0,4),('eyes',0,2),('mouth',0,1),('acc',0,2),('outfit',0,4),('bg',0,4)
    ) t(k, lo, hi)
  loop
    perform public.za_bad(public.za_base() || jsonb_build_object(r.k, r.lo - 1), r.k || ' = ' || (r.lo - 1));
    perform public.za_bad(public.za_base() || jsonb_build_object(r.k, r.hi + 1), r.k || ' = ' || (r.hi + 1));
  end loop;
end $$;
select public.za_bad(public.za_base() || '{"hair":"1"}', 'string');
select public.za_bad(public.za_base() || '{"hair":true}', 'boolean');
select public.za_bad(public.za_base() || '{"hair":1.5}', 'float 1.5');
select public.za_bad(public.za_base() || '{"hair":1.0}', 'float 1.0');
select public.za_bad(public.za_base() || '{"hair":null}', 'null num campo');
select public.za_bad(public.za_base() || '{"hair":[1]}', 'array num campo');
select public.za_bad('[]'::jsonb, 'array');
select public.za_bad('[1,2,3]'::jsonb, 'array de numeros');
select public.za_bad('1'::jsonb, 'escalar numero');
select public.za_bad('"x"'::jsonb, 'escalar string');
select public.za_bad('true'::jsonb, 'escalar boolean');
select public.za_bad(public.za_base() || '{"hair":99999999999999999999999999999}', 'numero enorme');
select public.za_bad(public.za_base() || '{"hair":1e400}', 'numero 1e400');
select public.za_bad(public.za_base() || ('{"hair":1' || repeat('0', 5000) || '}')::jsonb, 'numero com 5000 digitos');
select public.za_assert((select avatar_config = public.za_base() from public.profiles where id = auth.uid()),
  'RPC: apos todas as invalidas, o avatar continua o ultimo valido');

-- UPDATE direto de avatar_config negado; o resto do perfil continua editavel
select public.za_expect_error($q$update public.profiles set avatar_config = null where id = auth.uid()$q$, '42501', 'permission denied');
select public.za_expect_error(
  $q$update public.profiles set avatar_config = '{"v":1,"skin":0,"hair":0,"hairColor":0,"eyes":0,"mouth":0,"acc":0,"outfit":0,"bg":0}' where id = auth.uid()$q$,
  '42501', 'permission denied');
select public.za_expect_error($q$update public.profiles set avatar_config = '{"v":9}' where id = auth.uid()$q$, '42501', 'permission denied');
select public.za_assert((select avatar_config = public.za_base() from public.profiles where id = auth.uid()),
  'GRANT: UPDATE direto negado nao alterou o avatar');
do $$
begin
  update public.profiles set display_name = 'Aluno Avatar A' where id = auth.uid();
  perform public.za_assert((select display_name = 'Aluno Avatar A' from public.profiles where id = auth.uid()),
    'GRANT: UPDATE de display_name continua funcionando');
end $$;

-- SQL null limpa
select public.za_assert(public.update_my_avatar(null) = jsonb_build_object('avatar_config', null), 'RPC: SQL null devolve {"avatar_config": null}');
select public.za_assert((select avatar_config is null from public.profiles where id = auth.uid())
  and public.get_profile_summary('UTC') -> 'avatar_config' = 'null'::jsonb,
  'RPC: SQL null limpa (coluna NULL, resumo com avatar_config null)');
-- JSON null limpa (vira NULL de SQL, nao jsonb null)
select public.update_my_avatar(public.za_base());
select public.za_assert(public.update_my_avatar('null'::jsonb) = jsonb_build_object('avatar_config', null), 'RPC: JSON null devolve {"avatar_config": null}');
select public.za_assert((select avatar_config is null from public.profiles where id = auth.uid()),
  'RPC: JSON null limpa (coluna fica NULL de SQL, nao jsonb null)');
reset role;

-- ---------------------------------------------------------------------
-- Isolamento: A nao altera B
-- ---------------------------------------------------------------------
set role authenticated;
select public.za_as('b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select public.update_my_avatar(public.za_base() || '{"skin":2,"hair":5,"bg":4}');
select public.za_as('a5a5a5a5-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.update_my_avatar(public.za_base() || '{"skin":3}');
select public.update_my_avatar(null);
select public.za_assert((select count(*) = 0 from public.profiles where id = 'b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  'ISOLA: A nao enxerga a linha de perfil de B (RLS)');
select public.za_expect_error($q$update public.profiles set avatar_config = null where id = 'b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb'$q$, '42501');
select public.za_as('b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select public.za_assert((select avatar_config = (public.za_base() || '{"skin":2,"hair":5,"bg":4}') from public.profiles where id = auth.uid())
  and public.get_profile_summary('UTC') -> 'avatar_config' = (public.za_base() || '{"skin":2,"hair":5,"bg":4}'),
  'ISOLA: o avatar de B ficou intacto depois das chamadas de A');
reset role;


-- ---------------------------------------------------------------------
-- Migration 007: profiles.avatar_url removida
-- ---------------------------------------------------------------------
select public.za_assert(not exists (select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'profiles' and column_name = 'avatar_url'),
  'DROP: a coluna profiles.avatar_url nao existe mais');
select public.za_assert(not exists (select 1 from information_schema.column_privileges
  where table_schema = 'public' and table_name = 'profiles' and column_name = 'avatar_url'),
  'DROP: nenhum privilegio de coluna sobrando para avatar_url');
select public.za_assert(
  (select array_agg(column_name::text order by column_name) from information_schema.column_privileges
    where table_schema = 'public' and table_name = 'profiles' and grantee = 'authenticated' and privilege_type = 'UPDATE')
  = array['display_name', 'locale', 'onboarding_completed_at', 'self_assessed_level_id'],
  'DROP: UPDATE de authenticated so em display_name, locale, onboarding_completed_at e self_assessed_level_id');
-- ---------------------------------------------------------------------
-- LGPD: excluir o usuario apaga o perfil com avatar
-- ---------------------------------------------------------------------
select public.za_assert((select avatar_config is not null from public.profiles where id = 'b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  'LGPD: antes de excluir, B tem avatar gravado');
delete from auth.users where id = 'b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select public.za_assert(not exists (select 1 from public.profiles where id = 'b5b5b5b5-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  'LGPD: excluir o usuario em auth.users apaga o perfil e o avatar');
delete from auth.users where id in ('a5a5a5a5-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc');
select public.za_assert(not exists (select 1 from public.profiles
  where id in ('a5a5a5a5-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c5c5c5c5-cccc-cccc-cccc-cccccccccccc')), 'LGPD: A e C tambem removidos');

\echo ===== TESTES AVATAR PASSARAM =====
