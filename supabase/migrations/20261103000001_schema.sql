-- =====================================================================
-- MyFluenti - Migration 001: schema, constraints, indices e triggers
-- Base: Dicionario de Dados v1.0 (03/11/2026)
-- Convencoes: PK uuid; datas timestamptz; enums como text + CHECK;
-- notas em numeric sem arredondar; gabaritos no schema "private".
-- =====================================================================

create schema if not exists private;
revoke all on schema private from public;

-- ---------------------------------------------------------------------
-- Utilitarios
-- ---------------------------------------------------------------------
create or replace function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- =====================================================================
-- 1. CURRICULO
-- =====================================================================
create table public.levels (
  id        uuid primary key default gen_random_uuid(),
  code      text not null unique check (code in ('A1','A2','B1','B2','C1','C2')),
  title     text not null,
  position  smallint not null unique check (position between 1 and 6)
);

create table public.modules (
  id            uuid primary key default gen_random_uuid(),
  level_id      uuid not null references public.levels(id),
  title         text not null,
  description   text,
  position      smallint not null check (position > 0),
  access_tier   text not null default 'free' check (access_tier in ('free','premium')),
  is_published  boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (level_id, position)
);

create table public.lessons (
  id           uuid primary key default gen_random_uuid(),
  module_id    uuid not null references public.modules(id),
  slug         text not null unique,
  position     smallint not null check (position > 0),
  is_required  boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (module_id, position)
);

create table public.lesson_versions (
  id                    uuid primary key default gen_random_uuid(),
  lesson_id             uuid not null references public.lessons(id),
  version_number        integer not null check (version_number > 0),
  title                 text not null,
  objective             text,
  is_published          boolean not null default false,
  published_at          timestamptz,
  change_note           text,
  requires_relearning   boolean not null default false,
  created_at            timestamptz not null default now(),
  unique (lesson_id, version_number),
  unique (id, lesson_id),
  constraint lesson_versions_published_consistency
    check (is_published = (published_at is not null))
);

create table public.grammar_topics (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  title         text not null,
  category      text not null,
  summary       text,
  content       jsonb not null default '{}'::jsonb,
  level_id      uuid references public.levels(id),
  access_tier   text not null default 'free' check (access_tier in ('free','premium')),
  is_published  boolean not null default false,
  created_at    timestamptz not null default now()
);

create table public.lesson_sections (
  id                 uuid primary key default gen_random_uuid(),
  lesson_version_id  uuid not null references public.lesson_versions(id) on delete cascade,
  position           smallint not null check (position > 0),
  section_type       text not null check (section_type in
                       ('intro','explanation','structure','examples','comparison','summary')),
  title              text,
  content            jsonb not null default '{}'::jsonb,
  is_required        boolean not null default true,
  unique (lesson_version_id, position)
);

create table public.exercises (
  id                 uuid primary key default gen_random_uuid(),
  lesson_version_id  uuid not null references public.lesson_versions(id) on delete cascade,
  position           smallint not null check (position > 0),
  title              text,
  instructions       text,
  is_assessed        boolean not null default true,
  unique (lesson_version_id, position),
  unique (id, lesson_version_id)
);

create table public.lesson_grammar_topics (
  lesson_version_id  uuid not null references public.lesson_versions(id) on delete cascade,
  grammar_topic_id   uuid not null references public.grammar_topics(id),
  is_primary         boolean not null default false,
  primary key (lesson_version_id, grammar_topic_id)
);

