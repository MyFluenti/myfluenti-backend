-- =====================================================================
-- MyFluenti - Testes da migration 011: get_my_notes, user_notes_body_length e
-- select_starting_level idempotente
-- Autocontido (nao usa o dev-seed). Roda DEPOIS do 70, no mesmo banco:
--   (1) Supabase local: db reset -> 10 -> ... -> 70 -> 80 (ou dentro de begin/rollback)
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> ... -> 70 -> 80
-- Helpers com prefixo zn_. Usuarios: 8a (A), 8b (B), 8c (C, Premium), 8d (D, nivel),
-- 8f (F, limite do corpo).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

create function public.zn_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zn_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zn_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

-- um item da lista de notas do usuario corrente (primeira pagina de 50)
create function public.zn_it(p_id uuid) returns jsonb language sql stable as $$
  select i from jsonb_array_elements(public.get_my_notes(50, 0) -> 'items') i
   where (i ->> 'id')::uuid = p_id
$$;

-- versao publicada (secao + exercicio + questao avaliativa) para uma aula
create function public.zn_mk_version(p_lesson uuid, p_vnum int, p_title text, p_sec_id uuid, p_sec_title text)
returns uuid language plpgsql as $$
declare v uuid; e uuid;
begin
  insert into public.lesson_versions (lesson_id, version_number, title)
    values (p_lesson, p_vnum, p_title) returning id into v;
  insert into public.lesson_sections (id, lesson_version_id, position, section_type, title)
    values (p_sec_id, v, 1, 'explanation', p_sec_title);
  insert into public.exercises (lesson_version_id, position, title) values (v, 1, 'Ex') returning id into e;
  insert into public.questions (lesson_version_id, exercise_id, question_type, prompt, position)
    values (v, e, 'multiple_choice', 'ZNQ ' || p_title, 1);
  update public.lesson_versions set is_published = true where id = v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Setup (postgres)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('8a8a8a8a-1111-1111-1111-111111111111', 'zn-a@teste'),
  ('8b8b8b8b-2222-2222-2222-222222222222', 'zn-b@teste'),
  ('8c8c8c8c-3333-3333-3333-333333333333', 'zn-c@teste'),
  ('8d8d8d8d-4444-4444-4444-444444444444', 'zn-d@teste'),
  ('8f8f8f8f-5555-5555-5555-555555555555', 'zn-f@teste');

insert into public.modules (id, level_id, slug, title, position, access_tier, is_published) values
  ('0e0e0e0e-0000-0000-0000-000000000080', (select id from public.levels where code = 'A1'), 'zn-m80', 'ZN free',       180, 'free',    true),
  ('0e0e0e0e-0000-0000-0000-000000000081', (select id from public.levels where code = 'A1'), 'zn-m81', 'ZN premium',    181, 'premium', true),
  ('0e0e0e0e-0000-0000-0000-000000000082', (select id from public.levels where code = 'A1'), 'zn-m82', 'ZN rascunho',   182, 'free',    false),
  ('0e0e0e0e-0000-0000-0000-000000000083', (select id from public.levels where code = 'A2'), 'zn-m83', 'ZN A2 free',    183, 'free',    true);

insert into public.lessons (id, module_id, slug, position) values
  ('1e1e1e1e-0000-0000-0000-000000000001', '0e0e0e0e-0000-0000-0000-000000000080', 'zn-l1', 80),
  ('1e1e1e1e-0000-0000-0000-000000000002', '0e0e0e0e-0000-0000-0000-000000000081', 'zn-p1', 81),
  ('1e1e1e1e-0000-0000-0000-000000000003', '0e0e0e0e-0000-0000-0000-000000000082', 'zn-u1', 82);

select public.zn_mk_version('1e1e1e1e-0000-0000-0000-000000000001', 1, 'ZN Aula 1', '5e5e5e5e-0000-0000-0000-000000000001', 'ZN Secao v1');
select public.zn_mk_version('1e1e1e1e-0000-0000-0000-000000000001', 2, 'ZN Aula 1 v2', '5e5e5e5e-0000-0000-0000-000000000002', 'ZN Secao v2');
select public.zn_mk_version('1e1e1e1e-0000-0000-0000-000000000002', 1, 'ZN Aula Premium', '5e5e5e5e-0000-0000-0000-000000000003', 'ZN Secao Premium');
select public.zn_mk_version('1e1e1e1e-0000-0000-0000-000000000003', 1, 'ZN Aula Oculta', '5e5e5e5e-0000-0000-0000-000000000004', 'ZN Secao Oculta');

insert into public.grammar_topics (id, slug, title, category, level_id, access_tier, is_published) values
  ('a8a8a8a8-0000-0000-0000-000000000001', 'zn-free',  'ZN Topico free',    'zn', (select id from public.levels where code = 'A1'), 'free',    true),
  ('a8a8a8a8-0000-0000-0000-000000000002', 'zn-prem',  'ZN Topico premium', 'zn', (select id from public.levels where code = 'A1'), 'premium', true),
  ('a8a8a8a8-0000-0000-0000-000000000003', 'zn-draft', 'ZN Topico rascunho','zn', (select id from public.levels where code = 'A1'), 'free',    false);

