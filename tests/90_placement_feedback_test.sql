-- =====================================================================
-- MyFluenti - Testes da migration 012: submit_placement_answer devolve
-- {"is_correct": boolean}
-- Autocontido (nao usa o dev-seed). Roda DEPOIS do 80, no mesmo banco:
--   (1) Supabase local: db reset -> 10 -> ... -> 80 -> 90
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> ... -> 80 -> 90
-- Helpers com prefixo zp_. Usuarios: 9a (A), 9b (B).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

create function public.zp_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zp_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zp_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

-- ---------------------------------------------------------------------
-- Setup (postgres): nivelamento publicado com 3 questoes (pesos 2, 1, 1) e uma
-- quarta questao fora do teste. Opcao certa 91..., errada 92....
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('9a9a9a9a-1111-1111-1111-111111111111', 'zp-a@teste'),
  ('9b9b9b9b-2222-2222-2222-222222222222', 'zp-b@teste');

insert into public.placement_tests (id, code, version_number, title, total_questions)
  values ('bbbbbbbb-0000-0000-0000-0000000000f9', 'zp', 1, 'ZP nivelamento', 3);

do $$
declare
  lvl uuid := (select id from public.levels where code = 'A1');
  i int; q uuid;
begin
  for i in 1..4 loop
    q := ('a9000000-0000-0000-0000-00000000000' || i)::uuid;
    insert into public.questions (id, question_type, prompt) values (q, 'multiple_choice', 'ZPQ ' || i);
    insert into public.answer_options (id, question_id, option_text, position)
      values (('a9100000-0000-0000-0000-00000000000' || i)::uuid, q, 'certa', 1);
    insert into public.answer_options (id, question_id, option_text, position)
      values (('a9200000-0000-0000-0000-00000000000' || i)::uuid, q, 'errada', 2);
    insert into private.question_answer_keys (question_id, correct_option_id, explanation)
      values (q, ('a9100000-0000-0000-0000-00000000000' || i)::uuid, 'ZP explicacao secreta ' || i);
    if i <= 3 then
      insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
        values ('bbbbbbbb-0000-0000-0000-0000000000f9', q, 'vocabulary', lvl, case when i = 1 then 2 else 1 end, i);
    end if;
  end loop;
  update public.placement_tests set is_published = true where id = 'bbbbbbbb-0000-0000-0000-0000000000f9';
end $$;

create table public.zp_ctx (k text primary key, v uuid);
grant select, insert on public.zp_ctx to authenticated;
create table public.zp_r (k text primary key, r jsonb);
grant select, insert on public.zp_r to authenticated;

-- ---------------------------------------------------------------------
-- Assinatura, tipo de retorno e grants
-- ---------------------------------------------------------------------
select public.zp_assert(
  (select pg_get_function_result(p.oid) = 'jsonb'
          and pg_get_function_arguments(p.oid) = 'p_attempt_id uuid, p_question_id uuid, p_answer jsonb'
     from pg_proc p where p.oid = 'public.submit_placement_answer(uuid, uuid, jsonb)'::regprocedure),
  'ASSINATURA: submit_placement_answer(uuid, uuid, jsonb) returns jsonb, argumentos inalterados');
select public.zp_assert(
  (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'submit_placement_answer'),
  'ASSINATURA: sem sobrecarga (a versao void foi substituida)');
select public.zp_assert(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p where p.oid = 'public.submit_placement_answer(uuid, uuid, jsonb)'::regprocedure),
  'SEGURANCA: security definer com search_path vazio');
select public.zp_assert(
  not has_function_privilege('anon', 'public.submit_placement_answer(uuid, uuid, jsonb)', 'execute'),
  'GRANT: anon sem execute');
select public.zp_assert(
  not has_function_privilege('public', 'public.submit_placement_answer(uuid, uuid, jsonb)', 'execute'),
  'GRANT: public sem execute');
select public.zp_assert(
  has_function_privilege('authenticated', 'public.submit_placement_answer(uuid, uuid, jsonb)', 'execute'),
  'GRANT: authenticated com execute');

-- ---------------------------------------------------------------------
-- Aluno A: acerto, erro e forma do retorno
-- ---------------------------------------------------------------------
set role authenticated;
select public.zp_as('9a9a9a9a-1111-1111-1111-111111111111');
insert into public.zp_ctx values ('att', public.start_placement_attempt('bbbbbbbb-0000-0000-0000-0000000000f9'));

insert into public.zp_r select 'ok', public.submit_placement_answer(
  (select v from public.zp_ctx where k = 'att'), 'a9000000-0000-0000-0000-000000000001',
  jsonb_build_object('option_id', 'a9100000-0000-0000-0000-000000000001'));
insert into public.zp_r select 'bad', public.submit_placement_answer(
  (select v from public.zp_ctx where k = 'att'), 'a9000000-0000-0000-0000-000000000002',
  jsonb_build_object('option_id', 'a9200000-0000-0000-0000-000000000002'));