-- =====================================================================
-- 2. QUESTOES E GABARITO
-- =====================================================================
-- lesson_version_id NULL = questao do banco de nivelamento/revisao.
create table public.questions (
  id                 uuid primary key default gen_random_uuid(),
  lesson_version_id  uuid references public.lesson_versions(id) on delete cascade,
  exercise_id        uuid,
  question_type      text not null check (question_type in
                       ('multiple_choice','fill_blank','word_order','translation',
                        'error_identification','error_correction')),
  prompt             text not null,
  prompt_data        jsonb not null default '{}'::jsonb,
  weight             numeric not null default 1 check (weight > 0),
  is_assessed        boolean not null default true,
  position           smallint,
  grammar_topic_id   uuid references public.grammar_topics(id),
  created_at         timestamptz not null default now(),
  constraint questions_exercise_needs_version
    check (exercise_id is null or lesson_version_id is not null),
  constraint questions_exercise_same_version
    foreign key (exercise_id, lesson_version_id)
    references public.exercises(id, lesson_version_id) on delete cascade,
  constraint questions_version_id_uk unique (lesson_version_id, id)
);

create table public.answer_options (
  id           uuid primary key default gen_random_uuid(),
  question_id  uuid not null references public.questions(id) on delete cascade,
  option_text  text not null,
  position     smallint not null check (position > 0),
  unique (question_id, position),
  unique (question_id, id)
);

create table private.question_answer_keys (
  question_id        uuid primary key references public.questions(id) on delete cascade,
  correct_option_id  uuid,
  grading_rules      jsonb not null default '{}'::jsonb,
  explanation        text,
  constraint keys_option_belongs_to_question
    foreign key (question_id, correct_option_id)
    references public.answer_options(question_id, id)
);

create table private.accepted_answers (
  id               uuid primary key default gen_random_uuid(),
  question_id      uuid not null references public.questions(id) on delete cascade,
  answer_text      text not null,
  normalized_text  text not null,
  is_primary       boolean not null default false,
  unique (question_id, normalized_text)
);

-- =====================================================================
-- 3. NIVELAMENTO
-- =====================================================================
create table public.placement_tests (
  id               uuid primary key default gen_random_uuid(),
  code             text not null,
  version_number   integer not null check (version_number > 0),
  title            text not null,
  total_questions  smallint not null check (total_questions > 0),
  is_published     boolean not null default false,
  published_at     timestamptz,
  created_at       timestamptz not null default now(),
  unique (code, version_number),
  constraint placement_tests_published_consistency
    check (is_published = (published_at is not null))
);

create table public.placement_questions (
  placement_test_id    uuid not null references public.placement_tests(id) on delete cascade,
  question_id          uuid not null references public.questions(id),
  competency           text not null check (competency in
                         ('vocabulary','grammar','reading','construction')),
  difficulty_level_id  uuid not null references public.levels(id),
  weight               numeric not null check (weight > 0),
  position             smallint not null check (position > 0),
  primary key (placement_test_id, question_id),
  unique (placement_test_id, position)
);

