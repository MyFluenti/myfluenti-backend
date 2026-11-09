-- =====================================================================
-- MyFluenti - Testes da migration 006: exclusao de conta (delete_my_account)
-- Autocontido (nao usa o dev-seed). Roda DEPOIS dos tests 10, 20 e 30, no mesmo banco:
--   (1) Supabase local: db reset -> 10 -> 20 -> 30 -> 40
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> 20 -> 30 -> 40
-- Helpers com prefixo zd_. Usuarios: 1d1d1d1d (A), 2d2d2d2d (B).
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create table public.zd_ids (k text primary key, id uuid);
grant select on public.zd_ids to authenticated;
create table public.zd_snap (k text, uid uuid, counts jsonb);

create function public.zd_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zd_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zd_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;
create function public.zd_id(p_k text) returns uuid language sql stable as $$
  select id from public.zd_ids where k = p_k
$$;

-- Linhas do usuario em TODA tabela com FK para auth.users (descoberta no catalogo,
-- entao tabelas futuras ficam cobertas). Roda como postgres.
-- Devolve {"schema.tabela.coluna": contagem}. So FKs de uma coluna.
create function public.zd_fk_counts(p_uid uuid) returns jsonb
language plpgsql as $$
declare r record; n bigint; res jsonb := '{}'::jsonb;
begin
  for r in
    select c.conrelid::regclass::text as tbl, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and array_length(c.conkey, 1) = 1
     order by 1, 2
  loop
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into n using p_uid;
    res := res || jsonb_build_object(r.tbl || '.' || r.col, n);
  end loop;
  return res;
end $$;

create function public.zd_total(p_counts jsonb) returns bigint language sql immutable as $$
  select coalesce(sum(value::bigint), 0) from jsonb_each_text(p_counts)
$$;
create function public.zd_tables_with_rows(p_counts jsonb) returns int language sql immutable as $$
  select count(*)::int from jsonb_each_text(p_counts) where value::bigint > 0
$$;

-- Aluno cria dados reais em varias tabelas, so por RPC ou escrita direta permitida.
create function public.zd_populate() returns void language plpgsql as $$
declare
  pa uuid; la uuid;
begin
  perform public.select_starting_level(public.zd_id('lvl'));
  pa := public.start_placement_attempt(public.zd_id('pt'));
  perform public.submit_placement_answer(pa, public.zd_id('pq'),
    jsonb_build_object('option_id', public.zd_id('pq_ok')));
  perform public.finish_placement_attempt(pa);

  la := public.start_lesson_attempt(public.zd_id('lesson'));
  perform public.record_section_view(public.zd_id('section'));
  perform public.submit_lesson_answer(la, public.zd_id('q1'), jsonb_build_object('option_id', public.zd_id('q1_ok')));
  perform public.submit_lesson_answer(la, public.zd_id('q2'), jsonb_build_object('option_id', public.zd_id('q2_bad')));
  perform public.finish_lesson_attempt(la);
  -- segunda tentativa, deixada em andamento
  perform public.start_lesson_attempt(public.zd_id('lesson'));

  perform public.record_review_result(p_vocabulary_id := public.zd_id('vocab'), p_quality := 4::smallint);
  perform public.record_review_result(p_grammar_topic_id := public.zd_id('topic'), p_quality := 3::smallint);

  insert into public.user_vocabulary (user_id, vocabulary_id, is_favorite)
    values (auth.uid(), public.zd_id('vocab'), true)
    on conflict (user_id, vocabulary_id) do update set is_favorite = true;
  insert into public.user_favorite_examples (user_id, vocabulary_example_id)
    values (auth.uid(), public.zd_id('vex'));
  insert into public.user_notes (user_id, lesson_id, body) values (auth.uid(), public.zd_id('lesson'), 'nota zd');
  insert into public.user_notes (user_id, vocabulary_id, body) values (auth.uid(), public.zd_id('vocab'), 'nota zd 2');
  update public.profiles set display_name = 'Aluno ZD' where id = auth.uid();
end $$;

-- ---------------------------------------------------------------------
-- Setup (postgres): conteudo minimo publicado + 2 alunos
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('1d1d1d1d-1111-1111-1111-111111111111', 'zd-a@teste'),
  ('2d2d2d2d-2222-2222-2222-222222222222', 'zd-b@teste');

