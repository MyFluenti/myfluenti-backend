-- =====================================================================
-- 009. Dados de referencia para o importador de conteudo
--   1. normalize_text passa a tratar apostrofos e aspas tipograficos
--      e as respostas aceitas ja gravadas sao renormalizadas;
--   2. modules.slug (chave natural para o importador);
--   3. niveis A1..C2 como dado de referencia;
--   4. lesson_versions.content_hash (sha256 em hex);
--   5. SELECT de lesson_versions por coluna, sem content_hash.
-- Nenhuma RPC muda de assinatura nem de retorno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Normalizacao de texto
-- Bug: "We’re" (apostrofo curvo, digitado no iPhone) nao casava com "we're".
-- A troca vem ANTES da remocao da pontuacao. O resto nao muda:
-- minusculas, remocao de . , ! ? ; : " , espacos colapsados e aparados.
--   -> '  : U+2019, U+2018, U+02BC, U+00B4 (acento agudo), U+0060 (crase), U+2032 (prime)
--   -> "  : U+201C, U+201D (depois removidas junto com a pontuacao)
--   removido: U+2026 (reticencias), tratado como pontuacao
-- translate() apaga os caracteres de "from" sem correspondente em "to": e assim
-- que U+2026 (9o caractere de "from", "to" tem 8) sai do texto.
-- ---------------------------------------------------------------------
create or replace function private.normalize_text(p text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(
           regexp_replace(
             translate(lower(coalesce(p, '')),
                       U&'\2019\2018\02BC\00B4\0060\2032\201C\201D\2026',
                       $q$''''''""$q$),
             '[.,!?;:"]', '', 'g'),
           '\s+', ' ', 'g'))
$$;

-- Renormaliza private.accepted_answers e devolve quantas questoes word_order
-- ficaram com os tokens (juntos e normalizados) iguais a uma resposta aceita.
-- normalized_text e dado DERIVADO de answer_text; recalcula-lo nao e mudanca de
-- conteudo, entao nao deve ser barrado pelos triggers de imutabilidade
-- (accepted_answers_guard) nem pelo de word_order (accepted_answers_word_order).
-- Eles ficam desligados SOMENTE dentro desta funcao. A funcao e um unico comando
-- (atomico mesmo em `psql -f` sem --single-transaction): se algo falhar, o
-- desligamento e revertido junto. security definer porque disable trigger exige
-- ser dono da tabela. Sem EXECUTE para ninguem alem do dono.
-- Colisao com unique (question_id, normalized_text): se duas variantes passam a
-- normalizar igual, fica a is_primary; no empate, a de menor id (a tabela nao tem
-- created_at). O UPDATE e em dois passos para nao colidir no meio do comando.
-- Verificacao final (word_order): so avisa (RAISE WARNING, sem ids nem textos).
-- Motivo: a migration nao pode corrigir o conteudo (versao publicada e imutavel),
-- e um erro travaria o deploy por um problema de conteudo que o trigger
-- guard_word_order_tokens ja impede de nascer de novo. O aviso aparece no log do
-- CI/deploy para o autor revisar.
create or replace function private.renormalize_accepted_answers() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_exposed integer;
begin
  alter table private.accepted_answers disable trigger accepted_answers_guard;
  alter table private.accepted_answers disable trigger accepted_answers_word_order;

  delete from private.accepted_answers a
  using (
    select id,
           row_number() over (
             partition by question_id, private.normalize_text(answer_text)
             order by is_primary desc, id) as rn
    from private.accepted_answers
  ) d
  where a.id = d.id and d.rn > 1;

  update private.accepted_answers
     set normalized_text = 'renorm:' || id::text
   where normalized_text is distinct from private.normalize_text(answer_text);

  update private.accepted_answers
     set normalized_text = private.normalize_text(answer_text)
   where normalized_text <> private.normalize_text(answer_text);

  alter table private.accepted_answers enable trigger accepted_answers_guard;
  alter table private.accepted_answers enable trigger accepted_answers_word_order;

  select count(*) into v_exposed
    from public.questions q
   where q.question_type = 'word_order'
     and pg_catalog.jsonb_typeof(q.prompt_data -> 'tokens') = 'array'
     and exists (
       select 1
         from private.accepted_answers a
        where a.question_id = q.id
          and a.normalized_text = private.normalize_text((
                select pg_catalog.array_to_string(
                         pg_catalog.array_agg(t.tok order by t.idx), ' ')
                  from pg_catalog.jsonb_array_elements_text(q.prompt_data -> 'tokens')
                       with ordinality as t(tok, idx))));
  if v_exposed > 0 then
    raise warning 'renormalize_accepted_answers: % word_order question(s) have tokens equal to an accepted answer; review the content', v_exposed;
  end if;
  return v_exposed;
end $$;
revoke all on function private.renormalize_accepted_answers() from public, anon, authenticated, service_role;

select private.renormalize_accepted_answers();

-- ---------------------------------------------------------------------
-- 2. modules.slug
-- Linhas existentes (so ambiente local) recebem '<nivel>-m<posicao>', que e
-- unico por (level_id, position) e respeita o formato.
-- Grants: public.modules tem SELECT em nivel de tabela para authenticated
-- (politica modules_read: so publicados) e escrita so via content_admin;
-- logo slug herda ambos, sem grant novo.
-- ---------------------------------------------------------------------
alter table public.modules add column slug text;

update public.modules m
   set slug = lower(l.code) || '-m' || m.position
  from public.levels l
 where l.id = m.level_id and m.slug is null;

alter table public.modules
  alter column slug set not null,
  add constraint modules_slug_key unique (slug),
  add constraint modules_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$');

-- ---------------------------------------------------------------------
-- 3. Niveis (dado de referencia)
-- ---------------------------------------------------------------------
insert into public.levels (code, title, position) values
  ('A1', 'Iniciante',         1),
  ('A2', 'Básico',            2),
  ('B1', 'Intermediário',     3),
  ('B2', 'Pós-intermediário', 4),
  ('C1', 'Avançado',          5),
  ('C2', 'Proficiente',       6)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 4. lesson_versions.content_hash
-- sha256 em hex minusculo (64 caracteres), gravado pelo importador no INSERT
-- ou no UPDATE de versao NAO publicada. Versao publicada continua imutavel:
-- guard_lesson_version barra qualquer UPDATE (55000), inclusive do hash.
-- ---------------------------------------------------------------------
alter table public.lesson_versions
  add column content_hash text,
  add constraint lesson_versions_content_hash_format
    check (content_hash is null or content_hash ~ '^[0-9a-f]{64}$');

-- ---------------------------------------------------------------------
-- 5. Grants de lesson_versions: content_hash fica fora do alcance do app.
-- O hash cobre o conteudo inteiro, inclusive o gabarito; com ele o aluno poderia
-- testar alternativas certas por forca bruta. Por isso o SELECT do
-- authenticated passa a ser por coluna, sem content_hash (nem `select *`).
-- Sem mudanca: INSERT/UPDATE/DELETE (continuam so via politica de content_admin),
-- anon (nunca teve grant) e service_role (le tudo). A view lesson_current_versions
-- (security_invoker) so le colunas da lista; as funcoes que leem a tabela sao
-- security definer. Coluna nova em lesson_versions: so entra no app com grant explicito.
-- ---------------------------------------------------------------------
revoke select on public.lesson_versions from authenticated;
grant select (id, lesson_id, version_number, title, objective, is_published,
              published_at, change_note, requires_relearning, created_at)
  on public.lesson_versions to authenticated;
