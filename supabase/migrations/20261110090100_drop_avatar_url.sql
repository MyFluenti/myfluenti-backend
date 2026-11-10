-- =====================================================================
-- MyFluenti - Migration 008: remove profiles.avatar_url
-- Decisao do Gabriel: o produto tera so avatares montaveis (profiles.avatar_config),
-- nunca foto. Dependencias conferidas: nenhuma view, politica, trigger ou indice usa a
-- coluna; handle_new_user nao a menciona; a unica funcao que a le e get_profile_summary
-- (recriada abaixo sem a chave). O privilegio de coluna do grant de update da 002 e removido junto com a coluna; o grant em display_name, locale,
-- self_assessed_level_id e onboarding_completed_at continua valendo.
-- ATENCAO: versoes antigas do app que leem/gravam avatar_url ou esperam a chave
-- avatar_url em get_profile_summary deixam de funcionar nesse ponto.
-- =====================================================================

-- Recria a RPC primeiro (nenhuma dependencia de plpgsql impede o drop, mas evita janela com a chave morta)
create or replace function public.get_profile_summary(p_timezone text default 'UTC')
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_end timestamptz;
  v_res jsonb;
begin
  v_end := private.local_day_end(p_timezone);

  select jsonb_build_object(
           'display_name', p.display_name,
           'email', (select u.email from auth.users u where u.id = v_uid),
           'avatar_config', p.avatar_config,
           'current_level', (select jsonb_build_object('id', l.id, 'code', l.code, 'title', l.title)
                               from public.levels l where l.id = p.current_level_id),
           'plan_tier', case when private.has_premium_access(v_uid) then 'premium' else 'free' end,
           'placement', jsonb_build_object(
             'completed', exists (select 1 from public.user_placement_attempts a
                                   where a.user_id = v_uid and a.status = 'completed'),
             'last_recommended_level_code', (
                select rl.code
                  from public.user_placement_attempts a
                  join public.levels rl on rl.id = a.recommended_level_id
                 where a.user_id = v_uid and a.status = 'completed'
                 order by a.completed_at desc limit 1),
             'last_completed_at', (
                select max(a.completed_at) from public.user_placement_attempts a
                 where a.user_id = v_uid and a.status = 'completed')),
           'progress', jsonb_build_object(
             'lessons_completed', (select count(*) from public.user_lesson_progress ulp
                                    where ulp.user_id = v_uid and ulp.status = 'completed'),
             'modules_completed', (select count(*) from public.user_module_progress ump
                                    where ump.user_id = v_uid and ump.status = 'completed')),
           'mastery', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'grammar_topic_id', t.id, 'slug', t.slug, 'title', t.title,
                                 'mastery_pct', m.mastery_score, 'attempts', m.attempts_count)
                               order by t.title, t.id), '[]'::jsonb)
                         from public.user_topic_mastery m
                         join public.grammar_topics t on t.id = m.grammar_topic_id and t.is_published
                        where m.user_id = v_uid),
           'review', jsonb_build_object(
             'due_today', private.accessible_due_count(v_uid, v_end),
             'total_scheduled', private.accessible_due_count(v_uid, 'infinity'::timestamptz)),
           'favorites_count',
             (select count(*) from public.user_vocabulary uv
                join public.vocabulary v on v.id = uv.vocabulary_id and v.is_published
               where uv.user_id = v_uid and uv.is_favorite)
             + (select count(*) from public.user_favorite_examples fe
                  join public.vocabulary_examples e on e.id = fe.vocabulary_example_id
                  join public.vocabulary v on v.id = e.vocabulary_id and v.is_published
                 where fe.user_id = v_uid),
           'notes_count', (select count(*) from public.user_notes n where n.user_id = v_uid))
    into v_res
    from (select 1) one
    left join public.profiles p on p.id = v_uid;
  return v_res;
end $$;

alter table public.profiles drop column avatar_url;
