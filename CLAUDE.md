# myfluenti-backend

Backend do MyFluenti: **Supabase** (PostgreSQL, Auth, RLS, RPC, Edge Functions). Leia também o `CLAUDE.md` da pasta mãe, que traz as regras oficiais.

## Estrutura

```
supabase/
  config.toml          # gerado por `supabase init`
  migrations/          # SQL versionado, só para frente
  functions/           # Edge Functions (futuro: webhook de assinatura)
  seed.sql             # dados de desenvolvimento (vazio por enquanto)
tests/
  00_supabase_stub.sql # simula auth e papéis, SOMENTE para PostgreSQL comum
  10_smoke_test.sql    # teste de ponta a ponta (NIV, AUL, MOD, REV, SEC)
  20_library_review_profile_test.sql  # Biblioteca, revisão, perfil, favoritos e notas (roda depois do 10)
  30_content_delivery_test.sql  # entrega de conteúdo e cadastro (roda depois do 20)
  40_account_deletion_test.sql  # exclusão de conta, LGPD (roda depois do 30)
  50_profile_avatar_test.sql    # avatar montável e remoção de avatar_url (roda depois do 40)
  60_content_reference_test.sql  # normalizacao de texto, niveis, modules.slug, content_hash (roda depois do 50)
  70_onboarding_test.sql         # select_starting_level conclui o onboarding (roda depois do 60)
  80_notes_and_level_test.sql    # get_my_notes, limite do corpo da nota, select_starting_level idempotente (roda depois do 70)
  90_placement_feedback_test.sql # submit_placement_answer devolve is_correct (roda depois do 80)
# Contrato das RPCs: myfluenti-docs/docs/dados/api.md
.github/workflows/     # test, deploy-staging, deploy-prod (a criar)
```

Os testes ficam fora de `supabase/` de propósito: o Supabase CLI trata `supabase/tests` como testes pgTAP.

## Como trabalhar aqui

- Nova regra ou tabela: crie uma migration nova com o próximo timestamp. Nunca edite uma migration já aplicada.
- Toda tabela em `public` tem RLS ligado e nenhuma política significa acesso negado. Dê o mínimo de `grant` necessário.
- Toda função que escreve progresso é `security definer`, usa `set search_path = ''`, valida `auth.uid()` e roda em transação. Revogue `execute` de `public` e `anon`.
- Gabarito só no schema `private`. Nunca devolva `correct_option_id` ou respostas aceitas em uma RPC.
- Triggers de imutabilidade (versão publicada, teste publicado, tentativas encerradas) são parte do contrato. Não os enfraqueça.
- Cada mudança de comportamento ganha um caso em `tests/10_smoke_test.sql` (ou novo arquivo de teste).

## Rodar os testes (PostgreSQL comum)

```bash
createdb mf
psql -v ON_ERROR_STOP=1 -d mf -f tests/00_supabase_stub.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261103000001_schema.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261103000002_rls.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261103000003_functions.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261104232828_library_review_profile.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261109121904_content_delivery.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261109150000_account_deletion.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261110090000_profile_avatar.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261110090100_drop_avatar_url.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261110100000_content_reference_data.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261110120000_onboarding_completed_with_level.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261110130000_notes_and_idempotent_level.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261111090000_placement_answer_feedback.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/10_smoke_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/20_library_review_profile_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/30_content_delivery_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/40_account_deletion_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/50_profile_avatar_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/60_content_reference_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/70_onboarding_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/80_notes_and_level_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/90_placement_feedback_test.sql
```

Esperado: 86 linhas `NOTICE:  PASS` no smoke (última linha `TODOS OS TESTES PASSARAM`) e 244 no tests/20 (última linha `TESTES BIBLIOTECA/REVISAO/PERFIL PASSARAM`) e 85 no tests/30 (última linha `TESTES ENTREGA DE CONTEUDO PASSARAM`) e 36 no tests/40 em PostgreSQL comum, 42 no Supabase local, onde também testa sessões, refresh tokens e o rastro em auth.audit_log_entries e auth.flow_state (última linha `TESTES EXCLUSAO DE CONTA PASSARAM`) e 116 no tests/50 (última linha `TESTES AVATAR PASSARAM`) e 83 no tests/60 (última linha `TESTES REFERENCIA DE CONTEUDO PASSARAM`) e 14 no tests/70 (última linha `TESTES ONBOARDING PASSARAM`) e 76 no tests/80 (última linha `TESTES NOTAS E NIVEL PASSARAM`) e 19 no tests/90 (última linha `TESTES FEEDBACK NIVELAMENTO PASSARAM`). O stub não deve ser aplicado no Supabase real.