insert into public.levels (code, title, position) values
  ('A1', 'Iniciante', 1), ('A2', 'Basico', 2), ('B1', 'Intermediario', 3),
  ('B2', 'Intermediario avancado', 4), ('C1', 'Avancado', 5), ('C2', 'Dominio', 6)
on conflict (code) do nothing;

do $$
declare
  lvl uuid := (select id from public.levels where code = 'A1');
  m uuid := '0d0d0d0d-0000-0000-0000-000000000071';
  l uuid; v uuid; s uuid; e uuid; q uuid; o1 uuid; o2 uuid; i int;
  t uuid; voc uuid; vex uuid; pt uuid; pq uuid;
begin
  insert into public.zd_ids values ('lvl', lvl), ('module', m);
  insert into public.modules (id, level_id, title, position, access_tier, is_published)
    values (m, lvl, 'ZD free', 71, 'free', true);

  insert into public.grammar_topics (slug, title, category, level_id, is_published)
    values ('zd-topic', 'ZD topic', 'zd', lvl, true) returning id into t;
  insert into public.vocabulary (lemma, part_of_speech, meaning_pt, level_id, is_published)
    values ('zdword', 'noun', 'palavra zd', lvl, true) returning id into voc;
  insert into public.vocabulary_examples (vocabulary_id, example_en, example_pt, position)
    values (voc, 'A zdword.', 'Uma zdword.', 1) returning id into vex;
  insert into public.zd_ids values ('topic', t), ('vocab', voc), ('vex', vex);

  insert into public.lessons (module_id, slug, position) values (m, 'zd-l1', 1) returning id into l;
  insert into public.lesson_versions (lesson_id, version_number, title) values (l, 1, 'ZD v1') returning id into v;
  insert into public.lesson_sections (lesson_version_id, position, section_type, title)
    values (v, 1, 'explanation', 'Explicacao') returning id into s;
  insert into public.exercises (lesson_version_id, position, title) values (v, 1, 'Ex') returning id into e;
  insert into public.lesson_grammar_topics (lesson_version_id, grammar_topic_id, is_primary) values (v, t, true);
  for i in 1..2 loop
    insert into public.questions (lesson_version_id, exercise_id, question_type, prompt, position, grammar_topic_id)
      values (v, e, 'multiple_choice', 'ZDQ ' || i, i, t) returning id into q;
    insert into public.answer_options (question_id, option_text, position) values (q, 'certa', 1) returning id into o1;
    insert into public.answer_options (question_id, option_text, position) values (q, 'errada', 2) returning id into o2;
    insert into private.question_answer_keys (question_id, correct_option_id, explanation) values (q, o1, 'expl zd');
    insert into public.zd_ids values ('q' || i, q), ('q' || i || '_ok', o1), ('q' || i || '_bad', o2);
  end loop;
  update public.lesson_versions set is_published = true where id = v;
  insert into public.zd_ids values ('lesson', l), ('section', s);

  -- nivelamento de 1 questao (nao e o oficial de 30), publicado
  insert into public.placement_tests (code, version_number, title, total_questions)
    values ('zd', 1, 'ZD nivelamento', 1) returning id into pt;
  insert into public.questions (question_type, prompt) values ('multiple_choice', 'ZDP 1') returning id into pq;
  insert into public.answer_options (question_id, option_text, position) values (pq, 'certa', 1) returning id into o1;
  insert into public.answer_options (question_id, option_text, position) values (pq, 'errada', 2);
  insert into private.question_answer_keys (question_id, correct_option_id) values (pq, o1);
  insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
    values (pt, pq, 'vocabulary', lvl, 1, 1);
  update public.placement_tests set is_published = true where id = pt;
  insert into public.zd_ids values ('pt', pt), ('pq', pq), ('pq_ok', o1);
end $$;

-- Plano e assinatura para os dois (tabela com FK para auth.users)
insert into public.subscription_plans (id, code, name, tier)
  values ('dddddddd-0000-0000-0000-000000000001', 'zd_premium', 'Premium (teste ZD)', 'premium')
on conflict (code) do nothing;
insert into public.user_subscriptions (user_id, plan_id, status, current_period_end)
  select u, (select id from public.subscription_plans where code = 'zd_premium'), 'active', now() + interval '30 days'
    from unnest(array['1d1d1d1d-1111-1111-1111-111111111111'::uuid, '2d2d2d2d-2222-2222-2222-222222222222'::uuid]) u;