insert into public.vocabulary (id, lemma, part_of_speech, meaning_pt, level_id, access_tier, is_published) values
  ('b8b8b8b8-0000-0000-0000-000000000001', 'znfree',  'noun', 'livre',    (select id from public.levels where code = 'A1'), 'free',    true),
  ('b8b8b8b8-0000-0000-0000-000000000002', 'znprem',  'noun', 'premium',  (select id from public.levels where code = 'A1'), 'premium', true),
  ('b8b8b8b8-0000-0000-0000-000000000003', 'zndraft', 'noun', 'rascunho', (select id from public.levels where code = 'A1'), 'free',    false);

-- Extras (revisao qa-security): modulo publicado NAO liberado ao aluno A (184), modulo
-- Premium em rascunho (185), topico e palavra Premium em rascunho, aluno E (vinculo com teste)
insert into auth.users (id, email) values ('8e8e8e8e-6666-6666-6666-666666666666', 'zn-e@teste');
insert into public.modules (id, level_id, slug, title, position, access_tier, is_published) values
  ('0e0e0e0e-0000-0000-0000-000000000184', (select id from public.levels where code = 'A1'), 'zn-m84', 'ZN nao liberado',       184, 'free',    true),
  ('0e0e0e0e-0000-0000-0000-000000000185', (select id from public.levels where code = 'A1'), 'zn-m85', 'ZN premium rascunho',   185, 'premium', false);
insert into public.lessons (id, module_id, slug, position) values
  ('1e1e1e1e-0000-0000-0000-000000000004', '0e0e0e0e-0000-0000-0000-000000000184', 'zn-nl', 184),
  ('1e1e1e1e-0000-0000-0000-000000000005', '0e0e0e0e-0000-0000-0000-000000000185', 'zn-pd', 185);
select public.zn_mk_version('1e1e1e1e-0000-0000-0000-000000000004', 1, 'ZN Aula Modulo Nao Liberado', '5e5e5e5e-0000-0000-0000-000000000005', 'ZN Secao Nao Liberada');
select public.zn_mk_version('1e1e1e1e-0000-0000-0000-000000000005', 1, 'ZN Aula Premium Rascunho', '5e5e5e5e-0000-0000-0000-000000000006', 'ZN Secao Premium Rascunho');
insert into public.grammar_topics (id, slug, title, category, level_id, access_tier, is_published) values
  ('a8a8a8a8-0000-0000-0000-000000000004', 'zn-pdraft', 'ZN Topico premium rascunho', 'zn', (select id from public.levels where code = 'A1'), 'premium', false);
insert into public.vocabulary (id, lemma, part_of_speech, meaning_pt, level_id, access_tier, is_published) values
  ('b8b8b8b8-0000-0000-0000-000000000004', 'znpremdraft', 'noun', 'premium rascunho', (select id from public.levels where code = 'A1'), 'premium', false);

-- Modulos liberados (mesma tabela que get_module_lessons consulta). A nao tem 184.
insert into public.user_module_progress (user_id, module_id) values
  ('8a8a8a8a-1111-1111-1111-111111111111', '0e0e0e0e-0000-0000-0000-000000000080'),
  ('8a8a8a8a-1111-1111-1111-111111111111', '0e0e0e0e-0000-0000-0000-000000000081'),
  ('8a8a8a8a-1111-1111-1111-111111111111', '0e0e0e0e-0000-0000-0000-000000000082'),
  ('8c8c8c8c-3333-3333-3333-333333333333', '0e0e0e0e-0000-0000-0000-000000000081');

insert into public.placement_tests (id, code, version_number, title, total_questions)
  values ('bbbbbbbb-0000-0000-0000-0000000000e1', 'zn', 1, 'ZN nivelamento', 30);

insert into public.subscription_plans (id, code, name, tier)
  values ('d8d8d8d8-0000-0000-0000-000000000001', 'zn_premium', 'Premium (teste ZN)', 'premium');
insert into public.user_subscriptions (id, user_id, plan_id, status, current_period_end)
  values ('d8d8d8d8-0000-0000-0000-0000000000a1', '8c8c8c8c-3333-3333-3333-333333333333',
          'd8d8d8d8-0000-0000-0000-000000000001', 'active', now() + interval '30 days');

