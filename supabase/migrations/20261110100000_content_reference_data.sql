-- =====================================================================
-- 009. Dados de referencia para o importador de conteudo
--   1. normalize_text passa a tratar apostrofos e aspas tipograficos
--      e as respostas aceitas ja gravadas sao renormalizadas;
--   2. modules.slug (chave natural para o importador);
--   3. niveis A1..C2 como dado de referencia;
--   4. lesson_versions.content_hash (sha256 em hex).
-- Nenhuma RPC muda de assinatura nem de retorno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Normalizacao de texto
-- Bug: "We’re" (apostrofo curvo, digitado no iPhone) nao casava com "we're".
-- A troca vem ANTES da remocao da pontuacao. O resto nao muda:
-- minusculas, remocao de . , ! ? ; : " , espacos colapsados e aparados.
-- Troca: U+2019 U+2018 U+02BC -> '   e   U+201C U+201D -> "
-- ---------------------------------------------------------------------
create or replace function private.normalize_text(p text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(
           regexp_replace(
             translate(lower(coalesce(p, '')),
                       U&'\2019\2018\02BC\201C\201D',
                       $q$'''""$q$),
             '[.,!?;:"]', '', 'g'),
           '\s+', ' ', 'g'))
$$;

-- Renormaliza private.accepted_answers.
-- normalized_text e dado DERIVADO de answer_text; recalcula-lo nao e mudanca de
-- conteudo, entao nao deve ser barrado pelos triggers de imutabilidade
-- (accepted_answers_guard) nem pelo de word_order (accepted_answers_word_order).
-- Eles ficam desligados SOMENTE durante este bloco (a migration roda como dono
-- da tabela e numa transacao; o enable e o disable sao revertidos juntos em
-- caso de erro). Triggers que nao sao tocados: nenhum outro existe na tabela.
-- Colisao com unique (question_id, normalized_text): se duas variantes passam a
-- normalizar igual, fica a is_primary; no empate, a de menor id (a tabela nao
-- tem created_at). Em dois passos para nao colidir no meio do UPDATE.
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
