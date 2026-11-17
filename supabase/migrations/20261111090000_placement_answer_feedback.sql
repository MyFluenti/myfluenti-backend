-- =====================================================================
-- 012: submit_placement_answer devolve {"is_correct": boolean}
--
-- Decisao do Gabriel (2026-11-10): o app passa a mostrar acerto/erro depois de cada
-- resposta do nivelamento. Substitui a regra "sem correcao no teste de nivelamento".
--
-- Contrato (regra 6): os ARGUMENTOS nao mudam (uuid, uuid, jsonb). So o retorno passa
-- de void para jsonb. Clientes antigos chamam a RPC e ignoram o retorno (o app usa um
-- helper rpcVoid), entao nao quebram. `create or replace` nao troca o tipo de retorno,
-- por isso drop + create na mesma migration (transacional). Grants refeitos como na 003.
--
-- Retorno: exatamente { "is_correct": boolean }. Sem resposta certa, sem explicacao,
-- sem pontos, sem respostas aceitas. is_correct e o mesmo v_ok gravado em
-- user_placement_answers.is_correct (private.grade_answer).
--
-- Erros (iguais aos anteriores): 28000 (sem sessao), 42501 (tentativa nao encontrada
-- ou de outro aluno), 55000 (tentativa encerrada), 23503 (questao fora do teste),
-- 23505 (questao ja respondida).
-- =====================================================================

drop function public.submit_placement_answer(uuid, uuid, jsonb);

create function public.submit_placement_answer(
  p_attempt_id uuid, p_question_id uuid, p_answer jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_status text; v_weight numeric; v_ok boolean;
begin
  select a.placement_test_id, a.status into v_test, v_status
    from public.user_placement_attempts a
   where a.id = p_attempt_id and a.user_id = v_uid
   for update;
  if not found then
    raise exception 'Tentativa nao encontrada' using errcode = '42501';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'Tentativa ja encerrada' using errcode = '55000';
  end if;

  select pq.weight into v_weight from public.placement_questions pq
   where pq.placement_test_id = v_test and pq.question_id = p_question_id;
  if not found then
    raise exception 'Questao nao pertence a este teste' using errcode = '23503';
  end if;
  if exists (select 1 from public.user_placement_answers x
              where x.attempt_id = p_attempt_id and x.question_id = p_question_id) then
    raise exception 'Questao ja respondida' using errcode = '23505';
  end if;

  select g.is_correct into v_ok from private.grade_answer(p_question_id, p_answer) g;
  insert into public.user_placement_answers
    (user_id, attempt_id, placement_test_id, question_id, submitted_answer, is_correct, awarded_points)
  values
    (v_uid, p_attempt_id, v_test, p_question_id, p_answer, v_ok,
     case when v_ok then v_weight else 0 end);

  return jsonb_build_object('is_correct', v_ok);
end $$;

revoke all on function public.submit_placement_answer(uuid, uuid, jsonb) from public, anon;
grant execute on function public.submit_placement_answer(uuid, uuid, jsonb) to authenticated;
