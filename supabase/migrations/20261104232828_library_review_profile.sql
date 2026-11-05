-- =====================================================================
-- MyFluenti - Migration 004: Biblioteca, Revisao e Perfil
-- Contrato aprovado pelo Gabriel. Esta migration:
--   * cria favoritos de frases, sessao/itens de revisao e coluna de secao em notas;
--   * CORRIGE private.can_read_question (questao Premium na fila de revisao
--     continuava legivel depois do cancelamento da assinatura);
--   * cria as RPCs: search_library, get_library_item, get_my_favorites,
--     get_review_queue, start_review_session, submit_review_answer,
--     record_review_result_v2, finish_review_session, get_profile_summary.
-- Nenhuma RPC devolve gabarito (correct_option_id, accepted_answers, grading_rules).
-- Mensagens de erro sao codigos estaveis em ingles (o app faz match na mensagem).
-- =====================================================================

-- ---------------------------------------------------------------------
-- A1. Frases favoritas
-- ---------------------------------------------------------------------
create table public.user_favorite_examples (
  user_id               uuid not null references auth.users(id) on delete cascade,
  vocabulary_example_id uuid not null references public.vocabulary_examples(id) on delete cascade,
  created_at            timestamptz not null default now(),
  primary key (user_id, vocabulary_example_id)
);
create index user_favorite_examples_user_idx
  on public.user_favorite_examples (user_id, created_at desc);

alter table public.user_favorite_examples enable row level security;
grant select, insert, delete on public.user_favorite_examples to authenticated;

create policy user_favorite_examples_select_own on public.user_favorite_examples
  for select to authenticated using (user_id = (select auth.uid()));
-- O exists abaixo passa pelo RLS de vocabulary_examples, que encadeia a
-- visibilidade da vocabulary (publicada e respeitando o plano Premium).
create policy user_favorite_examples_insert_own on public.user_favorite_examples
  for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.vocabulary_examples e
                           where e.id = vocabulary_example_id));
create policy user_favorite_examples_delete_own on public.user_favorite_examples
  for delete to authenticated using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- A2. Data em que a palavra foi favoritada
-- ---------------------------------------------------------------------
alter table public.user_vocabulary add column favorited_at timestamptz;
update public.user_vocabulary set favorited_at = now() where is_favorite;   -- backfill (antes do trigger)

create or replace function private.set_favorited_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.is_favorite then
    if tg_op = 'INSERT' then
      new.favorited_at := now();
    elsif not old.is_favorite then
      new.favorited_at := now();
    else
      new.favorited_at := old.favorited_at;   -- ja era favorita: o cliente nao reescreve a data
    end if;
  else
    new.favorited_at := null;
  end if;
  return new;
end $$;
create trigger user_vocabulary_favorited_at before insert or update on public.user_vocabulary
  for each row execute function private.set_favorited_at();

-- ---------------------------------------------------------------------
-- A3. Nota ancorada em uma secao da aula
-- ---------------------------------------------------------------------
alter table public.user_notes
  add column lesson_section_id uuid references public.lesson_sections(id) on delete set null;

-- security definer: a validacao nao depende do RLS de lesson_sections.
create or replace function private.validate_note_section() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.lesson_section_id is not null then
    if new.lesson_id is null or not exists (
         select 1
         from public.lesson_sections s
         join public.lesson_versions lv on lv.id = s.lesson_version_id
         where s.id = new.lesson_section_id and lv.lesson_id = new.lesson_id
           and lv.is_published) then
      raise exception 'section_not_in_lesson' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger user_notes_validate_section before insert or update on public.user_notes
  for each row execute function private.validate_note_section();

-- O aluno edita apenas o texto e a secao; user_id/created_at/alvo ficam fixos.
revoke update on public.user_notes from authenticated;
grant update (body, lesson_section_id) on public.user_notes to authenticated;