-- Notas do aluno A (updated_at explicito: ordem decrescente n1..n9)
insert into public.user_notes (id, user_id, lesson_id, lesson_section_id, grammar_topic_id, vocabulary_id, body, created_at, updated_at) values
  ('90000000-0000-0000-0000-000000000001', '8a8a8a8a-1111-1111-1111-111111111111', '1e1e1e1e-0000-0000-0000-000000000001', '5e5e5e5e-0000-0000-0000-000000000001', null, null, 'nota aula com secao',  '2026-03-01', '2026-03-09'),
  ('90000000-0000-0000-0000-000000000002', '8a8a8a8a-1111-1111-1111-111111111111', '1e1e1e1e-0000-0000-0000-000000000001', null, null, null, 'nota aula sem secao', '2026-03-01', '2026-03-08'),
  ('90000000-0000-0000-0000-000000000003', '8a8a8a8a-1111-1111-1111-111111111111', null, null, 'a8a8a8a8-0000-0000-0000-000000000001', null, 'nota topico free',     '2026-03-01', '2026-03-07'),
  ('90000000-0000-0000-0000-000000000004', '8a8a8a8a-1111-1111-1111-111111111111', null, null, null, 'b8b8b8b8-0000-0000-0000-000000000001', 'nota palavra free',    '2026-03-01', '2026-03-06'),
  ('90000000-0000-0000-0000-000000000005', '8a8a8a8a-1111-1111-1111-111111111111', null, null, 'a8a8a8a8-0000-0000-0000-000000000002', null, 'nota topico premium',  '2026-03-01', '2026-03-05'),
  ('90000000-0000-0000-0000-000000000006', '8a8a8a8a-1111-1111-1111-111111111111', '1e1e1e1e-0000-0000-0000-000000000002', null, null, null, 'nota aula premium',    '2026-03-01', '2026-03-04'),
  ('90000000-0000-0000-0000-000000000007', '8a8a8a8a-1111-1111-1111-111111111111', null, null, null, 'b8b8b8b8-0000-0000-0000-000000000002', 'nota palavra premium', '2026-03-01', '2026-03-03'),
  ('90000000-0000-0000-0000-000000000008', '8a8a8a8a-1111-1111-1111-111111111111', '1e1e1e1e-0000-0000-0000-000000000003', null, null, null, 'nota aula oculta',     '2026-03-01', '2026-03-02'),
  ('90000000-0000-0000-0000-000000000009', '8a8a8a8a-1111-1111-1111-111111111111', null, null, 'a8a8a8a8-0000-0000-0000-000000000003', null, 'nota topico rascunho', '2026-03-01', '2026-03-01');
-- A, extras: rascunho Premium (aula, topico, palavra) e aula de modulo nao liberado.
-- n12 e n13 empatam em updated_at (desempate por id).
insert into public.user_notes (id, user_id, lesson_id, lesson_section_id, grammar_topic_id, vocabulary_id, body, created_at, updated_at) values
  ('90000000-0000-0000-0000-000000000010', '8a8a8a8a-1111-1111-1111-111111111111', '1e1e1e1e-0000-0000-0000-000000000005', null, null, null, 'nota aula premium rascunho',   '2026-03-01', '2026-02-24'),
  ('90000000-0000-0000-0000-000000000011', '8a8a8a8a-1111-1111-1111-111111111111', null, null, 'a8a8a8a8-0000-0000-0000-000000000004', null, 'nota topico premium rascunho', '2026-03-01', '2026-02-23'),
  ('90000000-0000-0000-0000-000000000012', '8a8a8a8a-1111-1111-1111-111111111111', null, null, null, 'b8b8b8b8-0000-0000-0000-000000000004', 'nota palavra premium rascunho', '2026-03-01', '2026-02-22'),
  ('90000000-0000-0000-0000-000000000013', '8a8a8a8a-1111-1111-1111-111111111111', '1e1e1e1e-0000-0000-0000-000000000004', '5e5e5e5e-0000-0000-0000-000000000005', null, null, 'nota aula modulo nao liberado', '2026-03-01', '2026-02-22');

-- B: uma nota; C (Premium): notas em alvos Premium
insert into public.user_notes (id, user_id, vocabulary_id, body, updated_at) values
  ('90000000-0000-0000-0000-0000000000b1', '8b8b8b8b-2222-2222-2222-222222222222', 'b8b8b8b8-0000-0000-0000-000000000001', 'segredo de B', '2026-03-10');
insert into public.user_notes (id, user_id, lesson_id, body, updated_at) values
  ('90000000-0000-0000-0000-0000000000c1', '8c8c8c8c-3333-3333-3333-333333333333', '1e1e1e1e-0000-0000-0000-000000000002', 'C aula premium', '2026-03-10');
insert into public.user_notes (id, user_id, grammar_topic_id, body, updated_at) values
  ('90000000-0000-0000-0000-0000000000c2', '8c8c8c8c-3333-3333-3333-333333333333', 'a8a8a8a8-0000-0000-0000-000000000002', 'C topico premium', '2026-03-09');

-- ---------------------------------------------------------------------
-- Contrato e permissoes
-- ---------------------------------------------------------------------
select public.zn_assert(
  (select pg_get_function_identity_arguments(p.oid) = 'p_limit integer, p_offset integer'
          and p.prorettype = 'jsonb'::regtype and p.prosecdef
          and p.proconfig = array['search_path=""']
     from pg_proc p where p.oid = 'public.get_my_notes(int, int)'::regprocedure),
  'CONTRATO: get_my_notes(int, int) devolve jsonb, security definer, search_path vazio');
select public.zn_assert(
  has_function_privilege('authenticated', 'public.get_my_notes(int, int)', 'execute')
  and not has_function_privilege('anon', 'public.get_my_notes(int, int)', 'execute')
  and not has_function_privilege('public', 'public.get_my_notes(int, int)', 'execute'),
  'CONTRATO: get_my_notes so authenticated executa');
select public.zn_assert(
  (select pg_get_function_identity_arguments(p.oid) = 'p_level_id uuid, p_placement_attempt_id uuid'
          and p.prorettype = 'void'::regtype and p.prosecdef
     from pg_proc p where p.oid = 'public.select_starting_level(uuid, uuid)'::regprocedure)
  and has_function_privilege('authenticated', 'public.select_starting_level(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.select_starting_level(uuid, uuid)', 'execute'),
  'CONTRATO: select_starting_level manteve assinatura, retorno e grants');
