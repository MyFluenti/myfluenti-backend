-- #####################################################################
-- #                                                                   #
-- #   DADOS FICTÍCIOS DE TESTE, NUNCA EM STAGING/PRODUÇÃO            #
-- #                                                                   #
-- #   Este arquivo é SÓ para o banco LOCAL de desenvolvimento         #
-- #   (supabase start). Não é seed automático: o `db reset` continua  #
-- #   sem dados. Carregue com scripts/load-dev-seed.ps1 (Windows) ou  #
-- #   scripts/load-dev-seed.sh, que usam o contêiner local.           #
-- #                                                                   #
-- #   Tudo aqui tem slug dev-*, UUID com prefixo d0000000 e título    #
-- #   com "(TESTE)". Roda UMA vez: na segunda vez aborta.             #
-- #   Para recomecar: `supabase db reset`.                            #
-- #                                                                   #
-- #   FORMATO DO CONTEÚDO (PROVISÓRIO, decisão do Gabriel): todo      #
-- #   content e prompt_data leva "v":1; o app ignora blocos           #
-- #   desconhecidos.                                                  #
-- #####################################################################
set client_encoding = 'UTF8';
\set ON_ERROR_STOP on
begin;

-- Recusa rodar duas vezes (marca do seed: o modulo 1)
create function pg_temp.dev_id(p_kind text, p_a int default 0, p_b int default 0) returns uuid
language sql immutable as $$
  select ('d0000000' || substr(md5(p_kind || ':' || p_a || ':' || p_b), 9))::uuid
$$;

do $$
begin
  if exists (select 1 from public.modules where id = pg_temp.dev_id('module', 1)) then
    raise exception 'DEV SEED JÁ CARREGADO: este arquivo roda uma única vez. Rode `supabase db reset` para recomeçar.';
  end if;
  if exists (select 1 from public.modules) or exists (select 1 from public.lessons)
     or exists (select 1 from public.questions) or exists (select 1 from public.placement_tests)
     or exists (select 1 from public.vocabulary) or exists (select 1 from public.grammar_topics)
     or exists (select 1 from public.levels l
                 where (l.code, l.position) not in (('A1',1),('A2',2),('B1',3),('B2',4),('C1',5),('C2',6))) then
    raise exception 'Banco não está limpo: rode supabase db reset antes de carregar o dev-seed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Helper: cria uma aula completa (versao 1 publicada)
-- ---------------------------------------------------------------------
create function pg_temp.dev_lesson(p_module uuid, p_pos int, p_slug text, p_topic uuid, s jsonb) returns void
language plpgsql as $$
declare
  l uuid := pg_temp.dev_id('lesson', p_pos, abs(hashtext(p_slug)));
  v uuid := pg_temp.dev_id('version', p_pos, abs(hashtext(p_slug)));
  e uuid := pg_temp.dev_id('exercise', p_pos, abs(hashtext(p_slug)));
  q uuid; k text; qs jsonb; a text; i int := 0; n int; opt uuid; correct uuid; t jsonb;
