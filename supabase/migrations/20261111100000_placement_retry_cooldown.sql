-- =====================================================================
-- 013: carencia de 7 dias para nova tentativa do nivelamento
--
-- Decisao do Gabriel (2026-11-17), junto com o feedback de acerto da 012. Reduz a
-- sondagem do gabarito por tentativas repetidas.
--
-- start_placement_attempt(p_test_id uuid default null) returns uuid: MESMA assinatura,
-- retorno e grants (create or replace; execute so para authenticated). Ordem:
--   1. escolhe o teste como antes (o publicado mais recente, ou p_test_id publicado);
--   2. serializa por aluno (for update no perfil): dois toques simultaneos nao abrem
--      duas tentativas nem furam a carencia;
--   3. se ha tentativa in_progress NESTE teste, retoma e devolve (a carencia nunca
--      bloqueia retomar);
--   4. senao, se o aluno tem QUALQUER tentativa (qualquer teste e status) com
--      started_at > now() - 7 dias, falha com P0001 'placement_retry_too_soon' e
--      hint = max(started_at) + 7 dias em ISO 8601 UTC (YYYY-MM-DDTHH24:MI:SSZ),
--      arredondado para cima ao segundo (nunca antes do instante real de liberacao).
--      O erro nao traz gabarito, resposta certa, explicacao nem detail.
--
-- Tentativa in_progress de uma versao ANTERIOR do teste: nao e retomada (o RPC so retoma
-- no teste escolhido, o mais recente) e continua em andamento, sem ser alterada. Se
-- foi iniciada ha menos de 7 dias, ela conta na carencia; depois disso, abre-se uma
-- tentativa nova no teste atual. A tentativa antiga fica orfa (historico imutavel).
--
-- PROVISORIO: o intervalo de 7 dias e fixo (c_cooldown) ate o Gabriel decidir.
--
-- Contrato (regra 6): assinatura igual. Um app antigo que abre nova tentativa dentro
-- da carencia recebe um erro generico (P0001) em vez de uma tentativa; nao quebra
-- nenhuma outra chamada. Retomar continua igual.
-- =====================================================================

create or replace function public.start_placement_attempt(p_test_id uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_attempt uuid; v_last timestamptz;
  c_cooldown constant interval := interval '7 days';   -- PROVISORIO (013)
begin
  if p_test_id is null then
    select pt.id into v_test from public.placement_tests pt
     where pt.is_published order by pt.published_at desc limit 1;
  else
    select pt.id into v_test from public.placement_tests pt
     where pt.id = p_test_id and pt.is_published;
  end if;
  if v_test is null then
    raise exception 'Nenhum teste de nivelamento publicado' using errcode = 'P0002';
  end if;

  -- serializa por aluno (o perfil existe desde o cadastro)
  perform 1 from public.profiles p where p.id = v_uid for update;

  select a.id into v_attempt from public.user_placement_attempts a
   where a.user_id = v_uid and a.placement_test_id = v_test and a.status = 'in_progress';
  if v_attempt is not null then
    return v_attempt;                       -- retoma tentativa em andamento
  end if;

  select max(a.started_at) into v_last from public.user_placement_attempts a
   where a.user_id = v_uid;
  if v_last is not null and v_last > now() - c_cooldown then
    raise exception 'placement_retry_too_soon'
      using errcode = 'P0001',
            hint = to_char(date_trunc('second', v_last + c_cooldown + interval '0.999999 seconds')
                             at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;

  insert into public.user_placement_attempts (user_id, placement_test_id)
  values (v_uid, v_test) returning id into v_attempt;
  return v_attempt;
end $$;

revoke all on function public.start_placement_attempt(uuid) from public, anon;
grant execute on function public.start_placement_attempt(uuid) to authenticated;