select public.zn_assert(
  (select convalidated from pg_constraint
    where conname = 'user_notes_body_length' and conrelid = 'public.user_notes'::regclass),
  'CONTRATO: constraint user_notes_body_length existe e esta validada');

set role anon;
select public.zn_expect_error($q$select public.get_my_notes()$q$, '42501');
reset role;
set role authenticated;
select public.zn_as(null);
select public.zn_expect_error($q$select public.get_my_notes()$q$, '28000');
reset role;

-- ---------------------------------------------------------------------
-- A: lista sem plano Premium
-- ---------------------------------------------------------------------
set role authenticated;
select public.zn_as('8a8a8a8a-1111-1111-1111-111111111111');

select public.zn_assert(
  (select (r ->> 'total')::int = 13 and jsonb_array_length(r -> 'items') = 13 and (r ->> 'has_more')::boolean = false
     from (select public.get_my_notes() r) x),
  'LISTA: A ve as 13 notas dela, sem mais paginas');
select public.zn_assert(
  (select array_agg((i ->> 'id')::uuid order by ord) =
          array(select ('90000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid from generate_series(1, 13) n order by n)
     from jsonb_array_elements(public.get_my_notes() -> 'items') with ordinality t(i, ord)),
  'ORDEM: updated_at decrescente, empate (n12, n13) desempatado por id');

select public.zn_assert(
  (select i ->> 'target_type' = 'lesson'
          and i ->> 'target_title' = 'ZN Aula 1 v2'
          and i ->> 'section_title' = 'ZN Secao v1'
          and (i ->> 'lesson_id')::uuid = '1e1e1e1e-0000-0000-0000-000000000001'
          and (i ->> 'lesson_section_id')::uuid = '5e5e5e5e-0000-0000-0000-000000000001'
          and i ->> 'grammar_topic_id' is null and i ->> 'vocabulary_id' is null
          and i ->> 'body' = 'nota aula com secao'
          and (i ->> 'locked')::boolean = false and i ->> 'access_tier' = 'free'
          and (i ->> 'created_at')::timestamptz = '2026-03-01'::timestamptz
          and (i ->> 'updated_at')::timestamptz = '2026-03-09'::timestamptz
     from (select public.zn_it('90000000-0000-0000-0000-000000000001') i) x),
  'ALVO AULA: titulo da versao publicada mais recente, titulo da secao (da versao antiga ancorada), ids e datas');
select public.zn_assert(
  (select i ->> 'target_title' = 'ZN Aula 1 v2' and i ->> 'section_title' is null and i ->> 'lesson_section_id' is null
     from (select public.zn_it('90000000-0000-0000-0000-000000000002') i) x),
  'ALVO AULA SEM SECAO: section_title nulo');
select public.zn_assert(
  (select i ->> 'target_type' = 'grammar_topic' and i ->> 'target_title' = 'ZN Topico free'
          and (i ->> 'grammar_topic_id')::uuid = 'a8a8a8a8-0000-0000-0000-000000000001'
          and i ->> 'section_title' is null and (i ->> 'locked')::boolean = false
     from (select public.zn_it('90000000-0000-0000-0000-000000000003') i) x),
  'ALVO TOPICO: titulo do topico');
select public.zn_assert(
  (select i ->> 'target_type' = 'vocabulary' and i ->> 'target_title' = 'znfree'
          and (i ->> 'vocabulary_id')::uuid = 'b8b8b8b8-0000-0000-0000-000000000001'
          and (i ->> 'locked')::boolean = false
     from (select public.zn_it('90000000-0000-0000-0000-000000000004') i) x),
  'ALVO PALAVRA: lemma como titulo');

-- Premium sem plano: titulo oculto, locked = true, corpo da propria nota continua
select public.zn_assert(
  (select i ->> 'target_title' is null and (i ->> 'locked')::boolean and i ->> 'access_tier' = 'premium'
          and i ->> 'body' = 'nota topico premium'
     from (select public.zn_it('90000000-0000-0000-0000-000000000005') i) x),
  'PREMIUM SEM PLANO: topico com titulo nulo e locked');
select public.zn_assert(
  (select i ->> 'target_title' is null and i ->> 'section_title' is null and (i ->> 'locked')::boolean
          and i ->> 'body' = 'nota aula premium'
     from (select public.zn_it('90000000-0000-0000-0000-000000000006') i) x),
  'PREMIUM SEM PLANO: aula com titulo nulo e locked');
select public.zn_assert(
  (select i ->> 'target_title' is null and (i ->> 'locked')::boolean
     from (select public.zn_it('90000000-0000-0000-0000-000000000007') i) x),
  'PREMIUM SEM PLANO: palavra com titulo nulo e locked');
-- Nao publicado: titulo nulo, sem locked
select public.zn_assert(
  (select i ->> 'target_title' is null and i ->> 'section_title' is null and not (i ->> 'locked')::boolean
     from (select public.zn_it('90000000-0000-0000-0000-000000000008') i) x),
  'NAO PUBLICADO: aula de modulo em rascunho tem titulo nulo e nao e locked');
select public.zn_assert(
  (select i ->> 'target_title' is null and not (i ->> 'locked')::boolean
     from (select public.zn_it('90000000-0000-0000-0000-000000000009') i) x),
  'NAO PUBLICADO: topico em rascunho tem titulo nulo');
-- Rascunho Premium: locked = false, titulo nulo e access_tier nulo (nao revela o tier)
select public.zn_assert(
  (select i ->> 'target_title' is null and i ->> 'section_title' is null
          and not (i ->> 'locked')::boolean and i -> 'access_tier' = 'null'::jsonb
          and i ->> 'body' = 'nota aula premium rascunho'
     from (select public.zn_it('90000000-0000-0000-0000-000000000010') i) x),
  'RASCUNHO PREMIUM: aula de modulo Premium em rascunho tem locked=false, titulo e access_tier nulos');
select public.zn_assert(
  (select i ->> 'target_title' is null and not (i ->> 'locked')::boolean and i -> 'access_tier' = 'null'::jsonb
     from (select public.zn_it('90000000-0000-0000-0000-000000000011') i) x),
  'RASCUNHO PREMIUM: topico Premium em rascunho tem locked=false e access_tier nulo');
select public.zn_assert(
  (select i ->> 'target_title' is null and not (i ->> 'locked')::boolean and i -> 'access_tier' = 'null'::jsonb
     from (select public.zn_it('90000000-0000-0000-0000-000000000012') i) x),
  'RASCUNHO PREMIUM: palavra Premium em rascunho tem locked=false e access_tier nulo');
-- Modulo publicado, mas ainda nao liberado para A: titulo e secao nulos, nota listada
select public.zn_assert(
  (select i ->> 'target_title' is null and i ->> 'section_title' is null
          and not (i ->> 'locked')::boolean and i ->> 'access_tier' = 'free'
          and i ->> 'body' = 'nota aula modulo nao liberado'
          and (i ->> 'lesson_section_id')::uuid = '5e5e5e5e-0000-0000-0000-000000000005'
     from (select public.zn_it('90000000-0000-0000-0000-000000000013') i) x),
  'MODULO NAO LIBERADO: nota listada, titulo da aula e da secao nulos');
-- Nenhum texto escondido aparece em lugar nenhum da resposta
select public.zn_assert(
  position('ZN Topico premium' in public.get_my_notes()::text) = 0
  and position('ZN Aula Premium' in public.get_my_notes()::text) = 0
  and position('znprem' in public.get_my_notes()::text) = 0
  and position('ZN Aula Oculta' in public.get_my_notes()::text) = 0
  and position('ZN Topico rascunho' in public.get_my_notes()::text) = 0
  and position('zndraft' in public.get_my_notes()::text) = 0
  and position('ZN Secao Premium' in public.get_my_notes()::text) = 0
  and position('ZN Secao Oculta' in public.get_my_notes()::text) = 0
  and position('ZN Aula Modulo Nao Liberado' in public.get_my_notes()::text) = 0
  and position('ZN Secao Nao Liberada' in public.get_my_notes()::text) = 0
  and position('Premium Rascunho' in public.get_my_notes()::text) = 0
  and position('Topico premium rascunho' in public.get_my_notes()::text) = 0
  and position('znpremdraft' in public.get_my_notes()::text) = 0,
  'SEGURANCA: titulos de conteudo Premium bloqueado ou nao publicado nao vazam');

-- Paginacao
select public.zn_assert(
  (select jsonb_array_length(r -> 'items') = 3 and (r ->> 'has_more')::boolean and (r ->> 'total')::int = 13
          and (r -> 'items' -> 0 ->> 'id')::uuid = '90000000-0000-0000-0000-000000000001'
     from (select public.get_my_notes(3, 0) r) x),
  'PAGINACAO: primeira pagina de 3 tem mais');
select public.zn_assert(
  (select jsonb_array_length(r -> 'items') = 3 and not (r ->> 'has_more')::boolean
          and (r -> 'items' -> 0 ->> 'id')::uuid = '90000000-0000-0000-0000-000000000011'
     from (select public.get_my_notes(3, 10) r) x),
  'PAGINACAO: ultima pagina nao tem mais');
select public.zn_assert(
  (select jsonb_array_length(r -> 'items') = 0 and not (r ->> 'has_more')::boolean and (r ->> 'total')::int = 13
     from (select public.get_my_notes(20, 13) r) x),
  'PAGINACAO: offset alem do fim devolve vazio');
select public.zn_assert(
  (select (public.get_my_notes(1, 11) -> 'items' -> 0 ->> 'id')::uuid = '90000000-0000-0000-0000-000000000012'
      and (public.get_my_notes(1, 12) -> 'items' -> 0 ->> 'id')::uuid = '90000000-0000-0000-0000-000000000013'),
  'PAGINACAO: empate de updated_at nao repete nem perde nota entre paginas');
select public.zn_expect_error($q$select public.get_my_notes(0, 0)$q$, '22023', 'invalid_filter');
select public.zn_expect_error($q$select public.get_my_notes(51, 0)$q$, '22023', 'invalid_filter');
select public.zn_expect_error($q$select public.get_my_notes(20, -1)$q$, '22023', 'invalid_filter');
select public.zn_expect_error($q$select public.get_my_notes(null, 0)$q$, '22023', 'invalid_filter');
select public.zn_expect_error($q$select public.get_my_notes(20, null)$q$, '22023', 'invalid_filter');
reset role;

-- ---------------------------------------------------------------------
-- B e C
-- ---------------------------------------------------------------------
set role authenticated;
select public.zn_as('8b8b8b8b-2222-2222-2222-222222222222');
select public.zn_assert(
  (select (r ->> 'total')::int = 1 and r -> 'items' -> 0 ->> 'body' = 'segredo de B'
          and position('nota aula' in r::text) = 0
     from (select public.get_my_notes() r) x),
  'ISOLAMENTO: B ve so a nota dele, nenhuma de A');

select public.zn_as('8c8c8c8c-3333-3333-3333-333333333333');
select public.zn_assert(
  (select i ->> 'target_title' = 'ZN Aula Premium' and i ->> 'access_tier' = 'premium' and not (i ->> 'locked')::boolean
     from (select public.zn_it('90000000-0000-0000-0000-0000000000c1') i) x),
  'PREMIUM COM PLANO: titulo da aula Premium aparece e locked = false');
select public.zn_assert(
  (select i ->> 'target_title' = 'ZN Topico premium' and not (i ->> 'locked')::boolean
     from (select public.zn_it('90000000-0000-0000-0000-0000000000c2') i) x),
  'PREMIUM COM PLANO: titulo do topico Premium aparece');
select public.zn_assert(
  (select (r ->> 'total')::int = 2 from (select public.get_my_notes() r) x),
  'ISOLAMENTO: C ve so as 2 notas dela');
reset role;

-- usuario sem nota recebe lista vazia
set role authenticated;
select public.zn_as('8d8d8d8d-4444-4444-4444-444444444444');
select public.zn_assert(
  (select r = '{"items": [], "total": 0, "has_more": false}'::jsonb from (select public.get_my_notes() r) x),
  'LISTA VAZIA: aluno sem notas recebe items vazio');
reset role;

-- ---------------------------------------------------------------------
-- Limite do body (aluno F, escrevendo como authenticated)
-- ---------------------------------------------------------------------
set role authenticated;
select public.zn_as('8f8f8f8f-5555-5555-5555-555555555555');

insert into public.user_notes (id, user_id, vocabulary_id, body)
values ('91000000-0000-0000-0000-000000000001', auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', repeat('a', 2000));
select public.zn_assert(
  (select char_length(body) = 2000 from public.user_notes where id = '91000000-0000-0000-0000-000000000001'),
  'BODY: 2000 caracteres e aceito');
-- espacos, tab e quebras nas pontas sao APARADOS pelo trigger: o valor gravado e o medido
insert into public.user_notes (id, user_id, vocabulary_id, body)
values ('91000000-0000-0000-0000-000000000002', auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001',
        E' \t' || repeat('a', 2000) || repeat(' ', 10) || E'\r\n');
select public.zn_assert(
  (select body = repeat('a', 2000) from public.user_notes where id = '91000000-0000-0000-0000-000000000002'),
  'BODY: 2000 caracteres uteis com espacos/tab/CRLF nas pontas: gravado aparado, com 2000 caracteres');
insert into public.user_notes (id, user_id, vocabulary_id, body)
values ('91000000-0000-0000-0000-000000000003', auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', repeat(U&'\00E3', 2000));
select public.zn_assert(
  (select body = repeat(U&'\00E3', 2000) and octet_length(body) = 4000
     from public.user_notes where id = '91000000-0000-0000-0000-000000000003'),
  'BODY: 2000 caracteres multibyte e aceito (conta caracteres, nao bytes)');
insert into public.user_notes (id, user_id, vocabulary_id, body)
values ('91000000-0000-0000-0000-000000000004', auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', 'x');
select public.zn_assert(
  (select body = 'x' from public.user_notes where id = '91000000-0000-0000-0000-000000000004'),
  'BODY: 1 caractere e aceito');
insert into public.user_notes (id, user_id, vocabulary_id, body)
values ('91000000-0000-0000-0000-000000000005', auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', E'  \n  ola mundo\t\n ');
select public.zn_assert(
  (select body = 'ola mundo' from public.user_notes where id = '91000000-0000-0000-0000-000000000005'),
  'BODY: espacos e quebras so nas pontas sao aparados');
-- milhoes de espacos nas pontas: aparado, nunca gravado inteiro
insert into public.user_notes (id, user_id, vocabulary_id, body)
values ('91000000-0000-0000-0000-000000000006', auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001',
        'x' || repeat(' ', 5000000));
select public.zn_assert(
  (select body = 'x' and octet_length(body) = 1 from public.user_notes where id = '91000000-0000-0000-0000-000000000006'),
  'BODY: x seguido de 5 milhoes de espacos grava so "x"');
insert into public.user_notes (id, user_id, vocabulary_id, body)
values ('91000000-0000-0000-0000-000000000007', auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001',
        'a' || repeat(' ', 1998) || 'b');
select public.zn_assert(
  (select char_length(body) = 2000 from public.user_notes where id = '91000000-0000-0000-0000-000000000007'),
  'BODY: espacos do meio contam (a + 1998 espacos + b = 2000, aceito)');
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', 'a' || repeat(' ', 1999) || 'b')$q$,
  '23514', 'user_notes_body_length');
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', repeat('a', 2001) || repeat(' ', 5000000))$q$,
  '23514', 'user_notes_body_length');
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', repeat(' ', 5000000))$q$,
  '23514', 'user_notes_body_length');

select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', repeat('a', 2001))$q$,
  '23514', 'user_notes_body_length');
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', '   ')$q$,
  '23514', 'user_notes_body_length');
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', E' \t\n ')$q$,
  '23514', 'user_notes_body_length');
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', '')$q$,
  '23514', 'user_notes_body_length');
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), 'b8b8b8b8-0000-0000-0000-000000000001', null)$q$,
  '23502');
