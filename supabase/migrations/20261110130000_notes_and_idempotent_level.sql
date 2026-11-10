-- =====================================================================
-- MyFluenti - Migration 011: notas (lista com titulo, limite do corpo) e
-- select_starting_level idempotente.
--
-- 1. Limite do corpo da nota: trigger apara o body e a constraint
--    user_notes_body_length mede o texto JA aparado (1..2000 caracteres).
--    (INTERPRETACAO do pedido "2000 caracteres, constraint com trim"; confirmada pelo
--    Gabriel na revisao: o valor medido e o valor gravado.)
-- 2. public.get_my_notes: RPC de leitura das notas do aluno com o titulo do alvo.
--    Necessaria porque o titulo da aula vive em lesson_versions (versionado, RLS
--    por modulo/plano) e um select com relacao nao devolve a "versao atual".
-- 3. select_starting_level: idempotente e serializada por aluno.
--
-- Esta migration foi revisada ANTES do merge (so existia no Supabase local), com
-- autorizacao explicita do Gabriel. Depois do merge volta a ser imutavel.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Limite do corpo da nota
-- O trigger BEFORE INSERT/UPDATE apara espaco, tab, CR e LF das pontas (espacos
-- Unicode, como nbsp, nao entram). A constraint confere o texto aparado: 1 a 2000
-- caracteres (espacos e quebras de linha do meio contam). Texto com milhoes de
-- espacos nas pontas e aparado, nunca gravado inteiro. Conta caracteres, nao bytes.
-- Nenhuma linha existente viola (conferido no Supabase local, 0 notas; ainda nao ha
-- ambientes remotos). Se algum ambiente tiver nota violando, a migration falha sem
-- alterar nada: nenhum dado e apagado ou truncado automaticamente.
-- ---------------------------------------------------------------------
create or replace function private.trim_note_body() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.body := btrim(new.body, E' \t\r\n');
  return new;
end $$;

create trigger user_notes_trim_body before insert or update on public.user_notes
  for each row execute function private.trim_note_body();

alter table public.user_notes
  add constraint user_notes_body_length
  check (char_length(body) between 1 and 2000
         and body = btrim(body, E' \t\r\n'));

-- ---------------------------------------------------------------------
-- 2. get_my_notes
-- Titulo do alvo (target_title) e da secao (section_title), ou null quando o aluno
-- nao poderia ler o conteudo:
--   aula     -> versao publicada mais recente, SE private.can_read_lesson_version(versao)
--               (a mesma regra de get_module_lessons e get_lesson_content: versao
--               publicada, modulo liberado em user_module_progress e plano que permite).
--   topico   -> title, se publicado e (free ou plano Premium).
--   palavra  -> lemma, idem.
-- A nota continua listada; so o titulo some. O body e do proprio aluno e sempre volta.
-- locked = true somente para conteudo PUBLICADO e Premium sem plano.
-- Rascunho (nao publicado): locked false, target_title null e access_tier null (nao
-- revela o tier do rascunho). Modulo ainda nao liberado: locked false, titulo null,
-- access_tier do modulo publicado.
-- Paginacao igual a get_my_favorites (limit 1..50, offset 0..100000). Empate de
-- updated_at desempata por id.
-- ---------------------------------------------------------------------
create or replace function public.get_my_notes(p_limit int default 20, p_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid  uuid := private.require_user();
  v_prem boolean := private.has_premium_access(v_uid);
  v_total integer; v_items jsonb;
begin
  if p_limit is null or p_limit not between 1 and 50
     or p_offset is null or p_offset not between 0 and 100000 then
    raise exception 'invalid_filter' using errcode = '22023';
  end if;

  with notes as (
    select n.*,
           case when n.lesson_id is not null then 'lesson'
                when n.grammar_topic_id is not null then 'grammar_topic'
                else 'vocabulary' end as target_type,
           row_number() over (order by n.updated_at desc, n.id) as rn
      from public.user_notes n
     where n.user_id = v_uid
  ),
  page as (
    select * from notes where rn > p_offset::bigint and rn <= p_offset::bigint + p_limit
  ),
  resolved as (
    select p.*,
           lm.access_tier as lesson_tier,
           (lm.is_published and cv.id is not null) as lesson_pub,
           cv.id as lesson_version_id, cv.title as lesson_title,
           gt.access_tier as topic_tier, coalesce(gt.is_published, false) as topic_pub, gt.title as topic_title,
           vo.access_tier as vocab_tier, coalesce(vo.is_published, false) as vocab_pub, vo.lemma as vocab_lemma
      from page p
      left join public.lessons l on l.id = p.lesson_id
      left join public.modules lm on lm.id = l.module_id
      left join lateral (
        select lv.id, lv.title from public.lesson_versions lv
         where lv.lesson_id = p.lesson_id and lv.is_published
         order by lv.version_number desc limit 1) cv on true
      left join public.grammar_topics gt on gt.id = p.grammar_topic_id
      left join public.vocabulary vo on vo.id = p.vocabulary_id
  ),
  shaped as (
    select r.*,
           coalesce(case r.target_type when 'lesson' then r.lesson_pub
                                       when 'grammar_topic' then r.topic_pub
                                       else r.vocab_pub end, false) as is_pub,
           case r.target_type when 'lesson' then r.lesson_tier
                              when 'grammar_topic' then r.topic_tier
                              else r.vocab_tier end as tier
      from resolved r
  ),
  titled as (
    select s.*,
           (s.is_pub and s.tier = 'premium' and not v_prem) as is_locked,
           case s.target_type
             when 'lesson' then s.lesson_version_id is not null
                                and private.can_read_lesson_version(s.lesson_version_id)
             else s.is_pub and (s.tier = 'free' or v_prem) end as title_ok
      from shaped s
  )
  select (select count(*) from notes)::integer,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'id', t.id,
                     'target_type', t.target_type,
                     'lesson_id', t.lesson_id,
                     'grammar_topic_id', t.grammar_topic_id,
                     'vocabulary_id', t.vocabulary_id,
                     'lesson_section_id', t.lesson_section_id,
                     'target_title',
                       case when t.title_ok then
                         case t.target_type when 'lesson' then t.lesson_title
                                            when 'grammar_topic' then t.topic_title
                                            else t.vocab_lemma end
                       end,
                     'section_title',
                       case when t.title_ok and t.target_type = 'lesson'
                                 and t.lesson_section_id is not null then
                         (select ls.title from public.lesson_sections ls
                           where ls.id = t.lesson_section_id
                             and private.can_read_lesson_version(ls.lesson_version_id))
                       end,
                     'access_tier', case when t.is_pub then t.tier end,
                     'locked', coalesce(t.is_locked, false),
                     'body', t.body,
                     'created_at', t.created_at,
                     'updated_at', t.updated_at)
                   order by t.rn)
                   from titled t), '[]'::jsonb)
    into v_total, v_items;

  return jsonb_build_object(
    'items', v_items, 'total', v_total,
    'has_more', p_offset::bigint + jsonb_array_length(v_items) < v_total::bigint);