insert into public.user_module_progress (user_id, module_id)
  select u, public.zd_id('module')
    from unnest(array['1d1d1d1d-1111-1111-1111-111111111111'::uuid, '2d2d2d2d-2222-2222-2222-222222222222'::uuid]) u
on conflict do nothing;

-- ---------------------------------------------------------------------
-- Permissoes estaticas
-- ---------------------------------------------------------------------
select public.zd_assert((select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'delete_my_account'
      and p.pronargs = 1 and p.proargtypes[0] = 'text'::regtype),
  'SEC: delete_my_account tem um unico parametro text (sem parametro de id)');
select public.zd_assert(not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'delete_my_account'
       and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig))
            or has_function_privilege('anon', p.oid, 'EXECUTE')
            or not has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
  'SEC: security definer, search_path vazio, sem execute para anon, com execute para authenticated');
-- No Supabase local, o "db reset" reconcede EXECUTE a service_role em todas as funcoes de public
-- depois das migrations (mesmo as antigas); o revoke da migration so vale no stub / em db push.
-- service_role ignora RLS de qualquer forma e, sem auth.uid(), a RPC falha com 28000.
select public.zd_assert(has_function_privilege('authenticated', 'public.delete_my_account(text)', 'EXECUTE'),
  'SEC: authenticated executa delete_my_account');
do $$
begin
  if to_regclass('auth.sessions') is not null then
    raise notice 'SKIP: service_role recebe EXECUTE do db reset local; verificado so no stub';
    return;
  end if;
  perform public.zd_assert(not has_function_privilege('service_role', 'public.delete_my_account(text)', 'EXECUTE'),
    'SEC: service_role sem EXECUTE (revoke da migration)');
end $$;
select public.zd_assert(not has_function_privilege('anon', 'public.delete_my_account(text)', 'EXECUTE'),
  'SEC: has_function_privilege(anon) e falso');
select public.zd_assert(
  (select array_agg(attname::text order by attnum) from pg_attribute
    where attrelid = 'private.account_deletions'::regclass and attnum > 0 and not attisdropped) = array['id', 'deleted_at'],
  'LGPD: private.account_deletions so tem as colunas id e deleted_at');
select public.zd_assert(
  not has_table_privilege('anon', 'private.account_deletions', 'SELECT')
  and not has_table_privilege('authenticated', 'private.account_deletions', 'SELECT')
  and not has_table_privilege('authenticated', 'private.account_deletions', 'INSERT')
  and not has_table_privilege('authenticated', 'private.account_deletions', 'DELETE'),
  'LGPD: anon e authenticated sem privilegio na tabela de contagem');
select public.zd_assert((select relrowsecurity from pg_class where oid = 'private.account_deletions'::regclass),
  'LGPD: RLS ligado em private.account_deletions');

-- ---------------------------------------------------------------------
-- anon / sem login
-- ---------------------------------------------------------------------
set role anon;
select public.zd_expect_error($q$select public.delete_my_account('EXCLUIR')$q$, '42501', 'permission denied');
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub', '', false);
select public.zd_expect_error($q$select public.delete_my_account('EXCLUIR')$q$, '28000', 'Autenticacao obrigatoria');
reset role;

-- Dados dos dois alunos
set role authenticated;
select public.zd_as('1d1d1d1d-1111-1111-1111-111111111111');
select public.zd_populate();
select public.zd_as('2d2d2d2d-2222-2222-2222-222222222222');
select public.zd_populate();
reset role;

-- fila de revisao vencida + sessao de revisao (review_sessions / review_session_items)
update public.review_schedule set due_at = now() - interval '1 day';
set role authenticated;
select public.zd_as('1d1d1d1d-1111-1111-1111-111111111111');
select public.submit_review_answer(public.start_review_session(), public.zd_id('q2'),
  jsonb_build_object('option_id', public.zd_id('q2_ok')));
select public.zd_as('2d2d2d2d-2222-2222-2222-222222222222');
select public.submit_review_answer(public.start_review_session(), public.zd_id('q2'),
  jsonb_build_object('option_id', public.zd_id('q2_ok')));
reset role;