select public.zn_expect_error(
  $q$update public.user_notes set body = repeat('a', 2001) where id = '91000000-0000-0000-0000-000000000001'$q$,
  '23514', 'user_notes_body_length');
select public.zn_expect_error(
  $q$update public.user_notes set body = '   ' where id = '91000000-0000-0000-0000-000000000001'$q$,
  '23514', 'user_notes_body_length');
update public.user_notes set body = 'editada' where id = '91000000-0000-0000-0000-000000000001';
select public.zn_assert(
  (select body = 'editada' from public.user_notes where id = '91000000-0000-0000-0000-000000000001'),
  'BODY: update valido continua funcionando');
update public.user_notes set body = E'  editada de novo \n' || repeat(' ', 100000) where id = '91000000-0000-0000-0000-000000000001';
select public.zn_assert(
  (select body = 'editada de novo' from public.user_notes where id = '91000000-0000-0000-0000-000000000001'),
  'BODY: update tambem apara o texto gravado');
select public.zn_assert(
  (select count(*) = 7 from public.user_notes),
  'BODY: as tentativas recusadas nao gravaram nada (7 notas validas de F)');
reset role;
-- a constraint sozinha tambem recusa texto nao aparado (defesa se o trigger for desligado)
alter table public.user_notes disable trigger user_notes_trim_body;
select public.zn_expect_error(
  $q$insert into public.user_notes (user_id, vocabulary_id, body) values ('8f8f8f8f-5555-5555-5555-555555555555', 'b8b8b8b8-0000-0000-0000-000000000001', ' sem trigger ')$q$,
  '23514', 'user_notes_body_length');
