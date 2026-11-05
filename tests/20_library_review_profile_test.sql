-- =====================================================================
-- MyFluenti - Testes da migration 004: Biblioteca, Revisao e Perfil
-- Autocontido. Roda DEPOIS do tests/10_smoke_test.sql, no mesmo banco:
--   (1) Supabase local: db reset -> 10_smoke_test.sql -> este arquivo
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> este arquivo
-- O setup roda como postgres; os casos rodam com set role authenticated e
-- o claim request.jwt.claim.sub. Helpers proprios com prefixo zt_.
-- Usuarios: 44444444 (aluno A), 55555555 (aluno B), 66666666 (Premium).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------
-- Helpers de teste
-- ---------------------------------------------------------------------
create table public.zt_l (slug text, lesson_id uuid, version_id uuid, section_id uuid, module_id uuid);
create table public.zt_q (slug text, pos int, question_id uuid, correct_opt uuid, wrong_opt uuid);
grant select on public.zt_l, public.zt_q to authenticated;

create function public.zt_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zt_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zt_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

create function public.zt_qid(p_slug text, p_pos int) returns uuid language sql stable as $$
  select question_id from public.zt_q where slug = p_slug and pos = p_pos
$$;
create function public.zt_corr(p_slug text, p_pos int) returns uuid language sql stable as $$
  select correct_opt from public.zt_q where slug = p_slug and pos = p_pos
$$;
create function public.zt_wrong(p_slug text, p_pos int) returns uuid language sql stable as $$
  select wrong_opt from public.zt_q where slug = p_slug and pos = p_pos
$$;

-- true quando o jsonb NAO contem o id de nenhuma alternativa correta
create function public.zt_no_leak(j jsonb) returns boolean language sql stable as $$
  select not exists (select 1 from public.zt_q q where position(q.correct_opt::text in j::text) > 0)
$$;

-- as 9 RPCs novas, com argumentos validos o bastante para chegar na checagem de login/permissao
create function public.zt_rpc_calls() returns text[] language sql immutable as $$
  select array[
    $q$select public.search_library()$q$,
    $q$select public.get_library_item('grammar', gen_random_uuid())$q$,
    $q$select public.get_my_favorites()$q$,
    $q$select public.get_review_queue()$q$,
    $q$select public.start_review_session()$q$,
    $q$select public.submit_review_answer(gen_random_uuid(), gen_random_uuid(), '{}'::jsonb)$q$,
    $q$select public.record_review_result_v2(gen_random_uuid(), 'good')$q$,
    $q$select public.finish_review_session(gen_random_uuid())$q$,
    $q$select public.get_profile_summary()$q$
  ]
$$;

create function public.zt_mk_lesson(p_module uuid, p_slug text, p_pos int, p_nq int)
returns void language plpgsql as $$
declare l uuid; v uuid; s uuid; e uuid; q uuid; o1 uuid; o2 uuid; i int;
begin
  insert into public.lessons (module_id, slug, position) values (p_module, p_slug, p_pos) returning id into l;
  insert into public.lesson_versions (lesson_id, version_number, title)
    values (l, 1, 'Aula ' || p_slug) returning id into v;
  insert into public.lesson_sections (lesson_version_id, position, section_type, title)
    values (v, 1, 'explanation', 'Explicacao') returning id into s;
  insert into public.exercises (lesson_version_id, position, title) values (v, 1, 'Ex 1') returning id into e;
  for i in 1..p_nq loop
    insert into public.questions (lesson_version_id, exercise_id, question_type, prompt, position)
      values (v, e, 'multiple_choice', 'ZTQ ' || p_slug || ' ' || i, i) returning id into q;
    insert into public.answer_options (question_id, option_text, position) values (q, 'certa', 1) returning id into o1;
    insert into public.answer_options (question_id, option_text, position) values (q, 'errada', 2) returning id into o2;
    insert into private.question_answer_keys (question_id, correct_option_id, explanation)
      values (q, o1, 'Explicacao ' || p_slug || ' ' || i);
    insert into public.zt_q values (p_slug, i, q, o1, o2);
  end loop;
  update public.lesson_versions set is_published = true where id = v;
  insert into public.zt_l values (p_slug, l, v, s, p_module);
end $$;

-- ---------------------------------------------------------------------
-- Setup (postgres): usuarios, niveis, conteudo, fila de revisao
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('44444444-4444-4444-4444-444444444444', 'zt4@teste'),
  ('55555555-5555-5555-5555-555555555555', 'zt5@teste'),
  ('66666666-6666-6666-6666-666666666666', 'zt6@teste');

insert into public.levels (code, title, position) values
  ('A1', 'Iniciante', 1), ('A2', 'Basico', 2), ('B1', 'Intermediario', 3),
  ('B2', 'Intermediario avancado', 4), ('C1', 'Avancado', 5), ('C2', 'Dominio', 6)
on conflict (code) do nothing;

insert into public.modules (id, level_id, title, position, access_tier, is_published) values
  ('0e0e0e0e-0000-0000-0000-000000000050', (select id from public.levels where code = 'A1'),
   'ZT M50 free', 50, 'free', true),
  ('0e0e0e0e-0000-0000-0000-000000000051', (select id from public.levels where code = 'A1'),
   'ZT M51 premium', 51, 'premium', true);

select public.zt_mk_lesson('0e0e0e0e-0000-0000-0000-000000000050', 'ztL1', 1, 2);
select public.zt_mk_lesson('0e0e0e0e-0000-0000-0000-000000000050', 'ztL2', 2, 1);
select public.zt_mk_lesson('0e0e0e0e-0000-0000-0000-000000000051', 'ztP1', 1, 1);

insert into public.grammar_topics (id, slug, title, category, summary, content, level_id, access_tier, is_published) values
  ('a0a0a0a0-0000-0000-0000-000000000001', 'zt-present-perfect', 'ZT Present Perfect', 'zt-cat',
   'resumo do present perfect', '{"blocks":["x"]}', (select id from public.levels where code = 'A1'), 'free', true),
  ('a0a0a0a0-0000-0000-0000-000000000002', 'zt-conditionals', 'ZT Conditionals', 'zt-cat2',
   'resumo condicionais', '{"blocks":["secreto"]}', (select id from public.levels where code = 'A2'), 'premium', true),
  ('a0a0a0a0-0000-0000-0000-000000000003', 'zt-draft', 'ZT Draft', 'zt-cat',
   'rascunho', '{}', (select id from public.levels where code = 'A1'), 'free', false);

insert into public.vocabulary (id, lemma, part_of_speech, meaning_pt, level_id, access_tier, is_published) values
  ('b0b0b0b0-0000-0000-0000-000000000001', 'ztapple',    'noun', 'maca vermelha',      (select id from public.levels where code = 'A1'), 'free',    true),
  ('b0b0b0b0-0000-0000-0000-000000000002', 'ztbanana',   'noun', 'fruta amarela',      (select id from public.levels where code = 'A1'), 'free',    true),
  ('b0b0b0b0-0000-0000-0000-000000000003', 'ztcherry',   'noun', 'fruta pequena',      (select id from public.levels where code = 'A1'), 'free',    true),
  ('b0b0b0b0-0000-0000-0000-000000000004', 'ztpremword', 'verb', 'significado segredo', (select id from public.levels where code = 'A2'), 'premium', true),
  ('b0b0b0b0-0000-0000-0000-000000000005', 'ztdraft',    'noun', 'rascunho vocab',     (select id from public.levels where code = 'A1'), 'free',    false);

insert into public.vocabulary_forms (vocabulary_id, form_label, form_text, meaning_pt) values
  ('b0b0b0b0-0000-0000-0000-000000000001', 'plural', 'ztapples', 'macas'),
  ('b0b0b0b0-0000-0000-0000-000000000001', 'base',   'ztapple',  'maca'),
  ('b0b0b0b0-0000-0000-0000-000000000004', 'base',   'zzsecretform', 'forma secreta');

