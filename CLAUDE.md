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
docs/api.md            # contrato das RPCs (a criar)
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
psql -v ON_ERROR_STOP=1 -d mf -f tests/10_smoke_test.sql
```

Esperado: a última linha imprime `TODOS OS TESTES PASSARAM`. O stub não deve ser aplicado no Supabase real. Ao migrar os testes para `supabase start`, verifique se o `auth.users` real aceita os inserts do teste.

## Pendências deste repositório

Rodar tudo no Supabase local e depois em staging; criar `config.toml`, workflows de CI e `docs/api.md`; RPC de revisão com `review_sessions`; troca de nível ao concluir um nível; regra de refazer aula após nova versão (`requires_relearning`, `needs_update`).
