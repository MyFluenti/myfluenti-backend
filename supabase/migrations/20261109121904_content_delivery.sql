-- =====================================================================
-- MyFluenti - Migration 005: entrega de conteudo ao app
--   * get_lesson_content(p_attempt_id): conteudo da aula na versao da tentativa
--   * get_placement_items(p_attempt_id): questoes do nivelamento em andamento
--   * handle_new_user: le display_name do cadastro (higienizado)
--   * profiles_display_name_len: nome com 1 a 60 caracteres
-- Nenhuma RPC devolve correct_option_id, accepted_answers nem grading_rules.
-- FORMATO DO CONTEUDO (PROVISORIO, decisao do Gabriel): todo content e prompt_data
-- leva "v":1; o app ignora tipos de bloco desconhecidos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- C. Cadastro: display_name
-- ---------------------------------------------------------------------
alter table public.profiles
  add constraint profiles_display_name_len
  check (display_name is null or char_length(display_name) between 1 and 60);

-- raw_user_meta_data e editavel pelo proprio usuario: serve SO para exibicao,
-- nunca para autorizacao. O tratamento do nome nunca pode falhar o cadastro.
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := null;
begin
  begin
    if pg_catalog.jsonb_typeof(new.raw_user_meta_data -> 'display_name') = 'string' then
      v_name := new.raw_user_meta_data ->> 'display_name';
      -- invisiveis e controles de direcao (U+200B-200F, 202A-202E, 2060-2064, 2066-2069, FEFF) sao removidos;
      -- caracteres de controle viram espaco; espacos repetidos viram um; trim; corte em 60
      v_name := pg_catalog.regexp_replace(v_name, U&'[\200B-\200F\202A-\202E\2060-\2064\2066-\2069\FEFF]', '', 'g');
      v_name := pg_catalog.regexp_replace(v_name, '[\u0001-\u001f\u007f-\u009f]', ' ', 'g');
      v_name := pg_catalog.regexp_replace(v_name, '\s+', ' ', 'g');
      v_name := pg_catalog.btrim(v_name);
      v_name := pg_catalog.btrim(pg_catalog.left(v_name, 60));
      v_name := nullif(v_name, '');
    end if;
  exception when others then
    v_name := null;          -- nunca derruba o cadastro por causa do nome
  end;

  insert into public.profiles (id, display_name) values (new.id, v_name) on conflict do nothing;
  insert into public.user_roles (user_id, role) values (new.id, 'student') on conflict do nothing;
  return new;
end $$;
revoke all on function private.handle_new_user() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Segredo do embaralhamento (qa-security C1): sem ele, semente + question_id + tokens (todos conhecidos
-- do aluno) permitiriam calcular a saida "crua" S offline; se a RPC devolvesse algo diferente de S,
-- teria rotacionado, e S seria a resposta. A chave agora inclui um segredo que so o banco conhece.
-- Gerado na aplicacao da migration (por ambiente); nunca em arquivo, log ou resposta de RPC.
-- gen_random_uuid() e nativo (PG13+), nao exige pgcrypto.
create table private.shuffle_secret (
  id     smallint primary key check (id = 1),
  secret text not null
);
alter table private.shuffle_secret enable row level security;      -- sem politicas: acesso negado
revoke all on private.shuffle_secret from public, anon, authenticated;
insert into private.shuffle_secret (id, secret)
  values (1, replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''));