insert into public.vocabulary_examples (id, vocabulary_id, example_en, example_pt, position) values
  ('c0c0c0c0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'I eat an ztapple.', 'Eu como uma maca.', 1),
  ('c0c0c0c0-0000-0000-0000-000000000002', 'b0b0b0b0-0000-0000-0000-000000000001', 'The ztapple is red.', 'A maca e vermelha.', 2),
  ('c0c0c0c0-0000-0000-0000-000000000003', 'b0b0b0b0-0000-0000-0000-000000000004', 'They ztpremword it.', 'Eles ztpremword isso.', 1);

insert into public.subscription_plans (id, code, name, tier)
  values ('d0d0d0d0-0000-0000-0000-000000000001', 'zt_premium', 'Premium (teste ZT)', 'premium');
insert into public.user_subscriptions (id, user_id, plan_id, status, current_period_end)
  values ('d0d0d0d0-0000-0000-0000-0000000000a1', '66666666-6666-6666-6666-666666666666',
          'd0d0d0d0-0000-0000-0000-000000000001', 'active', now() + interval '30 days');

-- Perfil, nivelamento, progresso e dominio do aluno A
update public.profiles set current_level_id = (select id from public.levels where code = 'A1')
 where id = '44444444-4444-4444-4444-444444444444';
insert into public.placement_tests (id, code, version_number, title, total_questions)
  values ('bbbbbbbb-0000-0000-0000-0000000000f1', 'zt', 1, 'ZT nivelamento', 30);
insert into public.user_placement_attempts
  (user_id, placement_test_id, status, score_pct, recommended_level_id, started_at, completed_at)
values ('44444444-4444-4444-4444-444444444444', 'bbbbbbbb-0000-0000-0000-0000000000f1', 'completed', 55,
        (select id from public.levels where code = 'A2'), now() - interval '2 days', now() - interval '2 days');
insert into public.user_module_progress (user_id, module_id, status, started_at, completed_at)
  values ('44444444-4444-4444-4444-444444444444', '0e0e0e0e-0000-0000-0000-000000000050', 'completed', now(), now());
insert into public.user_lesson_progress (user_id, lesson_id, status, best_score, attempt_count, completed_at, completed_version_id)
  select '44444444-4444-4444-4444-444444444444', lesson_id, 'completed', 100, 1, now(), version_id
    from public.zt_l where slug = 'ztL1';
insert into public.user_topic_mastery (user_id, grammar_topic_id, mastery_score, attempts_count, correct_count, last_practiced_at) values
  ('44444444-4444-4444-4444-444444444444', 'a0a0a0a0-0000-0000-0000-000000000001', 75, 4, 3, now()),
  ('44444444-4444-4444-4444-444444444444', 'a0a0a0a0-0000-0000-0000-000000000002', 50, 2, 1, now());

-- Fila de revisao do aluno A (4 vencidos hoje, 1 amanha, 1 em 3 dias)
insert into public.review_schedule (user_id, vocabulary_id, grammar_topic_id, question_id, due_at) values
  ('44444444-4444-4444-4444-444444444444', 'b0b0b0b0-0000-0000-0000-000000000001', null, null, now() - interval '1 day'),
  ('44444444-4444-4444-4444-444444444444', 'b0b0b0b0-0000-0000-0000-000000000003', null, null, now() - interval '3 hours'),
  ('44444444-4444-4444-4444-444444444444', null, null, public.zt_qid('ztL1', 1), now() - interval '2 hours'),
  ('44444444-4444-4444-4444-444444444444', null, 'a0a0a0a0-0000-0000-0000-000000000001', null, now() - interval '1 hour'),
  ('44444444-4444-4444-4444-444444444444', 'b0b0b0b0-0000-0000-0000-000000000002', null, null,
     private.local_day_end('UTC') + interval '1 hour'),
  ('44444444-4444-4444-4444-444444444444', null, null, public.zt_qid('ztL1', 2),
     private.local_day_end('UTC') + interval '3 days');

-- Fila do aluno Premium (questao e palavra Premium vencidas)
insert into public.review_schedule (user_id, vocabulary_id, question_id, due_at) values
  ('66666666-6666-6666-6666-666666666666', null, public.zt_qid('ztP1', 1), now() - interval '1 hour'),
  ('66666666-6666-6666-6666-666666666666', 'b0b0b0b0-0000-0000-0000-000000000004', null, now() - interval '1 hour');

-- Elegibilidade: aluno A e aluno Premium ja responderam essas questoes em tentativas ENCERRADAS
insert into public.user_lesson_attempts (id, user_id, lesson_version_id, status, earned_points, total_points, score_pct, passed, completed_at) values
  ('e1e1e1e1-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
   (select version_id from public.zt_l where slug = 'ztL1'), 'completed', 1, 2, 50, false, now()),
  ('e1e1e1e1-0000-0000-0000-000000000002', '66666666-6666-6666-6666-666666666666',
   (select version_id from public.zt_l where slug = 'ztP1'), 'completed', 1, 1, 100, true, now());
insert into public.user_exercise_attempts
  (user_id, lesson_attempt_id, lesson_version_id, question_id, submitted_answer, is_correct, awarded_points, max_points)
select '44444444-4444-4444-4444-444444444444', 'e1e1e1e1-0000-0000-0000-000000000001',
       (select version_id from public.zt_l where slug = 'ztL1'), public.zt_qid('ztL1', i), '{}', false, 0, 1
  from generate_series(1, 2) i;
insert into public.user_exercise_attempts
  (user_id, lesson_attempt_id, lesson_version_id, question_id, submitted_answer, is_correct, awarded_points, max_points)
values ('66666666-6666-6666-6666-666666666666', 'e1e1e1e1-0000-0000-0000-000000000002',
        (select version_id from public.zt_l where slug = 'ztP1'), public.zt_qid('ztP1', 1), '{}', true, 1, 1);

-- S3: versao 2 NAO publicada de ztL2, com uma secao
insert into public.lesson_versions (id, lesson_id, version_number, title)
  select 'e2e2e2e2-0000-0000-0000-000000000001', lesson_id, 2, 'ztL2 v2 rascunho' from public.zt_l where slug = 'ztL2';
insert into public.lesson_sections (id, lesson_version_id, position, section_type)
  values ('e2e2e2e2-0000-0000-0000-000000000002', 'e2e2e2e2-0000-0000-0000-000000000001', 1, 'summary');

-- S5: topicos com curingas literais e controle
insert into public.grammar_topics (id, slug, title, category, is_published) values
  ('a0a0a0a0-0000-0000-0000-000000000011', 'lit-wild', 'lit 100% _x\y', 'lit', true),
  ('a0a0a0a0-0000-0000-0000-000000000012', 'lit-ctrl', 'lit 100 abc', 'lit', true);

-- Aluno 7: nivelamento em andamento com uma questao de banco
insert into auth.users (id, email) values ('77777777-7777-7777-7777-777777777777', 'zt7@teste');
insert into public.questions (id, question_type, prompt)
  values ('f1f1f1f1-0000-0000-0000-000000000001', 'multiple_choice', 'ZT placement q');
with o as (
  insert into public.answer_options (question_id, option_text, position) values
    ('f1f1f1f1-0000-0000-0000-000000000001', 'certa', 1), ('f1f1f1f1-0000-0000-0000-000000000001', 'errada', 2)
  returning id, position)
insert into public.zt_q
  select 'ztPL', 1, 'f1f1f1f1-0000-0000-0000-000000000001',
         (select id from o where position = 1), (select id from o where position = 2);
insert into private.question_answer_keys (question_id, correct_option_id, explanation)
  values ('f1f1f1f1-0000-0000-0000-000000000001', public.zt_corr('ztPL', 1), 'EXPLICACAO NIVELAMENTO');
insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
  values ('bbbbbbbb-0000-0000-0000-0000000000f1', 'f1f1f1f1-0000-0000-0000-000000000001', 'grammar',
          (select id from public.levels where code = 'A1'), 1, 1);
insert into public.user_placement_attempts (id, user_id, placement_test_id)
  values ('e3e3e3e3-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 'bbbbbbbb-0000-0000-0000-0000000000f1');
insert into public.user_module_progress (user_id, module_id)
  values ('77777777-7777-7777-7777-777777777777', '0e0e0e0e-0000-0000-0000-000000000050');

-- contagem esperada de vencidos em America/Sao_Paulo (depende da hora do dia)
select set_config('zt.sp_due', (select count(*)::text from public.review_schedule
  where user_id = '44444444-4444-4444-4444-444444444444'
    and due_at < private.local_day_end('America/Sao_Paulo')), false);

-- ---------------------------------------------------------------------
-- SEC: anon sem execute; authenticated sem claim recebe 28000
-- ---------------------------------------------------------------------
set role anon;
do $$
declare f text;
begin
  foreach f in array public.zt_rpc_calls() loop
    perform public.zt_expect_error(f, '42501');
  end loop;
  perform public.zt_assert(true, 'SEC: anon nao executa nenhuma das 9 RPCs novas (42501)');
end $$;
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub', '', false);
do $$
declare f text;
begin
  foreach f in array public.zt_rpc_calls() loop
    perform public.zt_expect_error(f, '28000');
  end loop;
  perform public.zt_assert(true, 'SEC: authenticated sem login (sem claim) recebe 28000 nas 9 RPCs');
  perform public.zt_expect_error($q$select private.local_day_end('UTC')$q$, '42501');
  perform public.zt_expect_error(
    $q$select private.review_item_accessible(gen_random_uuid(), null, null, null)$q$, '42501');
  perform public.zt_expect_error($q$select private.accessible_due_count(gen_random_uuid(), now())$q$, '42501');
  perform public.zt_assert(true, 'SEC: helpers privados nao sao executaveis pelo app');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Biblioteca: aluno B (plano Free, sem progressao e sem nivelamento)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zt_as('55555555-5555-5555-5555-555555555555');
do $$
declare r jsonb; it jsonb; gp uuid := 'a0a0a0a0-0000-0000-0000-000000000002';
        vp uuid := 'b0b0b0b0-0000-0000-0000-000000000004';
begin
  r := public.search_library(p_query := 'zt');
  perform public.zt_assert((r->>'total')::int = 6 and jsonb_array_length(r->'items') = 6
    and (r->>'limit')::int = 20 and (r->>'offset')::int = 0 and (r->>'has_more')::boolean is false,
    'LIB: busca devolve so itens publicados (rascunhos fora) e independe de progressao/nivelamento');
  perform public.zt_assert(r->'items'->0->>'type' = 'grammar' and r->'items'->0->>'slug' = 'zt-present-perfect'
    and r->'items'->5->>'type' = 'vocabulary' and r->'items'->5->>'id' = vp::text
    and r->'items'->1->>'title' = 'ztapple' and r->'items'->3->>'title' = 'ztcherry',
    'LIB: ordem provisoria (nivel, gramatica antes de vocabulario, titulo)');

  select e into it from jsonb_array_elements(r->'items') e where e->>'id' = vp::text;
  perform public.zt_assert((it->>'locked')::boolean and it->>'subtitle' is null and it->>'title' = 'ztpremword'
    and it->>'part_of_speech' = 'verb' and it->>'access_tier' = 'premium' and it->>'slug' is null,
    'LIB: vocabulario Premium sem plano vem locked, mostra lemma e esconde o significado');
  select e into it from jsonb_array_elements(r->'items') e where e->>'id' = gp::text;
  perform public.zt_assert((it->>'locked')::boolean and it->>'subtitle' = 'resumo condicionais'
    and it->>'category' = 'zt-cat2' and it->>'level_code' = 'A2',
    'LIB: gramatica Premium locked mostra title e summary');
  select e into it from jsonb_array_elements(r->'items') e where e->>'title' = 'ztapple';
  perform public.zt_assert(not (it->>'locked')::boolean and it->>'subtitle' = 'maca vermelha'
    and (it->>'mastery_pct') is null and (it->>'is_favorite')::boolean is false,
    'LIB: vocabulario Free vem liberado com significado');

  -- busca nao vaza conteudo Premium
  perform public.zt_assert((public.search_library(p_query := 'segredo')->>'total')::int = 0,
    'LIB: busca pelo significado de vocabulario Premium nao acha (sem plano)');
  perform public.zt_assert((public.search_library(p_query := 'zzsecretform')->>'total')::int = 0,
    'LIB: busca pela forma de vocabulario Premium nao acha (sem plano)');
  perform public.zt_assert((public.search_library(p_query := 'ztpremword')->>'total')::int = 1,
    'LIB: vocabulario Premium casa pelo lemma');
  perform public.zt_assert((public.search_library(p_query := 'condicionais')->'items'->0->>'id') = gp::text,
    'LIB: gramatica casa por summary, inclusive Premium locked');
  perform public.zt_assert((public.search_library(p_query := 'vermelha')->>'total')::int = 1
    and (public.search_library(p_query := 'ztapples')->>'total')::int = 1,
    'LIB: vocabulario liberado casa por significado e por forma');
  perform public.zt_assert((public.search_library(p_query := '  ZT PRESENT  ')->>'total')::int = 1
    and (public.search_library(p_query := '   ')->>'total')::int >= 6
    and public.search_library(p_query := '   ')->'total' = public.search_library()->'total',
    'LIB: query usa btrim e ILIKE; vazia vira sem filtro');
  perform public.zt_assert(
        public.search_library(p_query := '100%')->'items'->0->>'id' = 'a0a0a0a0-0000-0000-0000-000000000011'
    and (public.search_library(p_query := '100%')->>'total')::int = 1
    and (public.search_library(p_query := '100')->>'total')::int = 2
    and (public.search_library(p_query := ' _x')->>'total')::int = 1
    and public.search_library(p_query := 'x\y')->'items'->0->>'id' = 'a0a0a0a0-0000-0000-0000-000000000011'
    and (public.search_library(p_query := '%')->>'total')::int = 1
    and (public.search_library(p_query := '_')->>'total')::int = 1
    and (public.search_library(p_query := '\')->>'total')::int = 1
    and (public.search_library(p_query := '100_')->>'total')::int = 0
    and (public.search_library(p_query := '0 a')->>'total')::int = 1,
    'LIB: curingas %, _ e \ literais casam so o titulo que os contem (controle sem curinga fora)');

  -- filtros e paginacao
  perform public.zt_assert((public.search_library(p_type := 'grammar', p_query := 'zt')->>'total')::int = 2
    and (public.search_library(p_type := 'vocabulary', p_query := 'zt')->>'total')::int = 4,
    'LIB: filtro por tipo');
  r := public.search_library(p_level_code := 'A2', p_query := 'zt');
  perform public.zt_assert((r->>'total')::int = 2 and not exists (
      select 1 from jsonb_array_elements(r->'items') e where e->>'level_code' <> 'A2'),
    'LIB: filtro por nivel');
  r := public.search_library(p_category := 'zt-cat', p_query := 'zt');
  perform public.zt_assert((r->>'total')::int = 1 and r->'items'->0->>'type' = 'grammar',
    'LIB: categoria filtra so gramatica (vocabulario fica fora)');
  r := public.search_library(p_query := 'zt', p_limit := 2, p_offset := 0);
  perform public.zt_assert(jsonb_array_length(r->'items') = 2 and (r->>'has_more')::boolean, 'LIB: pagina 1 tem has_more');
  r := public.search_library(p_query := 'zt', p_limit := 2, p_offset := 4);
  perform public.zt_assert(jsonb_array_length(r->'items') = 2 and not (r->>'has_more')::boolean, 'LIB: ultima pagina sem has_more');
  r := public.search_library(p_query := 'zt', p_limit := 2, p_offset := 40);
  perform public.zt_assert(jsonb_array_length(r->'items') = 0 and (r->>'total')::int = 6 and not (r->>'has_more')::boolean,
    'LIB: offset alem do total devolve lista vazia');

  perform public.zt_expect_error($q$select public.search_library(p_type := 'x')$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.search_library(p_level_code := 'Z9')$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.search_library(p_limit := 0)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.search_library(p_limit := 51)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.search_library(p_offset := -1)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.search_library(p_offset := 2147483647)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.search_library(p_offset := 100001)$q$, '22023', 'invalid_filter');
  perform public.zt_assert((public.search_library(p_offset := 100000)->>'has_more')::boolean is false, 'LIB: offset 100000 e aceito');
  perform public.zt_expect_error($q$select public.get_my_favorites(null, 20, 2147483647)$q$, '22023', 'invalid_filter');

  -- get_library_item
  perform public.zt_expect_error(format($q$select public.get_library_item('vocabulary', %L)$q$, vp), '42501', 'premium_required');
  perform public.zt_expect_error(format($q$select public.get_library_item('grammar', %L)$q$, gp), '42501', 'premium_required');
  perform public.zt_expect_error(
    $q$select public.get_library_item('grammar', 'a0a0a0a0-0000-0000-0000-000000000003')$q$, 'P0002', 'item_not_found');
  perform public.zt_expect_error(
    $q$select public.get_library_item('vocabulary', 'b0b0b0b0-0000-0000-0000-000000000005')$q$, 'P0002', 'item_not_found');
  perform public.zt_expect_error($q$select public.get_library_item('vocabulary', gen_random_uuid())$q$, 'P0002', 'item_not_found');
  perform public.zt_expect_error($q$select public.get_library_item('lesson', gen_random_uuid())$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.get_library_item(null, gen_random_uuid())$q$, '22023', 'invalid_filter');
  r := public.get_library_item('grammar', 'a0a0a0a0-0000-0000-0000-000000000001');
  perform public.zt_assert(r->>'slug' = 'zt-present-perfect' and r->>'level_code' = 'A1'
    and r->'content'->'blocks'->>0 = 'x' and r->'mastery' = 'null'::jsonb and (r->>'notes_count')::int = 0,
    'LIB: get_library_item gramatica Free (mastery null para quem nunca praticou)');
  perform public.zt_assert(public.zt_no_leak(public.search_library(p_query := 'zt'))
    and public.zt_no_leak(r), 'SEC: busca e item nao contem id de alternativa correta');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Biblioteca: aluno Premium abre os itens Premium
-- ---------------------------------------------------------------------
set role authenticated;
select public.zt_as('66666666-6666-6666-6666-666666666666');
do $$
declare r jsonb; it jsonb;
begin
  r := public.search_library(p_query := 'segredo');
  perform public.zt_assert((r->>'total')::int = 1 and not (r->'items'->0->>'locked')::boolean
    and r->'items'->0->>'subtitle' = 'significado segredo',
    'LIB: Premium com plano acha pelo significado e ve o item liberado');
  perform public.zt_assert((public.search_library(p_query := 'zzsecretform')->>'total')::int = 1,
    'LIB: Premium com plano acha pela forma');
  r := public.get_library_item('vocabulary', 'b0b0b0b0-0000-0000-0000-000000000004');
  perform public.zt_assert(r->>'meaning_pt' = 'significado segredo' and r->'forms'->0->>'label' = 'base'
    and r->'forms'->0->>'text' = 'zzsecretform' and jsonb_array_length(r->'examples') = 1
    and (r->'examples'->0->>'is_favorite')::boolean is false,
    'LIB: usuario Premium abre vocabulario Premium');
  r := public.get_library_item('grammar', 'a0a0a0a0-0000-0000-0000-000000000002');
  perform public.zt_assert(r->>'title' = 'ZT Conditionals' and r->'content'->'blocks'->>0 = 'secreto',
    'LIB: usuario Premium abre gramatica Premium');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Favoritos e notas (aluno A)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zt_as('44444444-4444-4444-4444-444444444444');
do $$
declare t timestamptz; t2 timestamptz;
begin
  update public.profiles set display_name = 'Aluno ZT' where id = auth.uid();

  insert into public.user_vocabulary (user_id, vocabulary_id, is_favorite)
    values (auth.uid(), 'b0b0b0b0-0000-0000-0000-000000000001', true);
  select favorited_at into t from public.user_vocabulary where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001';
  perform public.zt_assert(t is not null, 'FAV: favoritar palavra grava favorited_at');
  update public.user_vocabulary set is_learned = true where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001';
  update public.user_vocabulary set favorited_at = '2000-01-01' where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001';
  select favorited_at into t2 from public.user_vocabulary where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001';
  perform public.zt_assert(t2 = t, 'FAV: favorited_at nao e reescrito pelo cliente nem por outro update');
  update public.user_vocabulary set is_favorite = false where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001';
  perform public.zt_assert((select favorited_at is null from public.user_vocabulary
                             where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001'),
    'FAV: desfavoritar zera favorited_at');
  update public.user_vocabulary set is_favorite = true where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001';
  perform public.zt_assert((select favorited_at is not null from public.user_vocabulary
                             where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000001'),
    'FAV: favoritar de novo grava favorited_at');
end $$;

-- transacao separada: a frase e favoritada depois da palavra (ordem por favorited_at desc)
insert into public.user_favorite_examples (user_id, vocabulary_example_id)
  values (auth.uid(), 'c0c0c0c0-0000-0000-0000-000000000001');

do $$
declare r jsonb; n1 uuid; n2 uuid; sec1 uuid; sec2 uuid; l1 uuid; l2 uuid; created timestamptz;
begin
  r := public.get_my_favorites();
  perform public.zt_assert((r->>'total')::int = 2 and not (r->>'has_more')::boolean
    and r->'items'->0->>'kind' = 'phrase' and r->'items'->1->>'kind' = 'word',
    'FAV: favoritos de palavra e de frase aparecem, mais recente primeiro');
  perform public.zt_assert(r->'items'->0->>'id' = 'c0c0c0c0-0000-0000-0000-000000000001'
    and r->'items'->0->>'title' = 'I eat an ztapple.' and r->'items'->0->>'subtitle' = 'Eu como uma maca.'
    and r->'items'->0->>'vocabulary_id' = 'b0b0b0b0-0000-0000-0000-000000000001'
    and not (r->'items'->0->>'locked')::boolean and r->'items'->0->>'favorited_at' is not null,
    'FAV: item de frase tem o id do exemplo e o vocabulary_id');
  perform public.zt_assert(r->'items'->1->>'id' = 'b0b0b0b0-0000-0000-0000-000000000001'
    and r->'items'->1->>'title' = 'ztapple' and r->'items'->1->>'subtitle' = 'maca vermelha',
    'FAV: item de palavra tem o id do vocabulario');
  perform public.zt_assert((public.get_my_favorites('word')->>'total')::int = 1
    and public.get_my_favorites('word')->'items'->0->>'kind' = 'word'
    and (public.get_my_favorites('phrase')->>'total')::int = 1,
    'FAV: filtro por tipo (word/phrase)');
  perform public.zt_assert((public.get_my_favorites(p_limit := 1)->>'has_more')::boolean
    and jsonb_array_length(public.get_my_favorites(p_limit := 1, p_offset := 1)->'items') = 1,
    'FAV: paginacao');
  perform public.zt_expect_error($q$select public.get_my_favorites('x')$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.get_my_favorites(null, 0)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.get_my_favorites(null, 51)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.get_my_favorites(null, 20, -1)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error(
    $q$update public.user_favorite_examples set created_at = now()$q$, '42501');
  perform public.zt_assert(public.zt_no_leak(r), 'SEC: favoritos nao contem id de alternativa correta');

  -- notas
  select lesson_id, section_id into l1, sec1 from public.zt_l where slug = 'ztL1';
  select lesson_id, section_id into l2, sec2 from public.zt_l where slug = 'ztL2';
  perform public.zt_expect_error(format(
    $q$insert into public.user_notes (user_id, lesson_id, lesson_section_id, body) values (auth.uid(), %L, %L, 'x')$q$, l1, sec2),
    '23514', 'section_not_in_lesson');
  perform public.zt_expect_error(format(
    $q$insert into public.user_notes (user_id, lesson_id, lesson_section_id, body)
       values (auth.uid(), %L, 'e2e2e2e2-0000-0000-0000-000000000002', 'x')$q$, l2),
    '23514', 'section_not_in_lesson');   -- S3: secao de versao nao publicada
  perform public.zt_expect_error(format(
    $q$insert into public.user_notes (user_id, grammar_topic_id, lesson_section_id, body)
       values (auth.uid(), 'a0a0a0a0-0000-0000-0000-000000000001', %L, 'x')$q$, sec1),
    '23514', 'section_not_in_lesson');
  insert into public.user_notes (user_id, lesson_id, lesson_section_id, body)
    values (auth.uid(), l1, sec1, 'nota da secao') returning id, created_at into n1, created;
  perform public.zt_assert(n1 is not null, 'NOTE: nota com secao da propria aula funciona');
  insert into public.user_notes (user_id, grammar_topic_id, body)
    values (auth.uid(), 'a0a0a0a0-0000-0000-0000-000000000001', 'nota gramatica');
  insert into public.user_notes (user_id, vocabulary_id, body)
    values (auth.uid(), 'b0b0b0b0-0000-0000-0000-000000000001', 'nota vocab') returning id into n2;
  update public.user_notes set body = 'nota editada' where id = n1;
  perform public.zt_assert((select body = 'nota editada' from public.user_notes where id = n1), 'NOTE: aluno edita o texto da nota');
  perform public.zt_expect_error(format($q$update public.user_notes set lesson_section_id = %L where id = %L$q$, sec2, n1),
    '23514', 'section_not_in_lesson');
  update public.user_notes set lesson_section_id = null where id = n1;
  perform public.zt_expect_error(format($q$update public.user_notes set created_at = now() where id = %L$q$, n1), '42501');
  perform public.zt_expect_error(format(
    $q$update public.user_notes set user_id = '55555555-5555-5555-5555-555555555555' where id = %L$q$, n1), '42501');
  perform public.zt_expect_error(format($q$update public.user_notes set lesson_id = %L where id = %L$q$, l2, n1), '42501');
  perform public.zt_assert((select created_at = created from public.user_notes where id = n1),
    'NOTE: aluno nao altera created_at, user_id nem o alvo da nota (42501)');
end $$;

-- item da biblioteca com dominio, notas e favoritos do aluno A
do $$
declare r jsonb;
begin
  r := public.get_library_item('grammar', 'a0a0a0a0-0000-0000-0000-000000000001');
  perform public.zt_assert((r->'mastery'->>'pct')::numeric = 75 and (r->'mastery'->>'attempts')::int = 4
    and (r->'mastery'->>'correct')::int = 3 and r->'mastery'->>'last_practiced_at' is not null
    and (r->>'notes_count')::int = 1, 'LIB: get_library_item gramatica traz dominio e notes_count do aluno');
  r := public.get_library_item('vocabulary', 'b0b0b0b0-0000-0000-0000-000000000001');
  perform public.zt_assert(r->'forms'->0->>'label' = 'base' and r->'forms'->1->>'label' = 'plural'
    and r->'forms'->0->>'text' = 'ztapple' and r->'forms'->0->>'meaning_pt' = 'maca'
    and jsonb_array_length(r->'examples') = 2
    and (r->'examples'->0->>'is_favorite')::boolean and not (r->'examples'->1->>'is_favorite')::boolean
    and r->'examples'->0->>'en' = 'I eat an ztapple.' and r->'examples'->0->>'pt' = 'Eu como uma maca.'
    and (r->>'is_favorite')::boolean and (r->>'is_learned')::boolean and (r->>'notes_count')::int = 1
    and r->>'level_code' = 'A1', 'LIB: get_library_item vocabulario traz formas, exemplos, favoritos e notas');
  r := public.search_library(p_query := 'ZT Present');
  perform public.zt_assert((r->'items'->0->>'mastery_pct')::numeric = 75, 'LIB: busca devolve mastery_pct da gramatica');
  r := public.search_library(p_query := 'ztapple');
  perform public.zt_assert((r->'items'->0->>'is_favorite')::boolean, 'LIB: busca devolve is_favorite do vocabulario');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Revisao: fila, sessao, respostas, resultado e fim (aluno A)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zt_as('44444444-4444-4444-4444-444444444444');
do $$
declare q jsonb; it jsonb; s1 uuid; s1b uuid; r jsonb; fin jsonb; fin2 jsonb;
        done1 timestamptz; done2 timestamptz;
        v_sched record;
begin
  -- fila
  q := public.get_review_queue();
  perform public.zt_assert((q->>'due_count')::int = 4 and (q->>'locked_count')::int = 0
    and jsonb_array_length(q->'items') = 4, 'REV: fila traz os 4 vencidos hoje');
  perform public.zt_assert((q->'upcoming'->>'tomorrow')::int = 1 and (q->'upcoming'->>'next_7_days')::int = 2,
    'REV: previsao de amanha (1) e dos proximos 7 dias (2)');
  perform public.zt_assert((q->>'next_due_at')::timestamptz = (
      select due_at from public.review_schedule where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000002'),
    'REV: next_due_at e o proximo vencimento futuro');
  perform public.zt_assert(q->'items'->0->>'item_type' = 'vocabulary'
    and q->'items'->0->'vocabulary'->>'lemma' = 'ztapple'
    and jsonb_array_length(q->'items'->0->'vocabulary'->'examples') = 2
    and q->'items'->1->'vocabulary'->>'lemma' = 'ztcherry'
    and q->'items'->2->>'item_type' = 'question' and q->'items'->3->>'item_type' = 'grammar_topic'
    and q->'items'->3->'grammar_topic'->>'slug' = 'zt-present-perfect',
    'REV: itens ordenados por due_at, cada um com o bloco do seu tipo');
  it := q->'items'->2;
  perform public.zt_assert(it->'question'->>'question_type' = 'multiple_choice'
    and jsonb_array_length(it->'question'->'options') = 2
    and it->'question'->'options'->0->>'position' = '1' and it->'question'->'options'->0->>'text' = 'certa'
    and it->>'schedule_id' is not null and it->>'due_at' is not null,
    'REV: item de questao traz enunciado e alternativas ordenadas');
  perform public.zt_assert(q::text !~* '(correct|accepted|grading|explanation|is_correct)',
    'SEC: fila nao traz gabarito, resposta aceita nem explicacao');
  perform public.zt_assert(jsonb_array_length(public.get_review_queue('UTC', 2)->'items') = 2
    and (public.get_review_queue('UTC', 2)->>'due_count')::int = 4, 'REV: p_limit limita os itens, nao o due_count');
  perform public.zt_assert((public.get_review_queue('America/Sao_Paulo')->>'due_count')::int = current_setting('zt.sp_due')::int
    and public.get_profile_summary('America/Sao_Paulo') is not null,
    'REV: fuso valido (America/Sao_Paulo) aceito na fila e no perfil');
  perform public.zt_expect_error($q$select public.get_review_queue('Mars/Phobos')$q$, '22023', 'invalid_timezone');
  perform public.zt_expect_error($q$select public.get_review_queue(null)$q$, '22023', 'invalid_timezone');
  perform public.zt_expect_error($q$select public.get_review_queue('UTC', 0)$q$, '22023', 'invalid_filter');
  perform public.zt_expect_error($q$select public.get_review_queue('UTC', 101)$q$, '22023', 'invalid_filter');

  -- perfil antes de revisar
  r := public.get_profile_summary('UTC');
  perform public.zt_assert((r->'review'->>'due_today')::int = 4 and (r->'review'->>'total_scheduled')::int = 6,
    'PERFIL: revisao do dia usa a mesma regra da fila (4 hoje, 6 agendados)');

  -- sessao
  s1 := public.start_review_session();
  perform public.zt_assert(s1 is not null and public.start_review_session() = s1,
    'REV: start_review_session retoma a sessao aberta');

  -- erro, forca lapso
  r := public.submit_review_answer(s1, public.zt_qid('ztL1', 1),
         jsonb_build_object('option_id', public.zt_wrong('ztL1', 1)));
  perform public.zt_assert(r = jsonb_build_object('is_correct', false, 'explanation', 'Explicacao ztL1 1'),
    'REV: resposta errada devolve so is_correct e explicacao');
  perform public.zt_assert(public.zt_no_leak(r), 'SEC: submit_review_answer nao devolve id da alternativa correta');
  perform public.zt_assert((select awarded_points = 0 and max_points = 0 and not is_correct
                              and lesson_attempt_id is null and lesson_version_id is null
                            from public.user_exercise_attempts where review_session_id = s1),
    'REV: resposta gravada em user_exercise_attempts (sessao, sem pontos, sem tentativa de aula)');
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{"option_id":"x"}')$q$, s1, public.zt_qid('ztL1', 1)),
    '23505', 'already_answered');
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{}')$q$, s1, public.zt_qid('ztL2', 1)),
    '23503', 'not_in_review_queue');
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, null, '{}')$q$, s1), '23503', 'not_in_review_queue');
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{}')$q$, gen_random_uuid(), public.zt_qid('ztL1', 1)),
    '42501', 'session_not_found');

  r := public.record_review_result_v2(s1, 'easy', p_question_id := public.zt_qid('ztL1', 1));
  perform public.zt_assert((r->>'repetitions')::int = 0 and (r->>'next_review_in_days')::numeric = 1,
    'REV: errar e mandar easy forca lapso (repetitions 0)');
  perform public.zt_assert((select last_quality = 2 and lapses = 1 and repetitions = 0 from public.review_schedule
                             where question_id = public.zt_qid('ztL1', 1)),
    'REV: quality 2 e lapso gravados no review_schedule');
  perform public.zt_assert((select rating = 'easy' and quality = 2 and is_correct is false
                            from public.review_session_items where session_id = s1 and question_id = public.zt_qid('ztL1', 1)),
    'REV: review_session_items guarda rating easy, quality 2 e is_correct false');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_question_id := %L)$q$, s1, public.zt_qid('ztL1', 1)),
    '23505', 'already_reviewed');

  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_question_id := %L)$q$, s1, public.zt_qid('ztL1', 2)),
    '22023', 'answer_required');
  -- acerto (Q2 ainda nao vence hoje, mas esta na fila do aluno)
  r := public.submit_review_answer(s1, public.zt_qid('ztL1', 2),
         jsonb_build_object('option_id', public.zt_corr('ztL1', 2)));
  perform public.zt_assert((r->>'is_correct')::boolean, 'REV: resposta correta devolve is_correct true');
  r := public.record_review_result_v2(s1, 'good', p_question_id := public.zt_qid('ztL1', 2));
  perform public.zt_assert((r->>'repetitions')::int = 1 and (select last_quality = 4 from public.review_schedule
                             where question_id = public.zt_qid('ztL1', 2)), 'REV: good = quality 4 (provisorio)');

  r := public.record_review_result_v2(s1, 'good', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000001');
  perform public.zt_assert((r->>'repetitions')::int = 1 and (r->>'next_review_in_days')::numeric = 1
    and public.zt_no_leak(r), 'REV: palavra revisada com good');
  r := public.record_review_result_v2(s1, 'hard', p_grammar_topic_id := 'a0a0a0a0-0000-0000-0000-000000000001');
  perform public.zt_assert((select last_quality = 3 from public.review_schedule
                             where grammar_topic_id = 'a0a0a0a0-0000-0000-0000-000000000001'),
    'REV: topico revisado com hard = quality 3 (provisorio)');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000001')$q$, s1),
    '23505', 'already_reviewed');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'ok', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000003')$q$, s1),
    '22023', 'invalid_rating');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good')$q$, s1), '22023', 'invalid_item');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000003',
       p_grammar_topic_id := 'a0a0a0a0-0000-0000-0000-000000000001')$q$, s1), '22023', 'invalid_item');
  perform public.zt_expect_error(
    $q$select public.record_review_result_v2(gen_random_uuid(), 'good', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000003')$q$,
    '42501', 'session_not_found');
  perform public.zt_assert((select count(*) = 0 from public.review_session_items
                             where vocabulary_id = 'b0b0b0b0-0000-0000-0000-000000000003'),
    'REV: tentativa invalida nao grava item na sessao');

  -- fim da sessao
  done1 := (select completed_at from public.review_sessions where id = s1);
  perform public.zt_assert(done1 is null, 'REV: sessao aberta antes de finalizar');
  fin := public.finish_review_session(s1, 'UTC');
  perform public.zt_assert((fin->>'session_id')::uuid = s1 and (fin->>'reviewed_count')::int = 4
    and (fin->>'hard')::int = 1 and (fin->>'good')::int = 2 and (fin->>'easy')::int = 1
    and (fin->>'correct')::int = 1 and (fin->>'incorrect')::int = 1
    and (fin->>'remaining_due')::int = 1 and fin->>'next_due_at' is not null,
    'REV: resumo da sessao (4 revisados, 1 hard, 2 good, 1 easy, 1 certa, 1 errada, 1 ainda vencida)');
  perform public.zt_assert(public.zt_no_leak(fin), 'SEC: finish_review_session nao devolve id de alternativa correta');
  done1 := (select completed_at from public.review_sessions where id = s1);
  perform public.zt_assert(done1 is not null, 'REV: sessao fechada');
  fin2 := public.finish_review_session(s1, 'UTC');
  done2 := (select completed_at from public.review_sessions where id = s1);
  perform public.zt_assert(fin2 = fin and done1 = done2, 'REV: finish_review_session e idempotente (mesmo resumo, mesma data)');
  perform public.zt_expect_error($q$select public.finish_review_session(gen_random_uuid())$q$, '42501', 'session_not_found');
  perform public.zt_expect_error(format($q$select public.finish_review_session(%L, 'Mars/Phobos')$q$, s1), '22023', 'invalid_timezone');
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{}')$q$, s1, public.zt_qid('ztL1', 2)), '55000', 'session_closed');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000003')$q$, s1),
    '55000', 'session_closed');
  s1b := public.start_review_session();
  perform public.zt_assert(s1b <> s1, 'REV: apos finalizar, start_review_session abre uma sessao nova');

  perform public.zt_assert((select count(*) = 4 from public.review_session_items where session_id = s1),
    'REV: aluno le os proprios itens da sessao');
  perform public.zt_expect_error(format(
    $q$insert into public.review_session_items (session_id, user_id, vocabulary_id, rating, quality)
       values (%L, auth.uid(), 'b0b0b0b0-0000-0000-0000-000000000003', 'good', 4)$q$, s1b), '42501');
  perform public.zt_expect_error($q$update public.review_session_items set quality = 5$q$, '42501');
  perform public.zt_expect_error($q$delete from public.review_session_items$q$, '42501');

  -- v1 segue funcionando
  r := public.record_review_result(p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000003', p_quality := 4::smallint);
  perform public.zt_assert((r->>'repetitions')::int = 1, 'REV: record_review_result (v1) continua funcionando');

  -- perfil completo
  r := public.get_profile_summary('UTC');
  perform public.zt_assert(r->>'display_name' = 'Aluno ZT' and r->>'email' = 'zt4@teste' and r->'avatar_url' = 'null'::jsonb
    and r->'current_level'->>'code' = 'A1' and r->'current_level'->>'id' is not null and r->'current_level'->>'title' = 'Iniciante'
    and r->>'plan_tier' = 'free', 'PERFIL: nome, email, nivel em estudo e plano free');
  perform public.zt_assert((r->'placement'->>'completed')::boolean and r->'placement'->>'last_recommended_level_code' = 'A2'
    and r->'placement'->>'last_completed_at' is not null, 'PERFIL: resumo do nivelamento');
  perform public.zt_assert((r->'progress'->>'lessons_completed')::int = 1 and (r->'progress'->>'modules_completed')::int = 1,
    'PERFIL: progresso');
  perform public.zt_assert(jsonb_array_length(r->'mastery') = 2 and r->'mastery'->0->>'title' = 'ZT Conditionals'
    and (r->'mastery'->0->>'mastery_pct')::numeric = 50 and (r->'mastery'->0->>'attempts')::int = 2
    and r->'mastery'->1->>'slug' = 'zt-present-perfect' and r->'mastery'->1->>'grammar_topic_id' is not null,
    'PERFIL: dominio por topico ordenado por titulo (formula provisoria)');
  perform public.zt_assert((r->'review'->>'due_today')::int = 0 and (r->'review'->>'total_scheduled')::int = 6,
    'PERFIL: revisao pendente hoje apos a sessao (cherry reagendada pelo v1)');
  perform public.zt_assert((r->>'favorites_count')::int = 2 and (r->>'notes_count')::int = 3,
    'PERFIL: contagem de favoritos (palavra + frase) e de notas');
  perform public.zt_assert(not (r ? 'streak') and not (r ? 'ranking') and public.zt_no_leak(r),
    'PERFIL: sem streak, sem ranking, sem gabarito');
  perform public.zt_expect_error($q$select public.get_profile_summary('Mars/Phobos')$q$, '22023', 'invalid_timezone');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Isolamento: aluno B nao mexe nos dados do aluno A; fila vazia
-- ---------------------------------------------------------------------
select s.id as sess_a from public.review_sessions s
 where s.user_id = '44444444-4444-4444-4444-444444444444' and s.completed_at is not null limit 1 \gset
select n.id as note_a from public.user_notes n
 where n.user_id = '44444444-4444-4444-4444-444444444444' limit 1 \gset

select set_config('zt.sess_a', :'sess_a', false), set_config('zt.note_a', :'note_a', false);

set role authenticated;
select public.zt_as('55555555-5555-5555-5555-555555555555');
do $$
declare q jsonb; r jsonb; s5 uuid; n int;
        sess_a uuid := current_setting('zt.sess_a')::uuid;
        note_a uuid := current_setting('zt.note_a')::uuid;
begin
  q := public.get_review_queue();
  perform public.zt_assert((q->>'due_count')::int = 0 and (q->>'locked_count')::int = 0 and q->'items' = '[]'::jsonb
    and (q->'upcoming'->>'tomorrow')::int = 0 and q->'next_due_at' = 'null'::jsonb,
    'REV: fila vazia nao da erro (due_count 0, items [])');
  s5 := public.start_review_session();
  perform public.zt_assert(s5 is not null, 'REV: aluno B abre a propria sessao');
  r := public.finish_review_session(s5);
  perform public.zt_assert((r->>'reviewed_count')::int = 0 and (r->>'remaining_due')::int = 0
    and r->'next_due_at' = 'null'::jsonb, 'REV: finalizar sessao vazia devolve resumo zerado');

  perform public.zt_expect_error(format($q$select public.finish_review_session(%L)$q$, sess_a), '42501', 'session_not_found');
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{}')$q$, sess_a, public.zt_qid('ztL1', 1)), '42501', 'session_not_found');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000001')$q$, sess_a),
    '42501', 'session_not_found');
  s5 := public.start_review_session();     -- a anterior foi finalizada
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{}')$q$, s5, public.zt_qid('ztL1', 1)), '23503', 'not_in_review_queue');

  perform public.zt_assert((select count(*) = 0 from public.review_session_items), 'SEC: B nao le review_session_items de A');
  perform public.zt_assert((select count(*) = 0 from public.review_sessions where id = sess_a), 'SEC: B nao le sessoes de A');
  perform public.zt_assert((select count(*) = 0 from public.user_exercise_attempts), 'SEC: B nao le respostas de revisao de A');
  perform public.zt_assert((select count(*) = 0 from public.review_schedule), 'SEC: B nao le a fila de A');
  perform public.zt_assert((select count(*) = 0 from public.user_notes), 'SEC: B nao le notas de A');
  perform public.zt_assert((select count(*) = 0 from public.user_favorite_examples)
    and (select count(*) = 0 from public.user_vocabulary), 'SEC: B nao le favoritos de A');
  perform public.zt_assert((public.get_my_favorites()->>'total')::int = 0 and (public.get_profile_summary()->>'notes_count')::int = 0
    and (public.get_profile_summary()->>'favorites_count')::int = 0, 'SEC: favoritos e notas de A nao aparecem para B');

  perform public.zt_expect_error(
    $q$insert into public.user_notes (user_id, grammar_topic_id, body)
       values ('44444444-4444-4444-4444-444444444444', 'a0a0a0a0-0000-0000-0000-000000000001', 'invasao')$q$, '42501');
  perform public.zt_expect_error(
    $q$insert into public.user_favorite_examples (user_id, vocabulary_example_id)
       values ('44444444-4444-4444-4444-444444444444', 'c0c0c0c0-0000-0000-0000-000000000002')$q$, '42501');
  perform public.zt_expect_error(
    $q$insert into public.user_vocabulary (user_id, vocabulary_id, is_favorite)
       values ('44444444-4444-4444-4444-444444444444', 'b0b0b0b0-0000-0000-0000-000000000002', true)$q$, '42501');
  -- B nao favorita frase de vocabulario Premium sem plano (RLS encadeada de vocabulary_examples)
  perform public.zt_expect_error(
    $q$insert into public.user_favorite_examples (user_id, vocabulary_example_id)
       values (auth.uid(), 'c0c0c0c0-0000-0000-0000-000000000003')$q$, '42501');
  update public.user_notes set body = 'invasao' where id = note_a;
  get diagnostics n = row_count;
  perform public.zt_assert(n = 0, 'SEC: B nao edita a nota de A');
  delete from public.user_notes where id = note_a;
  get diagnostics n = row_count;
  perform public.zt_assert(n = 0, 'SEC: B nao apaga a nota de A');

  r := public.get_profile_summary();
  perform public.zt_assert(r->>'email' = 'zt5@teste' and r->'display_name' = 'null'::jsonb and r->'current_level' = 'null'::jsonb
    and not (r->'placement'->>'completed')::boolean and r->'placement'->'last_recommended_level_code' = 'null'::jsonb
    and r->'mastery' = '[]'::jsonb and (r->'progress'->>'lessons_completed')::int = 0 and r->>'plan_tier' = 'free',
    'PERFIL: aluno novo (B) tem resumo vazio e so o proprio e-mail');
