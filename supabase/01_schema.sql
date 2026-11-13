-- =====================================================================
-- SISTEMA JURÍDICO · FASE 1 · ESTRUTURA DO BANCO (Supabase / Postgres)
-- Rodar inteiro no SQL Editor do Supabase, num projeto novo.
--
-- Regra central de sigilo: cada advogado só enxerga os processos em que
-- está cadastrado como advogado. Processo com os dois advogados aparece
-- para os dois. A regra é aplicada pelo banco (RLS), não pela tela.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. ADVOGADOS (um por login)
-- ---------------------------------------------------------------------
create table public.advogados (
  id          uuid primary key references auth.users(id) on delete cascade,
  nome        text not null,
  oab_numero  text not null,
  oab_uf      char(2) not null,
  email       text,
  criado_em   timestamptz not null default now(),
  unique (oab_numero, oab_uf)
);

-- ---------------------------------------------------------------------
-- 2. CLIENTES (pessoa física ou jurídica)
-- ---------------------------------------------------------------------
create table public.clientes (
  id              uuid primary key default gen_random_uuid(),
  tipo            text not null check (tipo in ('PF','PJ')),
  nome            text not null,               -- nome ou razão social
  nome_fantasia   text,
  cpf_cnpj        text,
  email           text,
  telefone        text,
  observacoes     text,
  criado_por      uuid not null default auth.uid() references public.advogados(id),
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);

-- Quem atende cada cliente (mesma lógica de sigilo dos processos)
create table public.cliente_advogados (
  cliente_id   uuid not null references public.clientes(id) on delete cascade,
  advogado_id  uuid not null references public.advogados(id) on delete cascade,
  primary key (cliente_id, advogado_id)
);