-- sessao de login (so se existir auth.sessions, ou seja, Supabase real)
do $$
begin
  if to_regclass('auth.sessions') is null then
    raise notice 'SKIP: auth.sessions ausente (stub); sessao/refresh token nao testados';
    return;
  end if;
  insert into auth.sessions (id, user_id) values
    ('5d5d5d5d-0000-0000-0000-00000000000a', '1d1d1d1d-1111-1111-1111-111111111111'),
    ('5d5d5d5d-0000-0000-0000-00000000000b', '2d2d2d2d-2222-2222-2222-222222222222');
  insert into auth.refresh_tokens (token, user_id, session_id) values
    ('zd-token-a', '1d1d1d1d-1111-1111-1111-111111111111', '5d5d5d5d-0000-0000-0000-00000000000a'),
    ('zd-token-b', '2d2d2d2d-2222-2222-2222-222222222222', '5d5d5d5d-0000-0000-0000-00000000000b');
  perform public.zd_assert((select count(*) = 2 from auth.sessions where user_id in
      ('1d1d1d1d-1111-1111-1111-111111111111', '2d2d2d2d-2222-2222-2222-222222222222')),
    'SESSAO: sessoes de A e B criadas');
end $$;

-- rastro fora da cascata: audit_log_entries e flow_state (so no Supabase real)
do $$
begin
  if to_regclass('auth.audit_log_entries') is null or to_regclass('auth.flow_state') is null then
    raise notice 'SKIP: auth.audit_log_entries/flow_state ausentes (stub); rastro nao testado';
    return;
  end if;
  insert into auth.audit_log_entries (id, payload) values
    ('a0d0d0d0-0000-0000-0000-00000000000a', '{"action":"login","actor_id":"1d1d1d1d-1111-1111-1111-111111111111","actor_username":"zd-a@teste","traits":{}}'),
    ('a0d0d0d0-0000-0000-0000-00000000000c', '{"action":"login","actor_username":"ZD-A@teste","traits":{}}'),
    ('a0d0d0d0-0000-0000-0000-00000000000d', '{"action":"user_updated_password","actor_id":"00000000-0000-0000-0000-0000000000ff","actor_username":"admin@teste","traits":{"user_id":"1d1d1d1d-1111-1111-1111-111111111111"}}'),
    ('a0d0d0d0-0000-0000-0000-00000000000e', '{"action":"user_recovery_requested","traits":{"user_email":"zd-a@teste"}}'),
    ('a0d0d0d0-0000-0000-0000-00000000000b', '{"action":"login","actor_id":"2d2d2d2d-2222-2222-2222-222222222222","actor_username":"zd-b@teste","traits":{}}'),
    ('a0d0d0d0-0000-0000-0000-0000000000bb', '{"action":"login","actor_username":"zd-b@teste","traits":{"user_id":"2d2d2d2d-2222-2222-2222-222222222222"}}'),
    ('a0d0d0d0-0000-0000-0000-0000000000ee', '{"action":"login","actor_username":"zd-outro@teste","traits":{}}');
  insert into auth.flow_state (id, user_id, provider_type, authentication_method) values
    ('f0d0d0d0-0000-0000-0000-00000000000a', '1d1d1d1d-1111-1111-1111-111111111111', 'email', 'password'),
    ('f0d0d0d0-0000-0000-0000-00000000000b', '2d2d2d2d-2222-2222-2222-222222222222', 'email', 'password');
  perform public.zd_assert((select count(*) = 7 from auth.audit_log_entries where id::text like 'a0d0d0d0%')
    and (select count(*) = 2 from auth.flow_state where id::text like 'f0d0d0d0%'),
    'RASTRO: linhas de audit_log_entries e flow_state de A e B criadas');
end $$;

insert into public.zd_snap
  select 'A_before', '1d1d1d1d-1111-1111-1111-111111111111', public.zd_fk_counts('1d1d1d1d-1111-1111-1111-111111111111');
insert into public.zd_snap
  select 'B_before', '2d2d2d2d-2222-2222-2222-222222222222', public.zd_fk_counts('2d2d2d2d-2222-2222-2222-222222222222');

select public.zd_assert((select public.zd_tables_with_rows(counts) >= 14 from public.zd_snap where k = 'A_before'),
  'DADOS: aluno A tem linhas em pelo menos 14 colunas com FK para auth.users');
select public.zd_assert((select public.zd_tables_with_rows(counts) >= 14 from public.zd_snap where k = 'B_before'),
  'DADOS: aluno B tambem tem dados em varias tabelas');
