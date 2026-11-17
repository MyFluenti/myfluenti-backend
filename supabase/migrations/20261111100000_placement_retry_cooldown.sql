-- =====================================================================
-- 013: carencia de 7 dias para nova tentativa do nivelamento
--
-- Decisao do Gabriel (2026-11-17), junto com o feedback de acerto da 012. Reduz a
-- sondagem do gabarito por tentativas repetidas.
--
-- start_placement_attempt(p_test_id uuid default null) returns uuid: MESMA assinatura,
-- retorno e grants (create or replace; execute so para authenticated). Ordem:
--   1. serializa por aluno (ver "Lock" abaixo): dois toques simultaneos nao abrem
--      duas tentativas nem furam a carencia;
--   2. RETOMADA (a carencia nunca bloqueia retomar):
--        - p_test_id nulo (como o app chama): devolve a tentativa in_progress mais
--          recente do aluno em QUALQUER teste publicado, inclusive de versao anterior;
--        - p_test_id informado: devolve a in_progress daquele teste (publicado);
--   3. so entao escolhe o teste (nulo: o publicado mais recente; informado: precisa
--      estar publicado, senao P0002);
--   4. carencia: se o aluno tem QUALQUER tentativa (qualquer teste e status) com
--      started_at > now() - 168 horas, falha com P0001 'placement_retry_too_soon' e
--      hint = max(started_at) + 168 horas em ISO 8601 UTC (YYYY-MM-DDTHH24:MI:SSZ),
--      arredondado para cima ao segundo (nunca antes do instante real de liberacao).
--      O erro nao traz gabarito, resposta certa, explicacao nem detail;
--   5. insere a tentativa.
--
-- 168 horas em vez de '7 days': com o fuso da sessao (o PostgREST aceita o header
-- Prefer: timezone), '7 days' atravessa horario de verao e varia 1 hora.
--
-- Tentativa in_progress de versao ANTERIOR do teste: com p_test_id nulo e retomada
-- (nao trava o aluno). Com p_test_id informado, so a do proprio teste e retomada; as
-- demais continuam em andamento, intactas (historico imutavel), e contam na carencia.
--
-- Lock: pega `for key share` em auth.users e depois `for update` em profiles. A
-- exclusao de conta (delete_my_account) trava auth.users e depois a cascata pede o
-- perfil; se o start travasse o perfil primeiro e o insert pedisse FOR KEY SHARE em
-- auth.users depois, haveria ciclo. Na mesma ordem da exclusao (users, perfil) nao
-- ha ciclo; se a conta foi excluida no meio, a linha de auth.users some e a funcao
-- falha com 28000. select_starting_level so trava o perfil (e depois pede KEY SHARE em
-- auth.users no insert do historico): essa ordem inversa ja existia antes da 013 e nao
-- e piorada por ela, pois o start nao segura nada que o select_starting_level espere.
-- Requer que o dono da funcao tenha UPDATE em alguma coluna de auth.users (exigencia do
-- Postgres para FOR KEY SHARE); validar no Supabase local.
--
-- PROVISORIO: o intervalo e fixo (c_cooldown) ate o Gabriel decidir.
--
-- Contrato (regra 6): assinatura igual. Um app antigo que abre nova tentativa dentro
-- da carencia recebe um erro generico (P0001) em vez de uma tentativa; nao quebra
-- nenhuma outra chamada. Retomar continua igual (e agora tambem cobre versao anterior).
-- =====================================================================

create or replace function public.start_placement_attempt(p_test_id uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_attempt uuid; v_last timestamptz;
  c_cooldown constant interval := interval '168 hours';   -- 7 dias, PROVISORIO (013)
begin
  -- serializa por aluno: users primeiro (como delete_my_account), depois o perfil
  perform 1 from auth.users u where u.id = v_uid for key share;
  if not found then
    raise exception 'Autenticacao obrigatoria' using errcode = '28000';
  end if;
  perform 1 from public.profiles p where p.id = v_uid for update;

  -- retomada
  if p_test_id is null then
    select a.id into v_attempt
      from public.user_placement_attempts a
      join public.placement_tests pt on pt.id = a.placement_test_id and pt.is_published
     where a.user_id = v_uid and a.status = 'in_progress'
     order by a.started_at desc, a.id limit 1;
  else
    select a.id into v_attempt
      from public.user_placement_attempts a
      join public.placement_tests pt on pt.id = a.placement_test_id and pt.is_published
     where a.user_id = v_uid and a.placement_test_id = p_test_id and a.status = 'in_progress';
  end if;
  if v_attempt is not null then
    return v_attempt;
  end if;

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