end $$;
reset role;

select public.zt_assert((select body <> 'invasao' from public.user_notes where id = :'note_a'),
  'SEC: nota de A intacta depois das tentativas de B');

-- ---------------------------------------------------------------------
-- Correcao do can_read_question: Premium cancelado nao le questao da fila
-- ---------------------------------------------------------------------
set role authenticated;
select public.zt_as('66666666-6666-6666-6666-666666666666');
do $$
declare q jsonb; s6 uuid;
begin
  perform public.zt_assert((select count(*) = 1 from public.questions where id = public.zt_qid('ztP1', 1))
    and (select count(*) = 2 from public.answer_options where question_id = public.zt_qid('ztP1', 1)),
    'SEC: com Premium ativo a questao Premium da fila e legivel');
  q := public.get_review_queue();
  perform public.zt_assert((q->>'due_count')::int = 2 and (q->>'locked_count')::int = 0, 'REV: Premium ativo ve os 2 itens Premium na fila');
  s6 := public.start_review_session();
  insert into public.user_vocabulary (user_id, vocabulary_id, is_favorite)
    values (auth.uid(), 'b0b0b0b0-0000-0000-0000-000000000004', true);
  insert into public.user_favorite_examples (user_id, vocabulary_example_id)
    values (auth.uid(), 'c0c0c0c0-0000-0000-0000-000000000003');
  perform public.zt_assert((public.get_profile_summary()->>'plan_tier') = 'premium', 'PERFIL: plan_tier premium com assinatura ativa');