-- ---------------------------------------------------------------------
-- A4. Itens revisados em cada sessao de revisao
-- ---------------------------------------------------------------------
create table public.review_session_items (
  id                uuid primary key default gen_random_uuid(),
  session_id        uuid not null,
  user_id           uuid not null references auth.users(id) on delete cascade,
  vocabulary_id     uuid references public.vocabulary(id),
  grammar_topic_id  uuid references public.grammar_topics(id),
  question_id       uuid references public.questions(id),
  rating            text not null check (rating in ('hard','good','easy')),
  quality           smallint not null check (quality between 0 and 5),
  is_correct        boolean,
  reviewed_at       timestamptz not null default now(),
  constraint review_session_items_one_item
    check (num_nonnulls(vocabulary_id, grammar_topic_id, question_id) = 1),
  foreign key (session_id, user_id)
    references public.review_sessions(id, user_id) on delete cascade
);
create unique index review_session_items_uk_vocab
  on public.review_session_items (session_id, vocabulary_id) where vocabulary_id is not null;
create unique index review_session_items_uk_topic
  on public.review_session_items (session_id, grammar_topic_id) where grammar_topic_id is not null;
create unique index review_session_items_uk_question
  on public.review_session_items (session_id, question_id) where question_id is not null;
create index review_session_items_user_idx on public.review_session_items (user_id);

alter table public.review_session_items enable row level security;
grant select on public.review_session_items to authenticated;      -- escrita so por funcao
create policy review_session_items_select_own on public.review_session_items
  for select to authenticated using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- A5. Uma resposta por questao em cada sessao de revisao
-- ---------------------------------------------------------------------
create unique index user_exercise_attempts_one_answer_per_review_question
  on public.user_exercise_attempts (review_session_id, question_id)
  where review_session_id is not null;

-- ---------------------------------------------------------------------
-- A8. Fim do dia local
-- PROVISORIO: "hoje" = ate o fim do dia local. O default 'UTC' e so rede de
-- seguranca; o app deve mandar o fuso do aparelho (IANA, ex.: America/Sao_Paulo).
-- ---------------------------------------------------------------------
create or replace function private.local_day_end(p_timezone text) returns timestamptz
language plpgsql stable set search_path = '' as $$
begin
  if p_timezone is null or not exists (
       select 1 from pg_catalog.pg_timezone_names n where n.name = p_timezone) then
    raise exception 'invalid_timezone' using errcode = '22023';
  end if;
  return (pg_catalog.date_trunc('day', pg_catalog.now() at time zone p_timezone)
          + interval '1 day') at time zone p_timezone;
end $$;

-- ---------------------------------------------------------------------
-- A6/A7. Acesso a questao e a itens da fila de revisao
-- ---------------------------------------------------------------------
-- Elegibilidade para revisao (impede usar a revisao como corretor): a questao
-- NAO pertence a nenhum teste de nivelamento E o aluno ja a respondeu em uma
-- tentativa de aula encerrada (status <> 'in_progress').
create or replace function private.question_reviewable(p_user uuid, p_question uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_question is not null
    and not exists (select 1 from public.placement_questions pq where pq.question_id = p_question)
    and exists (
      select 1
      from public.user_exercise_attempts x
      join public.user_lesson_attempts a on a.id = x.lesson_attempt_id
      where x.user_id = p_user and x.question_id = p_question
        and a.status <> 'in_progress')
$$;

-- Regra de uma questao NA REVISAO: elegivel (acima), de versao publicada e de
-- modulo permitido pelo plano. Nao exige user_module_progress: a revisao
-- independe da progressao. Questao sem versao (banco) nao e elegivel.
create or replace function private.review_question_ok(p_user uuid, p_question uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.question_reviewable(p_user, p_question)
    and exists (
      select 1
      from public.questions q
      join public.lesson_versions lv on lv.id = q.lesson_version_id
      join public.lessons l on l.id = lv.lesson_id
      where q.id = p_question
        and lv.is_published
        and private.module_plan_ok(p_user, l.module_id))
$$;

-- CORRECAO DE SEGURANCA (mesma assinatura): ramos de aula e de nivelamento
-- identicos; o ramo da fila de revisao agora respeita publicacao e plano.
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
          where rs.user_id = auth.uid() and rs.question_id = q.id
            and private.review_question_ok(auth.uid(), q.id))
      )
  )
$$;
revoke all on function private.can_read_question(uuid) from public, anon;
grant execute on function private.can_read_question(uuid) to authenticated;

