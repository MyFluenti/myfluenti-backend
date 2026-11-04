-- =====================================================================
-- MyFluenti - Migration 002: helpers de acesso, grants e politicas RLS
-- Principios: negar por padrao; aluno so le o que e dele ou o que seu plano
-- e sua progressao liberam; TODA escrita de progresso passa por funcoes
-- (migration 003); gabaritos ficam no schema private, sem acesso do app.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Helpers de acesso (security definer, sem recursao de RLS)
-- ---------------------------------------------------------------------
create or replace function private.has_premium_access(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.user_subscriptions s
    join public.subscription_plans p on p.id = s.plan_id
    where s.user_id = p_user
      and p.tier = 'premium'
      and s.status in ('active','trialing')
      and (s.current_period_end is null or s.current_period_end > now())
  )
$$;

create or replace function private.is_content_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles r
    where r.user_id = auth.uid() and r.role = 'content_admin'
  )
$$;

-- Modulo publicado e permitido pelo plano do aluno.
create or replace function private.module_plan_ok(p_user uuid, p_module uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.modules m
    where m.id = p_module and m.is_published
      and (m.access_tier = 'free' or private.has_premium_access(p_user))
  )
$$;

-- Versao publicada, de modulo liberado ao aluno e permitido pelo plano.
create or replace function private.can_read_lesson_version(p_version uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.lesson_versions lv
    join public.lessons l on l.id = lv.lesson_id
    join public.user_module_progress ump
      on ump.module_id = l.module_id and ump.user_id = auth.uid()
    where lv.id = p_version
      and lv.is_published
      and private.module_plan_ok(auth.uid(), l.module_id)
  )
$$;

-- Questao legivel: da aula acessivel, do nivelamento em andamento ou da fila de revisao.
create or replace function private.can_read_question(p_question uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.questions q
    where q.id = p_question
      and (
        (q.lesson_version_id is not null and private.can_read_lesson_version(q.lesson_version_id))
        or exists (
          select 1
          from public.user_placement_attempts a
          join public.placement_questions pq on pq.placement_test_id = a.placement_test_id
          where a.user_id = auth.uid() and a.status = 'in_progress' and pq.question_id = q.id)
        or exists (
          select 1 from public.review_schedule rs
          where rs.user_id = auth.uid() and rs.question_id = q.id)
      )
  )
$$;

grant usage on schema private to authenticated;
revoke all on function private.has_premium_access(uuid)        from public, anon;
revoke all on function private.is_content_admin()              from public, anon;
revoke all on function private.module_plan_ok(uuid, uuid)      from public, anon;
revoke all on function private.can_read_lesson_version(uuid)   from public, anon;
revoke all on function private.can_read_question(uuid)         from public, anon;
grant execute on function private.has_premium_access(uuid)      to authenticated;
grant execute on function private.is_content_admin()            to authenticated;
grant execute on function private.module_plan_ok(uuid, uuid)    to authenticated;
grant execute on function private.can_read_lesson_version(uuid) to authenticated;
grant execute on function private.can_read_question(uuid)      to authenticated;

-- ---------------------------------------------------------------------
-- 2. Grants: comeca do zero e libera o minimo
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema private revoke all on tables from public, anon, authenticated;

-- Leitura (o RLS decide as linhas)
grant select on
  public.levels, public.modules, public.lessons, public.lesson_versions,
  public.lesson_sections, public.exercises, public.lesson_grammar_topics,
  public.grammar_topics, public.questions, public.answer_options,
  public.placement_tests, public.placement_questions,
  public.vocabulary, public.vocabulary_forms, public.vocabulary_examples,
  public.subscription_plans, public.lesson_current_versions,
  public.profiles, public.user_roles, public.user_level_history,
  public.user_placement_attempts, public.user_lesson_attempts,
  public.user_exercise_attempts, public.review_sessions,
  public.user_lesson_progress, public.user_module_progress,
  public.user_section_progress, public.user_topic_mastery,
  public.review_schedule, public.user_subscriptions,
  public.user_vocabulary, public.user_notes
to authenticated;
-- user_placement_answers: sem SELECT para o app (evita extrair gabarito do nivelamento).

-- Escrita direta do aluno: apenas dados pessoais e colecoes proprias.
grant update (display_name, avatar_url, locale, self_assessed_level_id, onboarding_completed_at)
  on public.profiles to authenticated;
grant insert, update, delete on public.user_vocabulary, public.user_notes to authenticated;

-- Escrita de conteudo: concedida, mas so passa pelas politicas de content_admin.
grant insert, update, delete on
  public.levels, public.modules, public.lessons, public.lesson_versions,
  public.lesson_sections, public.exercises, public.lesson_grammar_topics,
  public.grammar_topics, public.questions, public.answer_options,
  public.placement_tests, public.placement_questions,
  public.vocabulary, public.vocabulary_forms, public.vocabulary_examples,
  public.subscription_plans
to authenticated;