-- =====================================================================
-- 4. USUARIO
-- =====================================================================
create table public.profiles (
  id                       uuid primary key references auth.users(id) on delete cascade,
  display_name             text,
  avatar_url               text,
  locale                   text not null default 'pt-BR',
  self_assessed_level_id   uuid references public.levels(id),
  current_level_id         uuid references public.levels(id),
  onboarding_completed_at  timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create table public.user_roles (
  user_id  uuid not null references auth.users(id) on delete cascade,
  role     text not null check (role in ('student','content_admin','support')),
  primary key (user_id, role)
);

create table public.user_placement_attempts (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  placement_test_id     uuid not null references public.placement_tests(id),
  status                text not null default 'in_progress'
                          check (status in ('in_progress','completed','abandoned')),
  score_pct             numeric,
  recommended_level_id  uuid references public.levels(id),
  competency_breakdown  jsonb,
  started_at            timestamptz not null default now(),
  completed_at          timestamptz,
  unique (id, placement_test_id),
  unique (id, user_id),
  constraint placement_attempt_completed_fields
    check (status <> 'completed'
           or (completed_at is not null and score_pct is not null
               and recommended_level_id is not null))
);

create table public.user_placement_answers (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  attempt_id         uuid not null,
  placement_test_id  uuid not null,
  question_id        uuid not null,
  submitted_answer   jsonb not null,
  is_correct         boolean not null,
  awarded_points     numeric not null check (awarded_points >= 0),
  answered_at        timestamptz not null default now(),
  unique (attempt_id, question_id),
  foreign key (attempt_id, placement_test_id)
    references public.user_placement_attempts(id, placement_test_id),
  foreign key (attempt_id, user_id)
    references public.user_placement_attempts(id, user_id),
  foreign key (placement_test_id, question_id)
    references public.placement_questions(placement_test_id, question_id)
);

create table public.user_level_history (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  level_id              uuid not null references public.levels(id),
  source                text not null check (source in
                          ('placement_recommended','placement_lower','self_assessment','manual_change')),
  placement_attempt_id  uuid references public.user_placement_attempts(id),
  started_at            timestamptz not null default now(),
  ended_at              timestamptz
);
create unique index user_level_history_one_active
  on public.user_level_history (user_id) where ended_at is null;

-- =====================================================================
-- 5. TENTATIVAS E PROGRESSO
-- =====================================================================
create table public.user_lesson_attempts (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  lesson_version_id  uuid not null references public.lesson_versions(id),
  status             text not null default 'in_progress'
                       check (status in ('in_progress','completed','abandoned')),
  earned_points      numeric not null default 0 check (earned_points >= 0),
  total_points       numeric not null default 0 check (total_points >= 0),
  score_pct          numeric,
  passed             boolean not null default false,
  started_at         timestamptz not null default now(),
  completed_at       timestamptz,
  unique (id, lesson_version_id),
  unique (id, user_id),
  constraint lesson_attempt_completed_fields
    check (status <> 'completed' or (completed_at is not null and score_pct is not null)),
  constraint lesson_attempt_passed_needs_completed
    check (not passed or status = 'completed')
);

create table public.review_sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  started_at    timestamptz not null default now(),
  completed_at  timestamptz,
  unique (id, user_id)
);

create table public.user_exercise_attempts (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  lesson_attempt_id  uuid,
  lesson_version_id  uuid,
  review_session_id  uuid,
  question_id        uuid not null references public.questions(id),
  submitted_answer   jsonb not null,
  is_correct         boolean not null,
  awarded_points     numeric not null check (awarded_points >= 0),
  max_points         numeric not null check (max_points >= 0),
  answered_at        timestamptz not null default now(),
  constraint exercise_attempt_one_context
    check (num_nonnulls(lesson_attempt_id, review_session_id) = 1),
  constraint exercise_attempt_version_matches_attempt
    check ((lesson_attempt_id is null) = (lesson_version_id is null)),
  constraint exercise_attempt_points_within_max check (awarded_points <= max_points),
  foreign key (lesson_attempt_id, lesson_version_id)
    references public.user_lesson_attempts(id, lesson_version_id),
  foreign key (lesson_attempt_id, user_id)
    references public.user_lesson_attempts(id, user_id),
  foreign key (lesson_version_id, question_id)
    references public.questions(lesson_version_id, id),
  foreign key (review_session_id, user_id)
    references public.review_sessions(id, user_id)
);
create unique index user_exercise_attempts_one_answer_per_question
  on public.user_exercise_attempts (lesson_attempt_id, question_id)
  where lesson_attempt_id is not null;

create table public.user_lesson_progress (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  lesson_id             uuid not null references public.lessons(id),
  status                text not null default 'not_started'
                          check (status in ('not_started','in_progress','completed')),
  best_score            numeric,
  attempt_count         integer not null default 0 check (attempt_count >= 0),
  completed_at          timestamptz,
  completed_version_id  uuid references public.lesson_versions(id),
  needs_update          boolean not null default false,
  last_accessed_at      timestamptz,
  unique (user_id, lesson_id),
  constraint lesson_progress_completed_fields
    check (status <> 'completed' or (completed_at is not null and completed_version_id is not null))
);

create table public.user_section_progress (
  user_id            uuid not null references auth.users(id) on delete cascade,
  lesson_section_id  uuid not null references public.lesson_sections(id) on delete cascade,
  first_viewed_at    timestamptz not null default now(),
  last_viewed_at     timestamptz not null default now(),
  primary key (user_id, lesson_section_id)
);