select public.zd_assert((select count(*) > 0 from public.user_exercise_attempts x
                           join public.review_sessions s on s.id = x.review_session_id
                          where s.user_id = '1d1d1d1d-1111-1111-1111-111111111111'),
  'DADOS: A tem resposta de revisao dentro de uma sessao de revisao');

select count(*) as zd_deletions_before from private.account_deletions \gset

-- ---------------------------------------------------------------------
-- Confirmacao invalida: nada e apagado
-- ---------------------------------------------------------------------
set role authenticated;
select public.zd_as('1d1d1d1d-1111-1111-1111-111111111111');
select public.zd_expect_error($q$select public.delete_my_account(null)$q$, '22023', 'confirmation_required');
select public.zd_expect_error($q$select public.delete_my_account('')$q$, '22023', 'confirmation_required');
select public.zd_expect_error($q$select public.delete_my_account('excluir')$q$, '22023', 'confirmation_required');
select public.zd_expect_error($q$select public.delete_my_account('EXCLUIR ')$q$, '22023', 'confirmation_required');
select public.zd_expect_error($q$select public.delete_my_account(' EXCLUIR')$q$, '22023', 'confirmation_required');
select public.zd_expect_error($q$select public.delete_my_account('DELETE')$q$, '22023', 'confirmation_required');
reset role;

select public.zd_assert(
  exists (select 1 from auth.users where id = '1d1d1d1d-1111-1111-1111-111111111111')
  and public.zd_fk_counts('1d1d1d1d-1111-1111-1111-111111111111') = (select counts from public.zd_snap where k = 'A_before')
  and (select count(*) = :zd_deletions_before from private.account_deletions),
  'CONFIRMACAO: confirmacao invalida nao apaga nada nem conta exclusao');

-- ---------------------------------------------------------------------
-- A exclui a propria conta
-- ---------------------------------------------------------------------
set role authenticated;
select public.zd_as('1d1d1d1d-1111-1111-1111-111111111111');
select set_config('zd.result', public.delete_my_account('EXCLUIR')::text, false);
reset role;

select public.zd_assert(current_setting('zd.result')::jsonb = '{"deleted": true}'::jsonb, 'DELETE: retorno {"deleted": true}');
select public.zd_assert(not exists (select 1 from auth.users where id = '1d1d1d1d-1111-1111-1111-111111111111'),
  'DELETE: auth.users de A removido');

-- varredura dinamica: nenhuma tabela com FK para auth.users tem linha de A
do $$
declare r record; leftover text := '';
begin
  for r in select key, value::bigint as n
             from jsonb_each_text(public.zd_fk_counts('1d1d1d1d-1111-1111-1111-111111111111'))
            where value::bigint > 0 loop
    leftover := leftover || r.key || '=' || r.n || ' ';
  end loop;
  perform public.zd_assert(leftover = '', 'DELETE: nenhuma tabela com FK para auth.users guarda linha de A ' || leftover);
  perform public.zd_assert(
    (select count(*) from jsonb_object_keys(public.zd_fk_counts('1d1d1d1d-1111-1111-1111-111111111111'))) >= 18,
    'DELETE: a varredura cobriu pelo menos 18 colunas com FK para auth.users');
end $$;

-- filhas sem FK direta para auth.users nao ficam orfas
select public.zd_assert(
  not exists (select 1 from public.user_exercise_attempts x where x.review_session_id is not null
                 and x.review_session_id not in (select id from public.review_sessions))
  and not exists (select 1 from public.user_exercise_attempts x where x.user_id = '1d1d1d1d-1111-1111-1111-111111111111'),
  'DELETE: respostas de revisao e de aula de A removidas, sem orfaos');

do $$
begin
  if to_regclass('auth.sessions') is null then
    raise notice 'SKIP: auth.sessions ausente (stub)';
    return;
  end if;
  perform public.zd_assert(
    not exists (select 1 from auth.sessions where user_id = '1d1d1d1d-1111-1111-1111-111111111111')
    and not exists (select 1 from auth.refresh_tokens where token = 'zd-token-a'),
    'SESSAO: sessao e refresh token de A sumiram');
  perform public.zd_assert(
    exists (select 1 from auth.sessions where user_id = '2d2d2d2d-2222-2222-2222-222222222222')
    and exists (select 1 from auth.refresh_tokens where token = 'zd-token-b'),
    'SESSAO: sessao e refresh token de B intactos');
end $$;

