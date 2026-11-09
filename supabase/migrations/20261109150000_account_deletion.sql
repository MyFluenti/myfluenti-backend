-- =====================================================================
-- MyFluenti - Migration 006: exclusao de conta (LGPD)
--   private.account_deletions : contador anonimo (sem qualquer identificador)
--   public.delete_my_account  : o aluno apaga a propria conta
-- Nao altera nenhuma migration anterior nem assinatura de RPC existente.
-- =====================================================================

-- Contador anonimo de exclusoes. De proposito NAO guarda user_id, e-mail, hash
-- nem qualquer dado que permita ligar a linha a uma pessoa. Somente id e data.
create table private.account_deletions (
  id          bigint generated always as identity primary key,
  deleted_at  timestamptz not null default now()
);

-- Mesmo padrao do schema private: RLS ligado, sem politica e sem grant para o app.
alter table private.account_deletions enable row level security;
revoke all on private.account_deletions from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- delete_my_account(p_confirmation text) -> jsonb  ({"deleted": true})
--
-- O alvo e sempre auth.uid(): nao existe parametro de id, entao ninguem apaga
-- a conta de outra pessoa. A confirmacao exige exatamente 'EXCLUIR' (sem trim,
-- sem diferenca de caixa). Apagar auth.users dispara a cascata (ON DELETE
-- CASCADE) por sessoes, refresh tokens, identidades e todas as tabelas do
-- aluno em public; a trigger private.guard_attempt_history deixa a cascata
-- passar.
--
-- Sessao: o refresh token morre na cascata, entao o app nao renova mais a
-- sessao. O access token (JWT) ja emitido segue valido ate expirar (jwt_expiry
-- 3600 s), mas a conta nao tem mais dados e nenhuma RPC de escrita consegue
-- gravar progresso para ela. O app deve descartar a sessao local apos o retorno.
--
-- Erros: 28000 'Autenticacao obrigatoria' (private.require_user) (sem uid), 22023 'confirmation_required',
--        P0002 'account_not_found' (JWT valido de conta ja apagada).
-- Nao registra id nem e-mail em log.
-- ---------------------------------------------------------------------
create or replace function public.delete_my_account(p_confirmation text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_deleted integer;
begin
  if p_confirmation is distinct from 'EXCLUIR' then
    raise exception 'confirmation_required' using errcode = '22023';
  end if;

  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then
    raise exception 'account_not_found' using errcode = 'P0002';
  end if;

  insert into private.account_deletions default values;
  return jsonb_build_object('deleted', true);
end $$;

revoke execute on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;
