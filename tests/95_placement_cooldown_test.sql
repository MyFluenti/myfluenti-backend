-- =====================================================================
-- MyFluenti - Testes da migration 013: carencia de 7 dias para nova tentativa do
-- nivelamento (start_placement_attempt). PROVISORIO: o intervalo de 7 dias e fixo.
-- Autocontido (nao usa o dev-seed). Roda DEPOIS do 90, no mesmo banco.
-- Helpers com prefixo zq_. Usuarios: 9d (D), 9e (E), f1 (G), f2 (H).
-- Para recuar started_at de tentativas (inclusive encerradas), o teste desliga o
-- trigger de historico como postgres, so durante o update.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

create function public.zq_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zq_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

-- Chama start_placement_attempt e devolve (sqlstate, message, hint, detail, id).
create function public.zq_try(p_test uuid default null)
returns table (state text, msg text, hint text, detail text, id uuid)
language plpgsql as $$
begin
  id := public.start_placement_attempt(p_test);
  return next;
exception when others then
  get stacked diagnostics state = returned_sqlstate, msg = message_text,
                          hint = pg_exception_hint, detail = pg_exception_detail;
  id := null;
  return next;
end $$;

-- Recua started_at (e completed_at, se houver) das tentativas do aluno. Roda como postgres.
create function public.zq_backdate(p_user uuid, p_interval interval) returns void
language plpgsql as $$
begin
  alter table public.user_placement_attempts disable trigger user_placement_attempts_guard;
  update public.user_placement_attempts
     set started_at = started_at - p_interval,
         completed_at = completed_at - p_interval
   where user_id = p_user;
  alter table public.user_placement_attempts enable trigger user_placement_attempts_guard;
end $$;

create table public.zq_ctx (k text primary key, v text);
grant select, insert on public.zq_ctx to authenticated;
create table public.zq_err (k text primary key, state text, msg text, hint text, detail text, id uuid);
grant select, insert on public.zq_err to authenticated;

-- ---------------------------------------------------------------------
-- Setup (postgres): dois testes publicados (v1 e v2), 1 questao cada
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('9d9d9d9d-1111-1111-1111-111111111111', 'zq-d@teste'),
  ('9e9e9e9e-2222-2222-2222-222222222222', 'zq-e@teste');

insert into public.placement_tests (id, code, version_number, title, total_questions) values
  ('bbbbbbbb-0000-0000-0000-0000000000d1', 'zq', 1, 'ZQ v1', 1),
  ('bbbbbbbb-0000-0000-0000-0000000000d2', 'zq', 2, 'ZQ v2', 1);

do $$
declare
  lvl uuid := (select id from public.levels where code = 'A1');
  i int; q uuid; o uuid;
begin
  for i in 1..2 loop
    q := ('b9000000-0000-0000-0000-00000000000' || i)::uuid;
    o := ('b9100000-0000-0000-0000-00000000000' || i)::uuid;
    insert into public.questions (id, question_type, prompt) values (q, 'multiple_choice', 'ZQ ' || i);
    insert into public.answer_options (id, question_id, option_text, position) values (o, q, 'certa', 1);
    insert into private.question_answer_keys (question_id, correct_option_id, explanation)
      values (q, o, 'ZQ explicacao secreta');
    insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
      values (('bbbbbbbb-0000-0000-0000-0000000000d' || i)::uuid, q, 'vocabulary', lvl, 1, 1);
  end loop;
  -- v2 e o publicado mais recente
  update public.placement_tests set is_published = true, published_at = now() - interval '1 day'
   where id = 'bbbbbbbb-0000-0000-0000-0000000000d1';
  update public.placement_tests set is_published = true, published_at = now()
   where id = 'bbbbbbbb-0000-0000-0000-0000000000d2';
end $$;

-- ---------------------------------------------------------------------
-- Assinatura e grants iguais
-- ---------------------------------------------------------------------
select public.zq_assert(
  (select pg_get_function_result(p.oid) = 'uuid'
          and pg_get_function_arguments(p.oid) = 'p_test_id uuid DEFAULT NULL::uuid'
          and p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p where p.oid = 'public.start_placement_attempt(uuid)'::regprocedure),
  'ASSINATURA: start_placement_attempt(p_test_id uuid default null) returns uuid, security definer, search_path vazio');