-- Linha criada somente quando o modulo e liberado (nao existe "locked").
create table public.user_module_progress (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  module_id     uuid not null references public.modules(id),
  status        text not null default 'available'
                  check (status in ('available','in_progress','completed')),
  unlocked_at   timestamptz not null default now(),
  started_at    timestamptz,
  completed_at  timestamptz,
  unique (user_id, module_id)
);

create table public.user_topic_mastery (
  user_id            uuid not null references auth.users(id) on delete cascade,
  grammar_topic_id   uuid not null references public.grammar_topics(id),
  mastery_score      numeric not null default 0 check (mastery_score between 0 and 100),
  attempts_count     integer not null default 0,
  correct_count      integer not null default 0,
  last_practiced_at  timestamptz,
  primary key (user_id, grammar_topic_id)
);

-- =====================================================================
-- 6. BIBLIOTECA E VOCABULARIO
-- =====================================================================
create table public.vocabulary (
  id              uuid primary key default gen_random_uuid(),
  lemma           text not null,
  part_of_speech  text not null check (part_of_speech in
                    ('verb','noun','adjective','adverb','expression','phrasal_verb')),
  meaning_pt      text not null,
  level_id        uuid references public.levels(id),
  access_tier     text not null default 'free' check (access_tier in ('free','premium')),
  is_published    boolean not null default false,
  unique (lemma, part_of_speech)
);

create table public.vocabulary_forms (
  id             uuid primary key default gen_random_uuid(),
  vocabulary_id  uuid not null references public.vocabulary(id) on delete cascade,
  form_label     text not null check (form_label in
                   ('base','third_person','past','past_participle','gerund',
                    'plural','comparative','superlative')),
  form_text      text not null,
  meaning_pt     text,
  unique (vocabulary_id, form_label)
);

create table public.vocabulary_examples (
  id             uuid primary key default gen_random_uuid(),
  vocabulary_id  uuid not null references public.vocabulary(id) on delete cascade,
  example_en     text not null,
  example_pt     text not null,
  position       smallint
);

create table public.user_vocabulary (
  user_id        uuid not null references auth.users(id) on delete cascade,
  vocabulary_id  uuid not null references public.vocabulary(id),
  is_favorite    boolean not null default false,
  is_learned     boolean not null default false,
  learned_at     timestamptz,
  primary key (user_id, vocabulary_id)
);

create table public.user_notes (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  lesson_id         uuid references public.lessons(id),
  grammar_topic_id  uuid references public.grammar_topics(id),
  vocabulary_id     uuid references public.vocabulary(id),
  body              text not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint user_notes_one_target
    check (num_nonnulls(lesson_id, grammar_topic_id, vocabulary_id) = 1)
);

-- =====================================================================
-- 7. REVISAO ESPACADA (inspirada no SM-2)
-- =====================================================================
create table public.review_schedule (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  vocabulary_id     uuid references public.vocabulary(id),
  grammar_topic_id  uuid references public.grammar_topics(id),
  question_id       uuid references public.questions(id),
  due_at            timestamptz not null,
  interval_days     numeric not null default 0,
  ease_factor       numeric not null default 2.5 check (ease_factor >= 1.3),
  repetitions       integer not null default 0,
  lapses            integer not null default 0,
  last_quality      smallint check (last_quality between 0 and 5),
  last_reviewed_at  timestamptz,
  constraint review_schedule_one_item
    check (num_nonnulls(vocabulary_id, grammar_topic_id, question_id) = 1)
);
create unique index review_schedule_uk_vocab    on public.review_schedule (user_id, vocabulary_id)    where vocabulary_id is not null;
create unique index review_schedule_uk_topic    on public.review_schedule (user_id, grammar_topic_id) where grammar_topic_id is not null;
create unique index review_schedule_uk_question on public.review_schedule (user_id, question_id)     where question_id is not null;

