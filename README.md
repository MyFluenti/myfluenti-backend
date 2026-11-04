# MyFluenti — Supabase (banco de dados)

Implementa o Dicionário de Dados v1.0 com as decisões da revisão técnica (versionamento por aula, gabarito protegido, módulos Free/Premium, nota ponderada, histórico completo de tentativas).

## Ordem das migrations

| Arquivo | Conteúdo |
| --- | --- |
| `supabase/migrations/20261103000001_schema.sql` | Tabelas, constraints, chaves compostas, índices, triggers de imutabilidade |
| `supabase/migrations/20261103000002_rls.sql` | Helpers de acesso, grants mínimos, políticas RLS, view do nivelamento |
| `supabase/migrations/20261103000003_functions.sql` | Regras de negócio no backend (RPCs `security definer`) |

Aplicar com `supabase db push` (ou copiar para `supabase/migrations/` do projeto). Cada migration deve rodar uma única vez, nesta sequência (não são re-executáveis).

## Como o app deve usar

O app **nunca grava progresso**. Ele chama RPCs:

`start_placement_attempt` → `submit_placement_answer` → `finish_placement_attempt` → `select_starting_level` → `get_course_overview` → `get_module_lessons` → `start_lesson_attempt` → `record_section_view` → `submit_lesson_answer` → `finish_lesson_attempt` · `record_review_result` · `refresh_my_unlocks`

Códigos de erro úteis (`42501`): mensagem `module_locked` (módulo ainda não liberado) e `premium_required` (módulo Premium sem plano).

Conteúdo (aulas, questões, alternativas) é lido por `select` normal; o RLS já aplica liberação e plano. O gabarito fica em `private.*` e só é lido por funções.

## Testes

`tests/00_supabase_stub.sql` simula `auth.users`, `auth.uid()` e os papéis do Supabase (usar **só** em PostgreSQL local).
`tests/10_smoke_test.sql` roda os critérios NIV, AUL, MOD, REV e SEC com 87 verificações.

```
createdb mf
psql -v ON_ERROR_STOP=1 -d mf -f tests/00_supabase_stub.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261103000001_schema.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261103000002_rls.sql
psql -v ON_ERROR_STOP=1 -d mf -f supabase/migrations/20261103000003_functions.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/10_smoke_test.sql
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
- Sessões de revisão com `review_sessions` + `user_exercise_attempts` (tabelas prontas; falta a RPC de correção da revisão).
- Mudança automática de `profiles.current_level_id` ao concluir um nível.
- Regra de "refazer aula" após nova versão (`requires_relearning` / `needs_update`).
