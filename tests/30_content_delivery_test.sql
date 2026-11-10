-- =====================================================================
-- MyFluenti - Testes da migration 005: entrega de conteudo
--   get_lesson_content, get_placement_items, trigger de cadastro (display_name)
-- Autocontido (nao usa o dev-seed). Roda DEPOIS dos tests 10 e 20, no mesmo banco:
--   (1) Supabase local: db reset -> 10 -> 20 -> 30
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> 20 -> 30
-- Helpers com prefixo zc_. Usuarios: 1c1c1c1c (A), 2c2c2c2c (B), 3c3c3c3c (Premium).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create table public.zc_q (slug text, pos int, question_id uuid, correct_opt uuid, wrong_opt uuid, accepted text);
create table public.zc_l (slug text, lesson_id uuid, version_id uuid, module_id uuid);
grant select on public.zc_q, public.zc_l to authenticated;

create function public.zc_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zc_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zc_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;
create function public.zc_qid(p_slug text, p_pos int) returns uuid language sql stable as $$
  select question_id from public.zc_q where slug = p_slug and pos = p_pos
$$;
create function public.zc_corr(p_slug text, p_pos int) returns uuid language sql stable as $$
  select correct_opt from public.zc_q where slug = p_slug and pos = p_pos
$$;

-- Uma versao: 2 secoes, 1 exercicio (q1 multipla escolha, q2 word_order) e q3 solta (sem exercicio).
create function public.zc_mk_version(p_lesson uuid, p_vnum int, p_title text, p_tag text) returns uuid
language plpgsql as $$
declare v uuid; e uuid; q uuid; o1 uuid; o2 uuid; i int;
begin
  insert into public.lesson_versions (lesson_id, version_number, title, objective)
    values (p_lesson, p_vnum, p_title, 'objetivo ' || p_title) returning id into v;
  insert into public.lesson_sections (lesson_version_id, position, section_type, title, content) values
    (v, 1, 'intro', 'Intro', '{"v":1,"blocks":[{"type":"paragraph","text":"zc intro"}]}'),
    (v, 2, 'examples', 'Exemplos', '{"v":1,"items":[{"en":"I am here.","pt":"Eu estou aqui.","note":"","vocabulary_example_id":null}]}');
  insert into public.exercises (lesson_version_id, position, title, instructions) values (v, 1, 'Ex', 'Responda') returning id into e;
  for i in 1..3 loop
    insert into public.questions (lesson_version_id, exercise_id, question_type, prompt, prompt_data, position)
      values (v, case when i = 3 then null else e end,
              case when i = 2 then 'word_order' else 'multiple_choice' end,
              'ZCQ ' || p_tag || ' ' || i,
              case when i = 2 then '{"v":1,"tokens":["here","zc","ok","am","now"]}'::jsonb else '{"v":1}'::jsonb end,
              i) returning id into q;
    if i = 2 then
      insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
        values (q, 'zc am here now ok', 'zc am here now ok', true), (q, 'zc is here now ok', 'zc is here now ok', false);
      insert into private.question_answer_keys (question_id, correct_option_id, explanation)
        values (q, null, 'EXPLICACAO-ZC ' || p_tag || ' 2');
      insert into public.zc_q values (p_tag, i, q, null, null, 'zc am here now ok');
    else
      insert into public.answer_options (question_id, option_text, position) values (q, 'certa', 1) returning id into o1;
      insert into public.answer_options (question_id, option_text, position) values (q, 'errada', 2) returning id into o2;
      insert into private.question_answer_keys (question_id, correct_option_id, explanation)
        values (q, o1, 'EXPLICACAO-ZC ' || p_tag || ' ' || i);
      insert into public.zc_q values (p_tag, i, q, o1, o2, null);
    end if;
  end loop;
  update public.lesson_versions set is_published = true where id = v;
  return v;
end $$;

create function public.zc_mk_lesson(p_module uuid, p_slug text, p_pos int) returns void
language plpgsql as $$
declare l uuid; v uuid;
begin
  insert into public.lessons (module_id, slug, position) values (p_module, p_slug, p_pos) returning id into l;
  v := public.zc_mk_version(l, 1, 'Aula ' || p_slug || ' v1', p_slug);
  insert into public.zc_l values (p_slug, l, v, p_module);
end $$;

create function public.zc_rpc_calls() returns text[] language sql immutable as $$
  select array[
    $q$select public.get_lesson_content(gen_random_uuid())$q$,
    $q$select public.get_placement_items(gen_random_uuid())$q$
  ]
$$;

-- ---------------------------------------------------------------------
-- Setup (postgres)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('1c1c1c1c-1111-1111-1111-111111111111', 'zc-a@teste'),
  ('2c2c2c2c-2222-2222-2222-222222222222', 'zc-b@teste'),
  ('3c3c3c3c-3333-3333-3333-333333333333', 'zc-p@teste');

-- Niveis A1..C2 vem da migration 009 (dado de referencia).

insert into public.modules (id, level_id, slug, title, position, access_tier, is_published) values
  ('0c0c0c0c-0000-0000-0000-000000000061', (select id from public.levels where code = 'A1'), 'zc-m61', 'ZC free',    61, 'free',    true),
  ('0c0c0c0c-0000-0000-0000-000000000062', (select id from public.levels where code = 'A1'), 'zc-m62', 'ZC premium', 62, 'premium', true),
  ('0c0c0c0c-0000-0000-0000-000000000063', (select id from public.levels where code = 'A1'), 'zc-m63', 'ZC locked',  63, 'free',    true);
