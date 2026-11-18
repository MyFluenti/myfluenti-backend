-- =====================================================================
-- MyFluenti - Testes da migration 014: teste de nivelamento por nivel (ADR 0006)
-- Autocontido, so com fixture (nenhum conteudo real de nivel). Roda DEPOIS do 95, no
-- mesmo banco. Helpers com prefixo zl_. Usuarios c0c0c0c0-...-0000000000NN (1 a 40).
-- Faixas (70% / 40%) e pesos sao PROVISORIOS (ADR 0006); o teste fixa o comportamento atual.
-- Os testes de nivel da fixture tem 10 questoes de peso 1 (e um com pesos 5/3/2); isso
-- NAO e o formato final do conteudo (8 questoes, 3-3-1-1): so facilita as fronteiras.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

create function public.zl_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zl_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zl_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;
create function public.zl_uid(n int) returns uuid language sql immutable as $$
  select ('c0c0c0c0-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
create function public.zl_lvl(p_code text) returns uuid language sql stable as $$
  select id from public.levels where code = p_code
$$;

-- fixture: (chave do teste, posicao) -> ids; opcao 1 certa, opcao 2 errada
create table public.zl_q (test_key text, pos int, qid uuid, ok_opt uuid, bad_opt uuid, primary key (test_key, pos));
-- resultados guardados por chave
create table public.zl_res (k text primary key, r jsonb);
grant select, insert on public.zl_res to authenticated;

-- Cria um teste com pesos informados. p_diffs: dificuldade por questao (default: nivel do teste).
-- Chave da fixture: code || '#' || version.
create function public.zl_mk_test(p_code text, p_version int, p_level text, p_weights numeric[],
                                  p_diffs text[] default null, p_publish boolean default true,
                                  p_published_at timestamptz default null)
returns uuid language plpgsql as $$
declare
  t uuid := gen_random_uuid(); i int; q uuid; o1 uuid; o2 uuid;
  n int := array_length(p_weights, 1);
  comps text[] := array['vocabulary','grammar','reading','construction'];
begin
  insert into public.placement_tests (id, code, version_number, title, total_questions, level_id)
    values (t, p_code, p_version, 'ZL ' || p_code, n,
            case when p_level is null then null else public.zl_lvl(p_level) end);
  for i in 1..n loop
    q := gen_random_uuid(); o1 := gen_random_uuid(); o2 := gen_random_uuid();
    insert into public.questions (id, question_type, prompt) values (q, 'multiple_choice', 'ZL ' || p_code || ' ' || i);
    insert into public.answer_options (id, question_id, option_text, position) values (o1, q, 'certa', 1), (o2, q, 'errada', 2);
    insert into private.question_answer_keys (question_id, correct_option_id, explanation)
      values (q, o1, 'ZL explicacao secreta');
    insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
      values (t, q, comps[1 + (i - 1) % 4], public.zl_lvl(coalesce(p_diffs[i], p_level)), p_weights[i], i);
    insert into public.zl_q values (p_code || '#' || p_version, i, q, o1, o2);
  end loop;
  if p_publish then
    update public.placement_tests set is_published = true, published_at = p_published_at where id = t;
  end if;
  return t;
end $$;

-- Executa uma tentativa como o aluno: start v2 (nivel ou geral), responde todas as questoes
-- (certa nas posicoes de p_correct) e finaliza. security definer so no teste (le zl_q).
create function public.zl_run(p_user uuid, p_key text, p_level text, p_correct int[])
returns jsonb language plpgsql security definer as $$
declare a uuid; r record; res jsonb;
begin
  perform public.zl_as(p_user);
  a := public.start_placement_attempt_v2(case when p_level is null then null else public.zl_lvl(p_level) end);
  for r in select * from public.zl_q where test_key = p_key order by pos loop
    res := public.submit_placement_answer(a, r.qid,
      jsonb_build_object('option_id', case when r.pos = any (p_correct) then r.ok_opt else r.bad_opt end));
    if (res ->> 'is_correct')::boolean is distinct from (r.pos = any (p_correct)) then
      raise exception 'FAIL: is_correct inesperado (% pos %)', p_key, r.pos;
    end if;
  end loop;
  return public.finish_placement_attempt(a);
end $$;

create function public.zl_rec(p_k text) returns text language sql stable as $$
  select r ->> 'recommended_level_code' from public.zl_res where k = p_k
$$;

-- ---------------------------------------------------------------------
-- Setup (postgres)
-- ---------------------------------------------------------------------
insert into auth.users (id, email)
  select public.zl_uid(n), 'zl-' || n || '@teste' from generate_series(1, 40) n;

insert into public.modules (level_id, slug, title, position, access_tier, is_published) values
  (public.zl_lvl('A1'), 'zl-m-a1', 'ZL A1', 196, 'free', true),
  (public.zl_lvl('A2'), 'zl-m-a2', 'ZL A2', 196, 'free', true),
  (public.zl_lvl('B1'), 'zl-m-b1', 'ZL B1', 196, 'free', true);

-- Teste geral proprio (3 questoes: A1, A2, B1), publicado no futuro proximo para ser o mais
-- recente dos gerais mesmo com os testes dos arquivos anteriores. Testes de nivel depois dele.
select public.zl_mk_test('zl-geral', 1, null, array[1,1,1], array['A1','A2','B1'], true, now() + interval '1 hour');
select public.zl_mk_test('zl-b1', 1, 'B1', array[1,1,1,1,1,1,1,1,1,1], null, true, now() + interval '2 hours');
select public.zl_mk_test('zl-a2', 1, 'A2', array[1,1,1,1,1,1,1,1,1,1], null, true, now() + interval '2 hours');
select public.zl_mk_test('zl-b2', 1, 'B2', array[5,3,2], null, true, now() + interval '2 hours');

-- ---------------------------------------------------------------------
-- Guarda de publicacao / A1
-- ---------------------------------------------------------------------
select public.zl_assert((select level_id is null from public.placement_tests where code = 'zl-geral')
  and (select level_id = public.zl_lvl('B1') from public.placement_tests where code = 'zl-b1'),
  'COLUNA: level_id nulo no teste geral e preenchido no teste de nivel');
select public.zl_expect_error(
  $q$insert into public.placement_tests (code, version_number, title, total_questions, level_id)
     values ('zl-a1', 1, 'A1 nao tem teste', 1, public.zl_lvl('A1'))$q$,
  '23514', 'placement_level_test_a1_not_allowed');
-- rascunho de nivel B1 com questao de dificuldade B2: criar rascunho pode, publicar nao
select public.zl_mk_test('zl-bad', 1, 'B1', array[1,1], array['B1','B2'], false);
select public.zl_expect_error(
  $q$update public.placement_tests set is_published = true where code = 'zl-bad'$q$,
  '23514', 'placement_level_test_difficulty_mismatch');
select public.zl_expect_error(
  $q$update public.placement_tests set level_id = public.zl_lvl('A1') where code = 'zl-bad'$q$,
  '23514', 'placement_level_test_a1_not_allowed');
select public.zl_assert(
  (select not is_published from public.placement_tests where code = 'zl-bad'),
  'PUBLICACAO: teste de nivel com questao fora da dificuldade do nivel continua rascunho');
update public.placement_questions set difficulty_level_id = public.zl_lvl('B1')
 where placement_test_id = (select id from public.placement_tests where code = 'zl-bad');
update public.placement_tests set is_published = true where code = 'zl-bad';
select public.zl_assert(
  (select is_published and published_at is not null from public.placement_tests where code = 'zl-bad'),
  'PUBLICACAO: com todas as questoes na dificuldade do nivel publica');
select public.zl_expect_error(
  $q$update public.placement_tests set level_id = public.zl_lvl('B2') where code = 'zl-bad'$q$,
  '55000');
select public.zl_assert(
  (select count(*) = 3 from public.placement_questions
    where placement_test_id = (select id from public.placement_tests where code = 'zl-geral')
      and difficulty_level_id in (public.zl_lvl('A1'), public.zl_lvl('A2'), public.zl_lvl('B1'))),
  'PUBLICACAO: teste geral continua aceitando dificuldades mistas');

-- ---------------------------------------------------------------------
-- Assinaturas e grants
-- ---------------------------------------------------------------------
select public.zl_assert(
  (select pg_get_function_result(p.oid) = 'uuid'
          and pg_get_function_arguments(p.oid) = 'p_level_id uuid DEFAULT NULL::uuid'
          and p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p where p.oid = 'public.start_placement_attempt_v2(uuid)'::regprocedure),
  'ASSINATURA: start_placement_attempt_v2(p_level_id uuid default null) returns uuid, security definer, search_path vazio');
select public.zl_assert(
  (select pg_get_function_result(p.oid) = 'uuid'
          and pg_get_function_arguments(p.oid) = 'p_test_id uuid DEFAULT NULL::uuid'
     from pg_proc p where p.oid = 'public.start_placement_attempt(uuid)'::regprocedure)
  and (select pg_get_function_result(p.oid) = 'jsonb' and pg_get_function_arguments(p.oid) = 'p_attempt_id uuid'
     from pg_proc p where p.oid = 'public.finish_placement_attempt(uuid)'::regprocedure)
  and (select pg_get_function_result(p.oid) = 'jsonb' and pg_get_function_arguments(p.oid) = 'p_attempt_id uuid'
     from pg_proc p where p.oid = 'public.get_placement_items(uuid)'::regprocedure),
  'ASSINATURA: start v1, finish e get_placement_items mantem argumentos e retorno');
select public.zl_assert(
  (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'start_placement_attempt_v2')
  and (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'start_placement_attempt'),
  'ASSINATURA: sem sobrecarga');
select public.zl_assert(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public'
                 and p.proname in ('start_placement_attempt', 'start_placement_attempt_v2', 'finish_placement_attempt', 'get_placement_items')
                 and (not p.prosecdef or not ('search_path=""' = any (p.proconfig))
                      or has_function_privilege('anon', p.oid, 'execute')
                      or has_function_privilege('public', p.oid, 'execute')
                      or not has_function_privilege('authenticated', p.oid, 'execute'))),
  'GRANT: as 4 RPCs sao security definer, search_path vazio, sem execute para anon e public, com execute para authenticated');