-- =====================================================================
-- 8. COMERCIAL
-- =====================================================================
create table public.subscription_plans (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  tier       text not null check (tier in ('free','premium')),
  is_active  boolean not null default true
);

create table public.user_subscriptions (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references auth.users(id) on delete cascade,
  plan_id                   uuid not null references public.subscription_plans(id),
  status                    text not null check (status in
                              ('active','trialing','past_due','canceled','expired')),
  current_period_end        timestamptz,
  provider                  text,
  provider_subscription_id  text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

-- =====================================================================
-- 9. INDICES (alem dos criados por PK/UNIQUE)
-- =====================================================================
create index lesson_versions_published_idx on public.lesson_versions (lesson_id, version_number desc) where is_published;
create index lesson_sections_version_idx on public.lesson_sections (lesson_version_id, position);
create index exercises_version_idx on public.exercises (lesson_version_id, position);
create index questions_version_exercise_idx on public.questions (lesson_version_id, exercise_id, position);
create index questions_grammar_topic_idx on public.questions (grammar_topic_id);
create index answer_options_question_idx on public.answer_options (question_id, position);
create index placement_questions_question_idx on public.placement_questions (question_id);
create index placement_questions_level_idx on public.placement_questions (difficulty_level_id);
create index user_placement_attempts_user_idx on public.user_placement_attempts (user_id, started_at desc);
create index user_placement_answers_attempt_idx on public.user_placement_answers (attempt_id);
create index user_level_history_user_idx on public.user_level_history (user_id, started_at desc);
create index user_lesson_attempts_user_idx on public.user_lesson_attempts (user_id, lesson_version_id, started_at desc);
create index user_exercise_attempts_attempt_idx on public.user_exercise_attempts (lesson_attempt_id);
create index user_exercise_attempts_review_idx on public.user_exercise_attempts (review_session_id);
create index user_exercise_attempts_user_question_idx on public.user_exercise_attempts (user_id, question_id);
create index user_lesson_progress_status_idx on public.user_lesson_progress (user_id, status);
create index user_module_progress_status_idx on public.user_module_progress (user_id, status);
create index user_module_progress_module_idx on public.user_module_progress (module_id);
create index review_schedule_due_idx on public.review_schedule (user_id, due_at);
create index user_subscriptions_access_idx on public.user_subscriptions (user_id, status, current_period_end);
create index grammar_topics_access_idx on public.grammar_topics (access_tier, is_published);
create index vocabulary_access_idx on public.vocabulary (access_tier, is_published);
create index vocabulary_lemma_idx on public.vocabulary (lower(lemma) text_pattern_ops);
create index user_notes_user_idx on public.user_notes (user_id);
create index lessons_module_idx on public.lessons (module_id, position);

-- =====================================================================
-- 10. VIEW DA VERSAO ATUAL (maior numero publicado por aula)
-- =====================================================================
create view public.lesson_current_versions
with (security_invoker = true) as
select distinct on (lv.lesson_id)
       lv.id as lesson_version_id, lv.lesson_id, lv.version_number, lv.title, lv.objective, lv.published_at
from public.lesson_versions lv
where lv.is_published
order by lv.lesson_id, lv.version_number desc;

-- =====================================================================
-- 11. TRIGGERS DE INTEGRIDADE E IMUTABILIDADE
-- =====================================================================
create trigger modules_touch before update on public.modules
  for each row execute function private.touch_updated_at();
create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();
create trigger user_notes_touch before update on public.user_notes
  for each row execute function private.touch_updated_at();
create trigger user_subscriptions_touch before update on public.user_subscriptions
  for each row execute function private.touch_updated_at();

-- 11.1 Versao de aula publicada e imutavel; publicar exige questao avaliativa.
create or replace function private.guard_lesson_version() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.is_published then
      raise exception 'Versao publicada nao pode ser removida' using errcode = '55000';
    end if;
    return old;
  end if;
  if old.is_published then
    raise exception 'Versao publicada e imutavel; crie uma nova versao' using errcode = '55000';
  end if;
  if new.is_published then
    if not exists (
      select 1
      from public.questions q
      left join public.exercises e on e.id = q.exercise_id
      where q.lesson_version_id = new.id
        and q.is_assessed and coalesce(e.is_assessed, true)
    ) then
      raise exception 'Versao sem questoes avaliativas nao pode ser publicada' using errcode = '23514';
    end if;
    new.published_at := coalesce(new.published_at, now());
  end if;
  return new;
end $$;
create trigger lesson_versions_guard before update or delete on public.lesson_versions
  for each row execute function private.guard_lesson_version();

-- 11.2 Filhos de versao publicada (e questoes de teste publicado) sao imutaveis.
create or replace function private.version_of_row(p_table text, p_row jsonb) returns uuid
language sql stable security definer set search_path = '' as $$
  select case
    when p_row is null then null
    when p_table in ('lesson_sections','exercises','questions','lesson_grammar_topics')
      then nullif(p_row->>'lesson_version_id','')::uuid
    when p_table in ('answer_options','question_answer_keys','accepted_answers')
      then (select q.lesson_version_id from public.questions q
            where q.id = (p_row->>'question_id')::uuid)
  end
$$;

create or replace function private.question_of_row(p_table text, p_row jsonb) returns uuid
language sql immutable set search_path = '' as $$
  select case
    when p_row is null then null
    when p_table = 'questions' then (p_row->>'id')::uuid
    when p_table in ('answer_options','question_answer_keys','accepted_answers')
      then (p_row->>'question_id')::uuid
  end
$$;

create or replace function private.question_in_published_placement(p_question uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.placement_questions pq
    join public.placement_tests pt on pt.id = pq.placement_test_id
    where pq.question_id = p_question and pt.is_published
  )
$$;

create or replace function private.guard_published_children() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  r_old jsonb; r_new jsonb;
  v uuid; q uuid;
begin
  if tg_op in ('UPDATE','DELETE') then r_old := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then r_new := to_jsonb(new); end if;

  foreach r_old in array array[r_old, r_new] loop
    continue when r_old is null;
    v := private.version_of_row(tg_table_name, r_old);
    q := private.question_of_row(tg_table_name, r_old);
    if v is not null and exists (select 1 from public.lesson_versions lv where lv.id = v and lv.is_published) then
      raise exception 'Versao publicada e imutavel (%)', tg_table_name using errcode = '55000';
    end if;
    if v is null and q is not null and private.question_in_published_placement(q) then
      raise exception 'Questao de teste de nivelamento publicado e imutavel (%)', tg_table_name using errcode = '55000';
    end if;
  end loop;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger lesson_sections_guard      before insert or update or delete on public.lesson_sections      for each row execute function private.guard_published_children();
create trigger exercises_guard            before insert or update or delete on public.exercises            for each row execute function private.guard_published_children();
create trigger questions_guard            before insert or update or delete on public.questions            for each row execute function private.guard_published_children();
create trigger lesson_grammar_topics_guard before insert or update or delete on public.lesson_grammar_topics for each row execute function private.guard_published_children();
create trigger answer_options_guard       before insert or update or delete on public.answer_options       for each row execute function private.guard_published_children();
create trigger answer_keys_guard          before insert or update or delete on private.question_answer_keys for each row execute function private.guard_published_children();
create trigger accepted_answers_guard     before insert or update or delete on private.accepted_answers    for each row execute function private.guard_published_children();

-- 11.3 Teste de nivelamento publicado e imutavel; publicar valida 30 questoes e distribuicao.
create or replace function private.guard_placement_test() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  n integer; v_voc integer; v_gra integer; v_rea integer; v_con integer;
begin
  if tg_op = 'DELETE' then
    if old.is_published then
      raise exception 'Teste publicado nao pode ser removido' using errcode = '55000';
    end if;
    return old;
  end if;
  if old.is_published then
    raise exception 'Teste publicado e imutavel; crie uma nova versao' using errcode = '55000';
  end if;
  if new.is_published then
    select count(*),
           count(*) filter (where competency = 'vocabulary'),
           count(*) filter (where competency = 'grammar'),
           count(*) filter (where competency = 'reading'),
           count(*) filter (where competency = 'construction')
      into n, v_voc, v_gra, v_rea, v_con
    from public.placement_questions where placement_test_id = new.id;
    if n <> new.total_questions then
      raise exception 'Teste precisa ter exatamente % questoes (tem %)', new.total_questions, n using errcode = '23514';
    end if;
    if new.total_questions = 30 and (v_voc, v_gra, v_rea, v_con) <> (8, 10, 6, 6) then
      raise exception 'Distribuicao oficial: 8 vocabulary, 10 grammar, 6 reading, 6 construction (atual: %,%,%,%)',
        v_voc, v_gra, v_rea, v_con using errcode = '23514';
    end if;
    new.published_at := coalesce(new.published_at, now());
  end if;
  return new;
end $$;
create trigger placement_tests_guard before update or delete on public.placement_tests
  for each row execute function private.guard_placement_test();

create or replace function private.guard_placement_questions() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t uuid;
begin
  foreach t in array array[
    case when tg_op <> 'INSERT' then old.placement_test_id end,
    case when tg_op <> 'DELETE' then new.placement_test_id end] loop
    continue when t is null;
    if exists (select 1 from public.placement_tests pt where pt.id = t and pt.is_published) then
      raise exception 'Teste publicado e imutavel' using errcode = '55000';
    end if;
  end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger placement_questions_guard before insert or update or delete on public.placement_questions
  for each row execute function private.guard_placement_questions();

-- 11.4 Historico de tentativas e imutavel depois de concluido.
-- Exclusao so e permitida quando o proprio usuario foi apagado (LGPD / cascade).
create or replace function private.guard_attempt_history() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from auth.users u where u.id = old.user_id) then
      raise exception 'Historico de tentativas e imutavel (%)', tg_table_name using errcode = '55000';
    end if;
    return old;
  end if;
  -- UPDATE
  if tg_table_name in ('user_lesson_attempts','user_placement_attempts') then
    if old.status <> 'in_progress' then
      raise exception 'Tentativa encerrada nao pode ser alterada' using errcode = '55000';
    end if;
    if new.user_id <> old.user_id then
      raise exception 'Tentativa nao pode mudar de aluno' using errcode = '55000';
    end if;
    return new;
  end if;
  raise exception 'Respostas registradas sao imutaveis (%)', tg_table_name using errcode = '55000';