end $$;
reset role;

update public.user_subscriptions set status = 'canceled' where id = 'd0d0d0d0-0000-0000-0000-0000000000a1';

set role authenticated;
select public.zt_as('66666666-6666-6666-6666-666666666666');
do $$
declare q jsonb; r jsonb; s6 uuid;
begin
  perform public.zt_assert((select count(*) = 0 from public.questions where id = public.zt_qid('ztP1', 1)),
    'SEC: apos cancelar o Premium, enunciado de questao Premium da fila nao e legivel (can_read_question)');
  perform public.zt_assert((select count(*) = 0 from public.answer_options where question_id = public.zt_qid('ztP1', 1)),
    'SEC: apos cancelar o Premium, alternativas da questao Premium nao sao legiveis');
  q := public.get_review_queue();
  perform public.zt_assert((q->>'due_count')::int = 0 and (q->>'locked_count')::int = 2 and q->'items' = '[]'::jsonb,
    'REV: itens Premium inacessiveis saem da fila e entram em locked_count');
  s6 := public.start_review_session();
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{}')$q$, s6, public.zt_qid('ztP1', 1)), '23503', 'not_in_review_queue');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_vocabulary_id := 'b0b0b0b0-0000-0000-0000-000000000004')$q$, s6),
    '42501', 'premium_required');
  r := public.get_my_favorites();
  perform public.zt_assert((r->>'total')::int = 2 and not exists (
      select 1 from jsonb_array_elements(r->'items') e where not (e->>'locked')::boolean or e->>'subtitle' is not null),
    'FAV: favoritos Premium sem plano ficam locked e sem subtitle');
  r := public.get_profile_summary();
  perform public.zt_assert(r->>'plan_tier' = 'free' and (r->'review'->>'due_today')::int = 0
    and (r->'review'->>'total_scheduled')::int = 0 and (r->>'favorites_count')::int = 2,
    'PERFIL: sem Premium o plano volta a free e a revisao Premium nao conta');
