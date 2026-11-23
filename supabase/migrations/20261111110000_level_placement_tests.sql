-- =====================================================================
-- 014: teste de nivelamento por nivel escolhido (ADR 0006)
--
-- O teste geral (30 questoes) continua. Passa a existir, alem dele, um teste publicado
-- por nivel de A2 a C2 (A1 nao tem teste: comeca direto). Nada de conteudo de nivel e
-- publicado aqui; so o contrato do banco.
--
-- 1. placement_tests.level_id: nulo = teste geral; preenchido = teste daquele nivel.
--    Um teste por nivel com `code` proprio (ex. 'nivel-b1'); unique (code, version_number)
--    continua. O numero de questoes e a distribuicao (8 questoes, 3-3-1-1) sao
--    PROVISORIOS e ficam no validador do conteudo; o banco so mantem o check do 001.
-- 2. Trigger placement_tests_level_guard (nao toca no guard do 001):
--      - INSERT ja publicado (is_published ou published_at), de qualquer teste, e recusado
--        (23514 placement_test_publish_on_insert_not_allowed): publica-se por update;
--      - teste de nivel de A1 e recusado (23514 placement_level_test_a1_not_allowed);
--      - ao publicar um teste de nivel, toda questao precisa ter difficulty_level_id
--        igual ao level_id (23514 placement_level_test_difficulty_mismatch).
-- 3. start_placement_attempt (v1): MESMA assinatura e grants (create or replace). Igual
--    a 013 (retomada, carencia de 168 h, lock auth.users key share + perfil), mas so
--    escolhe testes GERAIS. Com p_test_id que aponta para teste de nivel, recusa com
--    22023 placement_level_test_requires_v2 (app antigo nao abre teste de nivel); rascunho ou id inexistente: P0002. A
--    retomada de uma in_progress em andamento continua valendo para qualquer teste.
-- 4. start_placement_attempt_v2(p_level_id uuid default null): nulo = teste geral (igual
--    a v1 sem argumento); nivel informado = teste de nivel publicado mais recente.
--    A1 -> 22023 level_test_not_available. Nivel inexistente -> P0002 level_not_found.
--    Nivel sem teste publicado -> P0002 level_test_not_published. Mesma retomada
--    (a in_progress mais recente em qualquer teste publicado, mesmo de outro nivel, para
--    nao travar o aluno; o app le o nivel por get_placement_items.attempt.level_code) e
--    mesma carencia (soma tentativas de nivel e geral).
--    Os dois RPCs usam private.start_placement_impl.
-- 5. finish_placement_attempt: teste geral inalterado (60% em sequencia). Teste de nivel:
--    nota ponderada pelos pesos; >= 70% recomenda o proprio nivel; de 40% a < 70% o nivel
--    imediatamente abaixo; < 40% A1. Nunca acima do nivel do teste. Constantes
--    PROVISORIAS (ADR 0006). Retorno com a mesma forma e a chave aditiva level_test_code
--    (nulo no geral). Comparacao sem arredondar: earned * 100 >= total * pct.
-- 6. get_placement_items: chave aditiva attempt.level_code (nulo no geral).
-- 7. select_starting_level, submit_placement_answer e a view placement_test_items: sem
--    mudanca (funcionam com teste de nivel).
--
-- Contrato (regra 6): v1 mantem assinatura; chaves novas so aditivas; v2 nova.
-- =====================================================================

alter table public.placement_tests
  add column level_id uuid references public.levels(id);

-- ---------------------------------------------------------------------
-- 2. Guarda de teste de nivel
-- ---------------------------------------------------------------------
create or replace function private.guard_placement_level_test() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- teste novo nasce como rascunho (qualquer teste, geral ou de nivel): publicar so por update,
  -- depois de inserir as questoes. Sem isso, um teste publicado vazio ficaria sem como receber
  -- questoes (o guard do 001 so valida a contagem no update).
  if tg_op = 'INSERT' and (new.is_published or new.published_at is not null) then
    raise exception 'placement_test_publish_on_insert_not_allowed' using errcode = '23514';
  end if;
  if new.level_id is null then
    return new;
  end if;
  if exists (select 1 from public.levels l where l.id = new.level_id and l.code = 'A1') then
    raise exception 'placement_level_test_a1_not_allowed' using errcode = '23514';
  end if;
  if new.is_published and exists (
       select 1 from public.placement_questions pq
        where pq.placement_test_id = new.id and pq.difficulty_level_id <> new.level_id) then
    raise exception 'placement_level_test_difficulty_mismatch' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function private.guard_placement_level_test() from public, anon, authenticated;

create trigger placement_tests_level_guard
  before insert or update on public.placement_tests
  for each row execute function private.guard_placement_level_test();