do $$
begin
  if to_regclass('auth.audit_log_entries') is null or to_regclass('auth.flow_state') is null then
    raise notice 'SKIP: auth.audit_log_entries/flow_state ausentes (stub)';
    return;
  end if;
  perform public.zd_assert(
    not exists (select 1 from auth.audit_log_entries where id::text like 'a0d0d0d0%'
                  and id::text in ('a0d0d0d0-0000-0000-0000-00000000000a', 'a0d0d0d0-0000-0000-0000-00000000000c',
                                   'a0d0d0d0-0000-0000-0000-00000000000d', 'a0d0d0d0-0000-0000-0000-00000000000e'))
    and not exists (select 1 from auth.flow_state where id = 'f0d0d0d0-0000-0000-0000-00000000000a'),
    'RASTRO: audit_log_entries (actor_id, traits.user_id, actor_username, traits.user_email) e flow_state de A sumiram');
  perform public.zd_assert(
    (select count(*) = 3 from auth.audit_log_entries where id::text in
       ('a0d0d0d0-0000-0000-0000-00000000000b', 'a0d0d0d0-0000-0000-0000-0000000000bb', 'a0d0d0d0-0000-0000-0000-0000000000ee'))
    and exists (select 1 from auth.flow_state where id = 'f0d0d0d0-0000-0000-0000-00000000000b'),
    'RASTRO: linhas de B e de terceiros em audit_log_entries e flow_state ficaram intactas');
end $$;

-- contador anonimo
select public.zd_assert((select count(*) = :zd_deletions_before + 1 from private.account_deletions),
  'LGPD: private.account_deletions ganhou exatamente 1 linha');
select public.zd_assert((select deleted_at between now() - interval '1 hour' and now() + interval '1 minute'
                           from private.account_deletions order by id desc limit 1),
  'LGPD: a linha nova tem deleted_at recente');
set role authenticated;
select public.zd_expect_error($q$select * from private.account_deletions$q$, '42501');
select public.zd_expect_error($q$insert into private.account_deletions default values$q$, '42501');
reset role;
set role anon;
select public.zd_expect_error($q$select * from private.account_deletions$q$, '42501');
reset role;

-- ---------------------------------------------------------------------
-- B intacto; A nao alcanca B; segunda chamada
-- ---------------------------------------------------------------------
select public.zd_assert(
  exists (select 1 from auth.users where id = '2d2d2d2d-2222-2222-2222-222222222222')
  and public.zd_fk_counts('2d2d2d2d-2222-2222-2222-222222222222') = (select counts from public.zd_snap where k = 'B_before'),
  'ISOLAMENTO: B segue com todos os dados (contagens identicas as de antes)');

set role authenticated;
select public.zd_as('1d1d1d1d-1111-1111-1111-111111111111');
select public.zd_expect_error($q$select public.delete_my_account('EXCLUIR')$q$, 'P0002', 'account_not_found');
select public.zd_expect_error($q$select public.delete_my_account('2d2d2d2d-2222-2222-2222-222222222222')$q$, '22023', 'confirmation_required');
reset role;

select public.zd_assert(
  exists (select 1 from auth.users where id = '2d2d2d2d-2222-2222-2222-222222222222')
  and public.zd_fk_counts('2d2d2d2d-2222-2222-2222-222222222222') = (select counts from public.zd_snap where k = 'B_before')
  and (select count(*) = :zd_deletions_before + 1 from private.account_deletions),
  'ISOLAMENTO: segunda chamada de A falha e nao toca B nem o contador');

-- B ainda enxerga so o que e dele e pode excluir a si mesmo
set role authenticated;
select public.zd_as('2d2d2d2d-2222-2222-2222-222222222222');
select public.zd_assert((select count(*) = 2 from public.user_notes where body like 'nota zd%'),
  'ISOLAMENTO: B ve apenas as proprias 2 notas');
select public.delete_my_account('EXCLUIR');
reset role;
select public.zd_assert(not exists (select 1 from auth.users where id = '2d2d2d2d-2222-2222-2222-222222222222')
  and public.zd_total(public.zd_fk_counts('2d2d2d2d-2222-2222-2222-222222222222')) = 0
  and (select count(*) = :zd_deletions_before + 2 from private.account_deletions),
  'DELETE: B tambem se exclui por completo e o contador soma 2');

\echo ===== TESTES EXCLUSAO DE CONTA PASSARAM =====
