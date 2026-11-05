# MyFluenti — Supabase (banco de dados)

Implementa o Dicionário de Dados v1.0 com as decisões da revisão técnica (versionamento por aula, gabarito protegido, módulos Free/Premium, nota ponderada, histórico completo de tentativas).

## Ordem das migrations

| Arquivo | Conteúdo |
| --- | --- |
| `supabase/migrations/20261103000001_schema.sql` | Tabelas, constraints, chaves compostas, índices, triggers de imutabilidade |
| `supabase/migrations/20261103000002_rls.sql` | Helpers de acesso, grants mínimos, políticas RLS, view do nivelamento |
| `supabase/migrations/20261103000003_functions.sql` | Regras de negócio no backend (RPCs `security definer`) |
| `supabase/migrations/20261104232828_library_review_profile.sql` | Biblioteca, favoritos, notas por seção, sessões de revisão (RPCs v2) e perfil. Endurece `record_review_result` (v1) |

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

## Testes

`tests/10_smoke_test.sql` roda os critérios NIV, AUL, MOD, REV e SEC com 86 verificações (59 asserções e 27 erros esperados). Cada uma imprime `NOTICE:  PASS`, e a última linha imprime `===== TODOS OS TESTES PASSARAM =====`. Atenção: `grep -c PASS` devolve 87 porque também conta essa linha final.

`tests/20_library_review_profile_test.sql` cobre Biblioteca, favoritos, notas, revisão e perfil, com 210 verificações. Roda **depois** do smoke, no mesmo banco, sem `db reset` entre os dois. Termina com `===== TESTES BIBLIOTECA/REVISAO/PERFIL PASSARAM =====`.

### No Supabase local (referência)

O teste roda **sem o stub** e sem alterações. O `auth.users` real aceita o insert só com `id` e `email`, porque as demais colunas do GoTrue são anuláveis. O `auth.uid()` real lê `request.jwt.claim.sub`, que é o claim que o teste define. O teste também passa como `postgres`, que no Supabase não é superusuário.

```powershell
npx -y supabase@2.121.0 start -x realtime,storage-api,imgproxy,mailpit,studio,edge-runtime,logflare,vector,supavisor,postgres-meta
npx -y supabase@2.121.0 db reset
Get-Content tests/10_smoke_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
Get-Content tests/20_library_review_profile_test.sql -Raw | docker exec -i supabase_db_myfluenti-backend sh -c "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q 2>&1"
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
psql -v ON_ERROR_STOP=1 -d mf -f tests/10_smoke_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261104232828_library_review_profile.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/20_library_review_profile_test.sql
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