create or replace function private.review_item_accessible(
  p_user uuid, p_vocabulary uuid, p_topic uuid, p_question uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_vocabulary is not null then exists (
      select 1 from public.vocabulary v
       where v.id = p_vocabulary and v.is_published
         and (v.access_tier = 'free' or private.has_premium_access(p_user)))
    when p_topic is not null then exists (
      select 1 from public.grammar_topics t
       where t.id = p_topic and t.is_published
         and (t.access_tier = 'free' or private.has_premium_access(p_user)))
    when p_question is not null then private.review_question_ok(p_user, p_question)
    else false
  end
$$;

-- Vencidos (ate o fim do dia local) e acessiveis. Mesma regra em fila, fim de sessao e perfil.
create or replace function private.accessible_due_count(p_user uuid, p_end timestamptz) returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer
  from public.review_schedule rs
  where rs.user_id = p_user and rs.due_at < p_end
    and private.review_item_accessible(p_user, rs.vocabulary_id, rs.grammar_topic_id, rs.question_id)
$$;

create or replace function private.next_accessible_due(p_user uuid) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select min(rs.due_at)
  from public.review_schedule rs
  where rs.user_id = p_user and rs.due_at > now()
    and private.review_item_accessible(p_user, rs.vocabulary_id, rs.grammar_topic_id, rs.question_id)
$$;

-- Sessao aberta do proprio aluno; senao session_not_found / session_closed.
create or replace function private.lock_open_review_session(p_user uuid, p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare v_done timestamptz;
begin
  select s.completed_at into v_done
    from public.review_sessions s
   where s.id = p_session and s.user_id = p_user
   for update;
  if not found then
    raise exception 'session_not_found' using errcode = '42501';
  end if;
  if v_done is not null then
    raise exception 'session_closed' using errcode = '55000';
  end if;
end $$;

-- Helpers privados: ninguem alem do dono (e das funcoes security definer) executa.
revoke all on function private.set_favorited_at()                              from public, anon, authenticated;
revoke all on function private.validate_note_section()                         from public, anon, authenticated;
revoke all on function private.local_day_end(text)                             from public, anon, authenticated;
revoke all on function private.review_question_ok(uuid, uuid)                  from public, anon, authenticated;
revoke all on function private.question_reviewable(uuid, uuid)                 from public, anon, authenticated;
revoke all on function private.review_item_accessible(uuid, uuid, uuid, uuid)  from public, anon, authenticated;
revoke all on function private.accessible_due_count(uuid, timestamptz)         from public, anon, authenticated;
revoke all on function private.next_accessible_due(uuid)                       from public, anon, authenticated;
revoke all on function private.lock_open_review_session(uuid, uuid)            from public, anon, authenticated;

-- S4: no maximo uma sessao de revisao aberta por aluno (o lock consultivo segue em start_review_session).
create unique index review_sessions_one_open_per_user
  on public.review_sessions (user_id) where completed_at is null;

-- ---------------------------------------------------------------------
-- record_review_result (v1): MESMA assinatura e retorno, comportamento ENDURECIDO
-- por seguranca (B1/C1): questao so entra na revisao se for elegivel
-- (private.question_reviewable). Resto do corpo identico ao da migration 003.
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

  -- NOVO: questao de nivelamento ou ainda nao respondida em tentativa encerrada nao entra na revisao
  if p_question_id is not null and not private.question_reviewable(v_uid, p_question_id) then
    raise exception 'not_in_review_queue' using errcode = '23503';
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
-- create or replace preserva os grants; reafirma-os por clareza.
revoke all on function public.record_review_result(uuid, uuid, uuid, smallint) from public, anon;
grant execute on function public.record_review_result(uuid, uuid, uuid, smallint) to authenticated;

-- =====================================================================
-- B1. search_library
-- =====================================================================
-- PROVISORIO: ordem = nivel (nulos por ultimo), gramatica antes de vocabulario, titulo.
-- Premium sem plano NAO e escondido: vem com locked = true. Vocabulario locked
-- so casa pelo lemma e nao revela o significado. Independe de progressao e nivelamento.
create or replace function public.search_library(
  p_type text default null,
  p_level_code text default null,
  p_query text default null,
  p_category text default null,
  p_limit int default 20,
  p_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid  uuid := private.require_user();
  v_prem boolean := private.has_premium_access(v_uid);
  v_level uuid; v_query text; v_pat text; v_cat text;
  v_total integer; v_items jsonb;
begin
  if p_type is not null and p_type not in ('grammar','vocabulary') then
    raise exception 'invalid_filter' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 50 or p_offset is null or p_offset not between 0 and 100000 then
    raise exception 'invalid_filter' using errcode = '22023';
  end if;
  if p_level_code is not null then
    select l.id into v_level from public.levels l where l.code = p_level_code;
    if v_level is null then
      raise exception 'invalid_filter' using errcode = '22023';
    end if;
  end if;

  v_query := nullif(btrim(p_query), '');
  if v_query is not null then
    v_pat := '%' || replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  v_cat := nullif(btrim(p_category), '');

  with items as (
    select 'grammar'::text as type, t.id, t.slug::text as slug, t.title, t.summary as subtitle,
           t.category, null::text as part_of_speech, l.code as level_code,
           l.position as level_pos, t.access_tier,
           (t.access_tier = 'premium' and not v_prem) as locked,
           m.mastery_score as mastery_pct, false as is_favorite, 0 as type_ord
      from public.grammar_topics t
      left join public.levels l on l.id = t.level_id
      left join public.user_topic_mastery m
             on m.user_id = v_uid and m.grammar_topic_id = t.id
     where p_type is distinct from 'vocabulary'
       and t.is_published
       and (v_level is null or t.level_id = v_level)
       and (v_cat is null or lower(t.category) = lower(v_cat))
       and (v_pat is null or t.title ilike v_pat or t.summary ilike v_pat)
    union all
    select 'vocabulary', v.id, null, v.lemma,
           case when lk.locked then null else v.meaning_pt end,
           null, v.part_of_speech, l.code, l.position, v.access_tier, lk.locked,
           null, coalesce(uv.is_favorite, false), 1
      from public.vocabulary v
      cross join lateral (select (v.access_tier = 'premium' and not v_prem) as locked) lk
      left join public.levels l on l.id = v.level_id
      left join public.user_vocabulary uv
             on uv.user_id = v_uid and uv.vocabulary_id = v.id
     where p_type is distinct from 'grammar'
       and v_cat is null                      -- categoria so existe na gramatica
       and v.is_published
       and (v_level is null or v.level_id = v_level)
       and (v_pat is null
            or v.lemma ilike v_pat
            or (not lk.locked
                and (v.meaning_pt ilike v_pat
                     or exists (select 1 from public.vocabulary_forms f
                                 where f.vocabulary_id = v.id and f.form_text ilike v_pat))))
  ),
  ranked as (
    select i.*, row_number() over (
             order by i.level_pos asc nulls last, i.type_ord, lower(i.title), i.id) as rn
      from items i
  )
  select (select count(*) from ranked)::integer,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'type', r.type, 'id', r.id, 'slug', r.slug, 'title', r.title,
                     'subtitle', r.subtitle, 'category', r.category,
                     'part_of_speech', r.part_of_speech, 'level_code', r.level_code,
                     'access_tier', r.access_tier, 'locked', r.locked,
                     'mastery_pct', r.mastery_pct, 'is_favorite', r.is_favorite)
                   order by r.rn)
                   from ranked r
                  where r.rn > p_offset::bigint and r.rn <= p_offset::bigint + p_limit), '[]'::jsonb)
    into v_total, v_items;

  return jsonb_build_object(
    'items', v_items, 'total', v_total, 'limit', p_limit, 'offset', p_offset,
    'has_more', p_offset::bigint + jsonb_array_length(v_items) < v_total::bigint);