Migration 009 (`20261110100000_content_reference_data.sql`): `normalize_text` trata apóstrofo, aspas, acento agudo, crase e prime tipográficos (e remove reticências; renormalização em `private.renormalize_accepted_answers()`, que avisa por `RAISE WARNING` se tokens de `word_order` passarem a igualar uma resposta aceita); `modules.slug` (NOT NULL, único, formato `^[a-z0-9]+(-[a-z0-9]+)*$`); níveis A1 a C2 inseridos como dado de referência (`on conflict do nothing`); `lesson_versions.content_hash` (sha256 hex, nulo permitido, gravado pelo importador em versão não publicada; o app NÃO lê a coluna: `lesson_versions` tem SELECT por coluna para `authenticated`, sem `content_hash`. Coluna nova em `lesson_versions` só chega ao app com grant explícito). Os testes não inserem mais níveis: usam os da migration.

Migration 010 (`20261110120000_onboarding_completed_with_level.sql`): `select_starting_level` grava `profiles.onboarding_completed_at = coalesce(onboarding_completed_at, now())` na mesma transação do nível. Se a RPC falha, o onboarding continua em aberto; uma troca de nível posterior não muda a data. Contrato igual. O app não precisa mais gravar a coluna (o grant de UPDATE continua, para não quebrar versões antigas).

Migration 011 (`20261110130000_notes_and_idempotent_level.sql`): (1) `get_my_notes(p_limit int default 20, p_offset int default 0) returns jsonb`: notas do próprio aluno com `target_title` e `section_title`, nulos quando o aluno não poderia ler o conteúdo (mesma regra de `get_module_lessons`/`get_lesson_content`, via `private.can_read_lesson_version`: versão publicada, módulo liberado em `user_module_progress`, plano); `locked: true` só para conteúdo publicado Premium sem plano; rascunho tem `locked: false` e `access_tier` nulo; paginação como `get_my_favorites`. (2) Limite do corpo da nota: trigger `user_notes_trim_body` apara espaço, tab, CR e LF das pontas e a constraint `user_notes_body_length` exige 1 a 2000 caracteres no texto já aparado (o valor medido é o gravado). (3) `select_starting_level` idempotente e serializada por aluno (`for update` no perfil, sem `23505` em toque duplo): se o nível ativo já é `p_level_id`, não encerra nem grava histórico; se vier `p_placement_attempt_id` e a linha ativa não tem vínculo, grava só o vínculo (source e datas intactos; o primeiro vínculo é mantido). Validações, update de `profiles` e `unlock_module` continuam. O teste 70 usa um módulo A2 para a troca real de nível. Esta migration foi editada antes do merge, com autorização do Gabriel; depois do merge volta a ser imutável.

Migration 012 (`20261111090000_placement_answer_feedback.sql`): `submit_placement_answer(p_attempt_id uuid, p_question_id uuid, p_answer jsonb)` passa de `void` a `jsonb` e devolve exatamente `{"is_correct": boolean}` (decisão do Gabriel, 2026-11-10; substitui a regra de não dar correção no nivelamento). `drop function` + `create function` na mesma migration, grants refeitos (revoke de public e anon, execute para authenticated). Argumentos, erros e SQLSTATEs iguais; clientes antigos ignoram o retorno (helper `rpcVoid`). Sem resposta certa, explicação, pontos nem respostas aceitas. O `is_correct` é o mesmo gravado em `user_placement_answers`.

Dev seed: `supabase/dev-seed/dev_content.sql` é carregado por `scripts/load-dev-seed.ps1` (ou `.sh`). **Nunca** em staging ou produção. O `db reset` **não** o aplica.

No Supabase local, o mesmo teste roda sem stub e sem alterações (comandos no README, seção "No Supabase local"). Rode `supabase db reset` depois, para apagar os dados de teste.

## Pendências deste repositório

Rodar em staging; levar o teste no Supabase local para o CI; decidir sobre o aviso `security_definer_view` em `placement_test_items` (intencional, ver PR de testes locais); troca de nível ao concluir um nível; regra de refazer aula após nova versão (`requires_relearning`, `needs_update`).

Ordem dos testes, no mesmo banco e depois de `supabase db reset` (sem o dev-seed): `10_smoke_test.sql` (86 PASS), `20_library_review_profile_test.sql` (244 PASS), `30_content_delivery_test.sql` (85 PASS), `40_account_deletion_test.sql` (42 PASS no Supabase local, 36 no stub) e `50_profile_avatar_test.sql` (116 PASS) e `60_content_reference_test.sql` (83 PASS) e `70_onboarding_test.sql` (14 PASS) e `80_notes_and_level_test.sql` (76 PASS) e `90_placement_feedback_test.sql` (19 PASS).