alter table public.user_notes enable trigger user_notes_trim_body;
set role authenticated;
select public.zn_as('8f8f8f8f-5555-5555-5555-555555555555');
reset role;

-- ---------------------------------------------------------------------
-- select_starting_level idempotente (aluno D, autoavaliacao A2)
-- ---------------------------------------------------------------------
update public.profiles set self_assessed_level_id = (select id from public.levels where code = 'A2')
 where id = '8d8d8d8d-4444-4444-4444-444444444444';

set role authenticated;
select public.zn_as('8d8d8d8d-4444-4444-4444-444444444444');
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zn_assert(
  (select count(*) = 1 and count(*) filter (where ended_at is null and source = 'self_assessment') = 1
     from public.user_level_history where user_id = auth.uid()),
  'NIVEL: primeira escolha grava uma linha self_assessment');
reset role;

-- guarda a linha original e uma data de onboarding conhecida
create temp table zn_h0 as
  select id, started_at, source from public.user_level_history
   where user_id = '8d8d8d8d-4444-4444-4444-444444444444';
grant select on zn_h0 to authenticated;
update public.profiles set onboarding_completed_at = '2026-01-01T00:00:00Z'
 where id = '8d8d8d8d-4444-4444-4444-444444444444';
-- o desbloqueio precisa ser refeito se a chamada repetida passar por unlock_module
delete from public.user_module_progress where user_id = '8d8d8d8d-4444-4444-4444-444444444444';