end $$;

-- =====================================================================
-- B2. get_library_item
-- =====================================================================
create or replace function public.get_library_item(p_type text, p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_tier text; v_res jsonb;
begin
  if p_type is null or p_type not in ('grammar','vocabulary') then
    raise exception 'invalid_filter' using errcode = '22023';
  end if;

  if p_type = 'grammar' then
    select t.access_tier into v_tier
      from public.grammar_topics t where t.id = p_id and t.is_published;
    if not found then
      raise exception 'item_not_found' using errcode = 'P0002';
    end if;
    if v_tier = 'premium' and not private.has_premium_access(v_uid) then
      raise exception 'premium_required' using errcode = '42501';
    end if;

    select jsonb_build_object(
             'type', 'grammar', 'id', t.id, 'slug', t.slug, 'title', t.title,
             'category', t.category, 'summary', t.summary, 'content', t.content,
             'level_code', l.code, 'access_tier', t.access_tier,
             'mastery', (select jsonb_build_object(
                                  'pct', m.mastery_score, 'attempts', m.attempts_count,
                                  'correct', m.correct_count,
                                  'last_practiced_at', m.last_practiced_at)
                           from public.user_topic_mastery m
                          where m.user_id = v_uid and m.grammar_topic_id = t.id),
             'notes_count', (select count(*) from public.user_notes n
                              where n.user_id = v_uid and n.grammar_topic_id = t.id))
      into v_res
      from public.grammar_topics t
      left join public.levels l on l.id = t.level_id
     where t.id = p_id;
    return v_res;
  end if;

  select v.access_tier into v_tier
    from public.vocabulary v where v.id = p_id and v.is_published;
  if not found then
    raise exception 'item_not_found' using errcode = 'P0002';
  end if;
  if v_tier = 'premium' and not private.has_premium_access(v_uid) then
    raise exception 'premium_required' using errcode = '42501';
  end if;

  select jsonb_build_object(
           'type', 'vocabulary', 'id', v.id, 'lemma', v.lemma,
           'part_of_speech', v.part_of_speech, 'meaning_pt', v.meaning_pt,
           'level_code', l.code, 'access_tier', v.access_tier,
           'forms', (select coalesce(jsonb_agg(jsonb_build_object(
                                'label', f.form_label, 'text', f.form_text,
                                'meaning_pt', f.meaning_pt)
                              order by array_position(array['base','third_person','past',
                                'past_participle','gerund','plural','comparative','superlative']::text[],
                                f.form_label)), '[]'::jsonb)
                       from public.vocabulary_forms f where f.vocabulary_id = v.id),
           'examples', (select coalesce(jsonb_agg(jsonb_build_object(
                                'id', e.id, 'en', e.example_en, 'pt', e.example_pt,
                                'is_favorite', exists (
                                  select 1 from public.user_favorite_examples fe
                                   where fe.user_id = v_uid and fe.vocabulary_example_id = e.id))
                              order by e.position nulls last, e.id), '[]'::jsonb)
                          from public.vocabulary_examples e where e.vocabulary_id = v.id),
           'is_favorite', coalesce(uv.is_favorite, false),
           'is_learned', coalesce(uv.is_learned, false),
           'notes_count', (select count(*) from public.user_notes n
                            where n.user_id = v_uid and n.vocabulary_id = v.id))
    into v_res
    from public.vocabulary v
    left join public.levels l on l.id = v.level_id
    left join public.user_vocabulary uv on uv.user_id = v_uid and uv.vocabulary_id = v.id
   where v.id = p_id;
  return v_res;
end $$;

-- =====================================================================
-- B3. get_my_favorites
-- =====================================================================
-- Obs.: para frases de vocabulario Premium sem plano, o titulo (example_en) segue o
-- contrato aprovado e e devolvido; so o subtitle (traducao) fica null.
create or replace function public.get_my_favorites(
  p_kind text default null, p_limit int default 20, p_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid  uuid := private.require_user();
  v_prem boolean := private.has_premium_access(v_uid);
  v_total integer; v_items jsonb;
begin
  if p_kind is not null and p_kind not in ('word','phrase') then
    raise exception 'invalid_filter' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 50 or p_offset is null or p_offset not between 0 and 100000 then
    raise exception 'invalid_filter' using errcode = '22023';
  end if;

  with items as (
    select 'word'::text as kind, v.id as id, v.lemma as title,
           case when lk.locked then null else v.meaning_pt end as subtitle,
           v.id as vocabulary_id, v.access_tier, lk.locked, uv.favorited_at
      from public.user_vocabulary uv
      join public.vocabulary v on v.id = uv.vocabulary_id and v.is_published
      cross join lateral (select (v.access_tier = 'premium' and not v_prem) as locked) lk
     where uv.user_id = v_uid and uv.is_favorite and p_kind is distinct from 'phrase'
    union all
    select 'phrase', e.id, e.example_en,
           case when lk.locked then null else e.example_pt end,
           v.id, v.access_tier, lk.locked, fe.created_at
      from public.user_favorite_examples fe
      join public.vocabulary_examples e on e.id = fe.vocabulary_example_id
      join public.vocabulary v on v.id = e.vocabulary_id and v.is_published
      cross join lateral (select (v.access_tier = 'premium' and not v_prem) as locked) lk
     where fe.user_id = v_uid and p_kind is distinct from 'word'
  ),
  ranked as (
    select i.*, row_number() over (
             order by i.favorited_at desc nulls last, i.kind, i.id) as rn
      from items i
  )
  select (select count(*) from ranked)::integer,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'kind', r.kind, 'id', r.id, 'title', r.title, 'subtitle', r.subtitle,
                     'vocabulary_id', r.vocabulary_id, 'access_tier', r.access_tier,
                     'locked', r.locked, 'favorited_at', r.favorited_at)
                   order by r.rn)
                   from ranked r
                  where r.rn > p_offset::bigint and r.rn <= p_offset::bigint + p_limit), '[]'::jsonb)
    into v_total, v_items;

  return jsonb_build_object(
    'items', v_items, 'total', v_total,
    'has_more', p_offset::bigint + jsonb_array_length(v_items) < v_total::bigint);
