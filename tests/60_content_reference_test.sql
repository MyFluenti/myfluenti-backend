-- =====================================================================
-- MyFluenti - Testes da migration 009: dados de referencia para o importador
--   normalize_text (apostrofo/aspas tipograficos), renormalizacao de accepted_answers,
--   niveis A1..C2, modules.slug, lesson_versions.content_hash.
-- Autocontido. Roda DEPOIS do 50, no mesmo banco:
--   (1) Supabase local: db reset -> 10 -> 20 -> 30 -> 40 -> 50 -> 60
--   (2) PostgreSQL 16 puro: stub -> migrations -> 10 -> 20 -> 30 -> 40 -> 50 -> 60
-- Helpers com prefixo zr_. Usuario: f6f6f6f6 (aluno).
-- O arquivo e ASCII: acentos e aspas tipograficas entram por escapes U&'\XXXX'.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

create function public.zr_assert(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function public.zr_expect_error(p_sql text, p_state text default null, p_msg text default null)
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

create function public.zr_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false)
$$;

-- Normalizacao ANTIGA (migration 003), reproduzida inline para o "antes e depois".
create function public.zr_old_normalize(p text) returns text language sql immutable as $$
  select btrim(regexp_replace(
           regexp_replace(lower(coalesce(p, '')), '[.,!?;:"]', '', 'g'),
           '\s+', ' ', 'g'))
$$;

-- ---------------------------------------------------------------------
-- 1. normalize_text: antes e depois
-- ---------------------------------------------------------------------
select public.zr_assert(public.zr_old_normalize(U&'We\2019re friends') <> 'we''re friends',
  'NORM-01 antes: a expressao antiga NAO normaliza "We<U+2019>re friends" para "we''re friends"');
select public.zr_assert(private.normalize_text(U&'We\2019re friends') = 'we''re friends',
  'NORM-02 depois: a funcao nova normaliza o apostrofo curvo U+2019');
select public.zr_assert(private.normalize_text(U&'We\2018re friends') = 'we''re friends',
  'NORM-03 apostrofo U+2018 vira apostrofo reto');
select public.zr_assert(private.normalize_text(U&'We\02BCre friends') = 'we''re friends',
  'NORM-04 modificador U+02BC vira apostrofo reto');
select public.zr_assert(private.normalize_text(U&'\201CHello\201D, world!') = 'hello world',
  'NORM-05 aspas curvas U+201C/U+201D viram aspas retas e saem com a pontuacao');
select public.zr_assert(private.normalize_text(U&'\2018hi\2019') = '''hi''',
  'NORM-06 apostrofos curvos nas pontas viram apostrofos retos (apostrofo nao e pontuacao removida)');
select public.zr_assert(private.normalize_text(E'  Hello,\t  WORLD!!  ') = 'hello world',
  'NORM-07 minusculas, pontuacao removida e espacos colapsados/aparados (comportamento antigo mantido)');
select public.zr_assert(private.normalize_text('We''re friends.') = 'we''re friends',
  'NORM-08 apostrofo reto continua igual');
select public.zr_assert(private.normalize_text(null) = '' and private.normalize_text('') = '',
  'NORM-09 null e vazio continuam virando vazio');
select public.zr_assert(private.normalize_text(U&'Don\2019t stop; "now"?') = private.normalize_text('Don''t stop now'),
  'NORM-10 curvo e reto com pontuacao e aspas chegam ao mesmo texto');
select public.zr_assert(
  (select p.provolatile = 'i' and p.proconfig = array['search_path=""'] and not p.prosecdef
     from pg_proc p where p.oid = 'private.normalize_text(text)'::regprocedure),
  'NORM-11 normalize_text segue immutable, search_path vazio e sem security definer');
select public.zr_assert(
  (select count(*) = 0 from private.accepted_answers a
    where a.normalized_text is distinct from private.normalize_text(a.answer_text)),
  'RENORM-01 todas as linhas de accepted_answers tem normalized_text = normalize_text(answer_text)');
select public.zr_assert(
  (select count(*) = 2 from pg_trigger t
    where t.tgrelid = 'private.accepted_answers'::regclass
      and t.tgname in ('accepted_answers_guard', 'accepted_answers_word_order') and t.tgenabled = 'O'),
  'RENORM-02 os triggers accepted_answers_guard e accepted_answers_word_order estao habilitados');

-- ---------------------------------------------------------------------
-- Setup (postgres): modulo, aula publicada minima e uma versao nao publicada
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values ('f6f6f6f6-6666-6666-6666-666666666666', 'zr-a@teste');