select public.zl_assert(
  not has_function_privilege('authenticated', 'private.start_placement_impl(text, uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'private.start_placement_impl(text, uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'private.guard_placement_level_test()', 'execute'),
  'GRANT: funcoes private novas nao sao executaveis pelo app');

-- ---------------------------------------------------------------------
-- Erros de nivel (aluno 26)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zl_as(public.zl_uid(26));
select public.zl_expect_error(
  $q$select public.start_placement_attempt_v2((select id from public.levels where code = 'A1'))$q$,
  '22023', 'level_test_not_available');
select public.zl_expect_error(
  $q$select public.start_placement_attempt_v2('c0c0c0c0-ffff-ffff-ffff-ffffffffffff')$q$,
  'P0002', 'level_not_found');
select public.zl_expect_error(
  $q$select public.start_placement_attempt_v2((select id from public.levels where code = 'C2'))$q$,
  'P0002', 'level_test_not_published');
select public.zl_expect_error(
  $q$select public.start_placement_attempt(( select id from public.placement_tests where code = 'zl-b1'))$q$,
  '22023', 'placement_level_test_requires_v2');
reset role;
select public.zl_assert((select count(*) = 0 from public.user_placement_attempts where user_id = public.zl_uid(26)),
  'ERROS: nenhuma tentativa criada pelas chamadas recusadas');

-- ---------------------------------------------------------------------
-- Faixas de recomendacao (um aluno por caso)
-- ---------------------------------------------------------------------
set role authenticated;
insert into public.zl_res select 'b1_10', public.zl_run(public.zl_uid(1), 'zl-b1#1', 'B1', array[1,2,3,4,5,6,7,8,9,10]);
insert into public.zl_res select 'b1_07', public.zl_run(public.zl_uid(2), 'zl-b1#1', 'B1', array[1,2,3,4,5,6,7]);
insert into public.zl_res select 'b1_06', public.zl_run(public.zl_uid(3), 'zl-b1#1', 'B1', array[1,2,3,4,5,6]);
insert into public.zl_res select 'b1_04', public.zl_run(public.zl_uid(4), 'zl-b1#1', 'B1', array[1,2,3,4]);
insert into public.zl_res select 'b1_03', public.zl_run(public.zl_uid(5), 'zl-b1#1', 'B1', array[1,2,3]);
insert into public.zl_res select 'b1_00', public.zl_run(public.zl_uid(6), 'zl-b1#1', 'B1', array[]::int[]);
insert into public.zl_res select 'a2_07', public.zl_run(public.zl_uid(7), 'zl-a2#1', 'A2', array[1,2,3,4,5,6,7]);
insert into public.zl_res select 'a2_06', public.zl_run(public.zl_uid(8), 'zl-a2#1', 'A2', array[1,2,3,4,5,6]);
insert into public.zl_res select 'a2_04', public.zl_run(public.zl_uid(9), 'zl-a2#1', 'A2', array[1,2,3,4]);
insert into public.zl_res select 'a2_03', public.zl_run(public.zl_uid(10), 'zl-a2#1', 'A2', array[1,2,3]);
insert into public.zl_res select 'b2_13', public.zl_run(public.zl_uid(11), 'zl-b2#1', 'B2', array[1,3]);
insert into public.zl_res select 'b2_23', public.zl_run(public.zl_uid(12), 'zl-b2#1', 'B2', array[2,3]);
insert into public.zl_res select 'b2_1', public.zl_run(public.zl_uid(13), 'zl-b2#1', 'B2', array[1]);
insert into public.zl_res select 'b2_2', public.zl_run(public.zl_uid(14), 'zl-b2#1', 'B2', array[2]);
insert into public.zl_res select 'b2_12', public.zl_run(public.zl_uid(15), 'zl-b2#1', 'B2', array[1,2]);
reset role;

select public.zl_assert(public.zl_rec('b1_10') = 'B1', 'FAIXA B1: 100% confirma B1 (nunca sobe para B2)');
select public.zl_assert(public.zl_rec('b1_07') = 'B1' and (select (r ->> 'score_pct')::numeric = 70 from public.zl_res where k = 'b1_07'),
  'FAIXA B1: exatamente 70% confirma o nivel');
select public.zl_assert(public.zl_rec('b1_06') = 'A2', 'FAIXA B1: 60% recomenda um nivel abaixo (A2)');
select public.zl_assert(public.zl_rec('b1_04') = 'A2' and (select (r ->> 'score_pct')::numeric = 40 from public.zl_res where k = 'b1_04'),
  'FAIXA B1: exatamente 40% recomenda um nivel abaixo (A2)');
select public.zl_assert(public.zl_rec('b1_03') = 'A1', 'FAIXA B1: 30% recomenda A1');
select public.zl_assert(public.zl_rec('b1_00') = 'A1', 'FAIXA B1: 0% recomenda A1');
select public.zl_assert(public.zl_rec('a2_07') = 'A2', 'FAIXA A2: 70% confirma A2');
select public.zl_assert(public.zl_rec('a2_06') = 'A1', 'FAIXA A2: 60% desce um nivel = A1');
select public.zl_assert(public.zl_rec('a2_04') = 'A1', 'FAIXA A2: 40% desce um nivel = A1 (piso)');
select public.zl_assert(public.zl_rec('a2_03') = 'A1', 'FAIXA A2: 30% recomenda A1 (piso)');
select public.zl_assert(public.zl_rec('b2_13') = 'B2' and (select (r ->> 'score_pct')::numeric = 70 from public.zl_res where k = 'b2_13'),
  'PESOS: peso 5 + peso 2 de 10 = 70% confirma B2 (nota ponderada, nao contagem)');
select public.zl_assert(public.zl_rec('b2_23') = 'B1', 'PESOS: 3 + 2 = 50% recomenda B1');
select public.zl_assert(public.zl_rec('b2_1') = 'B1', 'PESOS: so a de peso 5 = 50% recomenda B1');
select public.zl_assert(public.zl_rec('b2_2') = 'A1', 'PESOS: so a de peso 3 = 30% recomenda A1');
select public.zl_assert(public.zl_rec('b2_12') = 'B2', 'PESOS: 80% confirma B2, nunca B1 nem C1');
select public.zl_assert(
  (select bool_and(r ->> 'level_test_code' = case when k like 'b1%' then 'B1' when k like 'a2%' then 'A2' else 'B2' end)
     from public.zl_res),
  'RETORNO: level_test_code traz o nivel do teste');
select public.zl_assert(
  (select bool_and(a.recommended_level_id = (z.r ->> 'recommended_level_id')::uuid
                   and a.score_pct = (z.r ->> 'score_pct')::numeric and a.status = 'completed')
     from public.zl_res z join public.user_placement_attempts a on a.id = (z.r ->> 'attempt_id')::uuid),
  'RETORNO: gravado na tentativa igual ao devolvido');
select public.zl_assert(
  (select bool_and((select array_agg(key order by key) from jsonb_object_keys(r) key) =
          array['attempt_id','competency_breakdown','level_test_code','recommended_level_code','recommended_level_id','score_pct'])
     from public.zl_res),
  'RETORNO: so as chaves esperadas (as antigas mais level_test_code)');
select public.zl_assert(
  (select bool_and(position('ZL explicacao' in r::text) = 0 and position('correct' in r::text) = 0) from public.zl_res),
  'GABARITO: o resultado nao traz explicacao nem resposta certa');

-- ---------------------------------------------------------------------
-- Teste geral continua com 60% (aluno 17: A1 e A2 certos, B1 errado -> A2; aluno 18: so A1 -> A1;
-- aluno 19: tudo certo -> B1)
-- ---------------------------------------------------------------------
set role authenticated;
insert into public.zl_res select 'g_a2', public.zl_run(public.zl_uid(17), 'zl-geral#1', null, array[1,2]);
insert into public.zl_res select 'g_a1', public.zl_run(public.zl_uid(18), 'zl-geral#1', null, array[1]);
insert into public.zl_res select 'g_b1', public.zl_run(public.zl_uid(19), 'zl-geral#1', null, array[1,2,3]);
reset role;
select public.zl_assert(public.zl_rec('g_a2') = 'A2' and public.zl_rec('g_a1') = 'A1' and public.zl_rec('g_b1') = 'B1',
  'GERAL: continua em sequencia a partir do A1 com 60% por nivel (A2, A1, B1)');
select public.zl_assert(
  (select (r ->> 'level_test_code') is null and r ? 'level_test_code' from public.zl_res where k = 'g_a2'),
  'GERAL: level_test_code presente e nulo');

-- ---------------------------------------------------------------------
-- v1 nao pega teste de nivel; v2 sem nivel = geral
-- ---------------------------------------------------------------------
set role authenticated;
select public.zl_as(public.zl_uid(20));
insert into public.zl_res select 'v1_open', jsonb_build_object('id', public.start_placement_attempt());
reset role;
select public.zl_assert(
  (select pt.code = 'zl-geral' and pt.level_id is null
     from public.user_placement_attempts a join public.placement_tests pt on pt.id = a.placement_test_id
    where a.id = (select (r ->> 'id')::uuid from public.zl_res where k = 'v1_open')),
  'V1: sem p_test_id escolhe o geral, mesmo com testes de nivel publicados depois dele');
set role authenticated;
select public.zl_as(public.zl_uid(21));
insert into public.zl_res select 'v2_null', jsonb_build_object('id', public.start_placement_attempt_v2());
reset role;
select public.zl_assert(
  (select pt.code = 'zl-geral' from public.user_placement_attempts a join public.placement_tests pt on pt.id = a.placement_test_id
    where a.id = (select (r ->> 'id')::uuid from public.zl_res where k = 'v2_null')),
  'V2: sem nivel abre o teste geral (igual a v1)');

-- v2 pega a versao mais recente do teste do nivel
select public.zl_mk_test('zl-b1', 2, 'B1', array[1,1,1,1,1,1,1,1,1,1], null, true, now() + interval '3 hours');
set role authenticated;
insert into public.zl_res select 'b1_v2', public.zl_run(public.zl_uid(22), 'zl-b1#2', 'B1', array[1,2,3,4,5,6,7,8,9,10]);
reset role;
select public.zl_assert(
  (select pt.version_number = 2 and pt.code = 'zl-b1' from public.user_placement_attempts a
     join public.placement_tests pt on pt.id = a.placement_test_id
    where a.id = (select (r ->> 'attempt_id')::uuid from public.zl_res where k = 'b1_v2')),
  'V2: com nivel escolhido usa a versao publicada mais recente do teste daquele nivel');

-- ---------------------------------------------------------------------
-- Retomada (v1 e v2) e get_placement_items.level_code
-- ---------------------------------------------------------------------
set role authenticated;
select public.zl_as(public.zl_uid(24));
insert into public.zl_res select 'r_open', jsonb_build_object('id', public.start_placement_attempt_v2((select id from public.levels where code = 'B1')));
insert into public.zl_res select 'r_v1', jsonb_build_object('id', public.start_placement_attempt());
insert into public.zl_res select 'r_v2b1', jsonb_build_object('id', public.start_placement_attempt_v2((select id from public.levels where code = 'B1')));
insert into public.zl_res select 'r_v2a2', jsonb_build_object('id', public.start_placement_attempt_v2((select id from public.levels where code = 'A2')));
insert into public.zl_res select 'r_v2null', jsonb_build_object('id', public.start_placement_attempt_v2());
insert into public.zl_res select 'r_items', public.get_placement_items((select (r ->> 'id')::uuid from public.zl_res where k = 'r_open'));
select public.zl_expect_error(
  $q$select public.start_placement_attempt((select id from public.placement_tests where code = 'zl-b1' and version_number = 2))$q$,
  '22023', 'placement_level_test_requires_v2');
reset role;
select public.zl_assert(
  (select count(distinct r ->> 'id') = 1 from public.zl_res where k in ('r_open', 'r_v1', 'r_v2b1', 'r_v2a2', 'r_v2null')),
  'RETOMADA: v1 e v2 (com o mesmo nivel, outro nivel ou sem nivel) devolvem a mesma in_progress');
select public.zl_assert(
  (select count(*) = 1 from public.user_placement_attempts where user_id = public.zl_uid(24)),
  'RETOMADA: nao cria segunda tentativa');
select public.zl_assert(
  (select r -> 'attempt' ->> 'level_code' = 'B1' and jsonb_array_length(r -> 'items') = 10
          and (r -> 'attempt') ? 'placement_test_id' and (r -> 'attempt') ? 'total_questions'
          and (r -> 'attempt') ? 'answered_count' and (r -> 'attempt') ? 'status' and (r -> 'attempt') ? 'id'
     from public.zl_res where k = 'r_items'),
  'ITEMS: teste de nivel traz attempt.level_code e as chaves antigas');
select public.zl_assert(position('ZL explicacao' in (select r::text from public.zl_res where k = 'r_items')) = 0
  and position('correct' in (select r::text from public.zl_res where k = 'r_items')) = 0,
  'GABARITO: itens do teste de nivel nao trazem explicacao nem resposta certa');
set role authenticated;
select public.zl_as(public.zl_uid(21));
select public.zl_assert((public.get_placement_items((select (r ->> 'id')::uuid from public.zl_res where k = 'v2_null')) -> 'attempt')
    ->> 'level_code' is null
  and (public.get_placement_items((select (r ->> 'id')::uuid from public.zl_res where k = 'v2_null')) -> 'attempt') ? 'level_code',
  'ITEMS: teste geral traz attempt.level_code nulo');
reset role;

-- ---------------------------------------------------------------------
-- Carencia soma tentativas de nivel e geral (nos dois sentidos)
-- Aluno 1 ja concluiu um teste de B1 (b1_10); aluno 17 concluiu o geral (g_a2).
-- ---------------------------------------------------------------------
set role authenticated;
select public.zl_as(public.zl_uid(1));
select public.zl_expect_error($q$select public.start_placement_attempt()$q$, 'P0001', 'placement_retry_too_soon');
select public.zl_expect_error($q$select public.start_placement_attempt_v2()$q$, 'P0001', 'placement_retry_too_soon');
select public.zl_expect_error(
  $q$select public.start_placement_attempt_v2((select id from public.levels where code = 'A2'))$q$, 'P0001', 'placement_retry_too_soon');
select public.zl_as(public.zl_uid(17));
select public.zl_expect_error(
  $q$select public.start_placement_attempt_v2((select id from public.levels where code = 'B1'))$q$, 'P0001', 'placement_retry_too_soon');
select public.zl_expect_error($q$select public.start_placement_attempt()$q$, 'P0001', 'placement_retry_too_soon');
reset role;
select public.zl_assert(
  (select count(*) = 1 from public.user_placement_attempts where user_id = public.zl_uid(1))
  and (select count(*) = 1 from public.user_placement_attempts where user_id = public.zl_uid(17)),
  'CARENCIA: nivel depois de geral e geral depois de nivel barram, sem criar tentativa');
-- depois de 168 h libera, em qualquer direcao
alter table public.user_placement_attempts disable trigger user_placement_attempts_guard;
update public.user_placement_attempts set started_at = started_at - interval '169 hours', completed_at = completed_at - interval '169 hours'
 where user_id in (public.zl_uid(1), public.zl_uid(17));
alter table public.user_placement_attempts enable trigger user_placement_attempts_guard;
set role authenticated;
select public.zl_as(public.zl_uid(1));
insert into public.zl_res select 'c_after_level', jsonb_build_object('id', public.start_placement_attempt());
select public.zl_as(public.zl_uid(17));
insert into public.zl_res select 'c_after_general', jsonb_build_object('id',
  public.start_placement_attempt_v2((select id from public.levels where code = 'B1')));
reset role;
select public.zl_assert(
  (select (select pt.level_id is null from public.user_placement_attempts a join public.placement_tests pt on pt.id = a.placement_test_id
            where a.id = (r ->> 'id')::uuid) from public.zl_res where k = 'c_after_level')
  and (select (select pt.level_id = public.zl_lvl('B1') from public.user_placement_attempts a join public.placement_tests pt on pt.id = a.placement_test_id
            where a.id = (r ->> 'id')::uuid) from public.zl_res where k = 'c_after_general'),
  'CARENCIA: passadas 168 horas abre o geral (apos nivel) e o de nivel (apos geral)');

-- ---------------------------------------------------------------------
-- select_starting_level com teste de nivel: recomendado e abaixo, nunca acima
-- Aluno 3: B1 com 60% -> recomendado A2. Aluno 2: B1 com 70% -> B1.
-- ---------------------------------------------------------------------
set role authenticated;
select public.zl_as(public.zl_uid(3));
select public.zl_expect_error(
  format($q$select public.select_starting_level(public.zl_lvl('B1'), %L)$q$, (select r ->> 'attempt_id' from public.zl_res where k = 'b1_06')),
  '22023', 'superar');
select public.select_starting_level(public.zl_lvl('A2'), (select (r ->> 'attempt_id')::uuid from public.zl_res where k = 'b1_06'));
select public.zl_assert((select current_level_id = public.zl_lvl('A2') from public.profiles where id = public.zl_uid(3)),
  'SELECT: aceita o nivel recomendado pelo teste de nivel');
select public.select_starting_level(public.zl_lvl('A1'), (select (r ->> 'attempt_id')::uuid from public.zl_res where k = 'b1_06'));
select public.zl_assert((select current_level_id = public.zl_lvl('A1') from public.profiles where id = public.zl_uid(3)),
  'SELECT: aceita nivel abaixo do recomendado');
select public.zl_as(public.zl_uid(2));
select public.select_starting_level(public.zl_lvl('B1'), (select (r ->> 'attempt_id')::uuid from public.zl_res where k = 'b1_07'));
select public.zl_assert((select current_level_id = public.zl_lvl('B1') from public.profiles where id = public.zl_uid(2)),
  'SELECT: 70% em B1 permite escolher B1');
select public.zl_expect_error(
  format($q$select public.select_starting_level(public.zl_lvl('B2'), %L)$q$, (select r ->> 'attempt_id' from public.zl_res where k = 'b1_07')),
  '22023', 'superar');
reset role;

\echo ===== TESTES NIVELAMENTO POR NIVEL PASSARAM =====