set role authenticated;
select public.zn_as('8d8d8d8d-4444-4444-4444-444444444444');
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zn_assert(
  (select count(*) = 1 and bool_and(h.id = z.id and h.started_at = z.started_at and h.source = z.source and h.ended_at is null)
     from public.user_level_history h join zn_h0 z on z.id = h.id
    where h.user_id = auth.uid())
  and (select count(*) = 1 from public.user_level_history where user_id = auth.uid()),
  'IDEMPOTENCIA: chamadas repetidas nao encerram nem criam linha; a linha original fica intacta');
select public.zn_assert(
  (select onboarding_completed_at = '2026-01-01T00:00:00Z'::timestamptz
          and current_level_id = (select id from public.levels where code = 'A1')
     from public.profiles where id = auth.uid()),
  'IDEMPOTENCIA: data do onboarding preservada e nivel corrente mantido');
reset role;
select public.zn_assert(
  exists (select 1 from public.user_module_progress
           where user_id = '8d8d8d8d-4444-4444-4444-444444444444'
             and module_id = private.first_published_module((select id from public.levels where code = 'A1'))),
  'IDEMPOTENCIA: unlock_module continua rodando na chamada repetida');

-- validacoes continuam valendo na chamada repetida
set role authenticated;
select public.zn_as('8d8d8d8d-4444-4444-4444-444444444444');
select public.zn_expect_error(
  format($q$select public.select_starting_level(%L, gen_random_uuid())$q$, (select id from public.levels where code = 'A1')), '42501');
