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
-- Rastro fora da cascata (decisao do Gabriel: apagar tambem): depois do delete em
-- auth.users (e confirmada a exclusao) removemos de auth.audit_log_entries as linhas em que o aluno e ator
-- (payload.actor_id), alvo (payload.traits.user_id) ou citado pelo e-mail
-- (payload.actor_username, payload.traits.user_email; so se actor_id/traits.user_id
-- estiver vazio ou for o dele), e de auth.flow_state as
-- linhas dele (user_id). So roda se as tabelas existirem (o stub do CI nao as tem).
-- Linhas de outros alunos nao sao tocadas.
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
  v_email text;
begin
  if p_confirmation is distinct from 'EXCLUIR' then
    raise exception 'confirmation_required' using errcode = '22023';
  end if;

  select u.email into v_email from auth.users u where u.id = v_uid;

  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then
    raise exception 'account_not_found' using errcode = 'P0002';
  end if;

  -- Rastro fora da cascata, so depois de confirmar a exclusao (uma linha de auditoria
  -- gravada por outra transacao no intervalo nao fica para tras). O e-mail so casa
  -- quando a linha nao pertence a outra conta (e-mail reutilizado, usuario SSO).
  if to_regclass('auth.audit_log_entries') is not null then
    execute 'delete from auth.audit_log_entries
              where payload->>''actor_id'' = $1
                 or payload->''traits''->>''user_id'' = $1
                 or ($2 is not null and (
                      (coalesce(payload->>''actor_id'', '''') in ('''', $1)
                         and lower(payload->>''actor_username'') = lower($2))
                      or (coalesce(payload->''traits''->>''user_id'', '''') in ('''', $1)
                         and lower(payload->''traits''->>''user_email'') = lower($2))))'
      using v_uid::text, v_email;
  end if;
  if to_regclass('auth.flow_state') is not null then
    execute 'delete from auth.flow_state where user_id = $1' using v_uid;
  end if;

  insert into private.account_deletions default values;
  return jsonb_build_object('deleted', true);
end $$;

revoke execute on function public.delete_my_account(text) from public, anon, service_role;
grant execute on function public.delete_my_account(text) to authenticated;
