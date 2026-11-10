# MyFluenti — Supabase (banco de dados)

Implementa o Dicionário de Dados v1.0 com as decisões da revisão técnica (versionamento por aula, gabarito protegido, módulos Free/Premium, nota ponderada, histórico completo de tentativas).

## Ordem das migrations

| Arquivo | Conteúdo |
| --- | --- |
| `supabase/migrations/20261103000001_schema.sql` | Tabelas, constraints, chaves compostas, índices, triggers de imutabilidade |
| `supabase/migrations/20261103000002_rls.sql` | Helpers de acesso, grants mínimos, políticas RLS, view do nivelamento |
| `supabase/migrations/20261103000003_functions.sql` | Regras de negócio no backend (RPCs `security definer`) |
| `supabase/migrations/20261104232828_library_review_profile.sql` | Biblioteca, favoritos, notas por seção, sessões de revisão (RPCs v2) e perfil. Endurece `record_review_result` (v1) |
| `supabase/migrations/20261110100000_content_reference_data.sql` | 009: `normalize_text` trata apóstrofo, aspas, acento agudo, crase e prime tipográficos e remove reticências (e renormaliza `accepted_answers` via `private.renormalize_accepted_answers()`), `modules.slug`, níveis A1 a C2 como dado de referência e `lesson_versions.content_hash` (sha256, oculto do app por SELECT por coluna), para o importador de conteúdo. Nenhuma RPC muda de contrato |
| `supabase/migrations/20261110120000_onboarding_completed_with_level.sql` | 010: `select_starting_level` grava `profiles.onboarding_completed_at` (se nulo) na mesma transação em que define o nível. Assinatura, retorno, erros e grants iguais |

Aplicar com `supabase db push` (ou copiar para `supabase/migrations/` do projeto). Cada migration deve rodar uma única vez, nesta sequência (não são re-executáveis).

## Como o app deve usar

O app **nunca grava progresso**. Ele chama RPCs:

`start_placement_attempt` → `submit_placement_answer` → `finish_placement_attempt` → `select_starting_level` → `get_course_overview` → `get_module_lessons` → `start_lesson_attempt` → `record_section_view` → `submit_lesson_answer` → `finish_lesson_attempt` · `record_review_result` · `refresh_my_unlocks`

Biblioteca e perfil: `search_library` · `get_library_item` · `get_my_favorites` · `get_profile_summary`.

Revisão (sessão): `get_review_queue` → `start_review_session` → para cada questão, `submit_review_answer` → `record_review_result_v2` (um por item) → `finish_review_session`.

Favoritos e notas não usam RPC: o app grava direto nas tabelas, com RLS por dono (`user_vocabulary`, `user_favorite_examples`, `user_notes`).

Contrato completo (assinaturas, retornos, erros e exemplos): `../myfluenti-docs/docs/dados/api.md`.

Códigos de erro úteis (`42501`): mensagem `module_locked` (módulo ainda não liberado) e `premium_required` (módulo Premium sem plano).

Conteúdo (aulas, questões, alternativas) é lido por `select` normal; o RLS já aplica liberação e plano. O gabarito fica em `private.*` e só é lido por funções.

## Dados de desenvolvimento

O `supabase db reset` **não** carrega dados (o `supabase/seed.sql` é só comentário), e os testes 10, 20 e 30 rodam com `db reset` normal. Para ter conteúdo fictício no banco **local** (6 níveis, 2 módulos A1, 4 aulas, 2 tópicos, 3 palavras e um nivelamento de 30 questões, tudo com slug `dev-*` e "(TESTE)"):

```powershell
supabase start
.\scripts\load-dev-seed.ps1        # Windows (PowerShell)
```

```bash
./scripts/load-dev-seed.sh         # Linux/macOS/Git Bash
```

Os scripts rodam `docker exec -i supabase_db_myfluenti-backend psql ... < supabase/dev-seed/dev_content.sql` e falham com mensagem clara se o contêiner não existir. **DADOS FICTÍCIOS DE TESTE, NUNCA EM STAGING/PRODUÇÃO.** O seed roda uma vez: na segunda vez aborta com "DEV SEED JA CARREGADO"; para recomeçar, `supabase db reset`. Rode o seed **depois** dos testes (os testes não dependem dele). O formato do conteúdo (`"v":1`, blocos) é provisório.

## Testes

`tests/10_smoke_test.sql` roda os critérios NIV, AUL, MOD, REV e SEC com 86 verificações (59 asserções e 27 erros esperados). Cada uma imprime `NOTICE:  PASS`, e a última linha imprime `===== TODOS OS TESTES PASSARAM =====`. Atenção: `grep -c PASS` devolve 87 porque também conta essa linha final.

`tests/20_library_review_profile_test.sql` cobre Biblioteca, favoritos, notas, revisão e perfil, com 244 verificações. Roda **depois** do smoke, no mesmo banco, sem `db reset` entre os dois. Termina com `===== TESTES BIBLIOTECA/REVISAO/PERFIL PASSARAM =====`.

### No Supabase local (referência)

`tests/30_content_delivery_test.sql` cobre `get_lesson_content`, `get_placement_items` e o nome no cadastro. Roda depois do 20, no mesmo banco, e termina com `===== TESTES ENTREGA DE CONTEUDO PASSARAM =====`.