end $$;
reset role;


-- ---------------------------------------------------------------------
-- B1/C1: a revisao nao pode virar corretor (aluno 7)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zt_as('77777777-7777-7777-7777-777777777777');
do $$
declare s7 uuid; la uuid; pq uuid := public.zt_qid('ztPL', 1); lq uuid := public.zt_qid('ztL2', 1);
begin
  -- questao do nivelamento em andamento
  perform public.zt_assert((select count(*) = 1 from public.questions where id = pq), 'B1: questao do nivelamento em andamento e legivel so pelo nivelamento');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result(p_question_id := %L, p_quality := 0::smallint)$q$, pq), '23503', 'not_in_review_queue');
  perform public.zt_assert((select count(*) = 0 from public.review_schedule), 'B1: v1 recusado nao grava nada em review_schedule');
  s7 := public.start_review_session();
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{"option_id":"x"}')$q$, s7, pq), '23503', 'not_in_review_queue');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result_v2(%L, 'good', p_question_id := %L)$q$, s7, pq), '23503', 'not_in_review_queue');

  -- questao de aula com tentativa aberta, ainda nao respondida
  la := public.start_lesson_attempt((select lesson_id from public.zt_l where slug = 'ztL2'));
  perform public.zt_expect_error(format(
    $q$select public.record_review_result(p_question_id := %L, p_quality := 5::smallint)$q$, lq), '23503', 'not_in_review_queue');
  perform public.zt_expect_error(format(
    $q$select public.submit_review_answer(%L, %L, '{"option_id":"x"}')$q$, s7, lq), '23503', 'not_in_review_queue');
  -- respondida, mas a tentativa continua aberta: ainda nao elegivel
  perform public.submit_lesson_answer(la, lq, jsonb_build_object('option_id', public.zt_wrong('ztL2', 1)));
  perform public.zt_expect_error(format(
    $q$select public.record_review_result(p_question_id := %L, p_quality := 5::smallint)$q$, lq), '23503', 'not_in_review_queue');
  perform public.zt_assert((select count(*) = 0 from public.review_schedule), 'B1: nada entrou na fila de revisao do aluno 7');
  perform public.zt_assert(public.zt_no_leak(public.get_review_queue()), 'B1: fila do aluno 7 vazia e sem gabarito');
