-- =====================================================================
-- MyFluenti - Teste de fumaca ponta a ponta (criterios de aceitacao do MVP)
-- Uso (banco de teste): psql -v ON_ERROR_STOP=1 -d mf -f tests/00_supabase_stub.sql
--   depois as 3 migrations, depois este arquivo, tudo como superusuario.
-- Cada bloco simula um aluno via set role authenticated + claim sub.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------
-- Helpers de teste
-- ---------------------------------------------------------------------
create table public.zz_l (slug text, lesson_id uuid, version_id uuid, section_id uuid, module_id uuid);
create table public.zz_q (slug text, pos int, question_id uuid, correct_opt uuid, wrong_opt uuid);
create table public.zz_pq (pos int, question_id uuid, correct_opt uuid, wrong_opt uuid, level_pos int);
grant select on public.zz_l, public.zz_q, public.zz_pq to authenticated;

create function public.zz_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zz_expect_error(p_sql text, p_state text default null, p_msg text default null)
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
    raise notice 'PASS (erro esperado): % [%]', left(p_sql, 60), left(m, 50);
    return;
  end;
  raise exception 'FAIL (era esperado erro): %', p_sql;
end $$;

create function public.zz_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

create function public.zz_answer(p_attempt uuid, p_slug text, p_correct int, p_total int, p_from int default 1)
returns void language plpgsql as $$
declare r record;
begin
  for r in select * from public.zz_q where slug = p_slug and pos >= p_from and pos <= p_total order by pos loop
    perform public.submit_lesson_answer(p_attempt, r.question_id,
      jsonb_build_object('option_id', case when r.pos <= p_correct then r.correct_opt else r.wrong_opt end));
  end loop;
end $$;

create function public.zz_mk_lesson(p_module uuid, p_slug text, p_pos int, p_required boolean, p_nq int)
returns void language plpgsql as $$
declare l uuid; v uuid; s uuid; e uuid; q uuid; o1 uuid; o2 uuid; i int;
begin
  insert into public.lessons (module_id, slug, position, is_required)
    values (p_module, p_slug, p_pos, p_required) returning id into l;
  insert into public.lesson_versions (lesson_id, version_number, title)
    values (l, 1, 'Aula ' || p_slug) returning id into v;
  insert into public.lesson_sections (lesson_version_id, position, section_type, title)
    values (v, 1, 'explanation', 'Explicacao') returning id into s;
  insert into public.exercises (lesson_version_id, position, title)
    values (v, 1, 'Ex 1') returning id into e;
  for i in 1..p_nq loop
    insert into public.questions (lesson_version_id, exercise_id, question_type, prompt, grammar_topic_id, position)
      values (v, e, 'multiple_choice', 'Q' || i,
              (select id from public.grammar_topics where slug = 'simple-present'), i)
      returning id into q;
    insert into public.answer_options (question_id, option_text, position) values (q, 'certa', 1) returning id into o1;
    insert into public.answer_options (question_id, option_text, position) values (q, 'errada', 2) returning id into o2;
    insert into private.question_answer_keys (question_id, correct_option_id, explanation)
      values (q, o1, 'Explicacao ' || i);
    insert into public.zz_q values (p_slug, i, q, o1, o2);
  end loop;
  update public.lesson_versions set is_published = true where id = v;
  insert into public.zz_l values (p_slug, l, v, s, p_module);
end $$;

-- ---------------------------------------------------------------------
-- Seed: usuarios, niveis, curriculo, nivelamento
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'u1@teste'),
  ('22222222-2222-2222-2222-222222222222', 'u2@teste'),
  ('33333333-3333-3333-3333-333333333333', 'admin@teste');
insert into public.user_roles (user_id, role) values ('33333333-3333-3333-3333-333333333333', 'content_admin');

insert into public.levels (id, code, title, position) values
  ('00000000-0000-0000-0000-0000000000a1', 'A1', 'Iniciante', 1),
  ('00000000-0000-0000-0000-0000000000a2', 'A2', 'Basico', 2),
  ('00000000-0000-0000-0000-0000000000b1', 'B1', 'Intermediario', 3),
  ('00000000-0000-0000-0000-0000000000b2', 'B2', 'Intermediario avancado', 4),
  ('00000000-0000-0000-0000-0000000000c1', 'C1', 'Avancado', 5),
  ('00000000-0000-0000-0000-0000000000c2', 'C2', 'Dominio', 6);

