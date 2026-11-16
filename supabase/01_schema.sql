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

-- =====================================================================
-- FASE 2.1 · DATAJUD
-- A rotina "datajud-sync" (Edge Function) grava os andamentos.
-- O agendamento diário fica em 02_agendamentos.sql.
-- =====================================================================

-- Confere o segredo do agendamento guardado no Vault do Supabase.
-- Só a função no servidor (service_role) pode chamar.
create or replace function public.cron_segredo_confere(p text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare s text;
begin
  select decrypted_secret into s from vault.decrypted_secrets where name = 'orbeo_cron' limit 1;
  return s is not null and p is not null and s = p;
end $$;
revoke all on function public.cron_segredo_confere(text) from public, anon, authenticated;
grant execute on function public.cron_segredo_confere(text) to service_role;

-- Marcar andamentos como vistos ao abrir a linha do tempo
create or replace function public.marcar_movimentacoes_vistas(p_processo uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.pode_ver_processo(p_processo) then return 0; end if;
  update movimentacoes set vista_em = now() where processo_id = p_processo and vista_em is null;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.marcar_movimentacoes_vistas(uuid) to authenticated;

create index if not exists processos_sync_idx on public.processos (situacao, datajud_sync_em nulls first);

-- =====================================================================
-- FASE 2.2 · AUDIÊNCIAS
-- =====================================================================
create table public.audiencias (
  id             uuid primary key default gen_random_uuid(),
  processo_id    uuid not null references public.processos(id) on delete cascade,
  tipo           text not null default 'conciliacao' check (tipo in
                 ('conciliacao','instrucao','una','inicial','julgamento','sustentacao_oral','outra')),
  data_hora      timestamptz not null,
  modalidade     text not null default 'presencial' check (modalidade in ('presencial','virtual','hibrida')),
  local          text,               -- sala, fórum, endereço
  link           text,               -- videoconferência
  status         text not null default 'agendada'
                 check (status in ('agendada','realizada','redesignada','cancelada','nao_realizada')),
  resultado      text,               -- o que aconteceu (acordo, adiada, instrução encerrada...)
  observacoes    text,
  responsavel_id uuid default auth.uid() references public.advogados(id) on delete set null,
  sugestao_id    uuid references public.sugestoes(id) on delete set null,
  criado_por     uuid default auth.uid() references public.advogados(id) on delete set null,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
create index on public.audiencias (data_hora);
create index on public.audiencias (processo_id);
create trigger atualizado_em before update on public.audiencias
  for each row execute function public.tg_atualizado_em();

alter table public.audiencias enable row level security;
create policy aud_tudo on public.audiencias for all to authenticated
  using (public.pode_ver_processo(processo_id))
  with check (public.pode_ver_processo(processo_id));
grant select, insert, update, delete on public.audiencias to authenticated;
grant all on public.audiencias to service_role;

-- Sugestão de audiência (vinda do DataJud/DJEN), confirmada pelo advogado
alter table public.sugestoes drop constraint if exists sugestoes_tipo_check;
alter table public.sugestoes add constraint sugestoes_tipo_check
  check (tipo in ('prazo','resultado','cumprimento','processo_novo','suspensao','audiencia'));

create view public.vw_audiencias with (security_invoker = on) as
select a.*, p.numero_cnj, p.tribunal, p.comarca, p.orgao_julgador, p.polo, p.parte_contraria,
       p.cliente_id, c.nome as cliente,
       ((a.data_hora at time zone 'America/Sao_Paulo')::date) as dia,
       ((a.data_hora at time zone 'America/Sao_Paulo')::date - (now() at time zone 'America/Sao_Paulo')::date) as dias_ate
from public.audiencias a
join public.processos p on p.id = a.processo_id
join public.clientes  c on c.id = p.cliente_id;
grant select on public.vw_audiencias to authenticated;

-- Próxima audiência na lista de processos
create or replace view public.vw_processos with (security_invoker = on) as
select p.*,
       c.nome as cliente_nome, c.tipo as cliente_tipo,
       coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nome',a.nome) order by a.nome)
                   from public.processo_advogados pa join public.advogados a on a.id = pa.advogado_id
                  where pa.processo_id = p.id), '[]') as advogados,
       (select count(*) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as prazos_abertos,
       (select min(z.prazo_fatal) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as proximo_prazo,
       (select count(*) from public.publicacoes u where u.processo_id = p.id and u.status = 'nova')
         + (select count(*) from public.movimentacoes m where m.processo_id = p.id and m.vista_em is null) as novidades,
       (select min(au.data_hora) from public.audiencias au
         where au.processo_id = p.id and au.status = 'agendada' and au.data_hora >= now() - interval '6 hours') as proxima_audiencia
from public.processos p
join public.clientes c on c.id = p.cliente_id;

-- =====================================================================
-- FASE 2.3 · PRAZOS: CÁLCULO AUTOMÁTICO DO PRAZO FATAL
-- Regras: CPC art. 219 (dias úteis), art. 224 (exclui o dia do começo, começa e vence
-- em dia útil; expediente encerrado antes da hora prorroga o vencimento), art. 220
-- (recesso). Disponibilização no DJEN: publicação = 1º dia útil seguinte (Lei 11.419, art. 4º §3º).
-- Feriado e ponto facultativo: dia não útil. Recesso, suspensão por ato e indisponibilidade:
-- suspendem a contagem (também nos prazos em dias corridos).
-- =====================================================================
alter table public.prazos
  add column calculo_auto          boolean not null default true,
  add column origem_contagem       text not null default 'intimacao'
                                   check (origem_contagem in ('intimacao','disponibilizacao')),
  add column data_inicio_contagem  date,
  add column prazo_fatal_anterior  date,
  add column recalculado_em        timestamptz;

-- Suspensões que valem para um processo num dia: 'nao_util', 'suspenso', 'parcial' ou null
create or replace function public.situacao_do_dia(d date, trib text, com text, org text)
returns text language sql stable security definer set search_path = public as $$
  select case
    when bool_or(s.hora_inicio is null and s.tipo in ('recesso','ato','indisponibilidade')) then 'suspenso'
    when bool_or(s.hora_inicio is null) then 'nao_util'
    when bool_or(s.hora_inicio is not null) then 'parcial'
  end
  from suspensoes s
  where d between s.data_inicio and s.data_fim
    and (s.abrangencia = 'nacional'
      or (s.tribunal = trib and (
            s.abrangencia = 'tribunal'
         or (s.abrangencia = 'comarca' and lower(coalesce(com,'')) = lower(s.comarca))
         or (s.abrangencia = 'orgao' and lower(coalesce(com,'')) = lower(s.comarca)
             and coalesce(org,'') ilike '%' || s.orgao || '%'))));
$$;

create or replace function public.eh_dia_util(d date, trib text, com text, org text)
returns boolean language sql stable security definer set search_path = public as $$
  select extract(isodow from d) < 6 and coalesce(public.situacao_do_dia(d, trib, com, org), 'ok') in ('ok','parcial');
$$;

create or replace function public.proximo_dia_util(d date, trib text, com text, org text)
returns date language plpgsql stable security definer set search_path = public as $$
declare x date := d + 1;
begin
  while not public.eh_dia_util(x, trib, com, org) loop x := x + 1; end loop;
  return x;
end $$;

-- Devolve (início da contagem, prazo fatal)
create or replace function public.calcular_prazo(p_data date, p_origem text, p_dias int, p_contagem text,
                                                 trib text, com text, org text,
                                                 out inicio date, out fatal date)
language plpgsql stable security definer set search_path = public as $$
declare base date := p_data; n int := 1; d date; sit text; guarda int := 0;
begin
  if p_data is null or p_dias is null or p_dias < 1 then return; end if;
  if p_origem = 'disponibilizacao' then base := public.proximo_dia_util(base, trib, com, org); end if;
  inicio := public.proximo_dia_util(base, trib, com, org);
  d := inicio;
  while n < p_dias loop
    d := d + 1; guarda := guarda + 1;
    if guarda > 2000 then raise exception 'Prazo longo demais para calcular.'; end if;
    if p_contagem = 'uteis' then
      if public.eh_dia_util(d, trib, com, org) then n := n + 1; end if;
    else
      sit := public.situacao_do_dia(d, trib, com, org);
      if sit is distinct from 'suspenso' then n := n + 1; end if;
    end if;
  end loop;
  -- vence em dia útil; expediente encerrado mais cedo no vencimento prorroga (art. 224 §1º)
  while not public.eh_dia_util(d, trib, com, org) or public.situacao_do_dia(d, trib, com, org) = 'parcial' loop
    d := d + 1;
  end loop;
  fatal := d;
end $$;
grant execute on function public.calcular_prazo(date, text, int, text, text, text, text) to authenticated;

-- Ao gravar um prazo automático, o banco calcula o prazo fatal
create or replace function public.tg_prazo_calcula()
returns trigger language plpgsql security definer set search_path = public as $$
declare p processos; r record;
begin
  if new.calculo_auto and new.dias is not null and new.data_recebimento is not null then
    select * into p from processos where id = new.processo_id;
    select * into r from public.calcular_prazo(new.data_recebimento, new.origem_contagem, new.dias, new.contagem,
                                               p.tribunal, p.comarca, p.orgao_julgador);
    new.data_inicio_contagem := r.inicio;
    if tg_op = 'UPDATE' and old.prazo_fatal is distinct from r.fatal and old.status = 'aberto'
       and new.data_recebimento = old.data_recebimento and new.dias = old.dias and new.contagem = old.contagem
       and new.origem_contagem = old.origem_contagem then
      new.prazo_fatal_anterior := old.prazo_fatal; new.recalculado_em := now();
    end if;
    new.prazo_fatal := r.fatal;
  end if;
  if new.prazo_fatal is null then raise exception 'Informe o prazo fatal ou os dias do prazo.'; end if;
  return new;
end $$;
drop trigger if exists prazo_calcula on public.prazos;
create trigger prazo_calcula before insert or update on public.prazos
  for each row execute function public.tg_prazo_calcula();
alter table public.prazos alter column prazo_fatal drop not null;
alter table public.prazos add constraint prazos_fatal_ok check (prazo_fatal is not null);

-- Mudou uma suspensão → recalcula os prazos automáticos em aberto (de todos os advogados)
create or replace function public.tg_suspensao_recalcula()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update prazos set atualizado_em = now()     -- o gatilho do prazo refaz a conta
   where status = 'aberto' and calculo_auto and dias is not null;
  return null;
end $$;
drop trigger if exists suspensao_recalcula on public.suspensoes;
create trigger suspensao_recalcula after insert or update or delete on public.suspensoes
  for each statement execute function public.tg_suspensao_recalcula();

-- Mudou tribunal/comarca/vara do processo → recalcula os prazos dele
create or replace function public.tg_processo_recalcula()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update prazos set atualizado_em = now()
   where processo_id = new.id and status = 'aberto' and calculo_auto and dias is not null;
  return new;
end $$;
drop trigger if exists processo_recalcula on public.processos;
create trigger processo_recalcula after update of tribunal, comarca, orgao_julgador on public.processos
  for each row execute function public.tg_processo_recalcula();

-- vw_prazos com as colunas novas
drop view if exists public.vw_prazos;
create view public.vw_prazos with (security_invoker = on) as
select pz.*,
       p.numero_cnj, p.tribunal, p.comarca, p.orgao_julgador, p.polo, p.tipo_acao, p.cliente_id, p.parte_contraria, c.nome as cliente,
       case
         when pz.status = 'cumprido' then 'cumprido'
         when pz.status = 'cancelado' then 'cancelado'
         when pz.prazo_fatal < (now() at time zone 'America/Sao_Paulo')::date then 'vencido'
         when pz.prazo_fatal = (now() at time zone 'America/Sao_Paulo')::date then 'vence_hoje'
         when pz.prazo_fatal <= (now() at time zone 'America/Sao_Paulo')::date + 3 then 'proximo'
         else 'aberto'
       end as situacao,
       case when pz.status = 'cumprido' then pz.data_cumprimento - pz.data_recebimento end as dias_ate_cumprir,
       case when pz.status = 'cumprido' then pz.prazo_fatal - pz.data_cumprimento end as folga_dias,
       (select a.nome from public.advogados a where a.id = pz.responsavel_id) as responsavel_nome
from public.prazos pz
join public.processos p on p.id = pz.processo_id
join public.clientes  c on c.id = p.cliente_id;
grant select on public.vw_prazos to authenticated;

-- =====================================================================
-- FASE 2.4 · RITOS (JUIZADOS, TRABALHISTA) E PRAZOS ESPECIAIS
-- Juizados: dias úteis (Lei 9.099, art. 12-A), contados da intimação/ciência (FONAJE 13).
-- Contestação no Juizado e na Justiça do Trabalho: até a audiência → prazo ligado à audiência.
-- Preparo do recurso inominado: 48 horas da interposição (Lei 9.099, art. 42 §1º).
-- =====================================================================
alter table public.processos add column rito text
  check (rito in ('comum','juizado_civel','juizado_fazenda','juizado_federal','trabalhista'));

create or replace function public.inferir_rito(trib text, classe text, orgao text)
returns text language sql immutable as $$
  select case
    when trib ilike 'TRT%' or trib = 'TST' then 'trabalhista'
    when coalesce(classe,'') || ' ' || coalesce(orgao,'') ~* '(juizado|turma recursal|JEC|JECC|SJE)' then
      case when coalesce(classe,'') || ' ' || coalesce(orgao,'') ~* 'fazenda' then 'juizado_fazenda'
           when trib ilike 'TRF%' then 'juizado_federal'
           else 'juizado_civel' end
    else 'comum'
  end;
$$;

create or replace function public.tg_processo_rito()
returns trigger language plpgsql as $$
begin
  if new.rito is null or (tg_op = 'UPDATE' and new.rito = old.rito and old.rito = 'comum'
      and (new.classe is distinct from old.classe or new.orgao_julgador is distinct from old.orgao_julgador)) then
    new.rito := public.inferir_rito(new.tribunal, new.classe, new.orgao_julgador);
  end if;
  return new;
end $$;
create trigger processo_rito before insert or update on public.processos
  for each row execute function public.tg_processo_rito();
update public.processos set rito = public.inferir_rito(tribunal, classe, orgao_julgador) where rito is null;

-- Prazo ligado a uma audiência (contestação até a audiência) e contagem a partir do ato (horas)
alter table public.prazos add column audiencia_id uuid references public.audiencias(id) on delete set null;
alter table public.prazos drop constraint if exists prazos_origem_contagem_check;
alter table public.prazos add constraint prazos_origem_contagem_check
  check (origem_contagem in ('intimacao','disponibilizacao','ato'));

-- 'ato': prazo em horas/dias corridos a partir do próprio ato (ex.: preparo em 48h = 2 dias);
-- se terminar em dia não útil, prorroga para o próximo dia útil.
create or replace function public.calcular_prazo(p_data date, p_origem text, p_dias int, p_contagem text,
                                                 trib text, com text, org text,
                                                 out inicio date, out fatal date)
language plpgsql stable security definer set search_path = public as $$
declare base date := p_data; n int := 1; d date; sit text; guarda int := 0;
begin
  if p_data is null or p_dias is null or p_dias < 1 then return; end if;
  if p_origem = 'ato' then
    inicio := p_data; d := p_data + p_dias;
    while not public.eh_dia_util(d, trib, com, org) or public.situacao_do_dia(d, trib, com, org) = 'parcial' loop d := d + 1; end loop;
    fatal := d; return;
  end if;
  if p_origem = 'disponibilizacao' then base := public.proximo_dia_util(base, trib, com, org); end if;
  inicio := public.proximo_dia_util(base, trib, com, org);
  d := inicio;
  while n < p_dias loop
    d := d + 1; guarda := guarda + 1;
    if guarda > 2000 then raise exception 'Prazo longo demais para calcular.'; end if;
    if p_contagem = 'uteis' then
      if public.eh_dia_util(d, trib, com, org) then n := n + 1; end if;
    else
      sit := public.situacao_do_dia(d, trib, com, org);
      if sit is distinct from 'suspenso' then n := n + 1; end if;
    end if;
  end loop;
  while not public.eh_dia_util(d, trib, com, org) or public.situacao_do_dia(d, trib, com, org) = 'parcial' loop
    d := d + 1;
  end loop;
  fatal := d;
end $$;

-- Gatilho do prazo: se ligado a audiência, o fatal é o dia da audiência
create or replace function public.tg_prazo_calcula()
returns trigger language plpgsql security definer set search_path = public as $$
declare p processos; r record; dia_aud date;
begin
  if new.audiencia_id is not null then
    select (data_hora at time zone 'America/Sao_Paulo')::date into dia_aud from audiencias where id = new.audiencia_id;
    new.calculo_auto := false;
    if tg_op = 'UPDATE' and old.prazo_fatal is distinct from dia_aud and old.audiencia_id = new.audiencia_id and old.status = 'aberto' then
      new.prazo_fatal_anterior := old.prazo_fatal; new.recalculado_em := now();
    end if;
    new.prazo_fatal := dia_aud;
  elsif new.calculo_auto and new.dias is not null and new.data_recebimento is not null then
    select * into p from processos where id = new.processo_id;
    select * into r from public.calcular_prazo(new.data_recebimento, new.origem_contagem, new.dias, new.contagem,
                                               p.tribunal, p.comarca, p.orgao_julgador);
    new.data_inicio_contagem := r.inicio;
    if tg_op = 'UPDATE' and old.prazo_fatal is distinct from r.fatal and old.status = 'aberto'
       and new.data_recebimento = old.data_recebimento and new.dias = old.dias and new.contagem = old.contagem
       and new.origem_contagem = old.origem_contagem then
      new.prazo_fatal_anterior := old.prazo_fatal; new.recalculado_em := now();
    end if;
    new.prazo_fatal := r.fatal;
  end if;
  if new.prazo_fatal is null then raise exception 'Informe o prazo fatal ou os dias do prazo.'; end if;
  return new;
end $$;

-- Audiência redesignada → prazos ligados a ela acompanham a nova data
create or replace function public.tg_audiencia_atualiza_prazos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update prazos set atualizado_em = now() where audiencia_id = new.id and status = 'aberto';
  return new;
end $$;
create trigger audiencia_atualiza_prazos after update of data_hora on public.audiencias
  for each row execute function public.tg_audiencia_atualiza_prazos();

-- Recria as visões para incluir as colunas novas (rito, audiencia_id)
drop view if exists public.vw_processos;
create view public.vw_processos with (security_invoker = on) as
select p.*,
       c.nome as cliente_nome, c.tipo as cliente_tipo,
       coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nome',a.nome) order by a.nome)
                   from public.processo_advogados pa join public.advogados a on a.id = pa.advogado_id
                  where pa.processo_id = p.id), '[]') as advogados,
       (select count(*) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as prazos_abertos,
       (select min(z.prazo_fatal) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as proximo_prazo,
       (select count(*) from public.publicacoes u where u.processo_id = p.id and u.status = 'nova')
         + (select count(*) from public.movimentacoes m where m.processo_id = p.id and m.vista_em is null) as novidades,
       (select min(au.data_hora) from public.audiencias au
         where au.processo_id = p.id and au.status = 'agendada' and au.data_hora >= now() - interval '6 hours') as proxima_audiencia
from public.processos p
join public.clientes c on c.id = p.cliente_id;
grant select on public.vw_processos to authenticated;

drop view if exists public.vw_prazos;
create view public.vw_prazos with (security_invoker = on) as
select pz.*,
       p.numero_cnj, p.tribunal, p.comarca, p.orgao_julgador, p.polo, p.tipo_acao, p.rito, p.cliente_id, p.parte_contraria, c.nome as cliente,
       case
         when pz.status = 'cumprido' then 'cumprido'
         when pz.status = 'cancelado' then 'cancelado'
         when pz.prazo_fatal < (now() at time zone 'America/Sao_Paulo')::date then 'vencido'
         when pz.prazo_fatal = (now() at time zone 'America/Sao_Paulo')::date then 'vence_hoje'
         when pz.prazo_fatal <= (now() at time zone 'America/Sao_Paulo')::date + 3 then 'proximo'
         else 'aberto'
       end as situacao,
       case when pz.status = 'cumprido' then pz.data_cumprimento - pz.data_recebimento end as dias_ate_cumprir,
       case when pz.status = 'cumprido' then pz.prazo_fatal - pz.data_cumprimento end as folga_dias,
       (select a.nome from public.advogados a where a.id = pz.responsavel_id) as responsavel_nome,
       (select au.data_hora from public.audiencias au where au.id = pz.audiencia_id) as audiencia_data_hora
from public.prazos pz
join public.processos p on p.id = pz.processo_id
join public.clientes  c on c.id = p.cliente_id;
grant select on public.vw_prazos to authenticated;

-- =====================================================================
-- FASE 2.5 · ALINHAMENTO COM O MODELO DO SISTEMA ANTERIOR
--  • Carnaval (segunda e terça) e Corpus Christi entram como dias sem prazo, automaticamente
--  • Instância: 1º grau / Juizados  x  2º grau / Turmas Recursais (como no calendário do TJBA)
--  • Data de elaboração não pode ser posterior ao prazo fatal
-- =====================================================================
alter table public.processos add column instancia text not null default '1g' check (instancia in ('1g','2g'));
alter table public.suspensoes add column instancia text not null default 'todas' check (instancia in ('todas','1g','2g'));

-- Feriados nacionais + Carnaval + Corpus Christi + recesso
create or replace function public.gerar_regras_nacionais(ano int) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into suspensoes (abrangencia, data_inicio, data_fim, tipo, motivo, numero_ato, fonte, criado_por)
  select 'nacional', d, d, t, m, lei, 'regra', null from (values
    (make_date(ano,1,1),  'feriado', 'Confraternização Universal', 'Lei 662/1949'),
    (pascoa(ano) - 48,    'ponto_facultativo', 'Carnaval (segunda-feira)', 'Calendário forense'),
    (pascoa(ano) - 47,    'ponto_facultativo', 'Carnaval (terça-feira)', 'Calendário forense'),
    (pascoa(ano) - 2,     'feriado', 'Sexta-feira Santa',          'Lei 9.093/1995'),
    (make_date(ano,4,21), 'feriado', 'Tiradentes',                 'Lei 662/1949'),
    (make_date(ano,5,1),  'feriado', 'Dia do Trabalho',            'Lei 662/1949'),
    (pascoa(ano) + 60,    'ponto_facultativo', 'Corpus Christi', 'Calendário forense'),
    (make_date(ano,9,7),  'feriado', 'Independência do Brasil',    'Lei 662/1949'),
    (make_date(ano,10,12),'feriado', 'Nossa Senhora Aparecida',    'Lei 6.802/1980'),
    (make_date(ano,11,2), 'feriado', 'Finados',                    'Lei 662/1949'),
    (make_date(ano,11,15),'feriado', 'Proclamação da República',   'Lei 662/1949'),
    (make_date(ano,11,20),'feriado', 'Dia Nacional de Zumbi e da Consciência Negra', 'Lei 14.759/2023'),
    (make_date(ano,12,25),'feriado', 'Natal',                      'Lei 662/1949')
  ) v(d, t, m, lei)
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

-- Funções de dia útil passam a considerar a instância (troca de assinatura)
drop function if exists public.calcular_prazo(date, text, int, text, text, text, text);
drop function if exists public.proximo_dia_util(date, text, text, text);
drop function if exists public.eh_dia_util(date, text, text, text);
drop function if exists public.situacao_do_dia(date, text, text, text);

create function public.situacao_do_dia(d date, trib text, com text, org text, inst text default '1g')
returns text language sql stable security definer set search_path = public as $$
  select case
    when bool_or(s.hora_inicio is null and s.tipo in ('recesso','ato','indisponibilidade')) then 'suspenso'
    when bool_or(s.hora_inicio is null) then 'nao_util'
    when bool_or(s.hora_inicio is not null) then 'parcial'
  end
  from suspensoes s
  where d between s.data_inicio and s.data_fim
    and (s.instancia = 'todas' or s.instancia = coalesce(inst, '1g'))
    and (s.abrangencia = 'nacional'
      or (s.tribunal = trib and (
            s.abrangencia = 'tribunal'
         or (s.abrangencia = 'comarca' and lower(coalesce(com,'')) = lower(s.comarca))
         or (s.abrangencia = 'orgao' and lower(coalesce(com,'')) = lower(s.comarca)
             and coalesce(org,'') ilike '%' || s.orgao || '%'))));
$$;

create function public.eh_dia_util(d date, trib text, com text, org text, inst text default '1g')
returns boolean language sql stable security definer set search_path = public as $$
  select extract(isodow from d) < 6 and coalesce(public.situacao_do_dia(d, trib, com, org, inst), 'ok') in ('ok','parcial');
$$;

create function public.proximo_dia_util(d date, trib text, com text, org text, inst text default '1g')
returns date language plpgsql stable security definer set search_path = public as $$
declare x date := d + 1;
begin
  while not public.eh_dia_util(x, trib, com, org, inst) loop x := x + 1; end loop;
  return x;
end $$;

create function public.calcular_prazo(p_data date, p_origem text, p_dias int, p_contagem text,
                                      trib text, com text, org text, inst text default '1g',
                                      out inicio date, out fatal date)
language plpgsql stable security definer set search_path = public as $$
declare base date := p_data; n int := 1; d date; sit text; guarda int := 0;
begin
  if p_data is null or p_dias is null or p_dias < 1 then return; end if;
  if p_origem = 'ato' then
    inicio := p_data; d := p_data + p_dias;
    while not public.eh_dia_util(d, trib, com, org, inst) or public.situacao_do_dia(d, trib, com, org, inst) = 'parcial' loop d := d + 1; end loop;
    fatal := d; return;
  end if;
  if p_origem = 'disponibilizacao' then base := public.proximo_dia_util(base, trib, com, org, inst); end if;
  inicio := public.proximo_dia_util(base, trib, com, org, inst);
  d := inicio;
  while n < p_dias loop
    d := d + 1; guarda := guarda + 1;
    if guarda > 2000 then raise exception 'Prazo longo demais para calcular.'; end if;
    if p_contagem = 'uteis' then
      if public.eh_dia_util(d, trib, com, org, inst) then n := n + 1; end if;
    else
      sit := public.situacao_do_dia(d, trib, com, org, inst);
      if sit is distinct from 'suspenso' then n := n + 1; end if;
    end if;
  end loop;
  while not public.eh_dia_util(d, trib, com, org, inst) or public.situacao_do_dia(d, trib, com, org, inst) = 'parcial' loop
    d := d + 1;
  end loop;
  fatal := d;
end $$;
grant execute on function public.calcular_prazo(date, text, int, text, text, text, text, text) to authenticated;

create or replace function public.tg_prazo_calcula()
returns trigger language plpgsql security definer set search_path = public as $$
declare p processos; r record; dia_aud date;
begin
  if new.audiencia_id is not null then
    select (data_hora at time zone 'America/Sao_Paulo')::date into dia_aud from audiencias where id = new.audiencia_id;
    new.calculo_auto := false;
    if tg_op = 'UPDATE' and old.prazo_fatal is distinct from dia_aud and old.audiencia_id = new.audiencia_id and old.status = 'aberto' then
      new.prazo_fatal_anterior := old.prazo_fatal; new.recalculado_em := now();
    end if;
    new.prazo_fatal := dia_aud;
  elsif new.calculo_auto and new.dias is not null and new.data_recebimento is not null then
    select * into p from processos where id = new.processo_id;
    select * into r from public.calcular_prazo(new.data_recebimento, new.origem_contagem, new.dias, new.contagem,
                                               p.tribunal, p.comarca, p.orgao_julgador, p.instancia);
    new.data_inicio_contagem := r.inicio;
    if tg_op = 'UPDATE' and old.prazo_fatal is distinct from r.fatal and old.status = 'aberto'
       and new.data_recebimento = old.data_recebimento and new.dias = old.dias and new.contagem = old.contagem
       and new.origem_contagem = old.origem_contagem then
      new.prazo_fatal_anterior := old.prazo_fatal; new.recalculado_em := now();
    end if;
    new.prazo_fatal := r.fatal;
  end if;
  if new.prazo_fatal is null then raise exception 'Informe o prazo fatal ou os dias do prazo.'; end if;
  -- elaboração após o fatal: bloqueia quando o próprio advogado informa a data
  if new.data_elaboracao is not null and new.data_elaboracao > new.prazo_fatal
     and (tg_op = 'INSERT' or new.data_elaboracao is distinct from old.data_elaboracao) then
    raise exception 'A data de elaboração não pode ser posterior ao prazo fatal (%).', to_char(new.prazo_fatal, 'DD/MM/YYYY');
  end if;
  return new;
end $$;

drop trigger if exists processo_recalcula on public.processos;
create trigger processo_recalcula after update of tribunal, comarca, orgao_julgador, instancia on public.processos
  for each row execute function public.tg_processo_recalcula();

-- vw_processos e vw_prazos de novo (colunas novas)
drop view if exists public.vw_processos;
create view public.vw_processos with (security_invoker = on) as
select p.*,
       c.nome as cliente_nome, c.tipo as cliente_tipo,
       coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nome',a.nome) order by a.nome)
                   from public.processo_advogados pa join public.advogados a on a.id = pa.advogado_id
                  where pa.processo_id = p.id), '[]') as advogados,
       (select count(*) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as prazos_abertos,
       (select min(z.prazo_fatal) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as proximo_prazo,
       (select count(*) from public.publicacoes u where u.processo_id = p.id and u.status = 'nova')
         + (select count(*) from public.movimentacoes m where m.processo_id = p.id and m.vista_em is null) as novidades,
       (select min(au.data_hora) from public.audiencias au
         where au.processo_id = p.id and au.status = 'agendada' and au.data_hora >= now() - interval '6 hours') as proxima_audiencia
from public.processos p
join public.clientes c on c.id = p.cliente_id;
grant select on public.vw_processos to authenticated;

drop view if exists public.vw_prazos;
create view public.vw_prazos with (security_invoker = on) as
select pz.*,
       p.numero_cnj, p.tribunal, p.comarca, p.orgao_julgador, p.instancia, p.polo, p.tipo_acao, p.rito, p.cliente_id, p.parte_contraria, c.nome as cliente,
       case
         when pz.status = 'cumprido' then 'cumprido'
         when pz.status = 'cancelado' then 'cancelado'
         when pz.prazo_fatal < (now() at time zone 'America/Sao_Paulo')::date then 'vencido'
         when pz.prazo_fatal = (now() at time zone 'America/Sao_Paulo')::date then 'vence_hoje'
         when pz.prazo_fatal <= (now() at time zone 'America/Sao_Paulo')::date + 3 then 'proximo'
         else 'aberto'
       end as situacao,
       case when pz.status = 'cumprido' then pz.data_cumprimento - pz.data_recebimento end as dias_ate_cumprir,
       case when pz.status = 'cumprido' then pz.prazo_fatal - pz.data_cumprimento end as folga_dias,
       (select a.nome from public.advogados a where a.id = pz.responsavel_id) as responsavel_nome,
       (select au.data_hora from public.audiencias au where au.id = pz.audiencia_id) as audiencia_data_hora
from public.prazos pz
join public.processos p on p.id = pz.processo_id
join public.clientes  c on c.id = p.cliente_id;
grant select on public.vw_prazos to authenticated;

-- Recalcula os prazos abertos com as regras novas (Carnaval, Corpus Christi, instância)
update public.prazos set atualizado_em = now() where status = 'aberto' and calculo_auto and dias is not null;

-- =====================================================================
-- FASE 2.6 · DJEN PELO NÚMERO DO PROCESSO
--  • Publicações buscadas pelo número de cada processo cadastrado (sem OAB fixa)
--  • Data em que o tribunal atualizou a base do DataJud (para enxergar atraso)
-- =====================================================================
alter table public.publicacoes alter column advogado_id drop not null;
alter table public.publicacoes
  add column if not exists numero_comunicacao text,
  add column if not exists meio text,
  add column if not exists classe text,
  add column if not exists destinatarios jsonb,
  add column if not exists advogados_intimados jsonb,
  add column if not exists hash text;
alter table public.processos
  add column if not exists djen_sync_em timestamptz,
  add column if not exists datajud_atualizado_em timestamptz;

insert into public.configuracoes (chave, valor, descricao) values
  ('djen_teto_minuto', '19', 'Consultas por minuto ao DJEN (limite do CNJ: 20; usamos um a menos).'),
  ('djen_dias_primeira_busca', '90', 'Na primeira consulta de um processo, quantos dias de publicações buscar.')
on conflict (chave) do nothing;

-- Linha do tempo: publicação mostra o tipo e o texto inteiro (a tela resume)
drop view if exists public.vw_linha_do_tempo;
create view public.vw_linha_do_tempo with (security_invoker = on) as
select m.processo_id, 'movimentacao'::text as origem, m.id as item_id, m.data_hora as quando,
       m.nome as titulo, m.complemento as detalhe, (m.vista_em is null) as nova,
       coalesce((select jsonb_agg(jsonb_build_object('tipo',a.tipo,'texto',a.texto,'autor',a.autor_id,'em',a.criado_em) order by a.criado_em)
                 from public.anotacoes a where a.movimentacao_id = m.id), '[]') as anotacoes,
       null::jsonb as extra
from public.movimentacoes m
union all
select p.processo_id, 'publicacao', p.id,
       (p.data_disponibilizacao::timestamp + time '12:00') at time zone 'America/Sao_Paulo',
       coalesce(p.tipo_documento, p.tipo_comunicacao, 'Publicação'), p.texto,
       (p.status = 'nova'),
       coalesce((select jsonb_agg(jsonb_build_object('tipo',a.tipo,'texto',a.texto,'autor',a.autor_id,'em',a.criado_em) order by a.criado_em)
                 from public.anotacoes a where a.publicacao_id = p.id), '[]'),
       jsonb_build_object('tipo_comunicacao', p.tipo_comunicacao, 'orgao', p.orgao_julgador, 'link', p.link,
                          'disponibilizacao', p.data_disponibilizacao, 'publicacao', p.data_publicacao, 'status', p.status)
from public.publicacoes p
where p.processo_id is not null;
grant select on public.vw_linha_do_tempo to authenticated;

-- Ao abrir o processo, publicações novas passam a lidas (como os andamentos)
create or replace function public.marcar_movimentacoes_vistas(p_processo uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int; k int;
begin
  if not public.pode_ver_processo(p_processo) then return 0; end if;
  update movimentacoes set vista_em = now() where processo_id = p_processo and vista_em is null;
  get diagnostics n = row_count;
  update publicacoes set status = 'lida', lida_em = now() where processo_id = p_processo and status = 'nova';
  get diagnostics k = row_count;
  return n + k;
end $$;

-- Prazo criado a partir de uma publicação: a publicação fica marcada
create or replace function public.tg_prazo_marca_publicacao()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.publicacao_id is not null then
    update publicacoes set status = 'prazo_criado', lida_em = coalesce(lida_em, now()) where id = new.publicacao_id;
  end if;
  return new;
end $$;
drop trigger if exists prazo_marca_publicacao on public.prazos;
create trigger prazo_marca_publicacao after insert on public.prazos
  for each row execute function public.tg_prazo_marca_publicacao();

-- =====================================================================
-- FASE 2.7 · NOTIFICAÇÕES NO CELULAR (web push)
--  • Cada advogado ativa no(s) próprio(s) aparelho(s)
--  • As chaves de envio (VAPID) são geradas pela própria função, na 1ª vez, e ficam só no servidor
--  • Cada aviso é enviado uma vez só (tabela de controle)
-- =====================================================================
create table public.push_inscricoes (
  id           uuid primary key default gen_random_uuid(),
  advogado_id  uuid not null default auth.uid() references public.advogados(id) on delete cascade,
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  aparelho     text,
  criado_em    timestamptz not null default now(),
  ultimo_envio timestamptz,
  falhas       int not null default 0
);
alter table public.push_inscricoes enable row level security;
create policy push_ler on public.push_inscricoes for select to authenticated using (advogado_id = auth.uid());
create policy push_criar on public.push_inscricoes for insert to authenticated with check (advogado_id = auth.uid());
create policy push_editar on public.push_inscricoes for update to authenticated using (advogado_id = auth.uid()) with check (advogado_id = auth.uid());
create policy push_apagar on public.push_inscricoes for delete to authenticated using (advogado_id = auth.uid());

-- Chaves VAPID: sem nenhuma política = ninguém lê pelo app; só a função (chave de serviço)
create table public.push_chaves (
  id          int primary key default 1 check (id = 1),
  publica     text not null,
  privada_jwk jsonb not null,
  criado_em   timestamptz not null default now()
);
alter table public.push_chaves enable row level security;

-- Controle: cada aviso (chave) vai uma vez para cada advogado
create table public.push_enviados (
  advogado_id uuid not null references public.advogados(id) on delete cascade,
  chave       text not null,
  enviado_em  timestamptz not null default now(),
  primary key (advogado_id, chave)
);
alter table public.push_enviados enable row level security;

insert into public.configuracoes (chave, valor, descricao) values
  ('push_hora_prazos', '7', 'Hora (Brasília) do resumo de prazos que vencem hoje e amanhã.'),
  ('push_hora_vespera_audiencia', '18', 'Hora (Brasília) do aviso de audiência na véspera.'),
  ('push_horas_antes_audiencia', '2', 'Quantas horas antes da audiência vai o segundo aviso.'),
  ('push_hora_sugestoes', '8', 'Hora (Brasília) do aviso de sugestões pendentes.')
on conflict (chave) do nothing;