-- ---------------------------------------------------------------------
-- 3 e 4. Inicio de tentativa (implementacao comum)
-- p_mode: 'v1' (p_test_id), 'v2' (p_level_id)
-- ---------------------------------------------------------------------
create or replace function private.start_placement_impl(
  p_mode text, p_test_id uuid, p_level_id uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_attempt uuid; v_last timestamptz;
  c_cooldown constant interval := interval '168 hours';   -- 7 dias, PROVISORIO (013)
begin
  -- validacao de argumentos (antes de qualquer lock ou retomada)
  if p_mode = 'v1' and p_test_id is not null
     and exists (select 1 from public.placement_tests pt
                  where pt.id = p_test_id and pt.is_published and pt.level_id is not null) then
    raise exception 'placement_level_test_requires_v2' using errcode = '22023';
  end if;
  if p_mode = 'v2' and p_level_id is not null then
    if not exists (select 1 from public.levels l where l.id = p_level_id) then
      raise exception 'level_not_found' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.levels l where l.id = p_level_id and l.code = 'A1') then
      raise exception 'level_test_not_available' using errcode = '22023';
    end if;
  end if;

  -- serializa por aluno: users primeiro (como delete_my_account), depois o perfil
  perform 1 from auth.users u where u.id = v_uid for key share;
  if not found then
    raise exception 'Autenticacao obrigatoria' using errcode = '28000';
  end if;
  perform 1 from public.profiles p where p.id = v_uid for update;

  -- retomada (a carencia nunca bloqueia retomar)
  if p_mode = 'v1' and p_test_id is not null then
    select a.id into v_attempt
      from public.user_placement_attempts a
      join public.placement_tests pt on pt.id = a.placement_test_id and pt.is_published
     where a.user_id = v_uid and a.placement_test_id = p_test_id and a.status = 'in_progress';
  else
    select a.id into v_attempt
      from public.user_placement_attempts a
      join public.placement_tests pt on pt.id = a.placement_test_id and pt.is_published
     where a.user_id = v_uid and a.status = 'in_progress'
     order by a.started_at desc, a.id limit 1;
  end if;
  if v_attempt is not null then
    return v_attempt;
  end if;

  -- escolha do teste
  if p_mode = 'v2' and p_level_id is not null then
    select pt.id into v_test from public.placement_tests pt
     where pt.is_published and pt.level_id = p_level_id
     order by pt.published_at desc, pt.version_number desc limit 1;
    if v_test is null then
      raise exception 'level_test_not_published' using errcode = 'P0002';
    end if;
  elsif p_mode = 'v1' and p_test_id is not null then
    select pt.id into v_test from public.placement_tests pt
     where pt.id = p_test_id and pt.is_published and pt.level_id is null;
  else
    select pt.id into v_test from public.placement_tests pt
     where pt.is_published and pt.level_id is null
     order by pt.published_at desc, pt.version_number desc limit 1;
  end if;
  if v_test is null then
    raise exception 'Nenhum teste de nivelamento publicado' using errcode = 'P0002';
  end if;

  -- carencia: soma tentativas de qualquer teste (geral e de nivel)
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
revoke all on function private.start_placement_impl(text, uuid, uuid) from public, anon, authenticated;