select public.zc_mk_lesson('0c0c0c0c-0000-0000-0000-000000000061', 'zcL1', 1);
select public.zc_mk_lesson('0c0c0c0c-0000-0000-0000-000000000062', 'zcP1', 1);
select public.zc_mk_lesson('0c0c0c0c-0000-0000-0000-000000000063', 'zcX1', 1);

insert into public.subscription_plans (id, code, name, tier)
  values ('dcdcdcdc-0000-0000-0000-000000000001', 'zc_premium', 'Premium (teste ZC)', 'premium')
on conflict (code) do nothing;
insert into public.user_subscriptions (id, user_id, plan_id, status, current_period_end)
  values ('dcdcdcdc-0000-0000-0000-0000000000a1', '3c3c3c3c-3333-3333-3333-333333333333',
          (select id from public.subscription_plans where code = 'zc_premium'), 'active', now() + interval '30 days');

-- Liberacao: A tem o modulo free e (de proposito) o premium; Premium tem o premium; ninguem tem o "locked"
insert into public.user_module_progress (user_id, module_id) values
  ('1c1c1c1c-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000061'),
  ('1c1c1c1c-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000062'),
  ('3c3c3c3c-3333-3333-3333-333333333333', '0c0c0c0c-0000-0000-0000-000000000062');

-- Tentativas criadas direto (casos de borda): modulo bloqueado (A) e premium (A sem plano)
insert into public.user_lesson_attempts (id, user_id, lesson_version_id, total_points)
  select 'acac0000-0000-0000-0000-000000000001', '1c1c1c1c-1111-1111-1111-111111111111', version_id, 3
    from public.zc_l where slug = 'zcX1';
insert into public.user_lesson_attempts (id, user_id, lesson_version_id, total_points)
  select 'acac0000-0000-0000-0000-000000000002', '1c1c1c1c-1111-1111-1111-111111111111', version_id, 3
    from public.zc_l where slug = 'zcP1';

-- Nivelamento (teste nao publicado, so para a tentativa): 2 de multipla escolha + 1 word_order
insert into public.placement_tests (id, code, version_number, title, total_questions)
  values ('bcbc0000-0000-0000-0000-000000000001', 'zc', 1, 'ZC nivelamento', 30);
do $$
declare i int; q uuid; o1 uuid; o2 uuid;
begin
  for i in 1..3 loop
    insert into public.questions (question_type, prompt, prompt_data)
      values (case when i = 3 then 'word_order' else 'multiple_choice' end, 'ZCP ' || i,
              case when i = 3 then '{"v":1,"tokens":["r","p","s","q"]}'::jsonb else '{"v":1}'::jsonb end)
      returning id into q;
    if i = 3 then
      insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
        values (q, 'p q r s', 'p q r s', true);
      insert into private.question_answer_keys (question_id, correct_option_id, explanation) values (q, null, 'EXPLICACAO-ZC PL 3');
      insert into public.zc_q values ('PL', i, q, null, null, 'p q r s');
    else
      insert into public.answer_options (question_id, option_text, position) values (q, 'b', 2) returning id into o2;
      insert into public.answer_options (question_id, option_text, position) values (q, 'a', 1) returning id into o1;
      insert into private.question_answer_keys (question_id, correct_option_id, explanation) values (q, o1, 'EXPLICACAO-ZC PL ' || i);
      insert into public.zc_q values ('PL', i, q, o1, o2, null);
    end if;
    insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
      values ('bcbc0000-0000-0000-0000-000000000001', q,
              case i when 1 then 'vocabulary' when 2 then 'grammar' else 'construction' end,
              (select id from public.levels where code = 'A1'), 7, i);
  end loop;
end $$;
insert into public.user_placement_attempts (id, user_id, placement_test_id, status, score_pct, recommended_level_id, completed_at)
  values ('bdbd0000-0000-0000-0000-000000000002', '1c1c1c1c-1111-1111-1111-111111111111',
          'bcbc0000-0000-0000-0000-000000000001', 'completed', 0, (select id from public.levels where code = 'A1'), now());