-- Embaralhamento deterministico dos tokens de word_order
-- (mesma tentativa, mesma ordem; a ordem entregue nunca e a resposta aceita)
-- ---------------------------------------------------------------------
create or replace function private.shuffled_prompt_data(
  p_seed text, p_question uuid, p_type text, p_prompt_data jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tokens text[]; v_shuffled text[]; v_n integer; v_secret text;
begin
  if p_type is distinct from 'word_order'
     or pg_catalog.jsonb_typeof(p_prompt_data -> 'tokens') is distinct from 'array' then
    return p_prompt_data;
  end if;
  select pg_catalog.array_agg(t.tok order by t.idx)
    into v_tokens
    from pg_catalog.jsonb_array_elements_text(p_prompt_data -> 'tokens') with ordinality as t(tok, idx);
  v_n := coalesce(pg_catalog.array_length(v_tokens, 1), 0);
  if v_n < 2 then
    return p_prompt_data;                       -- 1 token: nada a embaralhar
  end if;
  select s.secret into v_secret from private.shuffle_secret s where s.id = 1;   -- segredo so do banco (ver tabela)

  -- CANONICALIZACAO (fecha o vazamento da ordem autorada): a semente publica (tentativa/fila),
  -- o question_id e o texto do token sao conhecidos do aluno. Se o embaralhamento dependesse da
  -- posicao autorada (idx), o aluno recalcularia a saida para cada ordem candidata e recuperaria a
  -- resposta. Aqui a chave depende SO do multiconjunto de tokens: cada token vira (texto, ordinal da
  -- repeticao entre tokens iguais), a chave e md5(semente || questao || texto || ordinal), e o
  -- desempate e (lower(texto), texto, ordinal). Duas ordens autoradas do mesmo multiconjunto
  -- produzem exatamente a mesma saida.
  select pg_catalog.array_agg(c.tok order by pg_catalog.md5(v_secret || p_seed || p_question::text || c.tok || c.rep::text),
                              pg_catalog.lower(c.tok), c.tok, c.rep)
    into v_shuffled
    from (select u.tok, pg_catalog.row_number() over (partition by u.tok order by u.idx) as rep
            from pg_catalog.unnest(v_tokens) with ordinality as u(tok, idx)) c;

  -- nao pode coincidir com uma resposta aceita; senao rotaciona um passo
  if exists (select 1 from private.accepted_answers a
              where a.question_id = p_question
                and a.normalized_text = private.normalize_text(pg_catalog.array_to_string(v_shuffled, ' '))) then
    -- A rotacao exclui apenas esta permutacao (a ordem aceita); as demais continuam possiveis.
    v_shuffled := v_shuffled[2:v_n] || v_shuffled[1:1];
    -- Se ainda coincidir (ex.: todos os tokens iguais), aceitamos: nao ha ordem diferente a oferecer.
  end if;
  return pg_catalog.jsonb_set(p_prompt_data, '{tokens}', pg_catalog.to_jsonb(v_shuffled));
end $$;
revoke all on function private.shuffled_prompt_data(text, uuid, text, jsonb) from public, anon, authenticated;

-- Questao no formato de entrega; "answer" so existe se respondida NESTA tentativa de aula
-- (e so ai a explicacao sai do gabarito).
create or replace function private.lesson_question_json(p_attempt uuid, p_question uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', q.id,
    'position', q.position,
    'question_type', q.question_type,
    'prompt', q.prompt,
    'prompt_data', private.shuffled_prompt_data(p_attempt::text, q.id, q.question_type, q.prompt_data),
    'is_assessed', (q.is_assessed and coalesce(e.is_assessed, true)),
    'max_points', case when q.is_assessed and coalesce(e.is_assessed, true) then q.weight else 0 end,
    'options', coalesce((select jsonb_agg(jsonb_build_object(
                                 'id', o.id, 'text', o.option_text, 'position', o.position)
                               order by o.position)
                           from public.answer_options o where o.question_id = q.id), '[]'::jsonb),
    'answer', (select jsonb_build_object(
                        'is_correct', x.is_correct, 'awarded_points', x.awarded_points,
                        'explanation', k.explanation)
                 from public.user_exercise_attempts x
                 left join private.question_answer_keys k on k.question_id = x.question_id
                where x.lesson_attempt_id = p_attempt and x.question_id = q.id))
  from public.questions q
  left join public.exercises e on e.id = q.exercise_id
  where q.id = p_question
$$;
revoke all on function private.lesson_question_json(uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- A. get_lesson_content
-- =====================================================================
create or replace function public.get_lesson_content(p_attempt_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_version uuid; v_status text; v_vnum integer; v_lesson uuid; v_module uuid;
  v_pos smallint; v_title text; v_objective text;
  v_sections jsonb; v_exercises jsonb; v_other jsonb; v_progress jsonb;
begin
  select a.lesson_version_id, a.status, lv.version_number, lv.lesson_id, l.module_id,
         l.position, lv.title, lv.objective
    into v_version, v_status, v_vnum, v_lesson, v_module, v_pos, v_title, v_objective
    from public.user_lesson_attempts a
    join public.lesson_versions lv on lv.id = a.lesson_version_id
    join public.lessons l on l.id = lv.lesson_id
   where a.id = p_attempt_id and a.user_id = v_uid;
  if not found then
    raise exception 'attempt_not_found' using errcode = '42501';
  end if;

  -- revalida na leitura: liberacao e plano podem ter mudado depois do inicio da tentativa
  if not exists (select 1 from public.user_module_progress ump
                  where ump.user_id = v_uid and ump.module_id = v_module) then
    raise exception 'module_locked' using errcode = '42501';
  end if;
  if not private.module_plan_ok(v_uid, v_module) then
    raise exception 'premium_required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'position', s.position, 'section_type', s.section_type,
           'title', s.title, 'content', s.content, 'is_required', s.is_required,
           'viewed', exists (select 1 from public.user_section_progress usp
                              where usp.user_id = v_uid and usp.lesson_section_id = s.id))
         order by s.position), '[]'::jsonb)
    into v_sections
    from public.lesson_sections s where s.lesson_version_id = v_version;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'position', e.position, 'title', e.title,
           'instructions', e.instructions, 'is_assessed', e.is_assessed,
           'questions', coalesce((select jsonb_agg(private.lesson_question_json(p_attempt_id, q.id)
                                                   order by q.position, q.id)
                                    from public.questions q where q.exercise_id = e.id), '[]'::jsonb))
         order by e.position), '[]'::jsonb)
    into v_exercises
    from public.exercises e where e.lesson_version_id = v_version;

  select coalesce(jsonb_agg(private.lesson_question_json(p_attempt_id, q.id) order by q.position, q.id), '[]'::jsonb)
    into v_other
    from public.questions q where q.lesson_version_id = v_version and q.exercise_id is null;

  select jsonb_build_object(
           'sections_required', (select count(*) from public.lesson_sections s
                                  where s.lesson_version_id = v_version and s.is_required),
           'sections_viewed', (select count(*) from public.lesson_sections s
                                join public.user_section_progress usp
                                  on usp.lesson_section_id = s.id and usp.user_id = v_uid
                               where s.lesson_version_id = v_version and s.is_required),
           'questions_assessed', (select count(*) from public.questions q
                                    left join public.exercises e on e.id = q.exercise_id
                                   where q.lesson_version_id = v_version
                                     and q.is_assessed and coalesce(e.is_assessed, true)),
           'questions_answered', (select count(*) from public.user_exercise_attempts x
                                   where x.lesson_attempt_id = p_attempt_id and x.max_points > 0))
    into v_progress;

  return jsonb_build_object(
    'attempt', jsonb_build_object('id', p_attempt_id, 'status', v_status,
                                  'lesson_version_id', v_version, 'version_number', v_vnum),
    'lesson', jsonb_build_object('id', v_lesson, 'module_id', v_module, 'position', v_pos,
                                 'title', v_title, 'objective', v_objective),
    'sections', v_sections,
    'exercises', v_exercises,
    'other_questions', v_other,
    'progress', v_progress);