insert into public.modules (id, level_id, slug, title, position, access_tier, is_published)
  values ('0f0f0f0f-0000-0000-0000-000000000080', (select id from public.levels where code = 'A1'),
          'zr-m80', 'ZR modulo', 80, 'free', true);
insert into public.user_module_progress (user_id, module_id)
  values ('f6f6f6f6-6666-6666-6666-666666666666', '0f0f0f0f-0000-0000-0000-000000000080');

create table public.zr_ids (k text primary key, id uuid);
grant select on public.zr_ids to authenticated;

do $$
declare l uuid; v uuid; e uuid; q uuid; i int;
begin
  insert into public.lessons (module_id, slug, position)
    values ('0f0f0f0f-0000-0000-0000-000000000080', 'zr-l1', 1) returning id into l;
  insert into public.lesson_versions (lesson_id, version_number, title) values (l, 1, 'ZR v1') returning id into v;
  insert into public.lesson_sections (lesson_version_id, position, section_type, title)
    values (v, 1, 'explanation', 'Explicacao');
  insert into public.exercises (lesson_version_id, position, title) values (v, 1, 'Ex') returning id into e;
  insert into public.zr_ids values ('lesson', l), ('version', v);
  for i in 1..3 loop
    insert into public.questions (lesson_version_id, exercise_id, question_type, prompt, position)
      values (v, e, 'fill_blank', 'ZRQ ' || i, i) returning id into q;
    insert into public.zr_ids values ('q' || i, q);
    insert into private.question_answer_keys (question_id, correct_option_id, explanation)
      values (q, null, 'EXPLICACAO-ZR ' || i);
  end loop;
  -- q1: resposta aceita com apostrofo reto; q2: aceita gravada COM apostrofo curvo; q3: so "we are friends"
  insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
    select id, 'We''re friends', private.normalize_text('We''re friends'), true from public.zr_ids where k = 'q1';
  insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
    select id, U&'They\2019re here', private.normalize_text(U&'They\2019re here'), true from public.zr_ids where k = 'q2';
  insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
    select id, 'We are friends', private.normalize_text('We are friends'), true from public.zr_ids where k = 'q3';
  update public.lesson_versions set is_published = true where id = v;
end $$;

-- ---------------------------------------------------------------------
-- 2. Ponta a ponta: aula e revisao
-- ---------------------------------------------------------------------
set role authenticated;
select public.zr_as('f6f6f6f6-6666-6666-6666-666666666666');
do $$
declare a uuid; r jsonb;
begin
  a := public.start_lesson_attempt((select id from public.zr_ids where k = 'lesson'));
  perform set_config('zr.attempt', a::text, false);
  r := public.submit_lesson_answer(a, (select id from public.zr_ids where k = 'q1'),
         jsonb_build_object('text', U&'We\2019re friends.'));
  perform public.zr_assert((r->>'is_correct')::boolean,
    'E2E-01 aula: resposta aceita "We''re friends" aceita "We<U+2019>re friends." (iPhone)');
  r := public.submit_lesson_answer(a, (select id from public.zr_ids where k = 'q2'),
         jsonb_build_object('text', 'They''re here'));
  perform public.zr_assert((r->>'is_correct')::boolean,
    'E2E-02 aula: resposta aceita gravada com apostrofo curvo aceita a digitacao com apostrofo reto');
  r := public.submit_lesson_answer(a, (select id from public.zr_ids where k = 'q3'),
         jsonb_build_object('text', U&'We\2019re friends'));
  perform public.zr_assert(not (r->>'is_correct')::boolean,
    'E2E-03 aula: "We<U+2019>re friends" continua errada onde a aceita e "We are friends"');
  perform public.zr_assert(r::text !~* '(accepted|correct_option|answer_text)',
    'E2E-04 a resposta da RPC nao traz gabarito');
end $$;
reset role;

-- Encerra a tentativa (a revisao so aceita questao de tentativa encerrada) e agenda q1 como vencida.
update public.user_lesson_attempts
   set status = 'completed', completed_at = now(), score_pct = 66.67, earned_points = 2, total_points = 3
 where id = current_setting('zr.attempt')::uuid;
insert into public.review_schedule (user_id, question_id, due_at)
  values ('f6f6f6f6-6666-6666-6666-666666666666', (select id from public.zr_ids where k = 'q1'), now() - interval '1 hour');