end $$;
reset role;

-- encerra o nivelamento e a aula: a questao do nivelamento deixa de ser legivel e continua nao elegivel
update public.user_placement_attempts set status = 'completed', completed_at = now(), score_pct = 0,
  recommended_level_id = (select id from public.levels where code = 'A1')
 where id = 'e3e3e3e3-0000-0000-0000-000000000001';
update public.user_lesson_attempts set status = 'completed', completed_at = now(), score_pct = 0
 where user_id = '77777777-7777-7777-7777-777777777777';

set role authenticated;
select public.zt_as('77777777-7777-7777-7777-777777777777');
do $$
declare pq uuid := public.zt_qid('ztPL', 1); lq uuid := public.zt_qid('ztL2', 1);
begin
  perform public.zt_assert((select count(*) = 0 from public.questions where id = pq)
    and (select count(*) = 0 from public.answer_options where question_id = pq),
    'B1: depois do nivelamento, a questao dele nao e legivel em public.questions');
  perform public.zt_expect_error(format(
    $q$select public.record_review_result(p_question_id := %L, p_quality := 0::smallint)$q$, pq), '23503', 'not_in_review_queue');
  -- aula encerrada com a questao respondida: agora elegivel
  perform public.zt_assert((public.record_review_result(p_question_id := lq, p_quality := 4::smallint)->>'repetitions')::int = 1,
    'C1: questao de aula respondida em tentativa encerrada e elegivel para revisao');
