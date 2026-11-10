-- =====================================================================
-- MyFluenti - Migration 011: notas (lista com titulo, limite do corpo) e
-- select_starting_level idempotente.
--
-- 1. user_notes_body_length: char_length(btrim(body, E' \t\r\n')) entre 1 e 2000
--    (INTERPRETACAO do pedido "2000 caracteres, constraint com trim"; confirmar).
--    O trim cobre espaco, tab, CR e LF; espacos Unicode (ex. nbsp) nao entram.
-- 2. public.get_my_notes: RPC de leitura das notas do aluno com o titulo do alvo.
--    Necessaria porque o titulo da aula vive em lesson_versions (versionado, RLS
--    por modulo/plano) e um select com relacao nao devolve a "versao atual".
-- 3. select_starting_level: se o nivel ativo ja e p_level_id, nao encerra nem
--    grava nova linha em user_level_history (o app repete a chamada quando perde
--    a resposta). Assinatura, retorno, erros e grants iguais.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Limite do corpo da nota
-- Nenhuma linha existente viola (conferido no Supabase local; ainda nao ha
-- ambientes remotos). Se algum ambiente tiver nota violando, esta migration falha
-- sem alterar nada: nenhum dado e apagado ou truncado automaticamente.
-- ---------------------------------------------------------------------
alter table public.user_notes
  add constraint user_notes_body_length
  check (char_length(btrim(body, E' \t\r\n')) between 1 and 2000);

-- ---------------------------------------------------------------------
-- 2. get_my_notes
-- Titulo do alvo (target_title):
--   aula     -> titulo da versao publicada mais recente, se o modulo esta publicado e o
--               plano permite; senao null.
--   topico   -> title, se publicado e permitido pelo plano; senao null.
--   palavra  -> lemma, se publicada e permitida pelo plano; senao null.
-- section_title: titulo da secao ancorada (versao da secao publicada e aula legivel);
-- null quando nao ha secao, a secao nao tem titulo ou o conteudo nao pode ser lido.
-- locked = true quando o alvo e Premium e o aluno esta sem plano. Alvo nao publicado:
-- target_title null e locked false. O corpo da nota e do proprio aluno e sempre volta.
-- Nao usa user_module_progress: a nota ja existe; publicacao e plano bastam para nao
-- vazar titulo. Paginacao igual a get_my_favorites (limit 1..50, offset 0..100000).
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
           lm.access_tier as lesson_tier, lm.is_published as lesson_pub,
           gt.access_tier as topic_tier,  gt.is_published as topic_pub,
           vo.access_tier as vocab_tier,  vo.is_published as vocab_pub
      from page p
      left join public.lessons l on l.id = p.lesson_id
      left join public.modules lm on lm.id = l.module_id
      left join public.grammar_topics gt on gt.id = p.grammar_topic_id
      left join public.vocabulary vo on vo.id = p.vocabulary_id
  ),
  shaped as (
    select r.*,
           coalesce((case r.target_type
                       when 'lesson' then r.lesson_tier
                       when 'grammar_topic' then r.topic_tier
                       else r.vocab_tier end) = 'premium' and not v_prem, false) as is_locked,
           coalesce(case r.target_type
                      when 'lesson' then r.lesson_pub
                      when 'grammar_topic' then r.topic_pub
                      else r.vocab_pub end, false) as is_pub
      from resolved r
  )
  select (select count(*) from notes)::integer,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'id', s.id,
                     'target_type', s.target_type,
                     'lesson_id', s.lesson_id,
                     'grammar_topic_id', s.grammar_topic_id,
                     'vocabulary_id', s.vocabulary_id,
                     'lesson_section_id', s.lesson_section_id,
                     'target_title',
                       case when s.is_locked or not s.is_pub then null
                       else case s.target_type
                         when 'lesson' then
                           (select lv.title from public.lesson_versions lv
                             where lv.lesson_id = s.lesson_id and lv.is_published
                             order by lv.version_number desc limit 1)
                         when 'grammar_topic' then
                           (select g.title from public.grammar_topics g where g.id = s.grammar_topic_id)
                         else
                           (select v.lemma from public.vocabulary v where v.id = s.vocabulary_id)
                       end end,
                     'section_title',
                       case when s.target_type = 'lesson' and s.lesson_section_id is not null
                                 and not s.is_locked and s.is_pub then
                         (select ls.title from public.lesson_sections ls
                            join public.lesson_versions lv on lv.id = ls.lesson_version_id
                           where ls.id = s.lesson_section_id and lv.is_published)
                       end,
                     'access_tier',
                       case s.target_type when 'lesson' then s.lesson_tier
                                          when 'grammar_topic' then s.topic_tier
                                          else s.vocab_tier end,
                     'locked', s.is_locked,
                     'body', s.body,
                     'created_at', s.created_at,
                     'updated_at', s.updated_at)
                   order by s.rn)
                   from shaped s), '[]'::jsonb)
    into v_total, v_items;

  return jsonb_build_object(
    'items', v_items, 'total', v_total,
    'has_more', p_offset::bigint + jsonb_array_length(v_items) < v_total::bigint);
end $$;

revoke all on function public.get_my_notes(int, int) from public, anon;
grant execute on function public.get_my_notes(int, int) to authenticated;

-- ---------------------------------------------------------------------
-- 3. select_starting_level idempotente
-- Copia da 010; muda so: v_active_level e o desvio que pula encerrar/inserir historico
-- quando o nivel ativo ja e p_level_id. Validacoes, update de profiles e unlock_module
-- continuam sempre executando.
-- ---------------------------------------------------------------------
create or replace function public.select_starting_level(
  p_level_id uuid, p_placement_attempt_id uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_attempt uuid; v_ref uuid; v_ref_pos smallint; v_sel_pos smallint;
  v_has_active boolean; v_active_level uuid; v_source text; v_first uuid;
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

  select h.level_id into v_active_level from public.user_level_history h
   where h.user_id = v_uid and h.ended_at is null;
  v_has_active := found;

  -- Idempotencia: o nivel ativo ja e o escolhido -> nao toca no historico.
  if v_active_level is distinct from p_level_id then
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