insert into public.user_placement_attempts (id, user_id, placement_test_id)
  values ('bdbd0000-0000-0000-0000-000000000001', '1c1c1c1c-1111-1111-1111-111111111111', 'bcbc0000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------
-- SEC: anon sem execute; sem login = 28000
-- ---------------------------------------------------------------------
set role anon;
do $$
declare f text;
begin
  foreach f in array public.zc_rpc_calls() loop
    perform public.zc_expect_error(f, '42501');
  end loop;
  perform public.zc_assert(true, 'SEC: anon nao executa get_lesson_content nem get_placement_items (42501)');
end $$;
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub', '', false);
do $$
declare f text;
begin
  foreach f in array public.zc_rpc_calls() loop
    perform public.zc_expect_error(f, '28000');
  end loop;
  perform public.zc_assert(true, 'SEC: sem login (sem claim) as duas RPCs devolvem 28000');
  perform public.zc_expect_error($q$select private.shuffled_prompt_data('s', gen_random_uuid(), 'word_order', '{}')$q$, '42501');
  perform public.zc_expect_error($q$select private.lesson_question_json(gen_random_uuid(), gen_random_uuid())$q$, '42501');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Aula: caso feliz, gabarito, resposta, secoes (aluno A)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zc_as('1c1c1c1c-1111-1111-1111-111111111111');
select public.start_lesson_attempt((select lesson_id from public.zc_l where slug = 'zcL1')) as la \gset
select set_config('zc.la', :'la', false);

do $$
declare la uuid := current_setting('zc.la')::uuid; c jsonb; c2 jsonb; qs jsonb; r jsonb; tokens jsonb;
begin
  c := public.get_lesson_content(la);
  perform public.zc_assert(c->'attempt'->>'status' = 'in_progress' and (c->'attempt'->>'version_number')::int = 1
    and c->'attempt'->>'id' = la::text and c->'lesson'->>'title' = 'Aula zcL1 v1' and c->'lesson'->>'objective' = 'objetivo Aula zcL1 v1'
    and (c->'lesson'->>'position')::int = 1 and c->'lesson'->>'module_id' = '0c0c0c0c-0000-0000-0000-000000000061',
    'LESSON: caso feliz traz attempt e lesson');
  perform public.zc_assert(jsonb_array_length(c->'sections') = 2 and c->'sections'->0->>'section_type' = 'intro'
    and c->'sections'->0->'content'->>'v' = '1' and (c->'sections'->0->>'viewed')::boolean is false
    and (c->'sections'->0->>'is_required')::boolean and c->'sections'->1->>'section_type' = 'examples'
    and c->'sections'->1->'content'->'items'->0->>'en' = 'I am here.',
    'LESSON: secoes ordenadas, com content versionado e viewed false');
  perform public.zc_assert(jsonb_array_length(c->'exercises') = 1 and c->'exercises'->0->>'title' = 'Ex'
    and jsonb_array_length(c->'exercises'->0->'questions') = 2 and jsonb_array_length(c->'other_questions') = 1
    and c->'other_questions'->0->>'prompt' = 'ZCQ zcL1 3', 'LESSON: exercicio com 2 questoes e 1 questao solta em other_questions');
  qs := c->'exercises'->0->'questions';
  perform public.zc_assert(qs->0->>'question_type' = 'multiple_choice' and (qs->0->>'is_assessed')::boolean
    and (qs->0->>'max_points')::numeric = 1 and qs->0->'options'->0->>'text' = 'certa' and qs->0->'options'->1->>'text' = 'errada'
    and (qs->0->'options'->0->>'position')::int = 1 and qs->0->'answer' = 'null'::jsonb and qs->0->'prompt_data' = '{"v":1}'::jsonb,
    'LESSON: questao com alternativas ordenadas, max_points e answer null');
  perform public.zc_assert((c->'progress'->>'sections_required')::int = 2 and (c->'progress'->>'sections_viewed')::int = 0
    and (c->'progress'->>'questions_assessed')::int = 3 and (c->'progress'->>'questions_answered')::int = 0, 'LESSON: progress inicial');

  -- gabarito: nenhuma chave de gabarito e nenhuma explicacao antes de responder
  perform public.zc_assert(c::text !~ '"(correct_option_id|accepted_answers|grading_rules|answer_text|normalized_text)"'
    and c::text !~ '"explanation"[ ]*:' and position('EXPLICACAO-ZC' in c::text) = 0
    and position('zc am here now ok' in c::text) = 0 and position('zc is here now ok' in c::text) = 0,
    'SEC: sem gabarito, sem accepted_answers e sem explanation antes de responder');

  -- word_order: tokens fora da ordem aceita e estaveis na mesma tentativa
  tokens := qs->1->'prompt_data'->'tokens';
  perform public.zc_assert(jsonb_array_length(tokens) = 5 and tokens <> '["zc","am","here","now","ok"]'::jsonb
    and qs->1->'prompt_data'->>'v' = '1', 'WORD_ORDER: tokens embaralhados (ordem diferente da resposta aceita)');
  c2 := public.get_lesson_content(la);
  perform public.zc_assert(c2->'exercises'->0->'questions'->1->'prompt_data'->'tokens' = tokens,
    'WORD_ORDER: duas chamadas na mesma tentativa devolvem a mesma ordem');
  perform set_config('zc.joined', (select string_agg(t, ' ' order by o) from jsonb_array_elements_text(tokens) with ordinality x(t, o)), false);

  -- secao vista e resposta
  perform public.record_section_view((select (c->'sections'->0->>'id')::uuid));
  r := public.submit_lesson_answer(la, public.zc_qid('zcL1', 1), jsonb_build_object('option_id', public.zc_corr('zcL1', 1)));
  c := public.get_lesson_content(la);
  qs := c->'exercises'->0->'questions';
  perform public.zc_assert((c->'sections'->0->>'viewed')::boolean and (c->'sections'->1->>'viewed')::boolean is false
    and (c->'progress'->>'sections_viewed')::int = 1 and (c->'progress'->>'questions_answered')::int = 1,
    'LESSON: viewed e progress refletem secao vista e questao respondida');
  perform public.zc_assert(qs->0->'answer' = jsonb_build_object('is_correct', true, 'awarded_points', 1, 'explanation', 'EXPLICACAO-ZC zcL1 1'),
    'LESSON: questao respondida traz is_correct, awarded_points e explanation');
  perform public.zc_assert(qs->1->'answer' = 'null'::jsonb and c->'other_questions'->0->'answer' = 'null'::jsonb
    and position('EXPLICACAO-ZC zcL1 2' in c::text) = 0 and position('EXPLICACAO-ZC zcL1 3' in c::text) = 0,
    'SEC: explicacao so das respondidas; nao respondida segue com answer null e sem explicacao');
  perform public.zc_assert(c::text !~ '"(correct_option_id|accepted_answers|grading_rules)"', 'SEC: sem chaves de gabarito depois de responder');

  -- erro conta como respondida, sem revelar a alternativa correta
  r := public.submit_lesson_answer(la, public.zc_qid('zcL1', 3), jsonb_build_object('option_id', (select wrong_opt from public.zc_q where slug = 'zcL1' and pos = 3)));
  c := public.get_lesson_content(la);
  perform public.zc_assert((c->'other_questions'->0->'answer'->>'is_correct')::boolean is false
    and (c->'other_questions'->0->'answer'->>'awarded_points')::numeric = 0
    and c->'other_questions'->0->'answer'->>'explanation' = 'EXPLICACAO-ZC zcL1 3', 'LESSON: resposta errada tem is_correct false e explicacao');
end $$;
reset role;

-- word_order: a frase montada com a ordem entregue nao e uma resposta aceita (confere no gabarito, como postgres)
select public.zc_assert(not exists (
    select 1 from private.accepted_answers a
     where a.question_id = public.zc_qid('zcL1', 2)
       and a.normalized_text = private.normalize_text(current_setting('zc.joined'))),
  'WORD_ORDER: a ordem entregue nao coincide com nenhuma accepted_answer');

-- embaralhamento: casos de borda do helper (postgres)
do $$
declare i int; r jsonb; q uuid;
begin
  q := public.zc_qid('zcL1', 2);
  -- 2 tokens com resposta aceita "a b": nunca entrega ["a","b"], em 40 sementes diferentes
  insert into public.questions (id, question_type, prompt, prompt_data)
    values ('cece0000-0000-0000-0000-000000000001', 'word_order', 'ZC 2 tokens', '{"v":1,"tokens":["b","a"]}');
  insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
    values ('cece0000-0000-0000-0000-000000000001', 'a b', 'a b', true);
  for i in 1..40 loop
    r := private.shuffled_prompt_data('semente' || i, 'cece0000-0000-0000-0000-000000000001', 'word_order', '{"v":1,"tokens":["a","b"]}');
    if r -> 'tokens' = '["a","b"]'::jsonb then raise exception 'FAIL: entregou a ordem aceita (semente %)', i; end if;
  end loop;
  perform public.zc_assert(true, 'WORD_ORDER: 2 tokens nunca saem na ordem aceita (40 sementes)');
  -- 1 token, tokens iguais e outros tipos: sem erro e sem mudanca indevida
  perform public.zc_assert(private.shuffled_prompt_data('s', q, 'word_order', '{"v":1,"tokens":["x"]}') = '{"v":1,"tokens":["x"]}'::jsonb
    and private.shuffled_prompt_data('s', q, 'word_order', '{"v":1,"tokens":["x","x"]}') = '{"v":1,"tokens":["x","x"]}'::jsonb
    and private.shuffled_prompt_data('s', q, 'multiple_choice', '{"v":1,"tokens":["b","a"]}') = '{"v":1,"tokens":["b","a"]}'::jsonb
    and private.shuffled_prompt_data('s', q, 'word_order', '{"v":1}') = '{"v":1}'::jsonb,
    'WORD_ORDER: 1 token, tokens iguais, outro tipo e prompt_data sem tokens passam sem mudar');
  -- a ordem muda de uma tentativa para outra (sementes diferentes) em pelo menos um caso
  perform public.zc_assert(exists (
      select 1 from generate_series(1, 30) g
       where private.shuffled_prompt_data('t' || g, q, 'word_order', '{"v":1,"tokens":["zc","am","here","now","ok"]}')
          <> private.shuffled_prompt_data('t1', q, 'word_order', '{"v":1,"tokens":["zc","am","here","now","ok"]}')),
    'WORD_ORDER: sementes diferentes podem gerar ordens diferentes');
end $$;

-- ---------------------------------------------------------------------
-- Versao: a tentativa antiga continua na versao 1 depois de publicar a 2
-- ---------------------------------------------------------------------
select public.zc_mk_version((select lesson_id from public.zc_l where slug = 'zcL1'), 2, 'Aula zcL1 v2 NOVA', 'zcL1v2') as v2 \gset
select public.zc_assert((select count(*) = 2 from public.lesson_versions where lesson_id = (select lesson_id from public.zc_l where slug = 'zcL1') and is_published),
  'VERSION: versao 2 publicada');

set role authenticated;
select public.zc_as('1c1c1c1c-1111-1111-1111-111111111111');
do $$
declare la uuid := current_setting('zc.la')::uuid; c jsonb; new_la uuid;
begin
  c := public.get_lesson_content(la);
  perform public.zc_assert((c->'attempt'->>'version_number')::int = 1 and c->'lesson'->>'title' = 'Aula zcL1 v1'
    and position('ZCQ zcL1v2' in c::text) = 0 and position('ZCQ zcL1 1' in c::text) > 0,
    'VERSION: tentativa antiga continua devolvendo o conteudo da versao 1');
  -- tentativa nova pega a versao 2; a antiga segue
  new_la := public.start_lesson_attempt((select lesson_id from public.zc_l where slug = 'zcL1'));
  perform public.zc_assert(public.get_lesson_content(new_la)->'attempt'->>'version_number' = '2', 'VERSION: nova tentativa usa a versao 2');
end $$;

-- tentativa encerrada: get_lesson_content continua funcionando (consulta)
select public.finish_lesson_attempt(current_setting('zc.la')::uuid);
do $$
declare c jsonb := public.get_lesson_content(current_setting('zc.la')::uuid);
begin
  perform public.zc_assert(c->'attempt'->>'status' = 'completed' and (c->'attempt'->>'version_number')::int = 1
    and c->'exercises'->0->'questions'->0->'answer'->>'explanation' = 'EXPLICACAO-ZC zcL1 1',
    'LESSON: tentativa encerrada (completed) e aceita, so consulta');
end $$;

-- modulo nao liberado e premium sem plano
do $$
begin
  perform public.zc_expect_error($q$select public.get_lesson_content('acac0000-0000-0000-0000-000000000001')$q$, '42501', 'module_locked');
  perform public.zc_expect_error($q$select public.get_lesson_content('acac0000-0000-0000-0000-000000000002')$q$, '42501', 'premium_required');
  perform public.zc_expect_error($q$select public.get_lesson_content(gen_random_uuid())$q$, '42501', 'attempt_not_found');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Premium: abre com plano; depois de cancelar, revalida na leitura
-- ---------------------------------------------------------------------
set role authenticated;
select public.zc_as('3c3c3c3c-3333-3333-3333-333333333333');
select public.start_lesson_attempt((select lesson_id from public.zc_l where slug = 'zcP1')) as lp \gset
select set_config('zc.lp', :'lp', false);
select public.zc_assert(public.get_lesson_content(current_setting('zc.lp')::uuid)->'lesson'->>'title' = 'Aula zcP1 v1',
  'PREMIUM: aluno com plano abre a aula Premium');
reset role;

update public.user_subscriptions set status = 'canceled' where id = 'dcdcdcdc-0000-0000-0000-0000000000a1';

set role authenticated;
select public.zc_as('3c3c3c3c-3333-3333-3333-333333333333');
select public.zc_expect_error(format($q$select public.get_lesson_content(%L)$q$, current_setting('zc.lp')), '42501', 'premium_required');
reset role;

-- ---------------------------------------------------------------------
-- Nivelamento (aluno A)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zc_as('1c1c1c1c-1111-1111-1111-111111111111');
do $$
declare pa uuid := 'bdbd0000-0000-0000-0000-000000000001'; c jsonb; it jsonb; tokens jsonb;
begin
  c := public.get_placement_items(pa);
  perform public.zc_assert(c->'attempt' = jsonb_build_object('id', pa, 'status', 'in_progress',
      'placement_test_id', 'bcbc0000-0000-0000-0000-000000000001', 'total_questions', 30, 'answered_count', 0)
    and jsonb_array_length(c->'items') = 3, 'PLACEMENT: caso feliz traz attempt e 3 itens');
  perform public.zc_assert((c->'items'->0->>'position')::int = 1 and (c->'items'->2->>'position')::int = 3
    and c->'items'->0->>'competency' = 'vocabulary' and c->'items'->2->>'competency' = 'construction'
    and (c->'items'->0->>'answered')::boolean is false
    and c->'items'->0->'question'->'options'->0->>'text' = 'a' and c->'items'->0->'question'->'options'->1->>'text' = 'b'
    and c->'items'->0->'question'->>'question_type' = 'multiple_choice' and c->'items'->0->'question'->>'prompt' = 'ZCP 1',
    'PLACEMENT: itens ordenados por position, com alternativas ordenadas');
  perform public.zc_assert(c::text !~ '"(weight|difficulty_level_id|is_correct|explanation|correct_option_id|accepted_answers|grading_rules|awarded_points)"'
    and position('EXPLICACAO-ZC' in c::text) = 0 and position('p q r s' in c::text) = 0
    and not ((c->'items'->0) ? 'weight') and (c->'items'->0->'question') ? 'prompt_data',
    'SEC: nivelamento sem dificuldade, peso, acerto, explicacao nem accepted_answers');
  tokens := c->'items'->2->'question'->'prompt_data'->'tokens';
  perform public.zc_assert(jsonb_array_length(tokens) = 4 and tokens <> '["p","q","r","s"]'::jsonb
    and public.get_placement_items(pa)->'items'->2->'question'->'prompt_data'->'tokens' = tokens,
    'WORD_ORDER: nivelamento embaralha os tokens e mantem a ordem na mesma tentativa');
  perform set_config('zc.pjoined', (select string_agg(t, ' ' order by o) from jsonb_array_elements_text(tokens) with ordinality x(t, o)), false);

  perform public.submit_placement_answer(pa, public.zc_qid('PL', 1), jsonb_build_object('option_id', public.zc_corr('PL', 1)));
  c := public.get_placement_items(pa);
  perform public.zc_assert((c->'attempt'->>'answered_count')::int = 1 and (c->'items'->0->>'answered')::boolean
    and (c->'items'->1->>'answered')::boolean is false and c::text !~ '"(is_correct|explanation)"',
    'PLACEMENT: answered/answered_count refletem as respostas, sem revelar acerto');
  perform public.zc_expect_error($q$select public.get_placement_items('bdbd0000-0000-0000-0000-000000000002')$q$, '55000', 'attempt_closed');
  perform public.zc_expect_error($q$select public.get_placement_items(gen_random_uuid())$q$, '42501', 'attempt_not_found');
end $$;
reset role;
select public.zc_assert(not exists (
    select 1 from private.accepted_answers a
     where a.question_id = public.zc_qid('PL', 3) and a.normalized_text = private.normalize_text(current_setting('zc.pjoined'))),
  'WORD_ORDER: ordem entregue no nivelamento nao coincide com a resposta aceita');

-- ---------------------------------------------------------------------
-- word_order: a ordem autorada nao vaza (qa-security)
-- ---------------------------------------------------------------------
-- (1) o aluno nao le prompt_data direto pela API (nem na aula, nem no nivelamento em andamento), mas le o resto
set role authenticated;
select public.zc_as('1c1c1c1c-1111-1111-1111-111111111111');
do $$
begin
  perform public.zc_expect_error(format($q$select prompt_data from public.questions where id = %L$q$, public.zc_qid('zcL1', 2)), '42501');
  perform public.zc_expect_error($q$select prompt_data from public.questions where prompt = 'ZCP 3'$q$, '42501');
  perform public.zc_expect_error($q$select * from public.questions where prompt = 'ZCP 3'$q$, '42501');
  perform public.zc_expect_error($q$select q.prompt_data from public.questions q join public.answer_options o on o.question_id = q.id$q$, '42501');
  perform public.zc_assert((select count(*) = 1 from public.questions where id = public.zc_qid('zcL1', 2) and prompt = 'ZCQ zcL1 2'
                              and question_type = 'word_order')
    and (select count(*) = 1 from public.questions where prompt = 'ZCP 3')
    and (select count(*) = 2 from public.answer_options where question_id = public.zc_qid('zcL1', 1)),
    'SEC: aluno nao le questions.prompt_data (42501), mas ainda le prompt, tipo e alternativas');
end $$;
reset role;

-- admin de conteudo continua escrevendo prompt_data (o grant de coluna so tirou o SELECT)
insert into auth.users (id, email) values ('ad000000-0000-0000-0000-000000000001', 'zc-admin@t');
insert into public.user_roles (user_id, role) values ('ad000000-0000-0000-0000-000000000001', 'content_admin');
set role authenticated;
select public.zc_as('ad000000-0000-0000-0000-000000000001');
do $$
begin
  update public.questions set prompt_data = '{"v":1,"tokens":["b","a"],"nota":"admin"}' where id = 'cece0000-0000-0000-0000-000000000001';
  perform public.zc_assert(true, 'SEC: content_admin ainda consegue atualizar prompt_data');
end $$;
reset role;
select public.zc_assert((select prompt_data ->> 'nota' = 'admin' from public.questions where id = 'cece0000-0000-0000-0000-000000000001'),
  'SEC: o update do admin foi gravado');

-- (2) a saida do embaralhamento nao depende da ordem autorada (mesma questao, mesma semente, ordens diferentes)
do $$
declare q uuid := public.zc_qid('zcL1', 2); i int; a jsonb; b jsonb; c jsonb;
begin
  for i in 1..25 loop
    a := private.shuffled_prompt_data('sem' || i, q, 'word_order', '{"v":1,"tokens":["here","zc","ok","am","now"]}');
    b := private.shuffled_prompt_data('sem' || i, q, 'word_order', '{"v":1,"tokens":["now","am","ok","zc","here"]}');
    c := private.shuffled_prompt_data('sem' || i, q, 'word_order', '{"v":1,"tokens":["ok","here","now","zc","am"]}');
    if a <> b or b <> c then raise exception 'FAIL: saida depende da ordem autorada (semente %): % / % / %', i, a, b, c; end if;
  end loop;
  perform public.zc_assert(true, 'WORD_ORDER: mesma semente e mesmos tokens em ordens autoradas diferentes dao a mesma saida (25 sementes)');
  perform public.zc_assert(
    private.shuffled_prompt_data('s9', q, 'word_order', '{"v":1,"tokens":["x","y","x","z","x"]}')
      = private.shuffled_prompt_data('s9', q, 'word_order', '{"v":1,"tokens":["z","x","x","y","x"]}')
    and jsonb_array_length(private.shuffled_prompt_data('s9', q, 'word_order', '{"v":1,"tokens":["x","y","x","z","x"]}') -> 'tokens') = 5,
    'WORD_ORDER: tokens repetidos tambem nao dependem da ordem autorada');
end $$;

-- (2b) segredo do embaralhamento: o app nao le, e a formula SEM o segredo nao reproduz a saida (oraculo da rotacao)
set role authenticated;
select public.zc_as('1c1c1c1c-1111-1111-1111-111111111111');
select public.zc_expect_error($q$select * from private.shuffle_secret$q$, '42501');
select public.zc_expect_error($q$select secret from private.shuffle_secret$q$, '42501');
reset role;
select public.zc_assert(not has_table_privilege('authenticated', 'private.shuffle_secret', 'SELECT')
  and not has_table_privilege('anon', 'private.shuffle_secret', 'SELECT')
  and (select relrowsecurity from pg_class where oid = 'private.shuffle_secret'::regclass)
  and (select count(*) = 1 and bool_and(char_length(secret) >= 64) from private.shuffle_secret),
  'SEC: private.shuffle_secret com RLS, sem grant para o app e com segredo de 64+ caracteres');
do $$
declare q uuid := 'de000000-0000-0000-0000-000000000001'; i int; naive jsonb; real_out jsonb; hits int := 0; orig text;
begin
  -- deterministico: segredo e question_id fixos de teste (o segredo real e restaurado no fim do bloco)
  select secret into orig from private.shuffle_secret where id = 1;
  update private.shuffle_secret set secret = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff' where id = 1;
  for i in 1..40 loop
    -- o que o aluno calcularia com tudo que conhece (semente, question_id, tokens), sem o segredo
    select to_jsonb(array_agg(t order by md5('sem' || i || q::text || t || '1'), lower(t), t))
      into naive from unnest(array['zc','am','here','now','ok']) t;
    real_out := private.shuffled_prompt_data('sem' || i, q, 'word_order', '{"v":1,"tokens":["here","zc","ok","am","now"]}') -> 'tokens';
    if naive = real_out then hits := hits + 1; end if;
  end loop;
  update private.shuffle_secret set secret = orig where id = 1;
  perform public.zc_assert(hits = 0, 'WORD_ORDER: a formula sem o segredo nao reproduz a saida real (0 de 40 sementes, segredo fixo de teste)');
end $$;
-- S1: tambem compara o normalize_text do answer_text (normalized_text forjado nao burla)
select public.zc_expect_error(
  $q$insert into private.accepted_answers (question_id, answer_text, normalized_text)
       values ('cece0000-0000-0000-0000-000000000001', 'B, a.', 'qualquer coisa')$q$, '23514', 'word_order_tokens_match_answer');

-- (3) o trigger recusa tokens na ordem da resposta aceita
select public.zc_expect_error(
  $q$insert into private.accepted_answers (question_id, answer_text, normalized_text) values
       ('cece0000-0000-0000-0000-000000000001', 'B, a.', private.normalize_text('B, a.'))$q$, '23514', 'word_order_tokens_match_answer');
select public.zc_expect_error(
  $q$update public.questions set prompt_data = '{"v":1,"tokens":["a","b"]}' where id = 'cece0000-0000-0000-0000-000000000001'$q$,
  '23514', 'word_order_tokens_match_answer');
select public.zc_expect_error(
  $q$update private.accepted_answers set answer_text = 'b a', normalized_text = 'b a'
      where question_id = 'cece0000-0000-0000-0000-000000000001'$q$, '23514', 'word_order_tokens_match_answer');
select public.zc_assert((select prompt_data -> 'tokens' = '["b","a"]'::jsonb from public.questions where id = 'cece0000-0000-0000-0000-000000000001')
  and (select count(*) = 1 from private.accepted_answers where question_id = 'cece0000-0000-0000-0000-000000000001' and normalized_text = 'a b'),
  'WORD_ORDER: trigger recusou (23514) tokens na ordem da resposta, em insert de resposta, update de tokens e update de resposta');

-- (4) get_review_queue entrega os tokens embaralhados (q2 da aula, word_order, respondida na tentativa encerrada)
insert into public.user_exercise_attempts
  (user_id, lesson_attempt_id, lesson_version_id, question_id, submitted_answer, is_correct, awarded_points, max_points)
  select '1c1c1c1c-1111-1111-1111-111111111111', a.id, a.lesson_version_id, public.zc_qid('zcL1', 2), '{}', false, 0, 1
    from public.user_lesson_attempts a where a.id = current_setting('zc.la')::uuid;
insert into public.review_schedule (user_id, question_id, due_at)
  values ('1c1c1c1c-1111-1111-1111-111111111111', public.zc_qid('zcL1', 2), now() - interval '1 hour');
set role authenticated;
select public.zc_as('1c1c1c1c-1111-1111-1111-111111111111');
do $$
declare q jsonb; it jsonb; tokens jsonb;
begin
  q := public.get_review_queue('UTC', 100);
  select e into it from jsonb_array_elements(q -> 'items') e
   where e -> 'question' ->> 'id' = public.zc_qid('zcL1', 2)::text;
  perform public.zc_assert(it is not null, 'REVIEW: a questao word_order esta na fila');
  tokens := it -> 'question' -> 'prompt_data' -> 'tokens';
  perform public.zc_assert(jsonb_array_length(tokens) = 5 and tokens <> '["zc","am","here","now","ok"]'::jsonb
    and (select array_agg(t order by t) from jsonb_array_elements_text(tokens) t) = array['am','here','now','ok','zc'],
    'REVIEW: get_review_queue entrega os mesmos tokens, embaralhados (nunca na ordem aceita)');
  perform set_config('zc.sched', it ->> 'schedule_id', false);
  perform set_config('zc.rtokens', tokens::text, false);
  perform public.zc_assert(public.get_review_queue('UTC', 100) -> 'items' = q -> 'items', 'REVIEW: a ordem dos tokens e estavel entre chamadas');
end $$;
reset role;
select public.zc_assert(
  current_setting('zc.rtokens')::jsonb = (private.shuffled_prompt_data(current_setting('zc.sched'), public.zc_qid('zcL1', 2), 'word_order',
        '{"v":1,"tokens":["now","ok","zc","here","am"]}') -> 'tokens'),
  'REVIEW: a semente da fila e o id do agendamento e a saida independe da ordem autorada');

-- ---------------------------------------------------------------------
-- Isolamento: aluno B nao le tentativas do aluno A
-- ---------------------------------------------------------------------
set role authenticated;
select public.zc_as('2c2c2c2c-2222-2222-2222-222222222222');
do $$
begin
  perform public.zc_expect_error(format($q$select public.get_lesson_content(%L)$q$, current_setting('zc.la')), '42501', 'attempt_not_found');
  perform public.zc_expect_error($q$select public.get_placement_items('bdbd0000-0000-0000-0000-000000000001')$q$, '42501', 'attempt_not_found');
  perform public.zc_expect_error($q$select public.get_placement_items('bdbd0000-0000-0000-0000-000000000002')$q$, '42501', 'attempt_not_found');
  perform public.zc_expect_error($q$select public.get_lesson_content('acac0000-0000-0000-0000-000000000001')$q$, '42501', 'attempt_not_found');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Cadastro: display_name
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('c1000000-0000-0000-0000-000000000001', 'zc-n1@t', '{"display_name":"Maria Silva"}'),
  ('c1000000-0000-0000-0000-000000000002', 'zc-n2@t', null),
  ('c1000000-0000-0000-0000-000000000003', 'zc-n3@t', '{"display_name":"     "}'),
  ('c1000000-0000-0000-0000-000000000004', 'zc-n4@t',
     jsonb_build_object('display_name', '  Ana' || chr(9) || chr(10) || '   ' || chr(1) || 'Maria  ' || chr(127))),
  ('c1000000-0000-0000-0000-000000000005', 'zc-n5@t', jsonb_build_object('display_name', repeat('x', 80))),
  ('c1000000-0000-0000-0000-000000000006', 'zc-n6@t', '{"display_name":123}'),
  ('c1000000-0000-0000-0000-000000000007', 'zc-n7@t', '{"display_name":{"a":1}}'),
  ('c1000000-0000-0000-0000-000000000008', 'zc-n8@t', '{"outra_chave":"x"}'),
  ('c1000000-0000-0000-0000-000000000009', 'zc-n9@t', jsonb_build_object('display_name', repeat('y', 59) || ' ' || repeat('z', 10))),
  ('c1000000-0000-0000-0000-000000000010', 'zc-n10@t', '{"display_name":["a"]}'),
  ('c1000000-0000-0000-0000-000000000011', 'zc-n11@t', '{"display_name":true}'),
  ('c1000000-0000-0000-0000-000000000012', 'zc-n12@t', jsonb_build_object('display_name', chr(1) || chr(2) || chr(9))),
  ('c1000000-0000-0000-0000-000000000013', 'zc-n13@t',
     jsonb_build_object('display_name', chr(8203) || 'Ana' || chr(8238) || 'Maria' || chr(65279) || chr(8288) || chr(8294) || ' Souza ' || chr(8207))),
  ('c1000000-0000-0000-0000-000000000014', 'zc-n14@t',
     jsonb_build_object('display_name', chr(8203) || chr(8204) || chr(8205) || chr(8206) || chr(65279) || chr(8232 + 6)));

select public.zc_assert(
  (select display_name from public.profiles where id = 'c1000000-0000-0000-0000-000000000001') = 'Maria Silva',
  'SIGNUP: com nome, grava o nome');
select public.zc_assert(
  (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000002')
  and exists (select 1 from public.user_roles where user_id = 'c1000000-0000-0000-0000-000000000002' and role = 'student'),
  'SIGNUP: sem metadado, perfil criado com nome null e papel student');
select public.zc_assert(
  (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000003'), 'SIGNUP: nome so de espacos vira null');
select public.zc_assert(
  (select display_name from public.profiles where id = 'c1000000-0000-0000-0000-000000000004') = 'Ana Maria',
  'SIGNUP: espacos e caracteres de controle sao limpos (Ana Maria)');
select public.zc_assert(
  (select char_length(display_name) = 60 and display_name = repeat('x', 60) from public.profiles where id = 'c1000000-0000-0000-0000-000000000005'),
  'SIGNUP: nome de 80 caracteres e cortado em 60');
select public.zc_assert(
  (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000006')
  and (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000007')
  and (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000008')
  and (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000010')
  and (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000011'),
  'SIGNUP: display_name numerico, objeto, array, booleano ou ausente vira null sem derrubar o cadastro');
select public.zc_assert(
  (select display_name = repeat('y', 59) from public.profiles where id = 'c1000000-0000-0000-0000-000000000009'),
  'SIGNUP: o corte em 60 nao deixa espaco sobrando no fim');
select public.zc_assert(
  (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000012'),
  'SIGNUP: nome so de caracteres de controle vira null');
select public.zc_assert(
  (select display_name = 'AnaMaria Souza' from public.profiles where id = 'c1000000-0000-0000-0000-000000000013')
  and (select display_name is null from public.profiles where id = 'c1000000-0000-0000-0000-000000000014'),
  'SIGNUP: invisiveis e controles de direcao (U+200B..200F, 202A..202E, 2060..2064, 2066..2069, FEFF) sao removidos');
select public.zc_assert(
  (select count(*) = 14 from public.profiles where id::text like 'c1000000-%')
  and (select count(*) = 14 from public.user_roles where user_id::text like 'c1000000-%' and role = 'student'),
  'SIGNUP: os 14 cadastros criaram perfil e papel student');

-- constraint profiles_display_name_len
select public.zc_expect_error(
  $q$update public.profiles set display_name = repeat('x', 61) where id = 'c1000000-0000-0000-0000-000000000001'$q$, '23514', 'profiles_display_name_len');
select public.zc_expect_error(
  $q$update public.profiles set display_name = '' where id = 'c1000000-0000-0000-0000-000000000001'$q$, '23514', 'profiles_display_name_len');
select public.zc_assert(
  (select display_name = 'Maria Silva' from public.profiles where id = 'c1000000-0000-0000-0000-000000000001'),
  'SIGNUP: update recusado nao altera o nome');
set role authenticated;
select public.zc_as('c1000000-0000-0000-0000-000000000001');
do $$
begin
  update public.profiles set display_name = repeat('x', 60) where id = auth.uid();
  perform public.zc_assert(true, 'SIGNUP: o aluno pode editar o proprio nome ate 60 caracteres');
  perform public.zc_expect_error($q$update public.profiles set display_name = repeat('x', 61) where id = auth.uid()$q$, '23514');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Permissoes estaticas
-- ---------------------------------------------------------------------
select public.zc_assert(not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('get_lesson_content', 'get_placement_items')
       and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig))
            or has_function_privilege('anon', p.oid, 'EXECUTE') or not has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
  'SEC: as 2 RPCs sao security definer, search_path vazio, sem execute para anon e com execute para authenticated');
select public.zc_assert(not has_function_privilege('authenticated', 'private.handle_new_user()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.shuffled_prompt_data(text, uuid, text, jsonb)', 'EXECUTE'),
  'SEC: funcoes privadas novas nao sao executaveis pelo app');

\echo ===== TESTES ENTREGA DE CONTEUDO PASSARAM =====