end $$;

-- =====================================================================
-- B4. get_review_queue
-- =====================================================================
-- PROVISORIO: ordem da fila = due_at asc, id; sem limite diario de revisoes.
-- PROVISORIO: "hoje" = ate o fim do dia local (private.local_day_end).
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
                                        'prompt', q.prompt, 'prompt_data', q.prompt_data,
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

-- =====================================================================
-- B5. start_review_session
-- =====================================================================
create or replace function public.start_review_session() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_session uuid;
begin
  -- serializa por aluno: duas chamadas simultaneas nao criam duas sessoes abertas
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_uid::text, 4));

  select s.id into v_session
    from public.review_sessions s
   where s.user_id = v_uid and s.completed_at is null
   order by s.started_at desc, s.id
   limit 1;
  if v_session is null then
    insert into public.review_sessions (user_id) values (v_uid) returning id into v_session;
  end if;
  return v_session;
end $$;

-- =====================================================================
-- B6. submit_review_answer
-- =====================================================================
-- Nao altera user_topic_mastery (PENDENTE de decisao do Gabriel).
create or replace function public.submit_review_answer(
  p_session_id uuid, p_question_id uuid, p_answer jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_ok boolean; v_expl text;
begin
  perform private.lock_open_review_session(v_uid, p_session_id);

  if p_question_id is null
     or not exists (select 1 from public.review_schedule rs
                     where rs.user_id = v_uid and rs.question_id = p_question_id)
     or not private.question_reviewable(v_uid, p_question_id)
     or not private.can_read_question(p_question_id) then
    raise exception 'not_in_review_queue' using errcode = '23503';
  end if;
  if exists (select 1 from public.user_exercise_attempts x
              where x.review_session_id = p_session_id and x.question_id = p_question_id) then
    raise exception 'already_answered' using errcode = '23505';
  end if;

  select g.is_correct, g.explanation into v_ok, v_expl
    from private.grade_answer(p_question_id, coalesce(p_answer, '{}'::jsonb)) g;

  insert into public.user_exercise_attempts
    (user_id, review_session_id, question_id, submitted_answer,
     is_correct, awarded_points, max_points)
  values (v_uid, p_session_id, p_question_id, coalesce(p_answer, '{}'::jsonb), v_ok, 0, 0);

  return jsonb_build_object('is_correct', v_ok, 'explanation', v_expl);
end $$;

-- =====================================================================
-- B7. record_review_result_v2 (o v1 mantem assinatura e retorno; foi endurecido acima com not_in_review_queue)
-- =====================================================================
-- PROVISORIO: botao -> qualidade SM-2: hard=3, good=4, easy=5.
-- PROVISORIO: questao errada nesta sessao forca quality = 2 (lapso), qualquer que seja o botao.
create or replace function public.record_review_result_v2(
  p_session_id uuid,
  p_rating text,
  p_vocabulary_id uuid default null,
  p_grammar_topic_id uuid default null,
  p_question_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_quality integer;
  v_is_correct boolean;
  v_res jsonb;
begin
  perform private.lock_open_review_session(v_uid, p_session_id);

  if p_rating is null or p_rating not in ('hard','good','easy') then
    raise exception 'invalid_rating' using errcode = '22023';
  end if;
  if num_nonnulls(p_vocabulary_id, p_grammar_topic_id, p_question_id) <> 1 then
    raise exception 'invalid_item' using errcode = '22023';
  end if;
  -- C3: item inacessivel (Premium sem plano, nao publicado, questao nao elegivel) = erro estavel
  if not private.review_item_accessible(v_uid, p_vocabulary_id, p_grammar_topic_id, p_question_id) then
    if p_question_id is not null then
      raise exception 'not_in_review_queue' using errcode = '23503';
    end if;
    raise exception 'premium_required' using errcode = '42501';
  end if;
  -- C2: questao exige resposta nesta sessao (submit_review_answer antes)
  if p_question_id is not null and not exists (
       select 1 from public.user_exercise_attempts x
        where x.review_session_id = p_session_id and x.question_id = p_question_id) then
    raise exception 'answer_required' using errcode = '22023';
  end if;
  if exists (
       select 1 from public.review_session_items i
        where i.session_id = p_session_id
          and i.vocabulary_id    is not distinct from p_vocabulary_id
          and i.grammar_topic_id is not distinct from p_grammar_topic_id
          and i.question_id      is not distinct from p_question_id) then
    raise exception 'already_reviewed' using errcode = '23505';
  end if;

  v_quality := case p_rating when 'hard' then 3 when 'good' then 4 else 5 end;
  if p_question_id is not null then
    select x.is_correct into v_is_correct
      from public.user_exercise_attempts x
     where x.review_session_id = p_session_id and x.question_id = p_question_id;
    if v_is_correct is false then
      v_quality := 2;
    end if;
  end if;

  -- v1 valida o acesso ao item e aplica o SM-2
  v_res := public.record_review_result(
             p_vocabulary_id := p_vocabulary_id,
             p_grammar_topic_id := p_grammar_topic_id,
             p_question_id := p_question_id,
             p_quality := v_quality::smallint);

  insert into public.review_session_items
    (session_id, user_id, vocabulary_id, grammar_topic_id, question_id,
     rating, quality, is_correct)
  values (p_session_id, v_uid, p_vocabulary_id, p_grammar_topic_id, p_question_id,
          p_rating, v_quality::smallint, v_is_correct);

  return v_res;
end $$;

-- =====================================================================
-- B8. finish_review_session (idempotente)
-- =====================================================================
create or replace function public.finish_review_session(
  p_session_id uuid, p_timezone text default 'UTC')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_end timestamptz;
  v_reviewed integer; v_hard integer; v_good integer; v_easy integer;
  v_correct integer; v_incorrect integer;
begin
  v_end := private.local_day_end(p_timezone);

  perform 1 from public.review_sessions s
    where s.id = p_session_id and s.user_id = v_uid
    for update;
  if not found then
    raise exception 'session_not_found' using errcode = '42501';
  end if;
  update public.review_sessions
     set completed_at = coalesce(completed_at, now())
   where id = p_session_id and user_id = v_uid;

  select count(*)::integer,
         (count(*) filter (where i.rating = 'hard'))::integer,
         (count(*) filter (where i.rating = 'good'))::integer,
         (count(*) filter (where i.rating = 'easy'))::integer
    into v_reviewed, v_hard, v_good, v_easy
    from public.review_session_items i
   where i.session_id = p_session_id and i.user_id = v_uid;

  select (count(*) filter (where x.is_correct))::integer,
         (count(*) filter (where not x.is_correct))::integer
    into v_correct, v_incorrect
    from public.user_exercise_attempts x
   where x.review_session_id = p_session_id and x.user_id = v_uid;

  return jsonb_build_object(
    'session_id', p_session_id,
    'reviewed_count', v_reviewed,
    'hard', v_hard, 'good', v_good, 'easy', v_easy,
    'correct', v_correct, 'incorrect', v_incorrect,
    'remaining_due', private.accessible_due_count(v_uid, v_end),
    'next_due_at', private.next_accessible_due(v_uid));
end $$;

-- =====================================================================
-- B9. get_profile_summary
-- =====================================================================
-- PROVISORIO: o bloco "mastery" e indicador de estudo (formula de dominio provisoria).
-- total_scheduled conta so itens acessiveis ao plano atual (coerente com due_today).
-- Sem streak, sem ranking.
create or replace function public.get_profile_summary(p_timezone text default 'UTC')
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_end timestamptz;
  v_res jsonb;
begin
  v_end := private.local_day_end(p_timezone);

  select jsonb_build_object(
           'display_name', p.display_name,
           'email', (select u.email from auth.users u where u.id = v_uid),
           'avatar_url', p.avatar_url,
           'current_level', (select jsonb_build_object('id', l.id, 'code', l.code, 'title', l.title)
                               from public.levels l where l.id = p.current_level_id),
           'plan_tier', case when private.has_premium_access(v_uid) then 'premium' else 'free' end,
           'placement', jsonb_build_object(
             'completed', exists (select 1 from public.user_placement_attempts a
                                   where a.user_id = v_uid and a.status = 'completed'),
             'last_recommended_level_code', (
                select rl.code
                  from public.user_placement_attempts a
                  join public.levels rl on rl.id = a.recommended_level_id
                 where a.user_id = v_uid and a.status = 'completed'
                 order by a.completed_at desc limit 1),
             'last_completed_at', (
                select max(a.completed_at) from public.user_placement_attempts a
                 where a.user_id = v_uid and a.status = 'completed')),
           'progress', jsonb_build_object(
             'lessons_completed', (select count(*) from public.user_lesson_progress ulp
                                    where ulp.user_id = v_uid and ulp.status = 'completed'),
             'modules_completed', (select count(*) from public.user_module_progress ump
                                    where ump.user_id = v_uid and ump.status = 'completed')),
           'mastery', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'grammar_topic_id', t.id, 'slug', t.slug, 'title', t.title,
                                 'mastery_pct', m.mastery_score, 'attempts', m.attempts_count)
                               order by t.title, t.id), '[]'::jsonb)
                         from public.user_topic_mastery m
                         join public.grammar_topics t on t.id = m.grammar_topic_id and t.is_published
                        where m.user_id = v_uid),
           'review', jsonb_build_object(
             'due_today', private.accessible_due_count(v_uid, v_end),
             'total_scheduled', private.accessible_due_count(v_uid, 'infinity'::timestamptz)),
           'favorites_count',
             (select count(*) from public.user_vocabulary uv
                join public.vocabulary v on v.id = uv.vocabulary_id and v.is_published
               where uv.user_id = v_uid and uv.is_favorite)
             + (select count(*) from public.user_favorite_examples fe
                  join public.vocabulary_examples e on e.id = fe.vocabulary_example_id
                  join public.vocabulary v on v.id = e.vocabulary_id and v.is_published
                 where fe.user_id = v_uid),
           'notes_count', (select count(*) from public.user_notes n where n.user_id = v_uid))
    into v_res
    from (select 1) one
    left join public.profiles p on p.id = v_uid;
  return v_res;
end $$;

-- =====================================================================
-- Permissoes de execucao: so usuarios autenticados chamam as RPCs
-- =====================================================================
do $$
declare f text;
begin
  foreach f in array array[
    'public.search_library(text, text, text, text, integer, integer)',
    'public.get_library_item(text, uuid)',
    'public.get_my_favorites(text, integer, integer)',
    'public.get_review_queue(text, integer)',
    'public.start_review_session()',
    'public.submit_review_answer(uuid, uuid, jsonb)',
    'public.record_review_result_v2(uuid, text, uuid, uuid, uuid)',
    'public.finish_review_session(uuid, text)',
    'public.get_profile_summary(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