select public.zq_assert(
  (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'start_placement_attempt'),
  'ASSINATURA: sem sobrecarga');
select public.zq_assert(
  not has_function_privilege('anon', 'public.start_placement_attempt(uuid)', 'execute')
  and not has_function_privilege('public', 'public.start_placement_attempt(uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.start_placement_attempt(uuid)', 'execute'),
  'GRANT: anon e public sem execute, authenticated com execute');

-- ---------------------------------------------------------------------
-- Aluno D: primeira tentativa livre; retomar funciona
-- ---------------------------------------------------------------------
set role authenticated;
select public.zq_as('9d9d9d9d-1111-1111-1111-111111111111');
insert into public.zq_ctx select 'd1', id::text from public.zq_try();
select public.zq_assert(
  (select a.placement_test_id = 'bbbbbbbb-0000-0000-0000-0000000000d2'
     from public.user_placement_attempts a where a.id = (select v::uuid from public.zq_ctx where k = 'd1')),
  'COOLDOWN: primeira tentativa abre sem carencia, no teste publicado mais recente');
select public.zq_assert(
  (select id = (select v::uuid from public.zq_ctx where k = 'd1') and state is null from public.zq_try()),
  'RETOMAR: in_progress devolvida de novo dentro da carencia');
select public.zq_assert(
  (select id = (select v::uuid from public.zq_ctx where k = 'd1') and state is null
     from public.zq_try('bbbbbbbb-0000-0000-0000-0000000000d2')),
  'RETOMAR: com p_test_id explicito tambem');
select public.zq_assert(
  (select count(*) = 1 from public.user_placement_attempts), 'RETOMAR: nao criou segunda tentativa');

-- encerra a tentativa: agora nova tentativa dentro da carencia falha
select public.submit_placement_answer((select v::uuid from public.zq_ctx where k = 'd1'),
  'b9000000-0000-0000-0000-000000000002', jsonb_build_object('option_id', 'b9100000-0000-0000-0000-000000000002'));
select public.finish_placement_attempt((select v::uuid from public.zq_ctx where k = 'd1'));
insert into public.zq_err select 'd_soon', t.* from public.zq_try() t;
insert into public.zq_err select 'd_soon_v1', t.* from public.zq_try('bbbbbbbb-0000-0000-0000-0000000000d1') t;
reset role;

-- erro: SQLSTATE, mensagem, hint no formato exato e nada vazando
select public.zq_assert(
  (select state = 'P0001' and msg = 'placement_retry_too_soon' and id is null from public.zq_err where k = 'd_soon'),
  'COOLDOWN: nova tentativa dentro de 7 dias falha com P0001 placement_retry_too_soon');