-- ---------------------------------------------------------------------
-- 3. RLS ligado em tudo (private sem politicas = acesso negado)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  for t in
    select format('%I.%I', schemaname, tablename)
    from pg_tables where schemaname in ('public','private')
  loop
    execute format('alter table %s enable row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Politicas de conteudo (leitura do aluno)
-- ---------------------------------------------------------------------
create policy levels_read on public.levels
  for select to authenticated using (true);

create policy modules_read on public.modules
  for select to authenticated using (is_published);

create policy lessons_read on public.lessons
  for select to authenticated
  using (exists (select 1 from public.modules m where m.id = module_id and m.is_published));

create policy lesson_versions_read on public.lesson_versions
  for select to authenticated using (private.can_read_lesson_version(id));

create policy lesson_sections_read on public.lesson_sections
  for select to authenticated using (private.can_read_lesson_version(lesson_version_id));

create policy exercises_read on public.exercises
  for select to authenticated using (private.can_read_lesson_version(lesson_version_id));

create policy lesson_grammar_topics_read on public.lesson_grammar_topics
  for select to authenticated using (private.can_read_lesson_version(lesson_version_id));

create policy questions_read on public.questions
  for select to authenticated using (private.can_read_question(id));

create policy answer_options_read on public.answer_options
  for select to authenticated using (private.can_read_question(question_id));

create policy grammar_topics_read on public.grammar_topics
  for select to authenticated
  using (is_published and (access_tier = 'free' or private.has_premium_access((select auth.uid()))));

create policy vocabulary_read on public.vocabulary
  for select to authenticated
  using (is_published and (access_tier = 'free' or private.has_premium_access((select auth.uid()))));

create policy vocabulary_forms_read on public.vocabulary_forms
  for select to authenticated
  using (exists (select 1 from public.vocabulary v where v.id = vocabulary_id));

create policy vocabulary_examples_read on public.vocabulary_examples
  for select to authenticated
  using (exists (select 1 from public.vocabulary v where v.id = vocabulary_id));

create policy placement_tests_read on public.placement_tests
  for select to authenticated using (is_published);

-- placement_questions: sem politica de aluno (peso e dificuldade nao sao expostos).
-- O app usa a view public.placement_test_items (abaixo).

create policy subscription_plans_read on public.subscription_plans
  for select to authenticated using (is_active);

-- ---------------------------------------------------------------------
-- 5. Politicas de dados do aluno
-- ---------------------------------------------------------------------
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy user_roles_select_own on public.user_roles
  for select to authenticated using (user_id = (select auth.uid()));

-- Tabelas somente-leitura para o aluno (escrita via funcoes)
do $$
declare t text;
begin
  foreach t in array array[
    'user_level_history','user_placement_attempts','user_lesson_attempts',
    'user_exercise_attempts','review_sessions','user_lesson_progress',
    'user_module_progress','user_section_progress','user_topic_mastery',
    'review_schedule','user_subscriptions'
  ] loop
    execute format(
      'create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))',
      t || '_select_own', t);
  end loop;
end $$;

-- Colecoes pessoais (CRUD proprio)
create policy user_vocabulary_select_own on public.user_vocabulary
  for select to authenticated using (user_id = (select auth.uid()));
create policy user_vocabulary_insert_own on public.user_vocabulary
  for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.vocabulary v where v.id = vocabulary_id));
create policy user_vocabulary_update_own on public.user_vocabulary
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy user_vocabulary_delete_own on public.user_vocabulary
  for delete to authenticated using (user_id = (select auth.uid()));

create policy user_notes_select_own on public.user_notes
  for select to authenticated using (user_id = (select auth.uid()));
create policy user_notes_insert_own on public.user_notes
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy user_notes_update_own on public.user_notes
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy user_notes_delete_own on public.user_notes
  for delete to authenticated using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- 6. Administracao de conteudo (papel content_admin)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'levels','modules','lessons','lesson_versions','lesson_sections','exercises',
    'lesson_grammar_topics','grammar_topics','questions','answer_options',
    'placement_tests','placement_questions','vocabulary','vocabulary_forms',
    'vocabulary_examples','subscription_plans'
  ] loop
    execute format(
      'create policy %I on public.%I for all to authenticated using (private.is_content_admin()) with check (private.is_content_admin())',
      t || '_admin_all', t);
  end loop;
end $$;
-- Gabaritos (private.*) sao gerenciados por service_role / painel, nunca pelo app.

-- ---------------------------------------------------------------------
-- 7. Itens do teste de nivelamento em andamento (sem peso/dificuldade)
-- ---------------------------------------------------------------------
create view public.placement_test_items as
select pq.placement_test_id, pq.question_id, pq.position, pq.competency
from public.placement_questions pq
where exists (
  select 1 from public.user_placement_attempts a
  where a.user_id = auth.uid()
    and a.placement_test_id = pq.placement_test_id
    and a.status = 'in_progress'
);
revoke all on public.placement_test_items from public, anon;
grant select on public.placement_test_items to authenticated;