end $$;

revoke all on function public.get_my_notes(int, int) from public, anon;
grant execute on function public.get_my_notes(int, int) to authenticated;

-- ---------------------------------------------------------------------
-- 3. select_starting_level idempotente e serializada por aluno
-- Copia da 010; muda:
--   (a) trava a linha do perfil do aluno no inicio (for update): duas chamadas
--       simultaneas (toque duplo) sao serializadas; a segunda ve o historico ja
--       gravado pela primeira e nao faz nada (antes: 23505 em
--       user_level_history_one_active);
--   (b) se o nivel ativo ja e p_level_id, nao encerra nem grava historico;
--   (c) nesse caso, se vier p_placement_attempt_id explicito e a linha ativa ainda nao
--       tem vinculo com teste, grava SO o placement_attempt_id nela (source e datas
--       ficam como estavam: a linha continua dizendo como o nivel foi escolhido da
--       primeira vez). Se a linha ja tem vinculo, o primeiro vinculo e mantido.
-- Validacoes, update de profiles (coalesce de onboarding_completed_at) e
-- unlock_module continuam sempre executando. Assinatura, retorno e grants iguais.
-- ---------------------------------------------------------------------
create or replace function public.select_starting_level(
  p_level_id uuid, p_placement_attempt_id uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_attempt uuid; v_ref uuid; v_ref_pos smallint; v_sel_pos smallint;
  v_has_active boolean; v_active_level uuid; v_active_id uuid; v_active_attempt uuid;
  v_source text; v_first uuid;
begin
  -- serializa chamadas do mesmo aluno (a linha de perfil existe desde o cadastro)
  perform 1 from public.profiles p where p.id = v_uid for update;

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

  select h.id, h.level_id, h.placement_attempt_id
    into v_active_id, v_active_level, v_active_attempt
    from public.user_level_history h
   where h.user_id = v_uid and h.ended_at is null;
  v_has_active := found;

  if v_has_active and v_active_level = p_level_id then
    -- Idempotencia: o nivel ativo ja e o escolhido -> nao encerra nem cria linha.
    -- So registra o vinculo com o teste, se veio um e a linha ainda nao tem.
    if p_placement_attempt_id is not null and v_active_attempt is null then
      update public.user_level_history set placement_attempt_id = p_placement_attempt_id
       where id = v_active_id;
    end if;
  else
    v_source := case
      when v_has_active then 'manual_change'
      when v_attempt is null then 'self_assessment'
      when p_level_id = v_ref then 'placement_recommended'
      else 'placement_lower' end;

    update public.user_level_history set ended_at = now()
     where user_id = v_uid and ended_at is null;
    insert into public.user_level_history (user_id, level_id, source, placement_attempt_id)
    values (v_uid, p_level_id, v_source, v_attempt);
  end if;

  update public.profiles
     set current_level_id = p_level_id,
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = v_uid;

  perform private.unlock_module(v_uid, v_first);
end $$;