select public.zp_assert((select r = '{"is_correct": true}'::jsonb from public.zp_r where k = 'ok'),
  'RETORNO: acerto devolve {"is_correct": true}');
select public.zp_assert((select r = '{"is_correct": false}'::jsonb from public.zp_r where k = 'bad'),
  'RETORNO: erro devolve {"is_correct": false}');
select public.zp_assert(
  (select bool_and(jsonb_typeof(r) = 'object'
                   and (select count(*) from jsonb_object_keys(r)) = 1
                   and r ? 'is_correct'
                   and jsonb_typeof(r -> 'is_correct') = 'boolean') from public.zp_r),
  'RETORNO: objeto com so a chave is_correct, booleana');
select public.zp_assert(
  (select bool_and(position('ZP explicacao' in r::text) = 0 and position('a9100000' in r::text) = 0
                   and position('point' in r::text) = 0 and position('correct_option' in r::text) = 0
                   and position('accepted' in r::text) = 0) from public.zp_r),
  'GABARITO: retorno nao traz explicacao, opcao correta, pontos nem respostas aceitas');
reset role;

-- is_correct devolvido == o que foi gravado (mesma correcao); pontos pelo peso
select public.zp_assert(
  (select count(*) = 2
          and bool_and(x.is_correct = (z.r ->> 'is_correct')::boolean
                       and x.awarded_points = case when x.is_correct then pq.weight else 0 end)
     from public.user_placement_answers x
     join public.placement_questions pq
       on pq.placement_test_id = x.placement_test_id and pq.question_id = x.question_id
     join public.zp_r z
       on z.k = case x.question_id when 'a9000000-0000-0000-0000-000000000001' then 'ok' else 'bad' end
    where x.attempt_id = (select v from public.zp_ctx where k = 'att')),
  'CONSISTENCIA: is_correct devolvido igual ao gravado; pontos gravados pelo peso (2 e 0)');

-- ---------------------------------------------------------------------
-- Regras antigas
-- ---------------------------------------------------------------------
set role authenticated;
select public.zp_as('9a9a9a9a-1111-1111-1111-111111111111');
select public.zp_expect_error(
  format($q$select public.submit_placement_answer(%L, 'a9000000-0000-0000-0000-000000000001', '{"option_id":"a9100000-0000-0000-0000-000000000001"}')$q$,
         (select v from public.zp_ctx where k = 'att')), '23505', 'Questao ja respondida');
select public.zp_expect_error(
  format($q$select public.submit_placement_answer(%L, 'a9000000-0000-0000-0000-000000000004', '{"option_id":"a9100000-0000-0000-0000-000000000004"}')$q$,
         (select v from public.zp_ctx where k = 'att')), '23503', 'Questao nao pertence');
select public.zp_expect_error(
  $q$select public.submit_placement_answer('9a9a9a9a-0000-0000-0000-000000000000', 'a9000000-0000-0000-0000-000000000003', '{"option_id":"x"}')$q$,
  '42501', 'Tentativa nao encontrada');

-- outro aluno nao responde na tentativa do A
select public.zp_as('9b9b9b9b-2222-2222-2222-222222222222');
select public.zp_expect_error(
  format($q$select public.submit_placement_answer(%L, 'a9000000-0000-0000-0000-000000000003', '{"option_id":"a9100000-0000-0000-0000-000000000003"}')$q$,
         (select v from public.zp_ctx where k = 'att')), '42501', 'Tentativa nao encontrada');

-- tentativa encerrada
select public.zp_as('9a9a9a9a-1111-1111-1111-111111111111');
select public.finish_placement_attempt((select v from public.zp_ctx where k = 'att'));
select public.zp_expect_error(
  format($q$select public.submit_placement_answer(%L, 'a9000000-0000-0000-0000-000000000003', '{"option_id":"a9100000-0000-0000-0000-000000000003"}')$q$,
         (select v from public.zp_ctx where k = 'att')), '55000', 'Tentativa ja encerrada');

-- sem sessao
select set_config('request.jwt.claim.sub', '', false);
select public.zp_expect_error(
  $q$select public.submit_placement_answer('9a9a9a9a-0000-0000-0000-000000000000', 'a9000000-0000-0000-0000-000000000003', '{}')$q$,
  '28000');
reset role;

select public.zp_assert(
  (select count(*) = 2 from public.user_placement_answers
    where attempt_id = (select v from public.zp_ctx where k = 'att')),
  'ERROS: chamadas rejeitadas nao gravam resposta (continuam 2)');

-- anon: sem execute
set role anon;
select public.zp_expect_error(
  $q$select public.submit_placement_answer('9a9a9a9a-0000-0000-0000-000000000000', 'a9000000-0000-0000-0000-000000000003', '{}')$q$,
  '42501', 'permission denied');
reset role;

\echo ===== TESTES FEEDBACK NIVELAMENTO PASSARAM =====