`tests/40_account_deletion_test.sql` cobre `delete_my_account` (exclusão de conta, LGPD): confirmação exata `EXCLUIR`, cascata varrida dinamicamente por toda FK para `auth.users`, isolamento entre alunos, contador anônimo `private.account_deletions` e, no Supabase local, sessões, refresh tokens e o rastro em `auth.audit_log_entries` e `auth.flow_state`. Roda depois do 30, no mesmo banco: 36 PASS em PostgreSQL comum (com stub) e 42 no Supabase local. Termina com `===== TESTES EXCLUSAO DE CONTA PASSARAM =====`.
`tests/50_profile_avatar_test.sql` cobre o avatar montável (`update_my_avatar`, `private.is_valid_avatar_config`, `profiles.avatar_config`) e a remoção de `profiles.avatar_url`. Roda depois do 30 (e do 40, se existir), no mesmo banco, e termina com `===== TESTES AVATAR PASSARAM =====`.

`tests/60_content_reference_test.sql` cobre a migration 009: antes e depois do apóstrofo curvo (`We’re`), ponta a ponta pela aula e pela revisão, `private.renormalize_accepted_answers()` sobre dados antigos simulados (colisão, versão publicada, aviso de `word_order`), os 6 níveis, `modules.slug`, `lesson_versions.content_hash` (imutabilidade da versão publicada e SELECT por coluna: o aluno recebe 42501 ao ler o hash) e permissões do aluno. Roda depois do 50, no mesmo banco: 83 PASS (iguais no stub e no Supabase local). Termina com `===== TESTES REFERENCIA DE CONTEUDO PASSARAM =====`.

`tests/70_onboarding_test.sql` cobre a migration 010: `select_starting_level` conclui o onboarding junto com o nível, preserva a data em uma troca posterior (`manual_change`) e não conclui nada quando falha (22023 e P0002). Confere também assinatura e permissão de execução. Roda depois do 60, no mesmo banco: 14 PASS (iguais no stub e no Supabase local). Termina com `===== TESTES ONBOARDING PASSARAM =====`.

O teste roda **sem o stub** e sem alterações. O `auth.users` real aceita o insert só com `id` e `email`, porque as demais colunas do GoTrue são anuláveis. O `auth.uid()` real lê `request.jwt.claim.sub`, que é o claim que o teste define. O teste também passa como `postgres`, que no Supabase não é superusuário.

```powershell
npx -y supabase@2.121.0 start -x realtime,storage-api,imgproxy,mailpit,studio,edge-runtime,logflare,vector,supavisor,postgres-meta
npx -y supabase@2.121.0 db reset
Get-Content tests/10_smoke_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
Get-Content tests/20_library_review_profile_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
Get-Content tests/30_content_delivery_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
Get-Content tests/40_account_deletion_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
Get-Content tests/50_profile_avatar_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
Get-Content tests/60_content_reference_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
Get-Content tests/70_onboarding_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
npx -y supabase@2.121.0 db reset   # apaga os dados e as tabelas zz_* criadas pelo teste
npx -y supabase@2.121.0 db advisors --local --type all
```

O `-x` deixa de fora os serviços que o teste não usa (economiza alguns GB de imagens). O psql roda dentro do contêiner do banco, então não precisa instalar o psql no Windows. O `2>&1` fica dentro do `sh -c` de propósito. O psql imprime os `NOTICE` no stderr, e o PowerShell 5.1 transforma a primeira linha de stderr num falso erro vermelho que repete a linha, o que faz a contagem dar uma a mais.

### Em PostgreSQL comum (CI atual)

`tests/00_supabase_stub.sql` simula `auth.users`, `auth.uid()` e os papéis do Supabase (usar **só** em PostgreSQL comum, nunca no Supabase).

```
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
psql -v ON_ERROR_STOP=1 -d mf -f tests/10_smoke_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/20_library_review_profile_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/30_content_delivery_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/40_account_deletion_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/50_profile_avatar_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/60_content_reference_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/70_onboarding_test.sql
```

## Diferenças em relação ao Dicionário v1.0

- `questions` não tem `is_published`: a publicação vem da versão da aula (`lesson_versions`) ou do teste de nivelamento publicado.
- `user_placement_answers` ganhou `user_id` e **não** tem `SELECT` para o app (evita extrair o gabarito do nivelamento).
- `placement_questions` não é legível pelo aluno; ele usa a view `placement_test_items` (sem peso nem dificuldade).
- `user_exercise_attempts` ganhou `user_id` e `max_points` nulo-seguro (`0` em prática não avaliativa).

## Parâmetros provisórios (pendências do Dicionário, seção 15)

- Nível recomendado: maior nível em sequência com ≥ 60% de aproveitamento (`finish_placement_attempt`).
- Domínio: `mastery_score` = % de acertos acumulado (`finish_lesson_attempt`).
- Revisão: SM-2 simplificado; erros de aula entram na fila para o dia seguinte.

## Ainda não implementado

- Autoria/publicação de conteúdo e seed (hoje via painel ou `service_role`).
- Mudança automática de `profiles.current_level_id` ao concluir um nível.
- Regra de "refazer aula" após nova versão (`requires_relearning` / `needs_update`).