insert into public.grammar_topics (slug, title, category, is_published)
  values ('simple-present', 'Simple Present', 'tempos verbais', true);

insert into public.modules (id, level_id, title, position, access_tier, is_published) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'M1 Fundamentos',  1, 'free',    true),
  ('aaaaaaaa-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000a1', 'M2 Frases',       2, 'free',    true),
  ('aaaaaaaa-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'M3 Cotidiano',    3, 'premium', true),
  ('aaaaaaaa-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000a2', 'M4 Basico',       1, 'free',    true);

select public.zz_mk_lesson('aaaaaaaa-0000-0000-0000-000000000001', 'L1',  1, true,  5);
select public.zz_mk_lesson('aaaaaaaa-0000-0000-0000-000000000001', 'L2',  2, true,  7);
select public.zz_mk_lesson('aaaaaaaa-0000-0000-0000-000000000001', 'L1o', 3, false, 3);
select public.zz_mk_lesson('aaaaaaaa-0000-0000-0000-000000000002', 'L3',  1, true,  4);
select public.zz_mk_lesson('aaaaaaaa-0000-0000-0000-000000000003', 'L4',  1, true,  4);
select public.zz_mk_lesson('aaaaaaaa-0000-0000-0000-000000000004', 'L5',  1, true,  4);

-- Teste de nivelamento oficial: 30 questoes (8 voc, 10 gra, 6 rea, 6 con); 5 por nivel
insert into public.placement_tests (id, code, version_number, title, total_questions)
  values ('bbbbbbbb-0000-0000-0000-000000000001', 'oficial', 1, 'Nivelamento', 30);
do $$
declare i int; q uuid; o1 uuid; o2 uuid; comp text; lvl uuid; lvlpos int;
begin
  for i in 1..30 loop
    comp := case when i <= 8 then 'vocabulary' when i <= 18 then 'grammar'
                 when i <= 24 then 'reading' else 'construction' end;
    lvlpos := 1 + ((i - 1) % 6);
    select id into lvl from public.levels where position = lvlpos;
    insert into public.questions (question_type, prompt) values ('multiple_choice', 'P' || i) returning id into q;
    insert into public.answer_options (question_id, option_text, position) values (q, 'certa', 1) returning id into o1;
    insert into public.answer_options (question_id, option_text, position) values (q, 'errada', 2) returning id into o2;
    insert into private.question_answer_keys (question_id, correct_option_id) values (q, o1);
    insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
      values ('bbbbbbbb-0000-0000-0000-000000000001', q, comp, lvl, 1, i);
    insert into public.zz_pq values (i, q, o1, o2, lvlpos);
  end loop;
end $$;

-- Publicar teste incompleto deve falhar (29 questoes)
insert into public.placement_tests (id, code, version_number, title, total_questions)
  values ('bbbbbbbb-0000-0000-0000-000000000002', 'oficial', 2, 'Incompleto', 30);
select public.zz_expect_error(
  $q$update public.placement_tests set is_published = true where id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$,
  '23514', 'exatamente');
update public.placement_tests set is_published = true where id = 'bbbbbbbb-0000-0000-0000-000000000001';
select public.zz_assert((select count(*) = 30 from public.placement_questions
  where placement_test_id = 'bbbbbbbb-0000-0000-0000-000000000001'), 'seed: teste oficial publicado com 30 questoes');

-- Imutabilidade
select public.zz_expect_error(
  $q$update public.lesson_versions set title = 'x' where is_published$q$, '55000');
select public.zz_expect_error(
  $q$insert into public.lesson_sections (lesson_version_id, position, section_type)
     select version_id, 9, 'summary' from public.zz_l where slug = 'L1'$q$, '55000');
select public.zz_expect_error(
  $q$update public.questions set prompt = 'alterada' where prompt = 'P1'$q$, '55000');

-- ---------------------------------------------------------------------
-- NIV-01..03: nivelamento (aluno 1)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zz_as('11111111-1111-1111-1111-111111111111');

do $$
declare a uuid; r record; v_res jsonb;
begin
  a := public.start_placement_attempt();
  perform public.zz_assert(a is not null, 'NIV-01: tentativa criada');
  perform public.zz_assert((select count(*) = 30 from public.placement_test_items), 'NIV-01: teste apresenta 30 questoes');
  perform public.zz_assert((select count(*) = 30 from public.questions), 'NIV-01: enunciados das 30 questoes legiveis');
  perform public.zz_assert((select count(*) = 60 from public.answer_options), 'NIV-01: alternativas legiveis');
  perform public.zz_assert((select count(*) = 0 from public.placement_questions), 'SEC: peso/dificuldade do nivelamento nao expostos');
  perform public.zz_expect_error('select * from private.question_answer_keys', '42501');
  perform public.zz_expect_error('select * from public.user_placement_answers', '42501');
  perform public.zz_assert(public.start_placement_attempt() = a, 'NIV-01: retoma tentativa em andamento');

  -- acerta niveis A1, A2, B1 (posicao <= 3); erra o resto
  for r in select * from public.zz_pq order by pos loop
    perform public.submit_placement_answer(a, r.question_id,
      jsonb_build_object('option_id', case when r.level_pos <= 3 then r.correct_opt else r.wrong_opt end));
  end loop;
  perform public.zz_expect_error(format(
    $q$select public.submit_placement_answer(%L, %L, '{"option_id":"x"}')$q$, a,
    (select question_id from public.zz_pq where pos = 1)), '23505', 'ja respondida');

  v_res := public.finish_placement_attempt(a);
  perform public.zz_assert(v_res->>'recommended_level_code' = 'B1', 'NIV-02: nivel recomendado B1 registrado');
  perform public.zz_assert((v_res->>'score_pct')::numeric = 50, 'NIV-02: pontuacao 50%');
  perform public.zz_assert((select status = 'completed' and recommended_level_id is not null
                              from public.user_placement_attempts where id = a), 'NIV-02: resultado persistido');
  perform public.zz_assert((select current_level_id is null from public.profiles
                              where id = auth.uid()), 'NIV: refazer/concluir teste nao muda o nivel em estudo');
  perform public.zz_assert((select count(*) = 0 from public.placement_test_items), 'NIV: itens do teste somem apos concluir');
end $$;

-- NIV-03: nivel acima do recomendado e negado; nivel anterior permitido
select public.zz_expect_error(
  $q$select public.select_starting_level('00000000-0000-0000-0000-0000000000b2')$q$, '22023', 'superar');
select public.select_starting_level('00000000-0000-0000-0000-0000000000a1');
do $$
begin
  perform public.zz_assert((select current_level_id = '00000000-0000-0000-0000-0000000000a1'
                              from public.profiles where id = auth.uid()), 'NIV-03: curso inicia no nivel escolhido (A1)');
  perform public.zz_assert((select source = 'placement_lower' and ended_at is null
                              from public.user_level_history where user_id = auth.uid()), 'NIV-03: historico registra origem');
  perform public.zz_assert((select count(*) = 1 from public.user_module_progress), 'MOD: so o primeiro modulo e liberado');
  perform public.zz_assert((select state = 'available' from public.get_course_overview() where "position" = 1), 'MOD: M1 disponivel');
  perform public.zz_assert((select state = 'locked' from public.get_course_overview() where "position" = 2), 'MOD: M2 bloqueado por sequencia');
  perform public.zz_assert((select state = 'locked_plan' from public.get_course_overview() where "position" = 3), 'MOD: M3 bloqueado por plano');
end $$;

-- SEC-01 / escrita direta negada
select public.zz_expect_error(
  $q$update public.profiles set current_level_id = '00000000-0000-0000-0000-0000000000c2'$q$, '42501');
select public.zz_expect_error(
  $q$insert into public.user_lesson_progress (user_id, lesson_id, status, completed_at, completed_version_id)
     select auth.uid(), lesson_id, 'completed', now(), version_id from public.zz_l where slug = 'L1'$q$, '42501');
select public.zz_expect_error(
  $q$insert into public.user_module_progress (user_id, module_id)
     values (auth.uid(), 'aaaaaaaa-0000-0000-0000-000000000003')$q$, '42501');
select public.zz_expect_error(
  $q$insert into public.user_subscriptions (user_id, plan_id, status)
     select auth.uid(), id, 'active' from public.subscription_plans$q$, '42501');

-- ---------------------------------------------------------------------
-- AUL-01..03, MOD-01..03, REV (aluno 1, plano Free)
-- ---------------------------------------------------------------------
do $$
declare a uuid; res jsonb; r jsonb; done_at timestamptz; l1 uuid; l2 uuid; l3 uuid;
begin
  select lesson_id into l1 from public.zz_l where slug = 'L1';
  select lesson_id into l2 from public.zz_l where slug = 'L2';
  select lesson_id into l3 from public.zz_l where slug = 'L3';

  perform public.zz_expect_error(format($q$select public.start_lesson_attempt(%L)$q$, l3), '42501', 'module_locked');
  perform public.zz_expect_error(format($q$select public.start_lesson_attempt(%L)$q$,
    (select lesson_id from public.zz_l where slug = 'L4')), '42501', 'module_locked');

  -- AUL-01: 3/5 = 60% -> aula permanece nao concluida
  a := public.start_lesson_attempt(l1);
  perform public.record_section_view((select section_id from public.zz_l where slug = 'L1'));
  perform public.zz_answer(a, 'L1', 3, 5);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'passed')::boolean is false and (res->>'score_pct')::numeric = 60, 'AUL-01: 60% nao conclui');
  perform public.zz_assert((select status = 'in_progress' and best_score = 60 and attempt_count = 1
                              from public.user_lesson_progress where lesson_id = l1), 'AUL-01: progresso em andamento');
  perform public.zz_assert((select status = 'in_progress' from public.user_module_progress
                              where module_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 'MOD: modulo em andamento');
  perform public.zz_assert((select count(*) = 2 from public.review_schedule), 'REV-01: erros entram na fila de revisao');
  perform public.zz_assert((select attempts_count = 5 and correct_count = 3 and mastery_score = 60
                              from public.user_topic_mastery), 'dominio por topico registrado (formula provisoria)');
  perform public.zz_expect_error($q$update public.user_lesson_attempts set passed = true$q$, '42501');
  perform public.zz_expect_error(format($q$select public.submit_lesson_answer(%L, %L, '{}')$q$, a,
    (select question_id from public.zz_q where slug = 'L1' and pos = 1)), '55000', 'encerrada');

  -- AUL-02: exatamente 80% (4/5) conclui; MOD: M2 ainda nao existe
  a := public.start_lesson_attempt(l1);
  perform public.zz_answer(a, 'L1', 4, 5);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'passed')::boolean and (res->>'score_pct')::numeric = 80, 'AUL-02: 80% conclui');
  perform public.zz_assert((select status = 'completed' and best_score = 80 and attempt_count = 2
                              from public.user_lesson_progress where lesson_id = l1), 'AUL-02: progresso concluido');
  select completed_at into done_at from public.user_lesson_progress where lesson_id = l1;
  perform public.zz_assert((select count(*) = 1 from public.user_module_progress), 'MOD: M2 nao libera com aulas pendentes');

  -- AUL-03: tentativa pior preserva historico e conclusao
  a := public.start_lesson_attempt(l1);
  perform public.zz_answer(a, 'L1', 2, 5);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'passed')::boolean is false, 'AUL-03: tentativa inferior reprovada');
  perform public.zz_assert((select status = 'completed' and best_score = 80 and attempt_count = 3 and completed_at = done_at
                              from public.user_lesson_progress where lesson_id = l1), 'AUL-03: conclusao e primeira data preservadas');
  perform public.zz_assert((select count(*) = 3 from public.user_lesson_attempts), 'AUL-03: historico com 3 tentativas');
  perform public.zz_assert((select count(*) = 15 from public.user_exercise_attempts), 'AUL-03: 15 respostas preservadas');

  -- L2 (7 questoes): 5/7 = 71,43% nao conclui; 6/7 = 85,71% conclui
  a := public.start_lesson_attempt(l2);
  perform public.record_section_view((select section_id from public.zz_l where slug = 'L2'));
  r := public.submit_lesson_answer(a, (select question_id from public.zz_q where slug = 'L2' and pos = 1),
         jsonb_build_object('option_id', (select correct_opt from public.zz_q where slug = 'L2' and pos = 1)));
  perform public.zz_assert(r ? 'is_correct' and r ? 'explanation' and not (r::text like '%option%'),
    'SEC: resposta devolve so correcao/explicacao, sem gabarito');
  perform public.zz_answer(a, 'L2', 5, 7, 2);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'passed')::boolean is false, 'AUL: 5/7 (71,43%) nao conclui');
  a := public.start_lesson_attempt(l2);
  perform public.zz_answer(a, 'L2', 6, 7);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'passed')::boolean and (res->>'module_completed')::boolean, 'AUL: 6/7 (85,71%) conclui');

  -- MOD-01/02: todas as aulas obrigatorias (opcional L1o ignorada) -> modulo concluido, proximo liberado
  perform public.zz_assert((select status = 'completed' from public.user_module_progress
                              where module_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 'MOD-01: M1 concluido (aula opcional nao conta)');
  perform public.zz_assert((select status = 'available' from public.user_module_progress
                              where module_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 'MOD-02: M2 liberado');
  perform public.zz_assert((select count(*) = 2 from public.user_module_progress), 'MOD: M3 premium nao foi liberado');
  -- MOD-03: revisitar modulo concluido
  perform public.zz_assert(public.start_lesson_attempt(l1) is not null, 'MOD-03: aula de modulo concluido pode ser revisitada');

  -- Secoes obrigatorias: 4/4 corretas sem ver a secao nao conclui
  a := public.start_lesson_attempt(l3);
  perform public.zz_answer(a, 'L3', 4, 4);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'passed')::boolean is false and (res->>'sections_complete')::boolean is false,
    'AUL: sem acessar secoes obrigatorias nao conclui');
  perform public.record_section_view((select section_id from public.zz_l where slug = 'L3'));
  a := public.start_lesson_attempt(l3);
  perform public.zz_answer(a, 'L3', 4, 4);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'passed')::boolean and (res->>'module_completed')::boolean, 'AUL: com secoes e 100% conclui M2');
  perform public.zz_assert((select count(*) = 2 from public.user_module_progress where status = 'completed'), 'MOD: M1 e M2 concluidos');
  perform public.zz_assert((select count(*) = 2 from public.user_module_progress where status = 'completed')
                           and not exists (select 1 from public.user_module_progress where module_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
    'MOD: M3 (Premium) continua sem liberar para plano Free');
  perform public.zz_assert((select state = 'locked_plan' from public.get_course_overview() where "position" = 3), 'MOD: M3 aparece como bloqueado por plano');
end $$;

-- REV-02: revisao espacada (SM-2 adaptado)
do $$
declare q uuid; r jsonb;
begin
  select question_id into q from public.zz_q where slug = 'L1' and pos = 4;
  r := public.record_review_result(p_question_id := q, p_quality := 4::smallint);
  perform public.zz_assert((r->>'next_review_in_days')::numeric = 1 and (r->>'repetitions')::int = 1, 'REV-02: 1a revisao -> 1 dia');
  r := public.record_review_result(p_question_id := q, p_quality := 5::smallint);
  perform public.zz_assert((r->>'next_review_in_days')::numeric = 6, 'REV-02: 2a revisao -> 6 dias');
  r := public.record_review_result(p_question_id := q, p_quality := 1::smallint);
  perform public.zz_assert((r->>'next_review_in_days')::numeric = 1 and (r->>'repetitions')::int = 0, 'REV-02: falha reinicia o intervalo');
  perform public.zz_assert((select lapses = 1 and due_at > now() from public.review_schedule where question_id = q), 'REV-02: proxima data recalculada');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Premium: upgrade libera modulos elegiveis; cancelamento bloqueia por plano
-- ---------------------------------------------------------------------
insert into public.subscription_plans (id, code, name, tier) values
  ('cccccccc-0000-0000-0000-000000000001', 'premium_teste', 'Premium (teste)', 'premium');
insert into public.user_subscriptions (id, user_id, plan_id, status, current_period_end)
  values ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
          'cccccccc-0000-0000-0000-000000000001', 'active', now() + interval '30 days');