set role authenticated;
select public.zr_as('f6f6f6f6-6666-6666-6666-666666666666');
do $$
declare s uuid; r jsonb;
begin
  s := public.start_review_session();
  r := public.submit_review_answer(s, (select id from public.zr_ids where k = 'q1'),
         jsonb_build_object('text', U&'We\2019re friends.'));
  perform public.zr_assert((r->>'is_correct')::boolean,
    'E2E-05 revisao: "We<U+2019>re friends." tambem e aceita pelo caminho da revisao');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 3. Renormalizacao (replica do bloco da migration 009 sobre dados antigos simulados)
-- ---------------------------------------------------------------------
-- Estado "antigo": q4 (versao NAO publicada) com duas variantes que passam a normalizar igual
-- (reta e curva, a curva gravada com o normalized_text antigo) e q5 (versao PUBLICADA) com uma linha curva.
do $$
declare l uuid; v1 uuid; v2 uuid; q4 uuid; q5 uuid;
begin
  insert into public.lessons (module_id, slug, position)
    values ('0f0f0f0f-0000-0000-0000-000000000080', 'zr-l2', 2) returning id into l;
  insert into public.lesson_versions (lesson_id, version_number, title) values (l, 1, 'ZR l2 v1') returning id into v1;
  insert into public.zr_ids values ('lesson2', l), ('version_draft', v1);
  insert into public.questions (lesson_version_id, question_type, prompt, position)
    values (v1, 'fill_blank', 'ZRQ 4', 1) returning id into q4;
  insert into public.zr_ids values ('q4', q4);
  insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary) values
    (q4, 'It''s ok',         'its ok',  false),   -- reta, nao primaria
    (q4, U&'It\2019s ok',    U&'it\2019s ok', true),  -- curva, primaria, normalized_text antigo
    (q4, U&'It\2018s fine',  U&'it\2018s fine', false);

  insert into public.lessons (module_id, slug, position)
    values ('0f0f0f0f-0000-0000-0000-000000000080', 'zr-l3', 3) returning id into l;
  insert into public.lesson_versions (lesson_id, version_number, title) values (l, 1, 'ZR l3 v1') returning id into v2;
  insert into public.exercises (lesson_version_id, position, title) values (v2, 1, 'Ex');
  insert into public.questions (lesson_version_id, question_type, prompt, position)
    values (v2, 'fill_blank', 'ZRQ 5', 1) returning id into q5;
  insert into public.zr_ids values ('q5', q5), ('version_pub2', v2);
  insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
    values (q5, U&'We\2019re here', U&'we\2019re here', true);
  update public.lesson_versions set is_published = true where id = v2;
end $$;

-- Sem desligar o trigger, normalizar linha de versao publicada e barrado (o guard continua valendo).
select public.zr_expect_error(format(
  $q$update private.accepted_answers set normalized_text = private.normalize_text(answer_text) where question_id = %L$q$,
  (select id from public.zr_ids where k = 'q5')), '55000');
select public.zr_assert(
  (select normalized_text = U&'we\2019re here' from private.accepted_answers where question_id = (select id from public.zr_ids where k = 'q5')),
  'RENORM-03 sem desligar o trigger, a linha de versao publicada nao muda (imutabilidade intacta)');

alter table private.accepted_answers disable trigger accepted_answers_guard;
alter table private.accepted_answers disable trigger accepted_answers_word_order;
delete from private.accepted_answers a
using (
  select id, row_number() over (partition by question_id, private.normalize_text(answer_text)
                                order by is_primary desc, id) as rn
  from private.accepted_answers
) d
where a.id = d.id and d.rn > 1;
update private.accepted_answers set normalized_text = 'renorm:' || id::text
 where normalized_text is distinct from private.normalize_text(answer_text);
update private.accepted_answers set normalized_text = private.normalize_text(answer_text)
 where normalized_text <> private.normalize_text(answer_text);
alter table private.accepted_answers enable trigger accepted_answers_guard;
alter table private.accepted_answers enable trigger accepted_answers_word_order;

select public.zr_assert(
  (select count(*) = 0 from private.accepted_answers a
    where a.normalized_text is distinct from private.normalize_text(a.answer_text)),
  'RENORM-04 apos a renormalizacao, todas as linhas batem com normalize_text(answer_text)');
select public.zr_assert(
  (select count(*) = 1 and bool_and(is_primary) and min(answer_text) = U&'It\2019s ok'
     from private.accepted_answers where question_id = (select id from public.zr_ids where k = 'q4')
      and normalized_text = 'it''s ok'),
  'RENORM-05 colisao: as duas variantes viraram uma so e ficou a is_primary');
select public.zr_assert(
  (select count(*) = 2 from private.accepted_answers where question_id = (select id from public.zr_ids where k = 'q4')),
  'RENORM-06 a variante sem colisao (apostrofo U+2018) foi mantida');