create or replace function public.start_placement_attempt(p_test_id uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  return private.start_placement_impl('v1', p_test_id, null);
end $$;
revoke all on function public.start_placement_attempt(uuid) from public, anon;
grant execute on function public.start_placement_attempt(uuid) to authenticated;

create function public.start_placement_attempt_v2(p_level_id uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  return private.start_placement_impl('v2', null, p_level_id);
end $$;
revoke all on function public.start_placement_attempt_v2(uuid) from public, anon;
grant execute on function public.start_placement_attempt_v2(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. finish_placement_attempt
-- ---------------------------------------------------------------------
create or replace function public.finish_placement_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_status text; v_test_level uuid; v_test_level_pos smallint; v_test_level_code text;
  v_total numeric; v_earned numeric; v_score numeric;
  v_rec uuid; v_rec_code text; v_breakdown jsonb;
  r record;
  c_threshold constant numeric := 0.60;       -- teste geral (provisorio)
  c_level_pass_pct constant numeric := 70;    -- teste de nivel: confirma o nivel (provisorio, ADR 0006)
  c_level_mid_pct  constant numeric := 40;    -- teste de nivel: um nivel abaixo (provisorio, ADR 0006)
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

  select pt.level_id into v_test_level from public.placement_tests pt where pt.id = v_test;

  select coalesce(sum(pq.weight), 0) into v_total
    from public.placement_questions pq where pq.placement_test_id = v_test;
  select coalesce(sum(x.awarded_points), 0) into v_earned
    from public.user_placement_answers x where x.attempt_id = p_attempt_id;
  v_score := case when v_total > 0 then v_earned * 100 / v_total else 0 end;

  if v_test_level is null then
    -- teste geral: inalterado (maior nivel em sequencia com >= 60%)
    for r in
      select l.id, sum(pq.weight) as total, sum(coalesce(x.awarded_points, 0)) as earned
        from public.placement_questions pq
        join public.levels l on l.id = pq.difficulty_level_id
        left join public.user_placement_answers x
               on x.attempt_id = p_attempt_id and x.question_id = pq.question_id
       where pq.placement_test_id = v_test
       group by l.id, l.position
       order by l.position
    loop
      if r.earned / r.total >= c_threshold then v_rec := r.id; else exit; end if;
    end loop;
    if v_rec is null then
      select l.id into v_rec from public.levels l order by l.position limit 1;
    end if;
  else
    -- teste de nivel: confirma, desce um nivel ou vai para A1; nunca sobe
    select l.position, l.code into v_test_level_pos, v_test_level_code
      from public.levels l where l.id = v_test_level;
    if v_earned * 100 >= v_total * c_level_pass_pct and v_total > 0 then
      v_rec := v_test_level;
    elsif v_earned * 100 >= v_total * c_level_mid_pct and v_total > 0 then
      select l.id into v_rec from public.levels l
       where l.position < v_test_level_pos order by l.position desc limit 1;
    end if;
    if v_rec is null then
      select l.id into v_rec from public.levels l order by l.position limit 1;
    end if;
  end if;
  select l.code into v_rec_code from public.levels l where l.id = v_rec;

  select coalesce(jsonb_object_agg(t.competency, jsonb_build_object(
           'earned', t.earned, 'total', t.total,
           'pct', case when t.total > 0 then t.earned * 100 / t.total else 0 end)), '{}'::jsonb)
    into v_breakdown
    from (select pq.competency, sum(pq.weight) as total,
                 sum(coalesce(x.awarded_points, 0)) as earned
            from public.placement_questions pq
            left join public.user_placement_answers x
                   on x.attempt_id = p_attempt_id and x.question_id = pq.question_id
           where pq.placement_test_id = v_test
           group by pq.competency) t;

  update public.user_placement_attempts
     set status = 'completed', completed_at = now(), score_pct = v_score,
         recommended_level_id = v_rec, competency_breakdown = v_breakdown
   where id = p_attempt_id;

  return jsonb_build_object('attempt_id', p_attempt_id, 'score_pct', v_score,
                            'recommended_level_id', v_rec,
                            'recommended_level_code', v_rec_code,
                            'competency_breakdown', v_breakdown,
                            'level_test_code', v_test_level_code);
end $$;

-- ---------------------------------------------------------------------
-- 6. get_placement_items: attempt.level_code (aditivo)
-- ---------------------------------------------------------------------
create or replace function public.get_placement_items(p_attempt_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_test uuid; v_status text; v_total smallint; v_answered integer; v_items jsonb;
  v_level_code text;
begin
  select a.placement_test_id, a.status, pt.total_questions, l.code
    into v_test, v_status, v_total, v_level_code
    from public.user_placement_attempts a
    join public.placement_tests pt on pt.id = a.placement_test_id
    left join public.levels l on l.id = pt.level_id
   where a.id = p_attempt_id and a.user_id = v_uid;
  if not found then
    raise exception 'attempt_not_found' using errcode = '42501';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'attempt_closed' using errcode = '55000';
  end if;

  select count(*)::integer into v_answered
    from public.user_placement_answers x where x.attempt_id = p_attempt_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'position', pq.position,
           'competency', pq.competency,
           'answered', exists (select 1 from public.user_placement_answers x
                                where x.attempt_id = p_attempt_id and x.question_id = pq.question_id),
           'question', jsonb_build_object(
             'id', q.id, 'question_type', q.question_type, 'prompt', q.prompt,
             'prompt_data', private.shuffled_prompt_data(p_attempt_id::text, q.id, q.question_type, q.prompt_data),
             'options', coalesce((select jsonb_agg(jsonb_build_object(
                                          'id', o.id, 'text', o.option_text, 'position', o.position)
                                        order by o.position)
                                    from public.answer_options o where o.question_id = q.id), '[]'::jsonb)))
         order by pq.position), '[]'::jsonb)
    into v_items
    from public.placement_questions pq
    join public.questions q on q.id = pq.question_id
   where pq.placement_test_id = v_test;

  return jsonb_build_object(
    'attempt', jsonb_build_object('id', p_attempt_id, 'status', v_status,
                                  'placement_test_id', v_test, 'total_questions', v_total,
                                  'answered_count', v_answered, 'level_code', v_level_code),
    'items', v_items);
end $$;
revoke all on function public.get_placement_items(uuid) from public, anon;
grant execute on function public.get_placement_items(uuid) to authenticated;