select public.zn_expect_error(
  $q$select public.select_starting_level(gen_random_uuid())$q$, 'P0002');
select public.zn_expect_error(
  $q$select public.select_starting_level((select id from public.levels where code = 'C2'))$q$, '22023');
select public.zn_assert(
  (select count(*) = 1 from public.user_level_history where user_id = auth.uid()),
  'IDEMPOTENCIA: chamadas invalidas nao tocam o historico');

-- troca real continua gravando manual_change
select public.select_starting_level((select id from public.levels where code = 'A2'));
select public.zn_assert(
  (select count(*) = 2
          and count(*) filter (where ended_at is null and source = 'manual_change'
                               and level_id = (select id from public.levels where code = 'A2')) = 1
          and count(*) filter (where ended_at is not null
                               and level_id = (select id from public.levels where code = 'A1')) = 1
     from public.user_level_history where user_id = auth.uid())
  and (select onboarding_completed_at = '2026-01-01T00:00:00Z'::timestamptz
          and current_level_id = (select id from public.levels where code = 'A2')
     from public.profiles where id = auth.uid()),
  'TROCA REAL: A1 -> A2 encerra a linha, grava manual_change e preserva o onboarding');
select public.select_starting_level((select id from public.levels where code = 'A2'));
select public.zn_assert(
  (select count(*) = 2 from public.user_level_history where user_id = auth.uid()),
  'IDEMPOTENCIA: repetir o novo nivel ativo tambem nao cria linha');
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zn_assert(
  (select count(*) = 3 and count(*) filter (where ended_at is null and source = 'manual_change'
                               and level_id = (select id from public.levels where code = 'A1')) = 1
     from public.user_level_history where user_id = auth.uid()),
  'TROCA REAL: voltar de A2 para A1 grava nova linha manual_change');
reset role;

-- ---------------------------------------------------------------------
-- Vinculo com o teste de nivelamento na chamada repetida (aluno E)
-- E escolhe A1 por autoavaliacao; depois faz o teste (recomenda A1) e confirma A1.
-- ---------------------------------------------------------------------
update public.profiles set self_assessed_level_id = (select id from public.levels where code = 'A1')
 where id = '8e8e8e8e-6666-6666-6666-666666666666';
set role authenticated;
select public.zn_as('8e8e8e8e-6666-6666-6666-666666666666');
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zn_assert(
  (select count(*) = 1 and bool_and(source = 'self_assessment' and placement_attempt_id is null)
     from public.user_level_history where user_id = auth.uid()),
  'VINCULO: escolha inicial por autoavaliacao nao tem teste vinculado');
reset role;

create temp table zn_e0 as
  select id, started_at from public.user_level_history where user_id = '8e8e8e8e-6666-6666-6666-666666666666';
grant select on zn_e0 to authenticated;
insert into public.user_placement_attempts
  (id, user_id, placement_test_id, status, score_pct, recommended_level_id, started_at, completed_at)
values ('e4e4e4e4-0000-0000-0000-000000000001', '8e8e8e8e-6666-6666-6666-666666666666',
        'bbbbbbbb-0000-0000-0000-0000000000e1', 'completed', 30,
        (select id from public.levels where code = 'A1'), now(), now()),
       ('e4e4e4e4-0000-0000-0000-000000000002', '8e8e8e8e-6666-6666-6666-666666666666',
        'bbbbbbbb-0000-0000-0000-0000000000e1', 'completed', 31,
        (select id from public.levels where code = 'A1'), now(), now());

set role authenticated;
select public.zn_as('8e8e8e8e-6666-6666-6666-666666666666');
-- sem p_placement_attempt_id explicito, o teste recente NAO e vinculado sozinho
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zn_assert(
  (select count(*) = 1 and bool_and(placement_attempt_id is null)
     from public.user_level_history where user_id = auth.uid()),
  'VINCULO: repetir sem informar o teste nao vincula nada');
select public.select_starting_level((select id from public.levels where code = 'A1'),
                                    'e4e4e4e4-0000-0000-0000-000000000001');
select public.zn_assert(
  (select count(*) = 1
          and bool_and(placement_attempt_id = 'e4e4e4e4-0000-0000-0000-000000000001'
                       and source = 'self_assessment' and ended_at is null
                       and id = (select id from zn_e0) and started_at = (select started_at from zn_e0))
     from public.user_level_history where user_id = auth.uid()),
  'VINCULO: mesmo nivel com teste informado vincula o teste na linha ativa, sem linha nova, sem manual_change');
-- o primeiro vinculo e mantido
select public.select_starting_level((select id from public.levels where code = 'A1'),
                                    'e4e4e4e4-0000-0000-0000-000000000002');
select public.select_starting_level((select id from public.levels where code = 'A1'));
select public.zn_assert(
  (select count(*) = 1 and bool_and(placement_attempt_id = 'e4e4e4e4-0000-0000-0000-000000000001')
     from public.user_level_history where user_id = auth.uid()),
  'VINCULO: outro teste ou chamada sem teste nao troca o vinculo ja gravado');
select public.zn_expect_error(
  $q$select public.select_starting_level((select id from public.levels where code = 'A1'), '8f8f8f8f-0000-0000-0000-000000000000')$q$, '42501');
reset role;

\echo ===== TESTES NOTAS E NIVEL PASSARAM =====