select public.zr_assert(
  (select normalized_text = 'we''re here' from private.accepted_answers where question_id = (select id from public.zr_ids where k = 'q5')),
  'RENORM-07 linha de versao publicada foi renormalizada com os triggers desligados so durante o bloco');
select public.zr_assert(
  (select count(*) = 2 from pg_trigger t
    where t.tgrelid = 'private.accepted_answers'::regclass
      and t.tgname in ('accepted_answers_guard', 'accepted_answers_word_order') and t.tgenabled = 'O'),
  'RENORM-08 triggers religados depois do bloco');
select public.zr_expect_error(format(
  $q$update private.accepted_answers set answer_text = 'mudou' where question_id = %L$q$,
  (select id from public.zr_ids where k = 'q5')), '55000');

-- ---------------------------------------------------------------------
-- 4. Niveis
-- ---------------------------------------------------------------------
select public.zr_assert((select count(*) = 6 from public.levels), 'LVL-01 existem exatamente 6 niveis');
select public.zr_assert(
  (select array_agg(code || '|' || title || '|' || position order by position) = array[
     'A1|Iniciante|1',
     U&'A2|B\00E1sico|2',
     U&'B1|Intermedi\00E1rio|3',
     U&'B2|P\00F3s-intermedi\00E1rio|4',
     U&'C1|Avan\00E7ado|5',
     'C2|Proficiente|6']
   from public.levels),
  'LVL-02 codigos, titulos e posicoes dos 6 niveis conferem');

-- ---------------------------------------------------------------------
-- 5. modules.slug
-- ---------------------------------------------------------------------
select public.zr_assert(
  (select is_nullable = 'NO' from information_schema.columns
    where table_schema = 'public' and table_name = 'modules' and column_name = 'slug'),
  'SLUG-01 modules.slug e NOT NULL');
select public.zr_expect_error(
  $q$insert into public.modules (level_id, slug, title, position) values ((select id from public.levels where code = 'A1'), null, 'x', 81)$q$, '23502');
select public.zr_expect_error(
  $q$insert into public.modules (level_id, title, position) values ((select id from public.levels where code = 'A1'), 'sem slug', 81)$q$, '23502');
select public.zr_expect_error(
  $q$insert into public.modules (level_id, slug, title, position) values ((select id from public.levels where code = 'A1'), 'zr-m80', 'dup', 81)$q$, '23505');
select public.zr_expect_error(
  $q$update public.modules set slug = 'zr-m80' where id = (select id from public.modules where slug <> 'zr-m80' limit 1)$q$, '23505');
do $$
declare s text;
begin
  foreach s in array array['Zr-Upper', 'zr_under', 'zr--dup', '-zr', 'zr-', 'zr space', '', 'zr.dot'] loop
    perform public.zr_expect_error(format(
      $q$insert into public.modules (level_id, slug, title, position) values ((select id from public.levels where code = 'A1'), %L, 'x', 82)$q$, s), '23514');
  end loop;
end $$;
insert into public.modules (level_id, slug, title, position)
  values ((select id from public.levels where code = 'A1'), 'a1-modulo-9', 'ZR slug ok', 83);
select public.zr_assert(exists (select 1 from public.modules where slug = 'a1-modulo-9'),
  'SLUG-02 slug valido (minusculas, numeros e hifens) e aceito');

-- ---------------------------------------------------------------------
-- 6. lesson_versions.content_hash
-- ---------------------------------------------------------------------
select public.zr_assert((select data_type = 'text' and is_nullable = 'YES' from information_schema.columns
    where table_schema = 'public' and table_name = 'lesson_versions' and column_name = 'content_hash'),
  'HASH-01 content_hash e text e aceita null');
select public.zr_assert((select content_hash is null from public.lesson_versions
                          where id = (select id from public.zr_ids where k = 'version_draft')),
  'HASH-02 versao sem hash (null) e aceita');
update public.lesson_versions set content_hash = encode(sha256('conteudo zr'::bytea), 'hex')
 where id = (select id from public.zr_ids where k = 'version_draft');
select public.zr_assert((select content_hash ~ '^[0-9a-f]{64}$' from public.lesson_versions
                          where id = (select id from public.zr_ids where k = 'version_draft')),
  'HASH-03 UPDATE de versao nao publicada grava sha256 em hex');
update public.lesson_versions set content_hash = null where id = (select id from public.zr_ids where k = 'version_draft');
select public.zr_assert((select content_hash is null from public.lesson_versions
                          where id = (select id from public.zr_ids where k = 'version_draft')),
  'HASH-04 o hash pode voltar a null numa versao nao publicada');
