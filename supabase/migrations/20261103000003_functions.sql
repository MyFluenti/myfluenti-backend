-- =====================================================================
-- MyFluenti - Migration 003: funcoes do backend (regras de negocio)
-- O aplicativo NUNCA decide correcao, aprovacao, conclusao ou desbloqueio:
-- ele chama estas funcoes (RPC). Todas usam auth.uid(), security definer
-- e search_path vazio. Gabaritos so sao lidos aqui, dentro do schema private.
--
-- Parametros PROVISORIOS (pendencias do Dicionario de Dados, secao 15):
--   * matriz de nivelamento (limiar de 60% por nivel) -> finish_placement_attempt
--   * formula de dominio (mastery_score = % de acertos) -> finish_lesson_attempt
--   * parametros do SM-2 adaptado                       -> record_review_result
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Auxiliares privadas
-- ---------------------------------------------------------------------
create or replace function private.require_user() returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'Autenticacao obrigatoria' using errcode = '28000';
  end if;
  return v;
end $$;

create or replace function private.normalize_text(p text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(
           regexp_replace(lower(coalesce(p, '')), '[.,!?;:"]', '', 'g'),
           '\s+', ' ', 'g'))
$$;

-- Corrige uma resposta usando o gabarito protegido.
create or replace function private.grade_answer(p_question uuid, p_answer jsonb)
returns table (is_correct boolean, explanation text)
language plpgsql security definer set search_path = '' as $$
declare
  v_type text;
  v_key  private.question_answer_keys%rowtype;
  v_ok   boolean := false;
  v_text text;
begin
  select q.question_type into v_type from public.questions q where q.id = p_question;
  if not found then
    raise exception 'Questao inexistente' using errcode = 'P0002';
  end if;
  select * into v_key from private.question_answer_keys k where k.question_id = p_question;
  if not found then
    raise exception 'Questao sem gabarito cadastrado' using errcode = 'P0002';
  end if;

  if v_type = 'multiple_choice' then
    v_ok := v_key.correct_option_id is not null
            and (p_answer ->> 'option_id') = v_key.correct_option_id::text;
  else
    v_text := private.normalize_text(p_answer ->> 'text');
    v_ok := v_text <> '' and exists (
      select 1 from private.accepted_answers a
      where a.question_id = p_question and a.normalized_text = v_text);
  end if;
  return query select v_ok, v_key.explanation;
end $$;