begin
  insert into public.lessons (id, module_id, slug, position, is_required) values (l, p_module, p_slug, p_pos, true);
  insert into public.lesson_versions (id, lesson_id, version_number, title, objective)
    values (v, l, 1, s->>'title', s->>'objective');
  insert into public.lesson_grammar_topics (lesson_version_id, grammar_topic_id, is_primary) values (v, p_topic, true);

  insert into public.lesson_sections (lesson_version_id, position, section_type, title, content) values
    (v, 1, 'intro',       'Introdução',  jsonb_build_object('v', 1, 'blocks', s->'intro')),
    (v, 2, 'explanation', 'Explicação',  jsonb_build_object('v', 1, 'blocks', s->'explanation')),
    (v, 3, 'examples',    'Exemplos',    jsonb_build_object('v', 1, 'items',  s->'examples')),
    (v, 4, 'summary',     'Resumo',      jsonb_build_object('v', 1, 'blocks', s->'summary'));

  insert into public.exercises (id, lesson_version_id, position, title, instructions, is_assessed)
    values (e, v, 1, 'Prática (TESTE)', 'Responda às 4 questões.', true);

  foreach k in array array['mc', 'fb', 'wo', 'tr'] loop
    i := i + 1;
    qs := s->'q'->k;
    q := pg_temp.dev_id('question', i, abs(hashtext(p_slug)));
    insert into public.questions (id, lesson_version_id, exercise_id, question_type, prompt, prompt_data,
                                  weight, is_assessed, position, grammar_topic_id)
    values (q, v, e,
            case k when 'mc' then 'multiple_choice' when 'fb' then 'fill_blank'
                   when 'wo' then 'word_order' else 'translation' end,
            qs->>'prompt',
            case k
              when 'mc' then jsonb_build_object('v', 1)
              when 'fb' then jsonb_build_object('v', 1, 'sentence', qs->>'sentence', 'blank_hint', qs->>'hint')
              when 'wo' then jsonb_build_object('v', 1, 'tokens', qs->'tokens')
              else jsonb_build_object('v', 1, 'source_lang', 'pt', 'text', qs->>'text') end,
            1, true, i, p_topic);

    correct := null;
    if k = 'mc' then
      n := 0;
      for a in select jsonb_array_elements_text(qs->'options') loop
        n := n + 1;
        opt := pg_temp.dev_id('option', i * 10 + n, abs(hashtext(p_slug)));
        insert into public.answer_options (id, question_id, option_text, position) values (opt, q, a, n);
        if n = (qs->>'correct')::int then correct := opt; end if;
      end loop;
    else
      n := 0;
      for a in select jsonb_array_elements_text(qs->'answers') loop
        n := n + 1;
        insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
          values (q, a, private.normalize_text(a), n = 1);
      end loop;
    end if;
    insert into private.question_answer_keys (question_id, correct_option_id, explanation)
      values (q, correct, qs->>'explanation');
  end loop;

  update public.lesson_versions set is_published = true where id = v;   -- exige questao avaliativa
end $$;

-- ---------------------------------------------------------------------
-- Dados
-- ---------------------------------------------------------------------
do $$
declare
  lv uuid; m1 uuid := pg_temp.dev_id('module', 1); m2 uuid := pg_temp.dev_id('module', 2);
  t_free uuid := pg_temp.dev_id('topic', 1); t_prem uuid := pg_temp.dev_id('topic', 2);
  a1 uuid; b1 uuid; i int; j int; voc uuid;
  q uuid; o1 uuid; ct text; p int; w int; k int; txt text; lvl uuid; r jsonb; ans text; n int; pos_code text[];
  vocab jsonb; gram jsonb; read jsonb; cons jsonb; item jsonb; comp text; opts jsonb;