-- ---------------------------------------------------------------------
-- 3. PROCESSOS
-- ---------------------------------------------------------------------
create table public.processos (
  id                 uuid primary key default gen_random_uuid(),
  numero_cnj         text not null unique
                     check (numero_cnj ~ '^\d{7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4}$'),
  cliente_id         uuid not null references public.clientes(id),
  polo               text not null check (polo in ('autor','reu')),
  parte_contraria    text,
  tribunal           text not null,            -- sigla: TJBA, TRT5, TRF1...
  orgao_julgador     text,
  comarca            text,                      -- preenchida pelo DataJud (município) ou à mão
  municipio_ibge     int,
  classe             text,
  tipo_acao          text check (tipo_acao in ('Cível','Consumidor','Trabalhista','Outro')),
  valor_causa        numeric(14,2),
  situacao           text not null default 'ativo'
                     check (situacao in ('ativo','suspenso','arquivado','encerrado')),
  data_distribuicao  date,
  datajud_sync_em    timestamptz,               -- última consulta ao DataJud
  observacoes        text,
  criado_por         uuid not null default auth.uid() references public.advogados(id),
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
create index on public.processos (cliente_id);
create index on public.processos (tribunal);

create table public.processo_advogados (
  processo_id  uuid not null references public.processos(id) on delete cascade,
  advogado_id  uuid not null references public.advogados(id) on delete cascade,
  primary key (processo_id, advogado_id)
);
create index on public.processo_advogados (advogado_id);

-- ---------------------------------------------------------------------
-- 4. MONITORAMENTO DO DJEN (o que cada advogado quer vigiar)
--    Ex.: OAB 12345/BA; nome de parte "MARQUES TURISMO"
-- ---------------------------------------------------------------------
create table public.monitoramentos (
  id           uuid primary key default gen_random_uuid(),
  advogado_id  uuid not null default auth.uid() references public.advogados(id) on delete cascade,
  tipo         text not null check (tipo in ('oab','nome_parte')),
  valor        text not null,          -- número da OAB ou nome a buscar
  uf           char(2),                -- UF da OAB, quando tipo = 'oab'
  cliente_id   uuid references public.clientes(id) on delete cascade,
  ativo        boolean not null default true,
  ultima_busca timestamptz,
  criado_em    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 5. PUBLICAÇÕES (DJEN)
--    processo_id vazio = processo ainda não cadastrado ("processo novo")
-- ---------------------------------------------------------------------
create table public.publicacoes (
  id                    uuid primary key default gen_random_uuid(),
  djen_id               bigint not null unique,     -- id da comunicação no DJEN
  advogado_id           uuid not null references public.advogados(id),  -- quem recebeu pela busca
  monitoramento_id      uuid references public.monitoramentos(id) on delete set null,
  processo_id           uuid references public.processos(id) on delete set null,
  numero_cnj            text not null,
  tribunal              text,
  orgao_julgador        text,
  tipo_comunicacao      text,              -- Intimação, Citação, Edital...
  tipo_documento        text,              -- Sentença, Despacho, Decisão...
  data_disponibilizacao date not null,
  data_publicacao       date,               -- 1º dia útil seguinte à disponibilização
  texto                 text,
  link                  text,
  status                text not null default 'nova'
                        check (status in ('nova','lida','prazo_criado','sem_prazo','descartada')),
  lida_em               timestamptz,
  criado_em             timestamptz not null default now()
);
create index on public.publicacoes (processo_id);
create index on public.publicacoes (advogado_id, status);
create index on public.publicacoes (numero_cnj);

-- ---------------------------------------------------------------------
-- 6. MOVIMENTAÇÕES (DataJud)
-- ---------------------------------------------------------------------
create table public.movimentacoes (
  id           uuid primary key default gen_random_uuid(),
  processo_id  uuid not null references public.processos(id) on delete cascade,
  codigo_tpu   int,
  nome         text not null,
  complemento  text,
  data_hora    timestamptz not null,
  orgao        text,
  criado_em    timestamptz not null default now(),
  unique (processo_id, codigo_tpu, data_hora, nome)
);
create index on public.movimentacoes (processo_id, data_hora desc);

-- ---------------------------------------------------------------------
-- 7. SUSPENSÕES DE PRAZO (Brasil inteiro; valem para os dois advogados)
--    abrangencia: nacional (todos os tribunais), tribunal, comarca ou orgao (vara)
-- ---------------------------------------------------------------------
create table public.suspensoes (
  id           uuid primary key default gen_random_uuid(),
  abrangencia  text not null default 'tribunal'
               check (abrangencia in ('nacional','tribunal','comarca','orgao')),
  tribunal     text,                    -- sigla: TJBA, TJSP, TRT5... (vazio se nacional)
  comarca      text,                    -- quando abrangencia = comarca/orgao
  orgao        text,                    -- vara/órgão, quando abrangencia = orgao
  data_inicio  date not null,
  data_fim     date not null,
  hora_inicio  time,                    -- suspensão parcial: a partir de (ex.: 11:00)
  tipo         text not null default 'ato'
               check (tipo in ('feriado','recesso','ponto_facultativo','indisponibilidade','ato')),
  motivo       text not null,
  numero_ato   text,                    -- ex.: Decreto Judiciário nº 1.511/2026
  link_ato     text,
  fonte        text not null default 'manual' check (fonte in ('manual','sugestao','regra')),
  criado_por   uuid default auth.uid() references public.advogados(id),
  criado_em    timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (data_fim >= data_inicio),
  check (abrangencia = 'nacional' or tribunal is not null),
  check (abrangencia not in ('comarca','orgao') or comarca is not null),
  check (abrangencia <> 'orgao' or orgao is not null)
);
create index on public.suspensoes (data_inicio, data_fim);
create index on public.suspensoes (tribunal);
create unique index suspensoes_regra_unica on public.suspensoes (data_inicio, motivo) where fonte = 'regra';

-- Fontes de atos (decretos/portarias) por tribunal, lidas pela varredura diária.
-- Um registro é criado sozinho quando entra o 1º processo de um tribunal novo.
create table public.fontes_atos (
  tribunal        text primary key,
  url             text,                 -- página/diário administrativo onde saem os decretos
  ativo           boolean not null default true,
  ultima_leitura  timestamptz,
  ultimo_sucesso  timestamptz,
  ultimo_erro     text,
  criado_em       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 8. PRAZOS
--    data_recebimento = dia em que a intimação chegou (publicação/ciência).
--    Base do indicador "tempo entre recebimento e cumprimento".
-- ---------------------------------------------------------------------
create table public.prazos (
  id                uuid primary key default gen_random_uuid(),
  processo_id       uuid not null references public.processos(id) on delete cascade,
  publicacao_id     uuid references public.publicacoes(id) on delete set null,
  tipo              text not null,      -- Contestação, Réplica, Apelação, Manifestação...
  data_recebimento  date not null,
  dias              int check (dias > 0),
  contagem          text not null default 'uteis' check (contagem in ('uteis','corridos')),
  data_elaboracao   date,               -- quando pretende fazer
  prazo_fatal       date not null,
  responsavel_id    uuid default auth.uid() references public.advogados(id),
  status            text not null default 'aberto' check (status in ('aberto','cumprido','cancelado')),
  data_cumprimento  date,
  observacoes       text,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  check (status <> 'cumprido' or data_cumprimento is not null)
);
create index on public.prazos (processo_id);
create index on public.prazos (status, prazo_fatal);

-- ---------------------------------------------------------------------
-- 9. DECISÕES (base da taxa de êxito e da média de condenação)
--    Uma linha por sentença, acórdão ou decisão de recurso.
--    O polo (autor/réu) vem do processo.
-- ---------------------------------------------------------------------
create table public.decisoes (
  id                uuid primary key default gen_random_uuid(),
  processo_id       uuid not null references public.processos(id) on delete cascade,
  tipo              text not null check (tipo in ('sentenca','acordao','decisao_monocratica')),
  recurso           text,               -- Apelação, Recurso Inominado, RO, Agravo, REsp...
  instancia         text not null default '1_grau'
                    check (instancia in ('1_grau','2_grau','turma_recursal','superior')),
  data_decisao      date not null,
  resultado         text not null check (resultado in
                    ('procedente','parcialmente_procedente','improcedente',
                     'acordo','extinto_sem_merito')),
  valor_condenacao  numeric(14,2),      -- valor fixado (dano moral + material etc.)
  publicacao_id     uuid references public.publicacoes(id) on delete set null,
  observacoes       text,
  criado_por        uuid default auth.uid() references public.advogados(id),
  criado_em         timestamptz not null default now()
);
create index on public.decisoes (processo_id);

-- =====================================================================
-- FUNÇÕES DE APOIO
-- =====================================================================

-- O advogado logado enxerga este processo?
create or replace function public.pode_ver_processo(p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from processo_advogados
                 where processo_id = p and advogado_id = auth.uid());
$$;

create or replace function public.pode_ver_cliente(c uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from cliente_advogados
                 where cliente_id = c and advogado_id = auth.uid());
$$;

-- Quem cadastra o cliente/processo vira automaticamente advogado dele
create or replace function public.tg_vincula_criador_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into cliente_advogados (cliente_id, advogado_id)
  values (new.id, new.criado_por) on conflict do nothing;
  return new;
end $$;
create trigger vincula_criador after insert on public.clientes
  for each row execute function public.tg_vincula_criador_cliente();

create or replace function public.tg_vincula_criador_processo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into processo_advogados (processo_id, advogado_id)
  values (new.id, new.criado_por) on conflict do nothing;
  return new;
end $$;
create trigger vincula_criador after insert on public.processos
  for each row execute function public.tg_vincula_criador_processo();

-- Ao incluir um colega no processo, ele passa a ver também o cliente
create or replace function public.tg_compartilha_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into cliente_advogados (cliente_id, advogado_id)
  select cliente_id, new.advogado_id from processos where id = new.processo_id
  on conflict do nothing;
  return new;
end $$;
create trigger compartilha_cliente after insert on public.processo_advogados
  for each row execute function public.tg_compartilha_cliente();

-- Ao cadastrar um processo, liga a ele as publicações já recebidas com o mesmo número
create or replace function public.tg_liga_publicacoes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update publicacoes set processo_id = new.id
   where numero_cnj = new.numero_cnj and processo_id is null;
  return new;
end $$;
create trigger liga_publicacoes after insert on public.processos
  for each row execute function public.tg_liga_publicacoes();

-- atualizado_em automático
create or replace function public.tg_atualizado_em()
returns trigger language plpgsql as $$
begin new.atualizado_em := now(); return new; end $$;
create trigger atualizado_em before update on public.clientes  for each row execute function public.tg_atualizado_em();
create trigger atualizado_em before update on public.processos for each row execute function public.tg_atualizado_em();
create trigger atualizado_em before update on public.prazos    for each row execute function public.tg_atualizado_em();

-- =====================================================================
-- SEGURANÇA (RLS): o banco recusa o que o advogado não pode ver
-- =====================================================================
alter table public.advogados          enable row level security;
alter table public.clientes           enable row level security;
alter table public.cliente_advogados  enable row level security;
alter table public.processos          enable row level security;
alter table public.processo_advogados enable row level security;
alter table public.monitoramentos     enable row level security;
alter table public.publicacoes        enable row level security;
alter table public.movimentacoes      enable row level security;
alter table public.suspensoes         enable row level security;
alter table public.prazos             enable row level security;
alter table public.decisoes           enable row level security;

-- Advogados: todos se veem (para poder incluir o colega), cada um edita o próprio perfil
create policy adv_ler    on public.advogados for select to authenticated using (true);
create policy adv_criar  on public.advogados for insert to authenticated with check (id = auth.uid());
create policy adv_editar on public.advogados for update to authenticated using (id = auth.uid());

-- Clientes
create policy cli_ler     on public.clientes for select to authenticated
  using (public.pode_ver_cliente(id) or criado_por = auth.uid());
create policy cli_criar   on public.clientes for insert to authenticated
  with check (criado_por = auth.uid());
create policy cli_editar  on public.clientes for update to authenticated
  using (public.pode_ver_cliente(id));
create policy cli_excluir on public.clientes for delete to authenticated
  using (criado_por = auth.uid());

create policy cliadv_ler   on public.cliente_advogados for select to authenticated
  using (public.pode_ver_cliente(cliente_id));
create policy cliadv_criar on public.cliente_advogados for insert to authenticated
  with check (public.pode_ver_cliente(cliente_id));
create policy cliadv_tirar on public.cliente_advogados for delete to authenticated
  using (public.pode_ver_cliente(cliente_id));

-- Processos
create policy proc_ler     on public.processos for select to authenticated
  using (public.pode_ver_processo(id) or criado_por = auth.uid());
create policy proc_criar   on public.processos for insert to authenticated
  with check (criado_por = auth.uid() and public.pode_ver_cliente(cliente_id));
create policy proc_editar  on public.processos for update to authenticated
  using (public.pode_ver_processo(id));
create policy proc_excluir on public.processos for delete to authenticated
  using (public.pode_ver_processo(id));

-- Incluir/retirar colega: só quem já é advogado do processo
create policy procadv_ler   on public.processo_advogados for select to authenticated
  using (public.pode_ver_processo(processo_id));
create policy procadv_criar on public.processo_advogados for insert to authenticated
  with check (public.pode_ver_processo(processo_id));
create policy procadv_tirar on public.processo_advogados for delete to authenticated
  using (public.pode_ver_processo(processo_id));

-- Monitoramentos: cada um só os seus
create policy mon_tudo on public.monitoramentos for all to authenticated
  using (advogado_id = auth.uid()) with check (advogado_id = auth.uid());

-- Publicações: as do seu processo, ou as que a sua busca trouxe e ainda não têm processo
create policy pub_ler on public.publicacoes for select to authenticated
  using ((processo_id is not null and public.pode_ver_processo(processo_id))
      or (processo_id is null and advogado_id = auth.uid()));
create policy pub_editar on public.publicacoes for update to authenticated
  using ((processo_id is not null and public.pode_ver_processo(processo_id))
      or (processo_id is null and advogado_id = auth.uid()));
-- (inserção de publicações é feita só pela rotina automática, com a chave de serviço)

-- Movimentações, prazos e decisões seguem o processo
create policy mov_ler on public.movimentacoes for select to authenticated
  using (public.pode_ver_processo(processo_id));

create policy prz_tudo on public.prazos for all to authenticated
  using (public.pode_ver_processo(processo_id))
  with check (public.pode_ver_processo(processo_id));

create policy dec_tudo on public.decisoes for all to authenticated
  using (public.pode_ver_processo(processo_id))
  with check (public.pode_ver_processo(processo_id));

-- Suspensões: compartilhadas entre os dois
create policy sus_ler   on public.suspensoes for select to authenticated using (true);
create policy sus_criar on public.suspensoes for insert to authenticated with check (criado_por = auth.uid() and fonte <> 'regra');
create policy sus_editar on public.suspensoes for update to authenticated using (fonte <> 'regra');
create policy sus_excluir on public.suspensoes for delete to authenticated using (fonte <> 'regra');

alter table public.fontes_atos enable row level security;
create policy fon_ler    on public.fontes_atos for select to authenticated using (true);
create policy fon_editar on public.fontes_atos for update to authenticated using (true);
create policy fon_criar  on public.fontes_atos for insert to authenticated with check (true);

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;

-- =====================================================================
-- INDICADORES (views que respeitam o sigilo de quem consulta)
-- =====================================================================

-- Prazos com situação calculada e tempo até o cumprimento
create view public.vw_prazos with (security_invoker = on) as
select pz.*,
       p.numero_cnj, p.tribunal, p.comarca, p.orgao_julgador, p.polo, p.tipo_acao, p.cliente_id, c.nome as cliente,
       case
         when pz.status = 'cumprido' then 'cumprido'
         when pz.status = 'cancelado' then 'cancelado'
         when pz.prazo_fatal < (now() at time zone 'America/Sao_Paulo')::date then 'vencido'
         when pz.prazo_fatal = (now() at time zone 'America/Sao_Paulo')::date then 'vence_hoje'
         when pz.prazo_fatal <= (now() at time zone 'America/Sao_Paulo')::date + 3 then 'proximo'
         else 'aberto'
       end as situacao,
       case when pz.status = 'cumprido'
            then pz.data_cumprimento - pz.data_recebimento end as dias_ate_cumprir,
       case when pz.status = 'cumprido'
            then pz.prazo_fatal - pz.data_cumprimento end as folga_dias
from public.prazos pz
join public.processos p on p.id = pz.processo_id
join public.clientes  c on c.id = p.cliente_id;

-- Decisões com o polo do processo: base da taxa de êxito
create view public.vw_decisoes with (security_invoker = on) as
select d.*, p.numero_cnj, p.polo, p.tribunal, p.tipo_acao, p.cliente_id, c.nome as cliente,
       case
         when d.resultado = 'acordo' or d.resultado = 'extinto_sem_merito' then 'neutro'
         when p.polo = 'reu'   and d.resultado = 'improcedente' then 'exito'
         when p.polo = 'autor' and d.resultado = 'procedente'   then 'exito'
         when d.resultado = 'parcialmente_procedente'           then 'parcial'
         else 'derrota'
       end as desfecho_para_cliente
from public.decisoes d
join public.processos p on p.id = d.processo_id
join public.clientes  c on c.id = p.cliente_id;

-- Resumo de resultados por polo e tipo de decisão (quadro do dashboard)
create view public.vw_resultados_por_polo with (security_invoker = on) as
select polo, tipo, resultado, count(*) as quantidade
from public.vw_decisoes
group by polo, tipo, resultado;

-- Condenação média por tribunal (só decisões com valor fixado)
create view public.vw_condenacao_por_tribunal with (security_invoker = on) as
select tribunal,
       count(*)                          as decisoes_com_valor,
       round(avg(valor_condenacao), 2)   as media_condenacao,
       sum(valor_condenacao)             as total_condenacao,
       min(valor_condenacao)             as menor,
       max(valor_condenacao)             as maior
from public.vw_decisoes
where valor_condenacao is not null and valor_condenacao > 0
group by tribunal;

grant select on public.vw_prazos, public.vw_decisoes,
                public.vw_resultados_por_polo, public.vw_condenacao_por_tribunal
  to authenticated;

-- =====================================================================
-- FASE 1.1 · SUGESTÕES, ANOTAÇÕES E LINHA DO TEMPO
-- A rotina automática só SUGERE. Nada vira prazo ou resultado sem
-- confirmação de um advogado do processo.
-- =====================================================================

-- Movimentação nova ainda não vista
alter table public.movimentacoes add column vista_em timestamptz;
create policy mov_marcar_vista on public.movimentacoes for update to authenticated
  using (public.pode_ver_processo(processo_id));

-- Sugestões geradas pela rotina (DJEN + DataJud + leitura do texto por IA)
create table public.sugestoes (
  id               uuid primary key default gen_random_uuid(),
  tipo             text not null check (tipo in ('prazo','resultado','cumprimento','processo_novo','suspensao')),
  processo_id      uuid references public.processos(id) on delete cascade,
  publicacao_id    uuid references public.publicacoes(id) on delete cascade,
  movimentacao_id  uuid references public.movimentacoes(id) on delete cascade,
  advogado_id      uuid references public.advogados(id),   -- p/ sugestões sem processo
  dados            jsonb not null,   -- ex.: {"resultado":"improcedente","valor_condenacao":null,
                                     --       "trecho":"Ante o exposto, JULGO IMPROCEDENTE..."}
  justificativa    text,             -- por que a rotina sugeriu isso
  status           text not null default 'pendente'
                   check (status in ('pendente','aceita','ajustada','rejeitada')),
  decidido_por     uuid references public.advogados(id),
  decidido_em      timestamptz,
  criado_em        timestamptz not null default now(),
  check (processo_id is not null or advogado_id is not null or tipo = 'suspensao')
);
create index on public.sugestoes (status, processo_id);
alter table public.sugestoes enable row level security;
create policy sug_ler on public.sugestoes for select to authenticated
  using (tipo = 'suspensao'
      or (processo_id is not null and public.pode_ver_processo(processo_id))
      or (processo_id is null and advogado_id = auth.uid()));
create policy sug_decidir on public.sugestoes for update to authenticated
  using (tipo = 'suspensao'
      or (processo_id is not null and public.pode_ver_processo(processo_id))
      or (processo_id is null and advogado_id = auth.uid()))
  with check (decidido_por = auth.uid());

-- Decisão confirmada guarda quem confirmou e de qual sugestão veio
alter table public.decisoes
  add column sugestao_id   uuid references public.sugestoes(id) on delete set null,
  add column confirmado_por uuid default auth.uid() references public.advogados(id),
  add column trecho_dispositivo text;
alter table public.prazos
  add column sugestao_id   uuid references public.sugestoes(id) on delete set null;

-- Complementos do advogado a uma movimentação ou publicação
create table public.anotacoes (
  id               uuid primary key default gen_random_uuid(),
  processo_id      uuid not null references public.processos(id) on delete cascade,
  movimentacao_id  uuid references public.movimentacoes(id) on delete cascade,
  publicacao_id    uuid references public.publicacoes(id) on delete cascade,
  tipo             text not null default 'explicacao'
                   check (tipo in ('dispositivo','explicacao','observacao')),
  texto            text not null,
  autor_id         uuid not null default auth.uid() references public.advogados(id),
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  check (movimentacao_id is not null or publicacao_id is not null)
);
create index on public.anotacoes (processo_id);
create trigger atualizado_em before update on public.anotacoes
  for each row execute function public.tg_atualizado_em();
alter table public.anotacoes enable row level security;
create policy anot_ler on public.anotacoes for select to authenticated
  using (public.pode_ver_processo(processo_id));
create policy anot_criar on public.anotacoes for insert to authenticated
  with check (public.pode_ver_processo(processo_id) and autor_id = auth.uid());
create policy anot_editar on public.anotacoes for update to authenticated
  using (autor_id = auth.uid() and public.pode_ver_processo(processo_id));
create policy anot_excluir on public.anotacoes for delete to authenticated
  using (autor_id = auth.uid());

-- Registro de cada rodada da rotina (para ver se está rodando e se houve limite)
create table public.sincronizacoes (
  id             uuid primary key default gen_random_uuid(),
  fonte          text not null check (fonte in ('djen','datajud')),
  iniciada_em    timestamptz not null default now(),
  finalizada_em  timestamptz,
  status         text not null default 'rodando'
                 check (status in ('rodando','ok','parcial','erro')),
  requisicoes    int not null default 0,
  novidades      int not null default 0,
  cursor         jsonb,             -- onde parou, para retomar na rodada seguinte
  mensagem       text
);
alter table public.sincronizacoes enable row level security;
create policy sinc_ler on public.sincronizacoes for select to authenticated using (true);

grant select, insert, update, delete on public.sugestoes, public.anotacoes to authenticated;
grant select on public.sincronizacoes to authenticated;
grant all on public.sugestoes, public.anotacoes, public.sincronizacoes to service_role;

-- Linha do tempo do processo (botão "Ver movimentações"):
-- junta andamentos do DataJud e publicações do DJEN, com as anotações
create view public.vw_linha_do_tempo with (security_invoker = on) as
select m.processo_id, 'movimentacao'::text as origem, m.id as item_id,
       m.data_hora as quando, m.nome as titulo, m.complemento as detalhe,
       (m.vista_em is null) as nova,
       coalesce((select jsonb_agg(jsonb_build_object('tipo',a.tipo,'texto',a.texto,
                 'autor',a.autor_id,'em',a.criado_em) order by a.criado_em)
                 from public.anotacoes a where a.movimentacao_id = m.id), '[]') as anotacoes
from public.movimentacoes m
union all
select p.processo_id, 'publicacao', p.id,
       p.data_disponibilizacao::timestamptz,
       coalesce(p.tipo_documento, p.tipo_comunicacao, 'Publicação'), left(p.texto, 500),
       (p.status = 'nova'),
       coalesce((select jsonb_agg(jsonb_build_object('tipo',a.tipo,'texto',a.texto,
                 'autor',a.autor_id,'em',a.criado_em) order by a.criado_em)
                 from public.anotacoes a where a.publicacao_id = p.id), '[]')
from public.publicacoes p
where p.processo_id is not null;
grant select on public.vw_linha_do_tempo to authenticated;

-- =====================================================================
-- FASE 1.2 · CADASTRO (telas de clientes e processos) E CONFIGURAÇÕES
-- =====================================================================

-- Configurações do sistema (ajustáveis na tela, sem mexer no código)
create table public.configuracoes (
  chave          text primary key,
  valor          jsonb not null,
  descricao      text,
  atualizado_por uuid references public.advogados(id),
  atualizado_em  timestamptz not null default now()
);
alter table public.configuracoes enable row level security;
create policy cfg_ler    on public.configuracoes for select to authenticated using (true);
create policy cfg_editar on public.configuracoes for update to authenticated
  using (true) with check (atualizado_por = auth.uid());
grant select, update on public.configuracoes to authenticated;
grant all on public.configuracoes to service_role;

insert into public.configuracoes (chave, valor, descricao) values
 ('folga_limite',        '1',   'Quantas requisições abaixo do limite informado pela API a rotina para'),
 ('datajud_teto_minuto', '119', 'Máximo de requisições por minuto ao DataJud'),
 ('datajud_horario',     '"03:00"', 'Horário da consulta diária ao DataJud'),
 ('datajud_arquivados_dia_semana', '0', 'Dia da semana (0 = domingo) para consultar processos arquivados'),
 ('djen_horarios',       '["07:00","08:00","09:00","10:00","11:00","12:00","13:00","14:00","15:00","16:00","17:00","18:00","19:00","20:00"]',
                         'Horários das buscas no DJEN, em dias úteis'),
 ('djen_repescagem',     '{"dia_semana":6,"horario":"08:00","dias":7}', 'Revarredura semanal do DJEN'),
 ('atualizar_agora_intervalo_min', '10', 'Intervalo mínimo entre cliques em "Atualizar agora"');

-- Lista de processos já com o nome do cliente e os advogados (o que a tela usa)
create view public.vw_processos with (security_invoker = on) as
select p.*,
       c.nome as cliente_nome, c.tipo as cliente_tipo,
       coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nome',a.nome) order by a.nome)
                   from public.processo_advogados pa join public.advogados a on a.id = pa.advogado_id
                  where pa.processo_id = p.id), '[]') as advogados,
       (select count(*) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as prazos_abertos,
       (select min(z.prazo_fatal) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as proximo_prazo,
       (select count(*) from public.publicacoes u where u.processo_id = p.id and u.status = 'nova')
         + (select count(*) from public.movimentacoes m where m.processo_id = p.id and m.vista_em is null) as novidades
from public.processos p
join public.clientes c on c.id = p.cliente_id;

create view public.vw_clientes with (security_invoker = on) as
select c.*,
       (select count(*) from public.processos p where p.cliente_id = c.id) as qtd_processos,
       (select count(*) from public.processos p where p.cliente_id = c.id and p.situacao = 'ativo') as qtd_ativos,
       exists (select 1 from public.monitoramentos m
                where m.cliente_id = c.id and m.advogado_id = auth.uid() and m.ativo) as monitorado
from public.clientes c;

grant select on public.vw_processos, public.vw_clientes to authenticated;


-- =====================================================================
-- FASE 1.3 · SUSPENSÕES: REGRAS NACIONAIS, CONFIRMAÇÃO DE SUGESTÕES, FONTES
-- =====================================================================
create trigger atualizado_em before update on public.suspensoes
  for each row execute function public.tg_atualizado_em();
grant select, insert, update on public.fontes_atos to authenticated;
grant all on public.fontes_atos to service_role;

-- Domingo de Páscoa (algoritmo de Meeus/Jones/Butcher)
create or replace function public.pascoa(ano int) returns date language plpgsql immutable as $$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int; mes int; dia int;
begin
  a := ano % 19; b := ano / 100; c := ano % 100; d := b / 4; e := b % 4; f := (b + 8) / 25;
  g := (b - f + 1) / 3; h := (19*a + b - d - g + 15) % 30; i := c / 4; k := c % 4;
  l := (32 + 2*e + 2*i - h - k) % 7; m := (a + 11*h + 22*l) / 451;
  mes := (h + l - 7*m + 114) / 31; dia := ((h + l - 7*m + 114) % 31) + 1;
  return make_date(ano, mes, dia);
end $$;

-- Feriados nacionais e recesso do art. 220 do CPC para um ano.
-- Carnaval, Corpus Christi e feriados locais vêm do calendário de cada tribunal.
create or replace function public.gerar_regras_nacionais(ano int) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into suspensoes (abrangencia, data_inicio, data_fim, tipo, motivo, numero_ato, fonte, criado_por)
  select 'nacional', d, d, 'feriado', m, lei, 'regra', null from (values
    (make_date(ano,1,1),  'Confraternização Universal', 'Lei 662/1949'),
    (pascoa(ano) - 2,     'Sexta-feira Santa',          'Lei 9.093/1995'),
    (make_date(ano,4,21), 'Tiradentes',                 'Lei 662/1949'),
    (make_date(ano,5,1),  'Dia do Trabalho',            'Lei 662/1949'),
    (make_date(ano,9,7),  'Independência do Brasil',    'Lei 662/1949'),
    (make_date(ano,10,12),'Nossa Senhora Aparecida',    'Lei 6.802/1980'),
    (make_date(ano,11,2), 'Finados',                    'Lei 662/1949'),
    (make_date(ano,11,15),'Proclamação da República',   'Lei 662/1949'),
    (make_date(ano,11,20),'Dia Nacional de Zumbi e da Consciência Negra', 'Lei 14.759/2023'),
    (make_date(ano,12,25),'Natal',                      'Lei 662/1949')
  ) v(d, m, lei)
  on conflict (data_inicio, motivo) where fonte = 'regra' do nothing;
  get diagnostics n = row_count;
  insert into suspensoes (abrangencia, data_inicio, data_fim, tipo, motivo, numero_ato, fonte, criado_por)
  values ('nacional', make_date(ano,12,20), make_date(ano+1,1,20), 'recesso',
          'Suspensão de prazos de fim de ano', 'CPC, art. 220', 'regra', null)
  on conflict (data_inicio, motivo) where fonte = 'regra' do nothing;
  return n;
end $$;
select public.gerar_regras_nacionais(extract(year from now())::int);
select public.gerar_regras_nacionais(extract(year from now())::int + 1);

-- Confirmar uma sugestão de suspensão (com ajustes opcionais do advogado)
create or replace function public.confirmar_sugestao_suspensao(p_sugestao uuid, p_dados jsonb default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s sugestoes; d jsonb; novo uuid;
begin
  if auth.uid() is null then raise exception 'Faça login.'; end if;
  select * into s from sugestoes where id = p_sugestao and tipo = 'suspensao' and status = 'pendente' for update;
  if not found then raise exception 'Sugestão não encontrada ou já decidida.'; end if;
  d := s.dados || coalesce(p_dados, '{}'::jsonb);
  insert into suspensoes (abrangencia, tribunal, comarca, orgao, data_inicio, data_fim, hora_inicio,
                          tipo, motivo, numero_ato, link_ato, fonte, criado_por)
  values (coalesce(d->>'abrangencia','tribunal'), d->>'tribunal', d->>'comarca', d->>'orgao',
          (d->>'data_inicio')::date, coalesce(d->>'data_fim', d->>'data_inicio')::date,
          nullif(d->>'hora_inicio','')::time, coalesce(d->>'tipo','ato'), d->>'motivo',
          d->>'numero_ato', d->>'link_ato', 'sugestao', auth.uid())
  returning id into novo;
  update sugestoes set status = case when p_dados is null or p_dados = '{}'::jsonb then 'aceita' else 'ajustada' end,
         decidido_por = auth.uid(), decidido_em = now(), dados = d
   where id = p_sugestao;
  return novo;
end $$;
grant execute on function public.confirmar_sugestao_suspensao(uuid, jsonb) to authenticated;

-- Tribunal novo no cadastro de processos → vira fonte a monitorar
create or replace function public.tg_fonte_do_tribunal()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into fontes_atos (tribunal) values (new.tribunal) on conflict do nothing;
  return new;
end $$;
create trigger fonte_do_tribunal after insert or update of tribunal on public.processos
  for each row execute function public.tg_fonte_do_tribunal();

-- Tribunais e comarcas onde há processos ativos (para filtrar o que interessa).
-- Não expõe processos: só a sigla do tribunal e o nome da comarca.
create or replace function public.tribunais_em_uso()
returns table (tribunal text, comarca text)
language sql stable security definer set search_path = public as $$
  select distinct tribunal, comarca from processos where situacao = 'ativo'
  order by tribunal, comarca;
$$;
grant execute on function public.tribunais_em_uso() to authenticated;

-- =====================================================================
-- FASE 1.4 · ADMINISTRAÇÃO DE USUÁRIOS
-- Criar, desativar e excluir logins é feito pela função "admin-usuarios"
-- (Edge Function), que usa a chave de serviço no servidor. Aqui ficam o
-- perfil de administrador e as proteções do banco.
-- =====================================================================
alter table public.advogados
  add column admin        boolean not null default false,
  add column ativo        boolean not null default true,
  add column trocar_senha boolean not null default false;

create or replace function public.sou_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from advogados where id = auth.uid() and admin and ativo);
$$;
grant execute on function public.sou_admin() to authenticated;

-- Ninguém se promove a admin nem se reativa pela tela: só um admin ou o servidor.
-- (sem security definer: current_user precisa ser o papel de quem chamou)
create or replace function public.tg_protege_advogado()
returns trigger language plpgsql set search_path = public as $$
declare servidor boolean := current_user in ('service_role','postgres','supabase_admin');
begin
  if servidor or public.sou_admin() then return new; end if;
  if tg_op = 'INSERT' then
    new.admin := false; new.ativo := true; new.trocar_senha := false;
  else
    if new.admin is distinct from old.admin or new.ativo is distinct from old.ativo then
      raise exception 'Apenas o administrador altera perfil de acesso.';
    end if;
    if new.trocar_senha and not old.trocar_senha then
      raise exception 'Apenas o administrador exige troca de senha.';
    end if;
  end if;
  return new;
end $$;
create trigger protege_advogado before insert or update on public.advogados
  for each row execute function public.tg_protege_advogado();
create policy adv_admin_editar on public.advogados for update to authenticated using (public.sou_admin());

-- Permite excluir um advogado sem apagar o histórico de quem criou/decidiu cada registro
do $$
declare r record;
begin
  for r in select * from (values
    ('clientes','criado_por'), ('processos','criado_por'), ('suspensoes','criado_por'),
    ('prazos','responsavel_id'), ('decisoes','criado_por'), ('decisoes','confirmado_por'),
    ('sugestoes','decidido_por'), ('sugestoes','advogado_id'), ('anotacoes','autor_id'),
    ('configuracoes','atualizado_por'), ('publicacoes','advogado_id')) t(tabela, coluna)
  loop
    execute format('alter table public.%I alter column %I drop not null', r.tabela, r.coluna);
    execute format('alter table public.%I drop constraint if exists %I', r.tabela, r.tabela||'_'||r.coluna||'_fkey');
    execute format('alter table public.%I add constraint %I foreign key (%I) references public.advogados(id) on delete set null',
                   r.tabela, r.tabela||'_'||r.coluna||'_fkey', r.coluna);
  end loop;
end $$;

-- O que impede excluir um advogado: processos ou clientes que só ele enxerga
create or replace function public.exclusivos_do_advogado(p uuid)
returns table (processos bigint, clientes bigint)
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from processo_advogados pa where pa.advogado_id = p
       and not exists (select 1 from processo_advogados o where o.processo_id = pa.processo_id and o.advogado_id <> p)),
    (select count(*) from cliente_advogados ca where ca.advogado_id = p
       and not exists (select 1 from cliente_advogados o where o.cliente_id = ca.cliente_id and o.advogado_id <> p));
$$;
revoke all on function public.exclusivos_do_advogado(uuid) from public, authenticated;
grant execute on function public.exclusivos_do_advogado(uuid) to service_role;
