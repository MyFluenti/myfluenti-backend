-- =====================================================================
-- MyFluenti - Migration 007: avatar montavel do usuario
--   profiles.avatar_config (jsonb, formato v1), private.is_valid_avatar_config,
--   RPC update_my_avatar e avatar_config em get_profile_summary.
--
-- Decisoes:
--  * O avatar sai SO pela RPC update_my_avatar: avatar_config NAO entra no grant
--    de update por coluna da migration 002 (o UPDATE direto do aluno e negado).
--  * profiles.avatar_url nao e tocada aqui; sai na migration seguinte (008, decisao do Gabriel).
--  * Validacao no banco: objeto com exatamente as 9 chaves, todas numericas e
--    inteiras, dentro das faixas. Nunca lanca erro: entrada estranha devolve false.
--  * Inteiro = numero JSON cuja escala normalizada (scale do numeric, preservada pelo
--    jsonb) e zero. 1.0 e 2.0000 sao REJEITADOS; 2e0 e 0.5e1 sao aceitos (viram 2 e 5).
--    Assim o valor gravado e sempre inteiro canonico. Numeros enormes sao comparados como numeric, sem cast
--    para int, entao nao estouram.
--  * O check constraint chama private.is_valid_avatar_config a cada UPDATE de profiles,
--    inclusive os diretos do aluno em display_name; por isso authenticated e service_role tem EXECUTE
--    na validadora (pura, sem acesso a dados). Gravar avatar_config segue exclusivo da RPC.
-- =====================================================================

create or replace function private.is_valid_avatar_config(p jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  v_spec constant text[] := array[
    'v:1:1', 'skin:0:4', 'hair:0:5', 'hairColor:0:4', 'eyes:0:2',
    'mouth:0:1', 'acc:0:2', 'outfit:0:4', 'bg:0:4'];
  s text[];
  v_val jsonb;
  n numeric;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return false;
  end if;

  -- chaves exatas: nenhuma faltando, nenhuma extra (chaves repetidas ja colapsam no jsonb)
  if (select count(*) from jsonb_object_keys(p)) <> array_length(v_spec, 1) then
    return false;
  end if;

  for s in select string_to_array(x, ':') from unnest(v_spec) x loop
    v_val := p -> s[1];
    if v_val is null or jsonb_typeof(v_val) <> 'number' then
      return false;
    end if;
    n := v_val::numeric;                -- numeric aceita qualquer tamanho: sem estouro de int
    if scale(n) <> 0 or n < s[2]::numeric or n > s[3]::numeric then
      return false;
    end if;
  end loop;
  return true;
exception when others then
  return false;
end $$;

-- O Postgres confere EXECUTE do check no momento da gravacao, e o aluno grava display_name
-- direto (o check roda em todo UPDATE da linha). Por isso authenticated e service_role recebem EXECUTE na
-- validadora (service_role precisa para UPDATE/INSERT diretos em profiles): ela e pura, nao le tabela nem segredo, e o formato do avatar nao e sigiloso.
revoke all on function private.is_valid_avatar_config(jsonb) from public, anon;
grant execute on function private.is_valid_avatar_config(jsonb) to authenticated, service_role;

alter table public.profiles add column avatar_config jsonb null;
alter table public.profiles add constraint profiles_avatar_config_valid
  check (avatar_config is null or private.is_valid_avatar_config(avatar_config));

comment on column public.profiles.avatar_config is
  'Avatar montavel do usuario (jsonb v1). NULL = avatar padrao. Escrita so por update_my_avatar.';

-- =====================================================================
-- update_my_avatar
-- =====================================================================
create or replace function public.update_my_avatar(p_config jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_cfg jsonb := p_config;
begin
  if v_cfg is not null and jsonb_typeof(v_cfg) = 'null' then
    v_cfg := null;                                  -- JSON null = volta ao padrao
  end if;
  if v_cfg is not null and not private.is_valid_avatar_config(v_cfg) then
    raise exception 'invalid_avatar_config' using errcode = '22023';
  end if;

  update public.profiles set avatar_config = v_cfg where id = v_uid;
  if not found then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;
  return jsonb_build_object('avatar_config', v_cfg);
end $$;

revoke all on function public.update_my_avatar(jsonb) from public, anon, service_role;
grant execute on function public.update_my_avatar(jsonb) to authenticated;

-- =====================================================================
-- get_profile_summary: corpo da migration 004 + chave avatar_config
-- (assinatura, retorno e demais chaves inalterados; grants preservados)
-- =====================================================================
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
           'avatar_url', p.avatar_url,
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