end $$;

-- =====================================================================
-- B. get_placement_items
-- =====================================================================
-- Diagnostico: sem dificuldade, sem peso, sem acerto e sem explicacao.
create or replace function public.get_placement_items(p_attempt_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_status text; v_total smallint; v_answered integer; v_items jsonb;
begin
  select a.placement_test_id, a.status, pt.total_questions
    into v_test, v_status, v_total
    from public.user_placement_attempts a
    join public.placement_tests pt on pt.id = a.placement_test_id
   where a.id = p_attempt_id and a.user_id = v_uid;
  if not found then
    raise exception 'attempt_not_found' using errcode = '42501';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'attempt_closed' using errcode = '55000';
  end if;

  select count(*)::integer into v_answered
    from public.user_placement_answers x where x.attempt_id = p_attempt_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'position', pq.position,
           'competency', pq.competency,
           'answered', exists (select 1 from public.user_placement_answers x
                                where x.attempt_id = p_attempt_id and x.question_id = pq.question_id),
           'question', jsonb_build_object(
             'id', q.id, 'question_type', q.question_type, 'prompt', q.prompt,
             'prompt_data', private.shuffled_prompt_data(p_attempt_id::text, q.id, q.question_type, q.prompt_data),
             'options', coalesce((select jsonb_agg(jsonb_build_object(
                                          'id', o.id, 'text', o.option_text, 'position', o.position)
                                        order by o.position)
                                    from public.answer_options o where o.question_id = q.id), '[]'::jsonb)))
         order by pq.position), '[]'::jsonb)
    into v_items
    from public.placement_questions pq
    join public.questions q on q.id = pq.question_id
   where pq.placement_test_id = v_test;

  return jsonb_build_object(
    'attempt', jsonb_build_object('id', p_attempt_id, 'status', v_status,
                                  'placement_test_id', v_test, 'total_questions', v_total,
                                  'answered_count', v_answered),
    'items', v_items);