set role authenticated;
select public.zz_as('11111111-1111-1111-1111-111111111111');
do $$
declare a uuid; res jsonb; l4 uuid;
begin
  select lesson_id into l4 from public.zz_l where slug = 'L4';
  perform public.zz_assert((select status = 'available' from public.user_module_progress
                              where module_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
    'MOD: upgrade libera M3 automaticamente (modulo anterior ja concluido)');
  perform public.zz_assert((select state = 'available' from public.get_course_overview() where "position" = 3), 'MOD: M3 disponivel no overview');
  perform public.record_section_view((select section_id from public.zz_l where slug = 'L4'));
  a := public.start_lesson_attempt(l4);
  perform public.zz_answer(a, 'L4', 4, 4);
  res := public.finish_lesson_attempt(a);
  perform public.zz_assert((res->>'module_completed')::boolean, 'MOD: M3 concluido');
  perform public.zz_assert(exists (select 1 from public.user_module_progress
                                    where module_id = 'aaaaaaaa-0000-0000-0000-000000000004'),
    'MOD: ultimo modulo do nivel libera o primeiro do proximo nivel (A2)');
end $$;
reset role;

update public.user_subscriptions set status = 'canceled'
 where id = 'dddddddd-0000-0000-0000-000000000001';

set role authenticated;
select public.zz_as('11111111-1111-1111-1111-111111111111');
do $$
begin
  perform public.zz_expect_error(format($q$select public.start_lesson_attempt(%L)$q$,
    (select lesson_id from public.zz_l where slug = 'L4')), '42501', 'premium_required');
  perform public.zz_expect_error($q$select * from public.get_module_lessons('aaaaaaaa-0000-0000-0000-000000000003')$q$,
    '42501', 'premium_required');
  perform public.zz_assert((select state = 'locked_plan' from public.get_course_overview() where "position" = 3),
    'SEC-02: sem Premium o modulo volta a bloquear por plano');
  perform public.zz_assert((select count(*) = 0 from public.lesson_sections
                              where lesson_version_id = (select version_id from public.zz_l where slug = 'L4')),
    'SEC-02: conteudo Premium nao legivel sem plano (RLS)');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- SEC-01: aluno 2 nao acessa dados do aluno 1; administracao de conteudo
-- ---------------------------------------------------------------------
select id as att from public.user_lesson_attempts
 where user_id = '11111111-1111-1111-1111-111111111111' limit 1 \gset

set role authenticated;
select public.zz_as('22222222-2222-2222-2222-222222222222');
select public.zz_expect_error(format($q$select public.finish_lesson_attempt(%L)$q$, :'att'), '42501', 'nao encontrada');
do $$
begin
  perform public.zz_assert((select count(*) = 0 from public.user_lesson_progress), 'SEC-01: aluno 2 nao ve progresso do aluno 1');
  perform public.zz_assert((select count(*) = 0 from public.user_lesson_attempts), 'SEC-01: aluno 2 nao ve tentativas do aluno 1');
  perform public.zz_assert((select count(*) = 0 from public.user_placement_attempts), 'SEC-01: aluno 2 nao ve nivelamento do aluno 1');
  perform public.zz_assert((select count(*) = 1 from public.profiles), 'SEC-01: aluno 2 ve apenas o proprio perfil');
  perform public.zz_expect_error(format($q$select public.start_lesson_attempt(%L)$q$,
    (select lesson_id from public.zz_l where slug = 'L1')), '42501', 'module_locked');
  perform public.zz_expect_error(
    $q$insert into public.modules (level_id, title, position) values ('00000000-0000-0000-0000-0000000000a1', 'hack', 99)$q$, '42501');
  perform public.zz_expect_error($q$select public.select_starting_level('00000000-0000-0000-0000-0000000000a2')$q$, '22023', 'superar');
  perform public.start_placement_attempt();          -- aluno 2 inicia um nivelamento (usado no teste de exclusao)
end $$;
reset role;

set role authenticated;
select public.zz_as('33333333-3333-3333-3333-333333333333');
do $$
begin
  insert into public.modules (level_id, title, position) values ('00000000-0000-0000-0000-0000000000a2', 'M5 admin', 99);
  perform public.zz_assert(true, 'admin (content_admin) consegue cadastrar conteudo');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Imutabilidade do historico; exclusao de usuario (cascade permitido)
-- ---------------------------------------------------------------------
select public.zz_expect_error($q$update public.user_lesson_attempts set passed = true where status = 'completed'$q$, '55000');
select public.zz_expect_error($q$update public.user_exercise_attempts set is_correct = true$q$, '55000');
select public.zz_expect_error($q$delete from public.user_lesson_attempts$q$, '55000');
select public.zz_expect_error($q$update public.question_answer_keys set explanation = 'x'$q$, '42P01');
select public.zz_expect_error($q$update private.question_answer_keys set explanation = 'x'$q$, '55000');

delete from auth.users where id = '22222222-2222-2222-2222-222222222222';
select public.zz_assert((select count(*) = 0 from public.user_placement_attempts
                          where user_id = '22222222-2222-2222-2222-222222222222')
                        and not exists (select 1 from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  'LGPD: excluir usuario remove perfil e historico (cascade)');

delete from auth.users where id = '11111111-1111-1111-1111-111111111111';
select public.zz_assert((select count(*) = 0 from public.user_lesson_attempts)
                        and (select count(*) = 0 from public.user_exercise_attempts),
  'LGPD: excluir usuario com historico concluido funciona');

\echo ===== TODOS OS TESTES PASSARAM =====
