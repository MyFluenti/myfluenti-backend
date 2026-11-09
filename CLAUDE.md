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
psql -v ON_ERROR_STOP=1 -d mf -f tests/10_smoke_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/20_library_review_profile_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/30_content_delivery_test.sql
psql -v ON_ERROR_STOP=1 -d mf -f tests/40_account_deletion_test.sql
```

Esperado: 86 linhas `NOTICE:  PASS` no smoke (última linha `TODOS OS TESTES PASSARAM`) e 244 no tests/20 (última linha `TESTES BIBLIOTECA/REVISAO/PERFIL PASSARAM`) e 85 no tests/30 (última linha `TESTES ENTREGA DE CONTEUDO PASSARAM`) e 34 no tests/40 em PostgreSQL comum, 37 no Supabase local, onde também testa sessões e refresh tokens (última linha `TESTES EXCLUSAO DE CONTA PASSARAM`). O stub não deve ser aplicado no Supabase real.

Dev seed: `supabase/dev-seed/dev_content.sql` é carregado por `scripts/load-dev-seed.ps1` (ou `.sh`). **Nunca** em staging ou produção. O `db reset` **não** o aplica.

No Supabase local, o mesmo teste roda sem stub e sem alterações (comandos no README, seção "No Supabase local"). Rode `supabase db reset` depois, para apagar os dados de teste.

## Pendências deste repositório

Rodar em staging; levar o teste no Supabase local para o CI; decidir sobre o aviso `security_definer_view` em `placement_test_items` (intencional, ver PR de testes locais); troca de nível ao concluir um nível; regra de refazer aula após nova versão (`requires_relearning`, `needs_update`).

Ordem dos testes, no mesmo banco e depois de `supabase db reset` (sem o dev-seed): `10_smoke_test.sql` (86 PASS), `20_library_review_profile_test.sql` (244 PASS) e `30_content_delivery_test.sql` (85 PASS) e `40_account_deletion_test.sql` (37 PASS no Supabase local, 34 no stub).