end $$;

-- ---------------------------------------------------------------------
-- Permissoes de execucao
-- ---------------------------------------------------------------------
revoke all on function public.get_lesson_content(uuid)   from public, anon;
revoke all on function public.get_placement_items(uuid)  from public, anon;
grant execute on function public.get_lesson_content(uuid)  to authenticated;
grant execute on function public.get_placement_items(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Vazamento de word_order (qa-security): a ordem dos tokens nao pode revelar a resposta
-- ---------------------------------------------------------------------
-- (a) prompt_data nao e mais legivel pelo SELECT direto do aluno (o app le por get_lesson_content,
--     get_placement_items e get_review_queue, que embaralham). Lista = todas as colunas da migration 001
--     MENOS prompt_data. As politicas RLS continuam valendo; content_admin segue escrevendo
--     (insert/update/delete de tabela inalterados; so o SELECT de prompt_data some para o papel authenticated).
revoke select on public.questions from authenticated;
grant select (id, lesson_version_id, exercise_id, question_type, prompt, weight, is_assessed, position,
              grammar_topic_id, created_at)
  on public.questions to authenticated;

-- (b) o autor nao pode gravar os tokens na ordem da resposta aceita.
create or replace function private.guard_word_order_tokens() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_type text; v_data jsonb; v_question uuid; v_joined text; v_tokens text[];
begin
  if tg_table_name = 'accepted_answers' then
    v_question := new.question_id;
    select q.question_type, q.prompt_data into v_type, v_data from public.questions q where q.id = v_question;
  else
    v_question := new.id; v_type := new.question_type; v_data := new.prompt_data;
  end if;
  if v_type is distinct from 'word_order'
     or pg_catalog.jsonb_typeof(v_data -> 'tokens') is distinct from 'array' then
    return new;
  end if;
  select pg_catalog.array_agg(t.tok order by t.idx) into v_tokens
    from pg_catalog.jsonb_array_elements_text(v_data -> 'tokens') with ordinality as t(tok, idx);
  v_joined := private.normalize_text(pg_catalog.array_to_string(v_tokens, ' '));
  if tg_table_name = 'accepted_answers' then
    if v_joined = new.normalized_text or v_joined = private.normalize_text(new.answer_text) then
      raise exception 'word_order_tokens_match_answer' using errcode = '23514';
    end if;
  elsif exists (select 1 from private.accepted_answers a
                 where a.question_id = v_question and a.normalized_text = v_joined) then
    raise exception 'word_order_tokens_match_answer' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function private.guard_word_order_tokens() from public, anon, authenticated;

create trigger accepted_answers_word_order before insert or update on private.accepted_answers
  for each row execute function private.guard_word_order_tokens();
create trigger questions_word_order before insert or update of prompt_data, question_type on public.questions
  for each row execute function private.guard_word_order_tokens();

-- (c) get_review_queue: mesma funcao da migration 004 (assinatura e retorno identicos); unica mudanca:
--     prompt_data da questao passa por private.shuffled_prompt_data. Semente = id do agendamento
--     (review_schedule.id): estavel para o aluno e diferente entre alunos; a saida nao depende da
--     ordem autorada (ver canonicalizacao no helper).
create or replace function public.get_review_queue(
  p_timezone text default 'UTC', p_limit int default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_end timestamptz;
  v_res jsonb;
begin
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'invalid_filter' using errcode = '22023';
  end if;
  v_end := private.local_day_end(p_timezone);

  with s as (
    select rs.id, rs.due_at, rs.vocabulary_id, rs.grammar_topic_id, rs.question_id,
           private.review_item_accessible(
             v_uid, rs.vocabulary_id, rs.grammar_topic_id, rs.question_id) as ok
      from public.review_schedule rs
     where rs.user_id = v_uid
  ),
  agg as (
    select count(*) filter (where s.ok and s.due_at < v_end)                          as due_count,
           count(*) filter (where not s.ok and s.due_at < v_end)                      as locked_count,
           count(*) filter (where s.ok and s.due_at >= v_end
                                  and s.due_at < v_end + interval '1 day')            as tomorrow,
           count(*) filter (where s.ok and s.due_at >= v_end
                                  and s.due_at < v_end + interval '7 days')           as next_7_days,
           min(s.due_at) filter (where s.ok and s.due_at > now())                     as next_due_at
      from s
  ),
  due as (
    select * from s
     where s.ok and s.due_at < v_end
     order by s.due_at, s.id
     limit p_limit
  )
  select jsonb_build_object(
           'due_count', agg.due_count,
           'locked_count', agg.locked_count,
           'items', coalesce((
             select jsonb_agg(
                      jsonb_build_object(
                        'schedule_id', d.id,
                        'item_type', case when d.question_id is not null then 'question'
                                          when d.vocabulary_id is not null then 'vocabulary'
                                          else 'grammar_topic' end,
                        'due_at', d.due_at)
                      || case
                           when d.question_id is not null then jsonb_build_object(
                             'question', (
                               select jsonb_build_object(
                                        'id', q.id, 'question_type', q.question_type,
                                        'prompt', q.prompt,
                                        'prompt_data', private.shuffled_prompt_data(d.id::text, q.id, q.question_type, q.prompt_data),
                                        'options', coalesce((
                                          select jsonb_agg(jsonb_build_object(
                                                   'id', o.id, 'text', o.option_text,
                                                   'position', o.position)
                                                 order by o.position)
                                            from public.answer_options o
                                           where o.question_id = q.id), '[]'::jsonb))
                                 from public.questions q where q.id = d.question_id))
                           when d.vocabulary_id is not null then jsonb_build_object(
                             'vocabulary', (
                               select jsonb_build_object(
                                        'id', v.id, 'lemma', v.lemma,
                                        'part_of_speech', v.part_of_speech,
                                        'meaning_pt', v.meaning_pt,
                                        'examples', coalesce((
                                          select jsonb_agg(jsonb_build_object(
                                                   'id', e.id, 'en', e.example_en, 'pt', e.example_pt)
                                                 order by e.position nulls last, e.id)
                                            from public.vocabulary_examples e
                                           where e.vocabulary_id = v.id), '[]'::jsonb))
                                 from public.vocabulary v where v.id = d.vocabulary_id))
                           else jsonb_build_object(
                             'grammar_topic', (
                               select jsonb_build_object(
                                        'id', t.id, 'slug', t.slug, 'title', t.title,
                                        'summary', t.summary)
                                 from public.grammar_topics t where t.id = d.grammar_topic_id))
                         end
                      order by d.due_at, d.id)
               from due d), '[]'::jsonb),
           'upcoming', jsonb_build_object(
             'tomorrow', agg.tomorrow, 'next_7_days', agg.next_7_days),
           'next_due_at', agg.next_due_at)
    into v_res
    from agg;
  return v_res;
end $$;
revoke all on function public.get_review_queue(text, integer) from public, anon;
grant execute on function public.get_review_queue(text, integer) to authenticated;
