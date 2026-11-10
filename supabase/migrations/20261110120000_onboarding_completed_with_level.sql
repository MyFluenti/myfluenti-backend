-- =====================================================================
-- MyFluenti - Migration 010: select_starting_level conclui o onboarding
-- Antes, o app chamava select_starting_level e depois gravava
-- profiles.onboarding_completed_at por UPDATE direto. Se o app fechasse entre as duas
-- escritas, o aluno ficava com nivel definido e onboarding em aberto (escolhia de novo).
-- Agora a RPC grava os dois na mesma transacao: se ela falhar, nada muda.
-- onboarding_completed_at so e preenchido se estiver nulo (troca de nivel posterior,
-- source = manual_change, preserva a data original).
-- Assinatura, retorno, erros e grants nao mudam (create or replace mantem o execute
-- so para authenticated). O grant de UPDATE em onboarding_completed_at segue valendo
-- para versoes do app que ainda gravam a coluna.
-- =====================================================================

create or replace function public.select_starting_level(
  p_level_id uuid, p_placement_attempt_id uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_attempt uuid; v_ref uuid; v_ref_pos smallint; v_sel_pos smallint;
  v_has_active boolean; v_source text; v_first uuid;
begin
  select l.position into v_sel_pos from public.levels l where l.id = p_level_id;
  if not found then
    raise exception 'Nivel inexistente' using errcode = 'P0002';
  end if;

  if p_placement_attempt_id is not null then
    select a.id, a.recommended_level_id into v_attempt, v_ref
      from public.user_placement_attempts a
     where a.id = p_placement_attempt_id and a.user_id = v_uid and a.status = 'completed';
    if not found then
      raise exception 'Tentativa de nivelamento invalida' using errcode = '42501';
    end if;
  else
    select a.id, a.recommended_level_id into v_attempt, v_ref
      from public.user_placement_attempts a
     where a.user_id = v_uid and a.status = 'completed'
     order by a.completed_at desc limit 1;
  end if;

  if v_ref is null then                      -- sem teste: vale a autoavaliacao
    select p.self_assessed_level_id into v_ref from public.profiles p where p.id = v_uid;
  end if;
  if v_ref is null then                      -- sem nada: apenas o primeiro nivel
    select l.id into v_ref from public.levels l order by l.position limit 1;
  end if;

  select l.position into v_ref_pos from public.levels l where l.id = v_ref;
  if v_sel_pos > v_ref_pos then
    raise exception 'Nivel escolhido nao pode superar o nivel recomendado' using errcode = '22023';
  end if;

  v_first := private.first_published_module(p_level_id);
  if v_first is null then
    raise exception 'Nivel ainda sem modulos publicados' using errcode = 'P0002';
  end if;

  select exists (select 1 from public.user_level_history h
                  where h.user_id = v_uid and h.ended_at is null) into v_has_active;
  v_source := case
    when v_has_active then 'manual_change'
    when v_attempt is null then 'self_assessment'
    when p_level_id = v_ref then 'placement_recommended'
    else 'placement_lower' end;

  update public.user_level_history set ended_at = now()
   where user_id = v_uid and ended_at is null;
  insert into public.user_level_history (user_id, level_id, source, placement_attempt_id)
  values (v_uid, p_level_id, v_source, v_attempt);
  update public.profiles
     set current_level_id = p_level_id,
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = v_uid;

  perform private.unlock_module(v_uid, v_first);
end $$;