end $$;
reset role;

-- S4: uma unica sessao aberta por aluno
select public.zt_expect_error(
  $q$insert into public.review_sessions (user_id) values ('44444444-4444-4444-4444-444444444444')$q$, '23505');
-- ---------------------------------------------------------------------
-- Estado final visto pelo postgres: nada de gabarito exposto, cascata LGPD
-- ---------------------------------------------------------------------
select public.zt_assert(has_table_privilege('authenticated', 'public.review_session_items', 'SELECT')
  and not has_table_privilege('authenticated', 'public.review_session_items', 'INSERT')
  and not has_table_privilege('authenticated', 'public.review_session_items', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.review_session_items', 'DELETE')
  and not has_table_privilege('anon', 'public.review_session_items', 'SELECT'),
  'SEC: review_session_items so tem SELECT para o app');
select public.zt_assert(has_table_privilege('authenticated', 'public.user_favorite_examples', 'SELECT')
  and has_table_privilege('authenticated', 'public.user_favorite_examples', 'INSERT')
  and has_table_privilege('authenticated', 'public.user_favorite_examples', 'DELETE')
  and not has_table_privilege('authenticated', 'public.user_favorite_examples', 'UPDATE')
  and not has_table_privilege('anon', 'public.user_favorite_examples', 'SELECT'),
  'SEC: user_favorite_examples so tem SELECT/INSERT/DELETE para o app');
select public.zt_assert((select relrowsecurity from pg_class where oid = 'public.review_session_items'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.user_favorite_examples'::regclass),
  'SEC: RLS ligado nas tabelas novas');
select public.zt_assert(not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('search_library','get_library_item','get_my_favorites',
       'get_review_queue','start_review_session','submit_review_answer','record_review_result_v2',
       'finish_review_session','get_profile_summary')
       and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))),
  'SEC: as 9 RPCs sao security definer com search_path vazio');

delete from auth.users where id in ('44444444-4444-4444-4444-444444444444',
  '55555555-5555-5555-5555-555555555555', '66666666-6666-6666-6666-666666666666',
  '77777777-7777-7777-7777-777777777777');
select public.zt_assert(not exists (select 1 from public.review_session_items)
  and not exists (select 1 from public.user_favorite_examples)
  and not exists (select 1 from public.review_sessions)
  and not exists (select 1 from public.user_notes)
  and not exists (select 1 from public.review_schedule)
  and not exists (select 1 from public.user_vocabulary)
  and not exists (select 1 from public.user_exercise_attempts where review_session_id is not null),
  'LGPD: excluir usuarios remove sessoes, itens, fila, favoritos, respostas de revisao e notas (cascade)');

\echo ===== TESTES BIBLIOTECA/REVISAO/PERFIL PASSARAM =====