select public.zq_assert(
  (select hint ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' from public.zq_err where k = 'd_soon'),
  'COOLDOWN: hint no formato YYYY-MM-DDTHH:MM:SSZ');
select public.zq_assert(
  (select (e.hint::timestamptz) >= l.t + interval '7 days'
          and (e.hint::timestamptz) < l.t + interval '7 days' + interval '1 second'
     from public.zq_err e,
          (select max(started_at) t from public.user_placement_attempts
            where user_id = '9d9d9d9d-1111-1111-1111-111111111111') l
    where e.k = 'd_soon'),
  'COOLDOWN: hint = inicio da ultima tentativa + 7 dias (arredondado para cima ao segundo, nunca antes)');
select public.zq_assert(
  (select coalesce(detail, '') = '' and msg !~* '(ZQ|certa|explicacao|b9100000|b9000000)'
          and coalesce(hint, '') !~* '(ZQ|certa|explicacao|b9100000|b9000000)'
     from public.zq_err where k = 'd_soon'),
  'SEGURANCA: erro sem detail, gabarito, resposta certa nem explicacao');
select public.zq_assert(
  (select state = 'P0001' and msg = 'placement_retry_too_soon' and hint = (select hint from public.zq_err where k = 'd_soon')
     from public.zq_err where k = 'd_soon_v1'),
  'COOLDOWN: vale para qualquer teste (v1 tambem e barrado, mesmo hint)');

-- outro aluno nao e afetado (carencia por aluno)
set role authenticated;
select public.zq_as('9e9e9e9e-2222-2222-2222-222222222222');
insert into public.zq_err select 'e_first', t.* from public.zq_try() t;
reset role;
select public.zq_assert(
  (select state is null and id is not null from public.zq_err where k = 'e_first'),
  'POR ALUNO: a carencia de D nao afeta E');

-- ---------------------------------------------------------------------
-- Depois de 7 dias: recua 6 dias (ainda barra), depois mais 1 dia + (libera)
-- ---------------------------------------------------------------------
select public.zq_backdate('9d9d9d9d-1111-1111-1111-111111111111', interval '6 days');
set role authenticated;
select public.zq_as('9d9d9d9d-1111-1111-1111-111111111111');
insert into public.zq_err select 'd_6d', t.* from public.zq_try() t;
reset role;
select public.zq_assert((select state = 'P0001' from public.zq_err where k = 'd_6d'),
  'COOLDOWN: com 6 dias ainda barra');

select public.zq_backdate('9d9d9d9d-1111-1111-1111-111111111111', interval '1 day 1 minute');
set role authenticated;
select public.zq_as('9d9d9d9d-1111-1111-1111-111111111111');
insert into public.zq_err select 'd_7d', t.* from public.zq_try() t;
reset role;
select public.zq_assert((select state is null and id is not null from public.zq_err where k = 'd_7d'),
  'COOLDOWN: passados 7 dias abre nova tentativa');
select public.zq_assert(
  (select count(*) = 2 and count(*) filter (where status = 'in_progress') = 1
     from public.user_placement_attempts where user_id = '9d9d9d9d-1111-1111-1111-111111111111'),
  'COOLDOWN: historico preservado (antiga encerrada + nova em andamento)');

-- ---------------------------------------------------------------------
-- Tentativa in_progress de versao ANTERIOR (regra da 013 corrigida):
--   p_test_id nulo  -> retoma a in_progress mais recente em qualquer teste publicado;
--   p_test_id dado  -> so retoma a in_progress daquele teste; senao carencia.
-- Aluno E: tentativa em andamento no teste v1, iniciada ha 8 dias.
-- ---------------------------------------------------------------------
select public.zq_backdate('9e9e9e9e-2222-2222-2222-222222222222', interval '8 days');
update public.user_placement_attempts set placement_test_id = 'bbbbbbbb-0000-0000-0000-0000000000d1'
 where user_id = '9e9e9e9e-2222-2222-2222-222222222222';
set role authenticated;
select public.zq_as('9e9e9e9e-2222-2222-2222-222222222222');
insert into public.zq_err select 'e_old', t.* from public.zq_try() t;
reset role;
select public.zq_assert(
  (select state is null
          and id = (select a.id from public.user_placement_attempts a
                     where a.user_id = '9e9e9e9e-2222-2222-2222-222222222222'
                       and a.placement_test_id = 'bbbbbbbb-0000-0000-0000-0000000000d1')
     from public.zq_err where k = 'e_old'),
  'VERSAO ANTIGA: sem p_test_id retoma a in_progress do teste anterior (mesmo com mais de 7 dias)');
select public.zq_assert(
  (select count(*) = 1 from public.user_placement_attempts where user_id = '9e9e9e9e-2222-2222-2222-222222222222'),
  'VERSAO ANTIGA: nao criou outra tentativa');

-- Aluno G: tentativa recente (menos de 7 dias) no teste v1; v2 e o mais recente.
insert into auth.users (id, email) values ('f1f1f1f1-4444-4444-4444-444444444444', 'zq-g@teste');
set role authenticated;
select public.zq_as('f1f1f1f1-4444-4444-4444-444444444444');
insert into public.zq_err select 'g_open_v1', t.* from public.zq_try('bbbbbbbb-0000-0000-0000-0000000000d1') t;
insert into public.zq_err select 'g_null', t.* from public.zq_try() t;
insert into public.zq_err select 'g_v2', t.* from public.zq_try('bbbbbbbb-0000-0000-0000-0000000000d2') t;
reset role;
select public.zq_assert(
  (select n.state is null and n.id = o.id and o.id is not null
     from public.zq_err n, public.zq_err o where n.k = 'g_null' and o.k = 'g_open_v1'),
  'VERSAO ANTIGA: com menos de 7 dias, sem p_test_id devolve a mesma tentativa, sem erro');
select public.zq_assert(
  (select count(*) = 1 from public.user_placement_attempts where user_id = 'f1f1f1f1-4444-4444-4444-444444444444'),
  'VERSAO ANTIGA: continua uma so tentativa');
select public.zq_assert(
  (select state = 'P0001' and msg = 'placement_retry_too_soon' from public.zq_err where k = 'g_v2'),
  'P_TEST_ID: com p_test_id do teste atual (sem in_progress nele) vale a carencia');

-- p_test_id de teste NAO publicado: P0002
insert into public.placement_tests (id, code, version_number, title, total_questions)
  values ('bbbbbbbb-0000-0000-0000-0000000000d3', 'zq', 3, 'ZQ v3 rascunho', 1);
set role authenticated;
select public.zq_as('9d9d9d9d-1111-1111-1111-111111111111');
insert into public.zq_err select 'd_unpub', t.* from public.zq_try('bbbbbbbb-0000-0000-0000-0000000000d3') t;
select public.zq_as('9e9e9e9e-2222-2222-2222-222222222222');
insert into public.zq_err select 'e_unpub', t.* from public.zq_try('bbbbbbbb-0000-0000-0000-0000000000d3') t;
reset role;
select public.zq_assert(
  (select state = 'P0002' and id is null from public.zq_err where k = 'd_unpub'),
  'P_TEST_ID: teste nao publicado falha com P0002');
select public.zq_assert(
  (select state = 'P0002' and id is null from public.zq_err where k = 'e_unpub'),
  'P_TEST_ID: teste nao publicado falha com P0002 mesmo com in_progress em outro teste');

-- ---------------------------------------------------------------------
-- Fronteira exata (mesma transacao, entao now() e o mesmo no setup e na chamada)
-- Aluno H: uma tentativa; recuada para started_at = now() - 168 h (+ 1 s, ou exato).
-- ---------------------------------------------------------------------
create function public.zq_set_started(p_user uuid, p_ts timestamptz) returns void
language plpgsql as $$
begin
  alter table public.user_placement_attempts disable trigger user_placement_attempts_guard;
  update public.user_placement_attempts set started_at = p_ts where user_id = p_user;
  alter table public.user_placement_attempts enable trigger user_placement_attempts_guard;
end $$;

insert into auth.users (id, email) values ('f2f2f2f2-5555-5555-5555-555555555555', 'zq-h@teste');
set role authenticated;
select public.zq_as('f2f2f2f2-5555-5555-5555-555555555555');
insert into public.zq_ctx select 'h1', id::text from public.zq_try();
reset role;
-- encerra sem alterar o resto: fica abandonada (permitido pelo guard enquanto in_progress)
update public.user_placement_attempts set status = 'abandoned' where user_id = 'f2f2f2f2-5555-5555-5555-555555555555';

begin;
select public.zq_set_started('f2f2f2f2-5555-5555-5555-555555555555', now() - interval '168 hours' + interval '1 second');
set role authenticated;
select public.zq_as('f2f2f2f2-5555-5555-5555-555555555555');
insert into public.zq_err select 'h_before', t.* from public.zq_try() t;
reset role;
commit;
select public.zq_assert((select state = 'P0001' and msg = 'placement_retry_too_soon' from public.zq_err where k = 'h_before'),
  'FRONTEIRA: 1 segundo antes de completar 168 horas ainda barra');

begin;
select public.zq_set_started('f2f2f2f2-5555-5555-5555-555555555555', now() - interval '168 hours');
set role authenticated;
select public.zq_as('f2f2f2f2-5555-5555-5555-555555555555');
insert into public.zq_err select 'h_at', t.* from public.zq_try() t;
reset role;
commit;
select public.zq_assert((select state is null and id is not null from public.zq_err where k = 'h_at'),
  'FRONTEIRA: no instante exato (started_at + 168 horas = agora) ja abre');

-- 168 horas, nao '7 days': o fuso da sessao nao muda a carencia
select public.zq_assert(
  (select position('168 hours' in pg_get_functiondef('public.start_placement_attempt(uuid)'::regprocedure)) > 0
      and position('7 days' in pg_get_functiondef('public.start_placement_attempt(uuid)'::regprocedure)) = 0),
  'FUSO: a carencia usa 168 horas (sem interval de dias)');

\echo ===== TESTES CARENCIA NIVELAMENTO PASSARAM =====