create or replace function private.first_published_module(p_level uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select m.id from public.modules m
  where m.level_id = p_level and m.is_published
  order by m.position limit 1
$$;

-- Libera o modulo se publicado e permitido pelo plano (idempotente).
create or replace function private.unlock_module(p_user uuid, p_module uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.user_module_progress (user_id, module_id)
  select p_user, m.id from public.modules m
  where m.id = p_module and m.is_published
    and (m.access_tier = 'free' or private.has_premium_access(p_user))
  on conflict (user_id, module_id) do nothing
$$;

-- Proximo modulo do nivel; no ultimo modulo, o primeiro do proximo nivel.
create or replace function private.unlock_next_module(p_user uuid, p_module uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_level uuid; v_pos smallint; v_lvl_pos smallint; v_next uuid;
begin
  select level_id, position into v_level, v_pos from public.modules where id = p_module;
  select m.id into v_next from public.modules m
   where m.level_id = v_level and m.is_published and m.position > v_pos
   order by m.position limit 1;
  if v_next is null then
    select position into v_lvl_pos from public.levels where id = v_level;
    select m.id into v_next
      from public.modules m join public.levels l on l.id = m.level_id
     where m.is_published and l.position > v_lvl_pos
     order by l.position, m.position limit 1;
  end if;
  if v_next is not null then
    perform private.unlock_module(p_user, v_next);
  end if;
end $$;

-- Conclui o modulo quando todas as aulas obrigatorias publicadas estao concluidas.
-- Serializa por (aluno, modulo) com FOR UPDATE: duas conclusoes simultaneas nao divergem.
create or replace function private.evaluate_module_completion(p_user uuid, p_module uuid)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_status text; v_required integer; v_done integer;
begin
  select ump.status into v_status
    from public.user_module_progress ump
   where ump.user_id = p_user and ump.module_id = p_module
   for update;
  if not found then
    return false;
  end if;

  select count(*), count(*) filter (where ulp.status = 'completed')
    into v_required, v_done
    from public.lessons l
    left join public.user_lesson_progress ulp
           on ulp.lesson_id = l.id and ulp.user_id = p_user
   where l.module_id = p_module and l.is_required
     and exists (select 1 from public.lesson_versions lv
                  where lv.lesson_id = l.id and lv.is_published);

  if v_status = 'completed' or (v_required > 0 and v_required = v_done) then
    update public.user_module_progress
       set status = 'completed',
           started_at = coalesce(started_at, now()),
           completed_at = coalesce(completed_at, now())
     where user_id = p_user and module_id = p_module;
    perform private.unlock_next_module(p_user, p_module);
    return true;
  end if;

  if v_status = 'available' then
    update public.user_module_progress
       set status = 'in_progress', started_at = coalesce(started_at, now())
     where user_id = p_user and module_id = p_module;
  end if;
  return false;
end $$;

-- Reavalia desbloqueios (ex.: assinatura mudou).
create or replace function private.reevaluate_unlocks(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_level uuid; v_first uuid; v_mod uuid;
begin
  select current_level_id into v_level from public.profiles where id = p_user;
  if v_level is not null then
    v_first := private.first_published_module(v_level);
    if v_first is not null then
      perform private.unlock_module(p_user, v_first);
    end if;
  end if;
  for v_mod in
    select module_id from public.user_module_progress
     where user_id = p_user and status = 'completed'
  loop
    perform private.unlock_next_module(p_user, v_mod);
  end loop;
end $$;

create or replace function private.on_subscription_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.reevaluate_unlocks(new.user_id);
  return new;
end $$;
create trigger user_subscriptions_reevaluate
  after insert or update on public.user_subscriptions
  for each row execute function private.on_subscription_change();

-- ---------------------------------------------------------------------
-- 2. Nivelamento
-- ---------------------------------------------------------------------
create or replace function public.start_placement_attempt(p_test_id uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_attempt uuid;
begin
  if p_test_id is null then
    select pt.id into v_test from public.placement_tests pt
     where pt.is_published order by pt.published_at desc limit 1;
  else
    select pt.id into v_test from public.placement_tests pt
     where pt.id = p_test_id and pt.is_published;
  end if;
  if v_test is null then
    raise exception 'Nenhum teste de nivelamento publicado' using errcode = 'P0002';
  end if;

  select a.id into v_attempt from public.user_placement_attempts a
   where a.user_id = v_uid and a.placement_test_id = v_test and a.status = 'in_progress';
  if v_attempt is not null then
    return v_attempt;                       -- retoma tentativa em andamento
  end if;

  insert into public.user_placement_attempts (user_id, placement_test_id)
  values (v_uid, v_test) returning id into v_attempt;
  return v_attempt;
end $$;

-- Nao devolve correcao durante o teste (diagnostico, sem feedback imediato).
create or replace function public.submit_placement_answer(
  p_attempt_id uuid, p_question_id uuid, p_answer jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_status text; v_weight numeric; v_ok boolean;
begin
  select a.placement_test_id, a.status into v_test, v_status
    from public.user_placement_attempts a
   where a.id = p_attempt_id and a.user_id = v_uid
   for update;
  if not found then
    raise exception 'Tentativa nao encontrada' using errcode = '42501';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'Tentativa ja encerrada' using errcode = '55000';
  end if;

  select pq.weight into v_weight from public.placement_questions pq
   where pq.placement_test_id = v_test and pq.question_id = p_question_id;
  if not found then
    raise exception 'Questao nao pertence a este teste' using errcode = '23503';
  end if;
  if exists (select 1 from public.user_placement_answers x
              where x.attempt_id = p_attempt_id and x.question_id = p_question_id) then
    raise exception 'Questao ja respondida' using errcode = '23505';
  end if;

  select g.is_correct into v_ok from private.grade_answer(p_question_id, p_answer) g;
  insert into public.user_placement_answers
    (user_id, attempt_id, placement_test_id, question_id, submitted_answer, is_correct, awarded_points)
  values
    (v_uid, p_attempt_id, v_test, p_question_id, p_answer, v_ok,
     case when v_ok then v_weight else 0 end);
end $$;

-- Calcula pontuacao e recomenda nivel. NAO altera o nivel em estudo do aluno.
-- Regra provisoria: o nivel recomendado e o maior nivel, em sequencia a partir do
-- A1, cujo aproveitamento ponderado nas questoes daquele nivel seja >= 60%.
create or replace function public.finish_placement_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_status text;
  v_total numeric; v_earned numeric; v_score numeric;
  v_rec uuid; v_rec_code text; v_breakdown jsonb;
  r record;
  c_threshold constant numeric := 0.60;
begin
  select a.placement_test_id, a.status into v_test, v_status
    from public.user_placement_attempts a
   where a.id = p_attempt_id and a.user_id = v_uid
   for update;
  if not found then
    raise exception 'Tentativa nao encontrada' using errcode = '42501';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'Tentativa ja encerrada' using errcode = '55000';
  end if;

  select coalesce(sum(pq.weight), 0) into v_total
    from public.placement_questions pq where pq.placement_test_id = v_test;
  select coalesce(sum(x.awarded_points), 0) into v_earned
    from public.user_placement_answers x where x.attempt_id = p_attempt_id;
  v_score := case when v_total > 0 then v_earned * 100 / v_total else 0 end;

  for r in
    select l.id, sum(pq.weight) as total, sum(coalesce(x.awarded_points, 0)) as earned
      from public.placement_questions pq
      join public.levels l on l.id = pq.difficulty_level_id
      left join public.user_placement_answers x
             on x.attempt_id = p_attempt_id and x.question_id = pq.question_id
     where pq.placement_test_id = v_test
     group by l.id, l.position
     order by l.position
  loop
    if r.earned / r.total >= c_threshold then v_rec := r.id; else exit; end if;
  end loop;
  if v_rec is null then
    select l.id into v_rec from public.levels l order by l.position limit 1;
  end if;
  select l.code into v_rec_code from public.levels l where l.id = v_rec;

  select coalesce(jsonb_object_agg(t.competency, jsonb_build_object(
           'earned', t.earned, 'total', t.total,
           'pct', case when t.total > 0 then t.earned * 100 / t.total else 0 end)), '{}'::jsonb)
    into v_breakdown
    from (select pq.competency, sum(pq.weight) as total,
                 sum(coalesce(x.awarded_points, 0)) as earned
            from public.placement_questions pq
            left join public.user_placement_answers x
                   on x.attempt_id = p_attempt_id and x.question_id = pq.question_id
           where pq.placement_test_id = v_test
           group by pq.competency) t;

  update public.user_placement_attempts
     set status = 'completed', completed_at = now(), score_pct = v_score,
         recommended_level_id = v_rec, competency_breakdown = v_breakdown
   where id = p_attempt_id;

  return jsonb_build_object('attempt_id', p_attempt_id, 'score_pct', v_score,
                            'recommended_level_id', v_rec,
                            'recommended_level_code', v_rec_code,
                            'competency_breakdown', v_breakdown);
end $$;

-- Define o nivel de estudo: recomendado ou inferior, nunca superior.
create or replace function public.select_starting_level(
  p_level_id uuid, p_placement_attempt_id uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_attempt uuid; v_ref uuid; v_ref_pos smallint; v_sel_pos smallint;
  v_has_active boolean; v_source text; v_first uuid;
begin
  select l.position into v_sel_pos from public.levels l where l.id = p_level_id;
  if not found then
    raise exception 'Nivel inexistente' using errcode = 'P0002';
  end if;

  if p_placement_attempt_id is not null then
    select a.id, a.recommended_level_id into v_attempt, v_ref
      from public.user_placement_attempts a
     where a.id = p_placement_attempt_id and a.user_id = v_uid and a.status = 'completed';
    if not found then
      raise exception 'Tentativa de nivelamento invalida' using errcode = '42501';
    end if;
  else
    select a.id, a.recommended_level_id into v_attempt, v_ref
      from public.user_placement_attempts a
     where a.user_id = v_uid and a.status = 'completed'
     order by a.completed_at desc limit 1;
  end if;

  if v_ref is null then                      -- sem teste: vale a autoavaliacao
    select p.self_assessed_level_id into v_ref from public.profiles p where p.id = v_uid;
  end if;
  if v_ref is null then                      -- sem nada: apenas o primeiro nivel
    select l.id into v_ref from public.levels l order by l.position limit 1;
  end if;

  select l.position into v_ref_pos from public.levels l where l.id = v_ref;
  if v_sel_pos > v_ref_pos then
    raise exception 'Nivel escolhido nao pode superar o nivel recomendado' using errcode = '22023';
  end if;

  v_first := private.first_published_module(p_level_id);
  if v_first is null then
    raise exception 'Nivel ainda sem modulos publicados' using errcode = 'P0002';
  end if;

  select exists (select 1 from public.user_level_history h
                  where h.user_id = v_uid and h.ended_at is null) into v_has_active;
  v_source := case
    when v_has_active then 'manual_change'
    when v_attempt is null then 'self_assessment'
    when p_level_id = v_ref then 'placement_recommended'
    else 'placement_lower' end;

  update public.user_level_history set ended_at = now()
   where user_id = v_uid and ended_at is null;
  insert into public.user_level_history (user_id, level_id, source, placement_attempt_id)
  values (v_uid, p_level_id, v_source, v_attempt);
  update public.profiles set current_level_id = p_level_id where id = v_uid;

  perform private.unlock_module(v_uid, v_first);
end $$;

-- ---------------------------------------------------------------------
-- 3. Curso: visao geral e aulas do modulo
-- ---------------------------------------------------------------------
create or replace function public.get_course_overview(p_level_id uuid default null)
returns table (
  module_id uuid, level_id uuid, "position" smallint, title text, description text,
  access_tier text, state text, required_lessons integer, completed_lessons integer,
  progress_pct numeric)
language sql stable security definer set search_path = '' as $$
  with ctx as (
    select auth.uid() as uid,
           private.has_premium_access(auth.uid()) as prem,
           coalesce(p_level_id,
                    (select p.current_level_id from public.profiles p where p.id = auth.uid())) as lvl
  )
  select m.id, m.level_id, m.position, m.title, m.description, m.access_tier,
         case
           when m.access_tier = 'premium' and not ctx.prem then 'locked_plan'
           when ump.status = 'completed'   then 'completed'
           when ump.status = 'in_progress' then 'in_progress'
           when ump.status = 'available'   then 'available'
           else 'locked'
         end,
         cnt.required, cnt.done,
         case when cnt.required > 0 then cnt.done * 100.0 / cnt.required else 0 end
  from ctx
  join public.modules m on m.level_id = ctx.lvl and m.is_published
  left join public.user_module_progress ump
         on ump.module_id = m.id and ump.user_id = ctx.uid
  cross join lateral (
    select count(*)::integer as required,
           (count(*) filter (where ulp.status = 'completed'))::integer as done
      from public.lessons l
      left join public.user_lesson_progress ulp
             on ulp.lesson_id = l.id and ulp.user_id = ctx.uid
     where l.module_id = m.id and l.is_required
       and exists (select 1 from public.lesson_versions lv
                    where lv.lesson_id = l.id and lv.is_published)
  ) cnt
  where ctx.uid is not null
  order by m.position
$$;

create or replace function public.get_module_lessons(p_module_id uuid)
returns table (
  lesson_id uuid, "position" smallint, title text, is_required boolean,
  status text, best_score numeric, needs_update boolean)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare v_uid uuid := private.require_user();
begin
  if not exists (select 1 from public.user_module_progress ump
                  where ump.user_id = v_uid and ump.module_id = p_module_id) then
    raise exception 'module_locked' using errcode = '42501';
  end if;
  if not private.module_plan_ok(v_uid, p_module_id) then
    raise exception 'premium_required' using errcode = '42501';
  end if;
  return query
    select l.id, l.position, cv.title, l.is_required,
           coalesce(ulp.status, 'not_started'), ulp.best_score,
           coalesce(ulp.needs_update, false)
      from public.lessons l
      join public.lesson_current_versions cv on cv.lesson_id = l.id
      left join public.user_lesson_progress ulp
             on ulp.lesson_id = l.id and ulp.user_id = v_uid
     where l.module_id = p_module_id
     order by l.position;
end $$;

-- ---------------------------------------------------------------------
-- 4. Aulas: tentativa, resposta, conclusao
-- ---------------------------------------------------------------------
create or replace function public.start_lesson_attempt(p_lesson_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_module uuid; v_version uuid; v_attempt uuid; v_total numeric;
begin
  select l.module_id into v_module from public.lessons l where l.id = p_lesson_id;
  if not found then
    raise exception 'Aula inexistente' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.user_module_progress ump
                  where ump.user_id = v_uid and ump.module_id = v_module) then
    raise exception 'module_locked' using errcode = '42501';
  end if;
  if not private.module_plan_ok(v_uid, v_module) then
    raise exception 'premium_required' using errcode = '42501';
  end if;

  select cv.lesson_version_id into v_version
    from public.lesson_current_versions cv where cv.lesson_id = p_lesson_id;
  if v_version is null then
    raise exception 'Aula sem versao publicada' using errcode = 'P0002';
  end if;

  select a.id into v_attempt from public.user_lesson_attempts a
   where a.user_id = v_uid and a.lesson_version_id = v_version and a.status = 'in_progress';

  if v_attempt is null then
    select coalesce(sum(q.weight), 0) into v_total
      from public.questions q
      left join public.exercises e on e.id = q.exercise_id
     where q.lesson_version_id = v_version
       and q.is_assessed and coalesce(e.is_assessed, true);
    insert into public.user_lesson_attempts (user_id, lesson_version_id, total_points)
    values (v_uid, v_version, v_total) returning id into v_attempt;
  end if;

  insert into public.user_lesson_progress (user_id, lesson_id, status, last_accessed_at)
  values (v_uid, p_lesson_id, 'in_progress', now())
  on conflict (user_id, lesson_id) do update
    set last_accessed_at = now(),
        status = case when public.user_lesson_progress.status = 'completed'
                      then 'completed' else 'in_progress' end;

  update public.user_module_progress
     set status = 'in_progress', started_at = coalesce(started_at, now())
   where user_id = v_uid and module_id = v_module and status = 'available';

  return v_attempt;
end $$;

create or replace function public.record_section_view(p_section_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_version uuid;
begin
  select s.lesson_version_id into v_version
    from public.lesson_sections s where s.id = p_section_id;
  if not found or not private.can_read_lesson_version(v_version) then
    raise exception 'Secao inacessivel' using errcode = '42501';
  end if;
  insert into public.user_section_progress (user_id, lesson_section_id)
  values (v_uid, p_section_id)
  on conflict (user_id, lesson_section_id) do update set last_viewed_at = now();
end $$;

-- Devolve apenas: correta?, pontos, explicacao. Nunca o gabarito em si.
create or replace function public.submit_lesson_answer(
  p_attempt_id uuid, p_question_id uuid, p_answer jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_version uuid; v_status text;
  v_weight numeric; v_assessed boolean;
  v_ok boolean; v_expl text; v_max numeric; v_awarded numeric;
begin
  select a.lesson_version_id, a.status into v_version, v_status
    from public.user_lesson_attempts a
   where a.id = p_attempt_id and a.user_id = v_uid
   for update;
  if not found then
    raise exception 'Tentativa nao encontrada' using errcode = '42501';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'Tentativa ja encerrada' using errcode = '55000';
  end if;

  select q.weight, (q.is_assessed and coalesce(e.is_assessed, true))
    into v_weight, v_assessed
    from public.questions q
    left join public.exercises e on e.id = q.exercise_id
   where q.id = p_question_id and q.lesson_version_id = v_version;
  if not found then
    raise exception 'Questao nao pertence a esta tentativa' using errcode = '23503';
  end if;
  if exists (select 1 from public.user_exercise_attempts x
              where x.lesson_attempt_id = p_attempt_id and x.question_id = p_question_id) then
    raise exception 'Questao ja respondida' using errcode = '23505';
  end if;

  select g.is_correct, g.explanation into v_ok, v_expl
    from private.grade_answer(p_question_id, p_answer) g;
  v_max := case when v_assessed then v_weight else 0 end;
  v_awarded := case when v_ok and v_assessed then v_weight else 0 end;

  insert into public.user_exercise_attempts
    (user_id, lesson_attempt_id, lesson_version_id, question_id,
     submitted_answer, is_correct, awarded_points, max_points)
  values (v_uid, p_attempt_id, v_version, p_question_id, p_answer, v_ok, v_awarded, v_max);

  return jsonb_build_object('is_correct', v_ok, 'awarded_points', v_awarded,
                            'max_points', v_max, 'explanation', v_expl);
end $$;

-- Regra de conclusao: secoes obrigatorias acessadas + todas as questoes avaliativas
-- respondidas + aproveitamento ponderado >= 80% (comparacao exata, sem arredondar).
create or replace function public.finish_lesson_attempt(p_attempt_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_version uuid; v_status text; v_lesson uuid; v_module uuid;
  v_total numeric; v_earned numeric; v_score numeric;
  v_sections_total integer; v_sections_seen integer;
  v_assessed_total integer; v_assessed_answered integer;
  v_score_ok boolean; v_sections_ok boolean; v_answered_ok boolean; v_passed boolean;
  v_module_done boolean := false;
  c_min_pct constant numeric := 80;
begin
  select a.lesson_version_id, a.status, a.total_points
    into v_version, v_status, v_total
    from public.user_lesson_attempts a
   where a.id = p_attempt_id and a.user_id = v_uid
   for update;
  if not found then
    raise exception 'Tentativa nao encontrada' using errcode = '42501';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'Tentativa ja encerrada' using errcode = '55000';
  end if;

  select lv.lesson_id, l.module_id into v_lesson, v_module
    from public.lesson_versions lv join public.lessons l on l.id = lv.lesson_id
   where lv.id = v_version;

  select coalesce(sum(x.awarded_points), 0),
         count(*) filter (where x.max_points > 0)
    into v_earned, v_assessed_answered
    from public.user_exercise_attempts x where x.lesson_attempt_id = p_attempt_id;

  select count(*) into v_assessed_total
    from public.questions q left join public.exercises e on e.id = q.exercise_id
   where q.lesson_version_id = v_version and q.is_assessed and coalesce(e.is_assessed, true);

  select count(*), count(usp.lesson_section_id)
    into v_sections_total, v_sections_seen
    from public.lesson_sections s
    left join public.user_section_progress usp
           on usp.lesson_section_id = s.id and usp.user_id = v_uid
   where s.lesson_version_id = v_version and s.is_required;

  v_score := case when v_total > 0 then v_earned * 100 / v_total else 0 end;
  v_score_ok := v_total > 0 and v_earned * 100 >= v_total * c_min_pct;
  v_sections_ok := v_sections_seen = v_sections_total;
  v_answered_ok := v_assessed_answered = v_assessed_total;
  v_passed := v_score_ok and v_sections_ok and v_answered_ok;

  update public.user_lesson_attempts
     set status = 'completed', earned_points = v_earned, score_pct = v_score,
         passed = v_passed, completed_at = now()
   where id = p_attempt_id;

  insert into public.user_lesson_progress
    (user_id, lesson_id, status, best_score, attempt_count,
     completed_at, completed_version_id, last_accessed_at)
  values
    (v_uid, v_lesson, case when v_passed then 'completed' else 'in_progress' end,
     v_score, 1,
     case when v_passed then now() end, case when v_passed then v_version end, now())
  on conflict (user_id, lesson_id) do update set
    attempt_count = public.user_lesson_progress.attempt_count + 1,
    best_score = greatest(public.user_lesson_progress.best_score, excluded.best_score),
    last_accessed_at = now(),
    status = case when public.user_lesson_progress.status = 'completed'
                    or excluded.status = 'completed' then 'completed' else 'in_progress' end,
    completed_at = coalesce(public.user_lesson_progress.completed_at, excluded.completed_at),
    completed_version_id = case when excluded.status = 'completed'
                                then excluded.completed_version_id
                                else public.user_lesson_progress.completed_version_id end,
    needs_update = case when excluded.status = 'completed' then false
                        else public.user_lesson_progress.needs_update end;

  -- Dominio por topico (formula provisoria: % de acertos acumulado)
  insert into public.user_topic_mastery
    (user_id, grammar_topic_id, attempts_count, correct_count, mastery_score, last_practiced_at)
  select v_uid, q.grammar_topic_id, count(*), count(*) filter (where x.is_correct),
         count(*) filter (where x.is_correct) * 100.0 / count(*), now()
    from public.user_exercise_attempts x join public.questions q on q.id = x.question_id
   where x.lesson_attempt_id = p_attempt_id and q.grammar_topic_id is not null
   group by q.grammar_topic_id
  on conflict (user_id, grammar_topic_id) do update set
    attempts_count = public.user_topic_mastery.attempts_count + excluded.attempts_count,
    correct_count  = public.user_topic_mastery.correct_count + excluded.correct_count,
    mastery_score  = (public.user_topic_mastery.correct_count + excluded.correct_count) * 100.0
                     / (public.user_topic_mastery.attempts_count + excluded.attempts_count),
    last_practiced_at = now();

  -- Erros entram na fila de revisao (REV-01)
  insert into public.review_schedule (user_id, question_id, due_at)
  select v_uid, x.question_id, now() + interval '1 day'
    from public.user_exercise_attempts x
   where x.lesson_attempt_id = p_attempt_id and not x.is_correct and x.max_points > 0
  on conflict (user_id, question_id) where question_id is not null do nothing;

  if v_passed then
    v_module_done := private.evaluate_module_completion(v_uid, v_module);
  end if;

  return jsonb_build_object(
    'attempt_id', p_attempt_id, 'score_pct', v_score, 'passed', v_passed,
    'score_ok', v_score_ok, 'sections_complete', v_sections_ok,
    'all_questions_answered', v_answered_ok, 'module_completed', v_module_done);
end $$;

-- ---------------------------------------------------------------------
-- 5. Revisao espacada (SM-2 adaptado)
-- ---------------------------------------------------------------------
create or replace function public.record_review_result(
  p_vocabulary_id uuid default null,
  p_grammar_topic_id uuid default null,
  p_question_id uuid default null,
  p_quality smallint default 3)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_row public.review_schedule%rowtype;
  v_reps integer; v_interval numeric; v_ease numeric; v_lapses integer;
begin
  if num_nonnulls(p_vocabulary_id, p_grammar_topic_id, p_question_id) <> 1 then
    raise exception 'Informe exatamente um item de revisao' using errcode = '22023';
  end if;
  if p_quality is null or p_quality not between 0 and 5 then
    raise exception 'Qualidade deve estar entre 0 e 5' using errcode = '22023';
  end if;

  if p_vocabulary_id is not null and not exists (
       select 1 from public.vocabulary v
        where v.id = p_vocabulary_id and v.is_published
          and (v.access_tier = 'free' or private.has_premium_access(v_uid))) then
    raise exception 'Palavra inacessivel' using errcode = '42501';
  end if;
  if p_grammar_topic_id is not null and not exists (
       select 1 from public.grammar_topics t
        where t.id = p_grammar_topic_id and t.is_published
          and (t.access_tier = 'free' or private.has_premium_access(v_uid))) then
    raise exception 'Topico inacessivel' using errcode = '42501';
  end if;
  if p_question_id is not null and not private.can_read_question(p_question_id) then
    raise exception 'Questao inacessivel' using errcode = '42501';
  end if;

  select * into v_row from public.review_schedule r
   where r.user_id = v_uid
     and r.vocabulary_id    is not distinct from p_vocabulary_id
     and r.grammar_topic_id is not distinct from p_grammar_topic_id
     and r.question_id      is not distinct from p_question_id
   for update;

  v_reps     := coalesce(v_row.repetitions, 0);
  v_interval := coalesce(v_row.interval_days, 0);
  v_ease     := coalesce(v_row.ease_factor, 2.5);
  v_lapses   := coalesce(v_row.lapses, 0);

  if p_quality < 3 then
    v_reps := 0; v_interval := 1; v_lapses := v_lapses + 1;
  else
    v_reps := v_reps + 1;
    v_interval := case v_reps when 1 then 1 when 2 then 6
                  else greatest(1, round(v_interval * v_ease)) end;
  end if;
  v_ease := greatest(1.3, v_ease + (0.1 - (5 - p_quality) * (0.08 + (5 - p_quality) * 0.02)));

  if v_row.id is null then
    insert into public.review_schedule
      (user_id, vocabulary_id, grammar_topic_id, question_id, due_at, interval_days,
       ease_factor, repetitions, lapses, last_quality, last_reviewed_at)
    values (v_uid, p_vocabulary_id, p_grammar_topic_id, p_question_id,
            now() + make_interval(days => v_interval::integer), v_interval,
            v_ease, v_reps, v_lapses, p_quality, now());
  else
    update public.review_schedule
       set due_at = now() + make_interval(days => v_interval::integer),
           interval_days = v_interval, ease_factor = v_ease, repetitions = v_reps,
           lapses = v_lapses, last_quality = p_quality, last_reviewed_at = now()
     where id = v_row.id;
  end if;

  return jsonb_build_object('next_review_in_days', v_interval, 'ease_factor', v_ease,
                            'repetitions', v_reps);
end $$;

create or replace function public.refresh_my_unlocks() returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.reevaluate_unlocks(private.require_user());
end $$;

-- ---------------------------------------------------------------------
-- 6. Permissoes de execucao: somente usuarios autenticados chamam as RPCs
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.start_placement_attempt(uuid)',
    'public.submit_placement_answer(uuid, uuid, jsonb)',
    'public.finish_placement_attempt(uuid)',
    'public.select_starting_level(uuid, uuid)',
    'public.get_course_overview(uuid)',
    'public.get_module_lessons(uuid)',
    'public.start_lesson_attempt(uuid)',
    'public.record_section_view(uuid)',
    'public.submit_lesson_answer(uuid, uuid, jsonb)',
    'public.finish_lesson_attempt(uuid)',
    'public.record_review_result(uuid, uuid, uuid, smallint)',
    'public.refresh_my_unlocks()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- Funcoes do schema private: nada para anon/public; sem acesso do app.
revoke all on all functions in schema private from public, anon;
grant execute on function private.has_premium_access(uuid)      to authenticated;
grant execute on function private.is_content_admin()            to authenticated;
grant execute on function private.module_plan_ok(uuid, uuid)    to authenticated;
grant execute on function private.can_read_lesson_version(uuid) to authenticated;
grant execute on function private.can_read_question(uuid)       to authenticated;
