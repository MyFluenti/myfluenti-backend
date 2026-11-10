-- =====================================================================
-- MyFluenti - Testes da migration 010: select_starting_level conclui o onboarding
-- Autocontido (nao usa o dev-seed). Roda DEPOIS do 60, no mesmo banco:
--   (1) Supabase local: db reset -> 10 -> 20 -> 30 -> 40 -> 50 -> 60 -> 70
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> 20 -> 30 -> 40 -> 50 -> 60 -> 70
-- Helpers com prefixo zo_. Usuarios: 7a7a7a7a (A), 7b7b7b7b (B).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

create function public.zo_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zo_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zo_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

-- ---------------------------------------------------------------------
-- Setup (postgres): modulos publicados em A1 (zo-m70) e A2 (zo-m71), C2 sem modulo publicado,
-- 2 alunos (A com autoavaliacao A2, para a troca real A1 -> A2)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7a7a7a7a-1111-1111-1111-111111111111', 'zo-a@teste'),
  ('7b7b7b7b-2222-2222-2222-222222222222', 'zo-b@teste');

insert into public.modules (id, level_id, slug, title, position, access_tier, is_published)
  values ('0e0e0e0e-0000-0000-0000-000000000070',
          (select id from public.levels where code = 'A1'), 'zo-m70', 'ZO free', 70, 'free', true);

select public.zo_assert(
  (select onboarding_completed_at is null and current_level_id is null
     from public.profiles where id = '7a7a7a7a-1111-1111-1111-111111111111')
  and (select onboarding_completed_at is null
     from public.profiles where id = '7b7b7b7b-2222-2222-2222-222222222222'),
  'SETUP: alunos novos comecam sem nivel e com onboarding em aberto');

-- A2 publicado e autoavaliacao A2 do aluno A: a "troca de nivel" abaixo e uma troca real
-- (desde a 011, repetir o nivel ativo e idempotente e nao grava historico).
insert into public.modules (id, level_id, slug, title, position, access_tier, is_published)
  values ('0e0e0e0e-0000-0000-0000-000000000071',
          (select id from public.levels where code = 'A2'), 'zo-m71', 'ZO free A2', 71, 'free', true);
update public.profiles set self_assessed_level_id = (select id from public.levels where code = 'A2')
 where id = '7a7a7a7a-1111-1111-1111-111111111111';

select public.zo_assert(
  private.first_published_module((select id from public.levels where code = 'C2')) is null,
  'SETUP: C2 nao tem modulo publicado (pre-condicao do teste de P0002)');

-- ---------------------------------------------------------------------
-- Contrato: assinatura, retorno e permissao de execucao nao mudaram
-- ---------------------------------------------------------------------
select public.zo_assert(
  (select pg_get_function_identity_arguments(p.oid) = 'p_level_id uuid, p_placement_attempt_id uuid'
          and p.prorettype = 'void'::regtype and p.prosecdef
     from pg_proc p where p.oid = 'public.select_starting_level(uuid, uuid)'::regprocedure),
  'CONTRATO: select_starting_level(uuid, uuid) devolve void e segue security definer');

select public.zo_assert(
  has_function_privilege('authenticated', 'public.select_starting_level(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.select_starting_level(uuid, uuid)', 'execute'),
  'CONTRATO: so authenticated executa (anon nao)');

-- ---------------------------------------------------------------------
-- A: escolher o nivel conclui o onboarding na mesma chamada
-- ---------------------------------------------------------------------
set role authenticated;
select public.zo_as('7a7a7a7a-1111-1111-1111-111111111111');
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zo_assert(
  (select current_level_id = (select id from public.levels where code = 'A1')
          and onboarding_completed_at is not null
     from public.profiles where id = auth.uid()),
  'ONBOARDING: select_starting_level grava o nivel e onboarding_completed_at juntos');
reset role;

-- Troca de nivel posterior (manual_change) preserva a data original
update public.profiles set onboarding_completed_at = '2026-01-01T00:00:00Z'
 where id = '7a7a7a7a-1111-1111-1111-111111111111';

set role authenticated;
select public.zo_as('7a7a7a7a-1111-1111-1111-111111111111');
select public.select_starting_level((select id from public.levels where code = 'A2'));
select public.zo_assert(
  (select onboarding_completed_at = '2026-01-01T00:00:00Z'::timestamptz
     from public.profiles where id = auth.uid()),
  'ONBOARDING: nova escolha de nivel nao sobrescreve onboarding_completed_at');
select public.zo_assert(
  (select count(*) = 2 and count(*) filter (where source = 'manual_change') = 1
     from public.user_level_history where user_id = auth.uid()),
  'HISTORICO: troca real de nivel (A1 para A2) e registrada como manual_change');
reset role;

-- ---------------------------------------------------------------------
-- B: falhas de validacao nao concluem o onboarding (nivel e data ficam no mesmo UPDATE)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zo_as('7b7b7b7b-2222-2222-2222-222222222222');
-- sem teste e sem autoavaliacao, o teto e o primeiro nivel: C2 supera
select public.zo_expect_error(
  $q$select public.select_starting_level((select id from public.levels where code = 'C2'))$q$, '22023');
select public.zo_assert(
  (select onboarding_completed_at is null and current_level_id is null
     from public.profiles where id = auth.uid()),
  'FALHA NAO CONCLUI: erro 22023 nao conclui o onboarding nem define nivel');

-- autoavaliacao em C2 permite C2, mas C2 nao tem modulo publicado
update public.profiles set self_assessed_level_id = (select id from public.levels where code = 'C2')
 where id = auth.uid();
select public.zo_expect_error(
  $q$select public.select_starting_level((select id from public.levels where code = 'C2'))$q$, 'P0002');
select public.zo_assert(
  (select onboarding_completed_at is null and current_level_id is null
     from public.profiles where id = auth.uid())
  and not exists (select 1 from public.user_level_history where user_id = auth.uid()),
  'FALHA NAO CONCLUI: erro P0002 nao conclui o onboarding nem grava historico');

-- A escolha valida conclui
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zo_assert(
  (select onboarding_completed_at is not null
          and current_level_id = (select id from public.levels where code = 'A1')
     from public.profiles where id = auth.uid()),
  'ONBOARDING: depois das falhas, a escolha valida conclui');

-- B nao alterou A
select public.zo_assert(
  (select count(*) = 0 from public.profiles where id = '7a7a7a7a-1111-1111-1111-111111111111'),
  'ISOLAMENTO: B nao le o perfil de A');
reset role;

select public.zo_assert(
  (select onboarding_completed_at = '2026-01-01T00:00:00Z'::timestamptz
     from public.profiles where id = '7a7a7a7a-1111-1111-1111-111111111111'),
  'ISOLAMENTO: as chamadas de B nao tocam o perfil de A');

\echo ===== TESTES ONBOARDING PASSARAM =====