do $$
declare h text;
begin
  foreach h in array array[repeat('A', 64), repeat('a', 63), repeat('a', 65), repeat('g', 64), '', 'abc'] loop
    perform public.zr_expect_error(format(
      $q$update public.lesson_versions set content_hash = %L where id = %L$q$, h,
      (select id from public.zr_ids where k = 'version_draft')), '23514');
  end loop;
end $$;
do $$
declare l uuid;
begin
  select id into l from public.zr_ids where k = 'lesson2';
  insert into public.lesson_versions (lesson_id, version_number, title, content_hash)
    values (l, 2, 'ZR l2 v2', encode(sha256('v2'::bytea), 'hex'));
  perform public.zr_assert(true, 'HASH-05 INSERT de versao ja com hash valido');
  perform public.zr_expect_error(format(
    $q$insert into public.lesson_versions (lesson_id, version_number, title, content_hash) values (%L, 3, 'x', 'xyz')$q$, l), '23514');
end $$;
-- versao publicada segue imutavel, inclusive para o hash
select public.zr_expect_error(format(
  $q$update public.lesson_versions set content_hash = %L where id = %L$q$,
  repeat('a', 64), (select id from public.zr_ids where k = 'version')), '55000');
select public.zr_expect_error(format(
  $q$update public.lesson_versions set content_hash = null where id = %L$q$,
  (select id from public.zr_ids where k = 'version')), '55000');
select public.zr_expect_error(format(
  $q$update public.lesson_versions set title = 'outro' where id = %L$q$,
  (select id from public.zr_ids where k = 'version')), '55000');
select public.zr_assert((select content_hash is null from public.lesson_versions
                          where id = (select id from public.zr_ids where k = 'version')),
  'HASH-06 versao publicada continua imutavel (55000) e o hash nao mudou');

-- ---------------------------------------------------------------------
-- 7. Permissao: o aluno le (modulo publicado) mas nao escreve
-- ---------------------------------------------------------------------
set role authenticated;
select public.zr_as('f6f6f6f6-6666-6666-6666-666666666666');
do $$
declare n int;
begin
  perform public.zr_assert((select slug = 'zr-m80' from public.modules where id = '0f0f0f0f-0000-0000-0000-000000000080'),
    'PERM-01 o aluno le modules.slug de modulo publicado');
  perform public.zr_assert(not exists (select 1 from public.modules where slug = 'a1-modulo-9'),
    'PERM-02 o aluno nao ve modulo nao publicado (politica de leitura inalterada)');
  perform public.zr_expect_error(
    $q$insert into public.modules (level_id, slug, title, position) values ((select id from public.levels where code = 'A1'), 'zr-hack', 'hack', 90)$q$, '42501');
  update public.modules set slug = 'zr-hack' where id = '0f0f0f0f-0000-0000-0000-000000000080';
  get diagnostics n = row_count;
  perform public.zr_assert(n = 0, 'PERM-03 o aluno nao altera modulo (UPDATE nao afeta linhas)');
  delete from public.modules where id = '0f0f0f0f-0000-0000-0000-000000000080';
  get diagnostics n = row_count;
  perform public.zr_assert(n = 0, 'PERM-04 o aluno nao apaga modulo');
  perform public.zr_expect_error(format(
    $q$insert into public.lesson_versions (lesson_id, version_number, title, content_hash) values (%L, 9, 'hack', null)$q$,
    (select id from public.zr_ids where k = 'lesson')), '42501');
  update public.lesson_versions set content_hash = repeat('b', 64)
   where id = (select id from public.zr_ids where k = 'version');
  get diagnostics n = row_count;
  perform public.zr_assert(n = 0, 'PERM-05 o aluno nao grava content_hash em lesson_versions');
  update public.levels set title = 'hack' where code = 'A1';
  get diagnostics n = row_count;
  perform public.zr_assert(n = 0, 'PERM-06 o aluno nao altera niveis');
  perform public.zr_expect_error('select * from private.accepted_answers', '42501');
end $$;
reset role;
select public.zr_assert((select slug = 'zr-m80' from public.modules where id = '0f0f0f0f-0000-0000-0000-000000000080')
  and (select title = 'Iniciante' from public.levels where code = 'A1')
  and (select content_hash is null from public.lesson_versions where id = (select id from public.zr_ids where k = 'version')),
  'PERM-07 nada foi alterado pelas tentativas do aluno');

\echo ===== TESTES REFERENCIA DE CONTEUDO PASSARAM =====