end $$;
create trigger user_lesson_attempts_guard   before update or delete on public.user_lesson_attempts   for each row execute function private.guard_attempt_history();
create trigger user_exercise_attempts_guard before update or delete on public.user_exercise_attempts for each row execute function private.guard_attempt_history();
create trigger user_placement_attempts_guard before update or delete on public.user_placement_attempts for each row execute function private.guard_attempt_history();
create trigger user_placement_answers_guard before update or delete on public.user_placement_answers for each row execute function private.guard_attempt_history();

-- 11.5 Progresso de aula: primeira conclusao nunca e sobrescrita; melhor nota so sobe.
create or replace function private.guard_lesson_progress() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.completed_at is not null then
    new.completed_at := old.completed_at;
    if new.status <> 'completed' then new.status := 'completed'; end if;
    if new.completed_version_id is null then new.completed_version_id := old.completed_version_id; end if;
  end if;
  new.best_score := greatest(old.best_score, new.best_score);
  new.attempt_count := greatest(old.attempt_count, new.attempt_count);
  return new;
end $$;
create trigger user_lesson_progress_guard before update on public.user_lesson_progress
  for each row execute function private.guard_lesson_progress();

-- 11.6 Novo usuario: cria perfil e papel student.
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  insert into public.user_roles (user_id, role) values (new.id, 'student') on conflict do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();