begin
  -- Níveis
  insert into public.levels (code, title, position) values
    ('A1', 'Iniciante', 1), ('A2', 'Básico', 2), ('B1', 'Intermediário', 3),
    ('B2', 'Intermediário avançado', 4), ('C1', 'Avançado', 5), ('C2', 'Domínio', 6)
  on conflict (code) do nothing;
  select id into a1 from public.levels where code = 'A1';
  select id into b1 from public.levels where code = 'B1';

  -- Tópicos de gramática (1 Free e 1 Premium)
  insert into public.grammar_topics (id, slug, title, category, summary, content, level_id, access_tier, is_published) values
    (t_free, 'dev-simple-present', 'Simple Present (TESTE)', 'tempos verbais',
     'Rotinas, fatos e hábitos: como formar frases afirmativas, negativas e perguntas.',
     $j${"v":1,"blocks":[
       {"type":"paragraph","text":"O Simple Present descreve rotinas, fatos e hábitos."},
       {"type":"structure","label":"Estrutura","formula":"Sujeito + verbo base (+ s com he/she/it)","examples":["I work every day","She works every day"]},
       {"type":"tip","text":"Na negativa, use do not (don't) ou does not (doesn't) mais o verbo base."},
       {"type":"common_mistake","wrong":"She don't like coffee","right":"She doesn't like coffee","note":"Com he/she/it usamos does."}]}$j$::jsonb,
     a1, 'free', true),
    (t_prem, 'dev-conditionals', 'First Conditional (TESTE)', 'condicionais',
     'Situações possíveis no futuro: if + presente, will + verbo base.',
     $j${"v":1,"blocks":[
       {"type":"paragraph","text":"O first conditional fala de situações possíveis no futuro."},
       {"type":"structure","label":"Estrutura","formula":"If + Simple Present, will + verbo base","examples":["If it rains, I will stay home"]},
       {"type":"tip","text":"Depois de if, não usamos will."}]}$j$::jsonb,
     b1, 'premium', true);

  -- Vocabulário (3 palavras Free, 2 exemplos cada)
  insert into public.vocabulary (id, lemma, part_of_speech, meaning_pt, level_id, access_tier, is_published) values
    (pg_temp.dev_id('vocab', 1), 'book',  'noun',      'livro (TESTE)',     a1, 'free', true),
    (pg_temp.dev_id('vocab', 2), 'work',  'verb',      'trabalhar (TESTE)', a1, 'free', true),
    (pg_temp.dev_id('vocab', 3), 'happy', 'adjective', 'feliz (TESTE)',     a1, 'free', true);
  insert into public.vocabulary_forms (vocabulary_id, form_label, form_text, meaning_pt) values
    (pg_temp.dev_id('vocab', 1), 'base', 'book', 'livro'),
    (pg_temp.dev_id('vocab', 1), 'plural', 'books', 'livros'),
    (pg_temp.dev_id('vocab', 2), 'base', 'work', 'trabalhar'),
    (pg_temp.dev_id('vocab', 2), 'third_person', 'works', 'trabalha'),
    (pg_temp.dev_id('vocab', 2), 'past', 'worked', 'trabalhou'),
    (pg_temp.dev_id('vocab', 2), 'past_participle', 'worked', 'trabalhado'),
    (pg_temp.dev_id('vocab', 2), 'gerund', 'working', 'trabalhando'),
    (pg_temp.dev_id('vocab', 3), 'base', 'happy', 'feliz'),
    (pg_temp.dev_id('vocab', 3), 'comparative', 'happier', 'mais feliz'),
    (pg_temp.dev_id('vocab', 3), 'superlative', 'happiest', 'o mais feliz');
  insert into public.vocabulary_examples (id, vocabulary_id, example_en, example_pt, position) values
    (pg_temp.dev_id('vex', 1, 1), pg_temp.dev_id('vocab', 1), 'I read a book every week.', 'Eu leio um livro por semana.', 1),
    (pg_temp.dev_id('vex', 1, 2), pg_temp.dev_id('vocab', 1), 'This book is very good.', 'Este livro é muito bom.', 2),
    (pg_temp.dev_id('vex', 2, 1), pg_temp.dev_id('vocab', 2), 'I work every day.', 'Eu trabalho todos os dias.', 1),
    (pg_temp.dev_id('vex', 2, 2), pg_temp.dev_id('vocab', 2), 'She works in a school.', 'Ela trabalha em uma escola.', 2),
    (pg_temp.dev_id('vex', 3, 1), pg_temp.dev_id('vocab', 3), 'They are happy today.', 'Eles estão felizes hoje.', 1),
    (pg_temp.dev_id('vex', 3, 2), pg_temp.dev_id('vocab', 3), 'She is happier now.', 'Ela está mais feliz agora.', 2);

  -- Módulos
  insert into public.modules (id, level_id, title, description, position, access_tier, is_published) values
    (m1, a1, 'Fundamentos (TESTE)', 'Módulo gratuito de teste.', 1, 'free', true),
    (m2, a1, 'Cotidiano (TESTE)',   'Módulo Premium de teste.', 2, 'premium', true);

  -- Aula 1 (Free): verbo to be
  perform pg_temp.dev_lesson(m1, 1, 'dev-a1-m1-l1', t_free, $j$
  {"title":"Verbo to be (TESTE)","objective":"Usar am, is e are para dizer quem somos e como estamos.",
   "intro":[{"type":"paragraph","text":"Em inglês, o verbo to be liga o sujeito a uma informação: quem é, como está, onde está."}],
   "explanation":[
     {"type":"paragraph","text":"O verbo muda conforme o sujeito: I am, he/she/it is, we/you/they are."},
     {"type":"structure","label":"Estrutura","formula":"Sujeito + am/is/are + complemento","examples":["I am a student","She is happy","They are at home"]},
     {"type":"tip","text":"Na fala, usamos formas curtas: I'm, she's, they're."},
     {"type":"common_mistake","wrong":"She are happy","right":"She is happy","note":"Com she/he/it usamos is."}],
   "examples":[
     {"en":"I am a student.","pt":"Eu sou estudante.","note":"I am = I'm.","vocabulary_example_id":null},
     {"en":"She is happy.","pt":"Ela está feliz.","note":"She is = she's.","vocabulary_example_id":null},
     {"en":"They are at home.","pt":"Eles estão em casa.","note":"They are = they're.","vocabulary_example_id":null}],
   "summary":[{"type":"paragraph","text":"I am, he/she/it is, we/you/they are."},{"type":"tip","text":"Treine as formas curtas em voz alta."}],
   "q":{
     "mc":{"prompt":"Complete: She ___ happy.","options":["am","is","are"],"correct":2,"explanation":"Com she usamos is."},
     "fb":{"prompt":"Complete a frase.","sentence":"They ___ at home.","hint":"(be)","answers":["are"],"explanation":"Com they usamos are."},
     "wo":{"prompt":"Monte a frase: Eu sou estudante.","tokens":["student","I","a","am"],"answers":["I am a student","I'm a student"],"explanation":"Sujeito + am + complemento."},
     "tr":{"prompt":"Traduza para o inglês.","text":"Ela é feliz.","answers":["She is happy","She's happy"],"explanation":"She is (ou she's) happy."}}}
  $j$::jsonb);

  -- Aula 2 (Free): Simple Present negativo (primeiro exemplo aponta para um vocabulary_example)
  perform pg_temp.dev_lesson(m1, 2, 'dev-a1-m1-l2', t_free, jsonb_set($j$
  {"title":"Simple Present: negativa (TESTE)","objective":"Formar frases negativas com do not e does not.",
   "intro":[{"type":"paragraph","text":"Para dizer o que NÃO fazemos, usamos do not ou does not antes do verbo."}],
   "explanation":[
     {"type":"paragraph","text":"Com I, you, we e they usamos do not (don't). Com he, she e it usamos does not (doesn't)."},
     {"type":"structure","label":"Estrutura","formula":"Sujeito + do/does + not + verbo base","examples":["I do not work","She does not work"]},
     {"type":"tip","text":"Depois de does not, o verbo fica sem s: She doesn't work."},
     {"type":"common_mistake","wrong":"She doesn't works","right":"She doesn't work","note":"O s já está no does."}],
   "examples":[
     {"en":"I work every day.","pt":"Eu trabalho todos os dias.","note":"Afirmativa, para comparar.","vocabulary_example_id":null},
     {"en":"I do not work on Sundays.","pt":"Eu não trabalho aos domingos.","note":"do not = don't.","vocabulary_example_id":null},
     {"en":"She does not work here.","pt":"Ela não trabalha aqui.","note":"does not = doesn't.","vocabulary_example_id":null}],
   "summary":[{"type":"paragraph","text":"I/you/we/they + do not; he/she/it + does not; verbo sempre no base."}],
   "q":{
     "mc":{"prompt":"Complete: She ___ work on Sundays.","options":["do not","does not","not"],"correct":2,"explanation":"Com she usamos does not."},
     "fb":{"prompt":"Complete a frase (negativa).","sentence":"He ___ like coffee.","hint":"(negativa)","answers":["does not","doesn't"],"explanation":"Com he usamos does not (doesn't)."},
     "wo":{"prompt":"Monte a frase: Ela não trabalha aqui.","tokens":["work","She","not","here","does"],"answers":["She does not work here","She doesn't work here"],"explanation":"Sujeito + does not + verbo base."},
     "tr":{"prompt":"Traduza para o inglês.","text":"Eu não trabalho aos domingos.","answers":["I do not work on Sundays","I don't work on Sundays"],"explanation":"I do not (don't) work."}}}
  $j$::jsonb, '{examples,0,vocabulary_example_id}', to_jsonb(pg_temp.dev_id('vex', 2, 1)::text)));

  -- Aula 3 (Free): plurais
  perform pg_temp.dev_lesson(m1, 3, 'dev-a1-m1-l3', t_free, $j$
  {"title":"Plurais regulares (TESTE)","objective":"Formar o plural dos substantivos com s.",
   "intro":[{"type":"paragraph","text":"Para falar de mais de uma coisa, a maioria dos substantivos ganha s no final."}],
   "explanation":[
     {"type":"paragraph","text":"book vira books; apple vira apples."},
     {"type":"structure","label":"Estrutura","formula":"substantivo + s","examples":["one book, two books","one apple, three apples"]},
     {"type":"tip","text":"Depois de two, three, four... o substantivo vai para o plural."},
     {"type":"common_mistake","wrong":"two book","right":"two books","note":"Mais de um pede plural."}],
   "examples":[
     {"en":"I have two books.","pt":"Eu tenho dois livros.","note":"two + plural.","vocabulary_example_id":null},
     {"en":"They have three apples.","pt":"Eles têm três maçãs.","note":"three + plural.","vocabulary_example_id":null}],
   "summary":[{"type":"paragraph","text":"Plural regular: acrescente s."}],
   "q":{
     "mc":{"prompt":"One book, two ___.","options":["book","books","bookes"],"correct":2,"explanation":"O plural regular leva s."},
     "fb":{"prompt":"Complete a frase.","sentence":"I have two ___.","hint":"(apple)","answers":["apples"],"explanation":"Depois de two, plural: apples."},
     "wo":{"prompt":"Monte a frase: Eles têm três livros.","tokens":["books","They","three","have"],"answers":["They have three books"],"explanation":"Sujeito + have + número + plural."},
     "tr":{"prompt":"Traduza para o inglês.","text":"Eu tenho dois livros.","answers":["I have two books"],"explanation":"two books, no plural."}}}
  $j$::jsonb);

  -- Aula 1 do modulo Premium: Past Simple
  perform pg_temp.dev_lesson(m2, 1, 'dev-a1-m2-l1', t_free, $j$
  {"title":"Past Simple: afirmativa (TESTE)","objective":"Contar o que aconteceu no passado com verbos regulares e irregulares comuns.",
   "intro":[{"type":"paragraph","text":"O Past Simple fala de ações terminadas no passado."}],
   "explanation":[
     {"type":"paragraph","text":"Verbos regulares ganham ed: work vira worked. Alguns verbos são irregulares: go vira went."},
     {"type":"structure","label":"Estrutura","formula":"Sujeito + verbo no passado","examples":["He worked yesterday","I went to school"]},
     {"type":"tip","text":"Marcadores de tempo: yesterday, last night, last year."},
     {"type":"common_mistake","wrong":"I goed to school","right":"I went to school","note":"go é irregular."}],
   "examples":[
     {"en":"He worked yesterday.","pt":"Ele trabalhou ontem.","note":"regular: ed.","vocabulary_example_id":null},
     {"en":"I went to school.","pt":"Eu fui para a escola.","note":"irregular: went.","vocabulary_example_id":null}],
   "summary":[{"type":"paragraph","text":"Regulares: ed. Irregulares: decorar a forma."}],
   "q":{
     "mc":{"prompt":"Yesterday I ___ to school.","options":["go","went","goed"],"correct":2,"explanation":"O passado de go é went."},
     "fb":{"prompt":"Complete a frase.","sentence":"She ___ a movie last night.","hint":"(watch)","answers":["watched"],"explanation":"watch é regular: watched."},
     "wo":{"prompt":"Monte a frase: Nós visitamos minha tia ontem.","tokens":["aunt","We","yesterday","my","visited"],"answers":["We visited my aunt yesterday","Yesterday we visited my aunt"],"explanation":"Sujeito + passado + complemento."},
     "tr":{"prompt":"Traduza para o inglês.","text":"Ele trabalhou ontem.","answers":["He worked yesterday"],"explanation":"worked: passado regular."}}}
  $j$::jsonb);

  -- Nivelamento: 30 questoes (8 vocabulary, 10 grammar, 6 reading, 6 construction; 5 por nivel)
  insert into public.placement_tests (id, code, version_number, title, total_questions)
    values (pg_temp.dev_id('ptest', 1), 'dev-placement', 1, 'Nivelamento (TESTE)', 30);

  vocab := $j$[
    ["What does 'dog' mean? (TESTE)","cachorro","gato","cavalo"],
    ["What does 'house' mean? (TESTE)","casa","carro","escola"],
    ["What does 'water' mean? (TESTE)","água","leite","suco"],
    ["What does 'big' mean? (TESTE)","grande","pequeno","rápido"],
    ["What does 'happy' mean? (TESTE)","feliz","triste","cansado"],
    ["What does 'fast' mean? (TESTE)","rápido","lento","alto"],
    ["What does 'book' mean? (TESTE)","livro","mesa","janela"],
    ["What does 'friend' mean? (TESTE)","amigo","irmão","vizinho"]]$j$::jsonb;
  gram := $j$[
    ["She ___ a teacher. (TESTE)","is","am","are"],
    ["They ___ at school. (TESTE)","are","is","am"],
    ["I ___ coffee every day. (TESTE)","drink","drinks","drinking"],
    ["He ___ TV now. (TESTE)","is watching","watch","watches"],
    ["There ___ two books on the table. (TESTE)","are","is","am"],
    ["She doesn't ___ meat. (TESTE)","eat","eats","eating"],
    ["We ___ to Rio last year. (TESTE)","went","go","goes"],
    ["I have ___ apple. (TESTE)","an","a","the"],
    ["This is ___ book. (TESTE)","my","me","I"],
    ["Do you ___ English? (TESTE)","speak","speaks","speaking"]]$j$::jsonb;
  read := $j$[
    ["Read: 'Ana lives in Recife. She works in a school.' Where does Ana work? (TESTE)","In a school","In Recife","At home"],
    ["Read: 'Tom has a dog. The dog is brown.' What color is the dog? (TESTE)","Brown","Black","White"],
    ["Read: 'We eat breakfast at 7.' When do they eat breakfast? (TESTE)","At 7","At 8","At night"],
    ["Read: 'Lia likes tea, but she does not like coffee.' What does Lia like? (TESTE)","Tea","Coffee","Milk"],
    ["Read: 'The shop opens at 9 and closes at 6.' When does the shop close? (TESTE)","At 6","At 9","At noon"],
    ["Read: 'Paul is tired, so he goes to bed early.' Why does Paul go to bed early? (TESTE)","He is tired","He is happy","He is hungry"]]$j$::jsonb;
  cons := $j$[
    ["Put the words in order. (TESTE)",["like","music","I"],["I like music"]],
    ["Put the words in order. (TESTE)",["friend","She","my","is"],["She is my friend"]],
    ["Put the words in order. (TESTE)",["day","every","We","work"],["We work every day","Every day we work"]],
    ["Put the words in order. (TESTE)",["tea","He","like","not","does"],["He does not like tea","He doesn't like tea"]],
    ["Put the words in order. (TESTE)",["home","They","yesterday","went"],["They went home yesterday","Yesterday they went home"]],
    ["Put the words in order. (TESTE)",["big","I","dogs","have","two"],["I have two big dogs"]]]$j$::jsonb;

  pos_code := array['A1','A2','B1','B2','C1','C2'];
  for i in 1..30 loop
    comp := case when i <= 8 then 'vocabulary' when i <= 18 then 'grammar' when i <= 24 then 'reading' else 'construction' end;
    select id into lvl from public.levels where code = pos_code[1 + ((i - 1) % 6)];
    q := pg_temp.dev_id('pquestion', i);
    if comp = 'construction' then
      item := cons -> (i - 25);
      insert into public.questions (id, question_type, prompt, prompt_data)
        values (q, 'word_order', item ->> 0, jsonb_build_object('v', 1, 'tokens', item -> 1));
      n := 0;
      for ans in select jsonb_array_elements_text(item -> 2) loop
        n := n + 1;
        insert into private.accepted_answers (question_id, answer_text, normalized_text, is_primary)
          values (q, ans, private.normalize_text(ans), n = 1);
      end loop;
      insert into private.question_answer_keys (question_id, correct_option_id) values (q, null);
    else
      item := case comp when 'vocabulary' then vocab -> (i - 1)
                        when 'grammar' then gram -> (i - 9)
                        else read -> (i - 19) end;
      insert into public.questions (id, question_type, prompt, prompt_data)
        values (q, 'multiple_choice', item ->> 0, jsonb_build_object('v', 1));
      -- a alternativa correta (item[1]) fica na posicao 1, 2 ou 3 conforme a questao
      p := 1 + (i % 3); w := 2;
      for k in 1..3 loop
        o1 := pg_temp.dev_id('poption', i, k);
        if k = p then
          txt := item ->> 1; ct := o1::text;
        else
          txt := item ->> w; w := w + 1;
        end if;
        insert into public.answer_options (id, question_id, option_text, position) values (o1, q, txt, k);
      end loop;
      insert into private.question_answer_keys (question_id, correct_option_id, explanation)
        values (q, ct::uuid, 'Questão de teste (TESTE).');
    end if;
    insert into public.placement_questions (placement_test_id, question_id, competency, difficulty_level_id, weight, position)
      values (pg_temp.dev_id('ptest', 1), q, comp, lvl, 1, i);
  end loop;
  update public.placement_tests set is_published = true where id = pg_temp.dev_id('ptest', 1);

  raise notice 'Dev seed carregado (DADOS FICTÍCIOS DE TESTE).';
end $$;

commit;

select 'níveis' as item, count(*) from public.levels
union all select 'módulos dev', count(*) from public.modules where id in (pg_temp.dev_id('module', 1), pg_temp.dev_id('module', 2))
union all select 'aulas dev', count(*) from public.lessons where slug like 'dev-%'
union all select 'questões de aula', count(*) from public.questions where lesson_version_id is not null
union all select 'questões do nivelamento', count(*) from public.placement_questions
union all select 'tópicos dev', count(*) from public.grammar_topics where slug like 'dev-%'
union all select 'palavras dev', count(*) from public.vocabulary where meaning_pt like '%(TESTE)'
union all select 'exemplos de palavras', count(*) from public.vocabulary_examples;
