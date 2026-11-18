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

-- =====================================================================
-- FASE 2.8 · MAIS DE UMA OAB POR ADVOGADO (inscrições suplementares)
--  • advogado_oabs guarda todas as inscrições; uma é a principal
--  • advogados.oab_numero / oab_uf continuam existindo e sempre mostram a principal
--  • Inclusão, remoção e troca da principal só pelas funções abaixo (o próprio advogado ou um administrador)
-- =====================================================================
create table public.advogado_oabs (
  id          uuid primary key default gen_random_uuid(),
  advogado_id uuid not null references public.advogados(id) on delete cascade,
  numero      text not null check (numero ~ '^[0-9]{1,8}[A-Z]?$'),
  uf          char(2) not null,
  principal   boolean not null default false,
  criado_em   timestamptz not null default now(),
  unique (numero, uf)
);
create unique index advogado_oabs_uma_principal on public.advogado_oabs (advogado_id) where principal;
alter table public.advogado_oabs enable row level security;
create policy oab_ler on public.advogado_oabs for select to authenticated using (true);
grant select on public.advogado_oabs to authenticated;

-- Traz as OABs que já existem como principais
insert into public.advogado_oabs (advogado_id, numero, uf, principal)
select id, upper(oab_numero), upper(oab_uf), true from public.advogados
on conflict (numero, uf) do nothing;

-- Cadastro/edição do perfil (primeiro acesso, criação pelo admin, "Meus dados"): mantém a principal em dia
create or replace function public.tg_advogado_oab_principal()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.oab_numero = old.oab_numero and new.oab_uf = old.oab_uf then return new; end if;
  -- se a "nova principal" já é uma OAB suplementar do próprio advogado, só troca a marcação
  if exists (select 1 from advogado_oabs where advogado_id = new.id and numero = upper(new.oab_numero) and uf = upper(new.oab_uf)) then
    update advogado_oabs set principal = false where advogado_id = new.id and principal;
    update advogado_oabs set principal = true where advogado_id = new.id and numero = upper(new.oab_numero) and uf = upper(new.oab_uf);
  elsif exists (select 1 from advogado_oabs where advogado_id = new.id and principal) then
    update advogado_oabs set numero = upper(new.oab_numero), uf = upper(new.oab_uf) where advogado_id = new.id and principal;
  else
    insert into advogado_oabs (advogado_id, numero, uf, principal) values (new.id, upper(new.oab_numero), upper(new.oab_uf), true);
  end if;
  return new;
exception when unique_violation then
  raise exception 'A OAB %/% já está cadastrada para outro advogado.', new.oab_numero, new.oab_uf;
end $$;
drop trigger if exists advogado_oab_principal on public.advogados;
create trigger advogado_oab_principal after insert or update of oab_numero, oab_uf on public.advogados
  for each row execute function public.tg_advogado_oab_principal();

create or replace function public.pode_editar_oabs(p_adv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_adv = auth.uid() or public.sou_admin();
$$;

create or replace function public.incluir_oab(p_numero text, p_uf text, p_advogado uuid default null)
returns public.advogado_oabs language plpgsql security definer set search_path = public as $$
declare adv uuid := coalesce(p_advogado, auth.uid()); n text := upper(regexp_replace(coalesce(p_numero,''), '[^0-9A-Za-z]', '', 'g')); u text := upper(trim(coalesce(p_uf,''))); r advogado_oabs;
begin
  if not public.pode_editar_oabs(adv) then raise exception 'Sem permissão para alterar as OABs deste advogado.'; end if;
  if n !~ '^[0-9]{1,8}[A-Z]?$' then raise exception 'Número de OAB inválido.'; end if;
  if u not in ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO') then raise exception 'UF inválida.'; end if;
  if exists (select 1 from advogado_oabs where numero = n and uf = u and advogado_id = adv) then raise exception 'Essa OAB já está no seu cadastro.'; end if;
  if exists (select 1 from advogado_oabs where numero = n and uf = u) then raise exception 'A OAB %/% já está cadastrada para outro advogado.', n, u; end if;
  if exists (select 1 from advogado_oabs where advogado_id = adv and uf = u) then raise exception 'Já existe uma OAB de % neste cadastro.', u; end if;
  insert into advogado_oabs (advogado_id, numero, uf, principal) values (adv, n, u, false) returning * into r;
  return r;
end $$;

create or replace function public.tornar_oab_principal(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r advogado_oabs;
begin
  select * into r from advogado_oabs where id = p_id;
  if r.id is null or not public.pode_editar_oabs(r.advogado_id) then raise exception 'OAB não encontrada.'; end if;
  if r.principal then return; end if;
  update advogado_oabs set principal = false where advogado_id = r.advogado_id and principal;
  update advogado_oabs set principal = true where id = r.id;
  update advogados set oab_numero = r.numero, oab_uf = r.uf where id = r.advogado_id;  -- o gatilho vê que já é a principal
end $$;

create or replace function public.remover_oab(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r advogado_oabs;
begin
  select * into r from advogado_oabs where id = p_id;
  if r.id is null or not public.pode_editar_oabs(r.advogado_id) then raise exception 'OAB não encontrada.'; end if;
  if r.principal then raise exception 'Esta é a OAB principal. Torne outra OAB principal antes de remover esta.'; end if;
  delete from advogado_oabs where id = r.id;
end $$;
grant execute on function public.incluir_oab(text, text, uuid), public.tornar_oab_principal(uuid), public.remover_oab(uuid) to authenticated;

-- =====================================================================
-- FASE 2.9 · DESCOBERTA DIÁRIA DE PROCESSOS NOVOS (DJEN pelo nome do cliente)
--  • Processos cadastrados: andamentos e publicações só pelo NÚMERO (já existente)
--  • Processos novos: busca diária pelos nomes de busca de cada cliente (ou a razão social, se PJ sem nomes)
--  • O aviso vai só para os advogados daquele cliente, com registro de quem foi avisado e do que decidiu
-- =====================================================================
create table public.descoberta_buscas (
  cliente_id   uuid not null references public.clientes(id) on delete cascade,
  termo        text not null,
  ultima_busca timestamptz,
  ultimo_erro  text,
  primary key (cliente_id, termo)
);
alter table public.descoberta_buscas enable row level security;  -- só a rotina (chave de serviço)

create table public.descobertas (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  numero_cnj    text not null,
  tribunal      text,
  orgao_julgador text,
  classe        text,
  partes        jsonb,
  polo_cliente  text check (polo_cliente in ('autor','reu')),
  publicacoes   int not null default 1,
  primeira      date,
  ultima        date,
  ultimo_tipo   text,
  trecho        text,
  link          text,
  termo         text,
  encontrado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (cliente_id, numero_cnj)
);
alter table public.descobertas enable row level security;

create table public.descoberta_avisos (
  id            uuid primary key default gen_random_uuid(),
  descoberta_id uuid not null references public.descobertas(id) on delete cascade,
  advogado_id   uuid not null references public.advogados(id) on delete cascade,
  notificado_em timestamptz not null default now(),
  status        text not null default 'pendente' check (status in ('pendente','visualizado','cadastrado')),
  decidido_em   timestamptz,
  decidido_por  uuid references public.advogados(id) on delete set null,
  processo_id   uuid references public.processos(id) on delete set null,
  unique (descoberta_id, advogado_id)
);
create index on public.descoberta_avisos (advogado_id, status);
alter table public.descoberta_avisos enable row level security;

create or replace function public.recebi_descoberta(p_desc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from descoberta_avisos where descoberta_id = p_desc and advogado_id = auth.uid());
$$;
-- Vê a descoberta e o registro de avisos dela quem foi avisado (os advogados do cliente)
create policy desc_ler on public.descobertas for select to authenticated using (public.recebi_descoberta(id));
create policy desc_av_ler on public.descoberta_avisos for select to authenticated using (public.recebi_descoberta(descoberta_id));
grant select on public.descobertas, public.descoberta_avisos to authenticated;

-- "Visualizado" (ou desfazer): só o próprio aviso
create or replace function public.decidir_descoberta(p_aviso uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('pendente','visualizado') then raise exception 'Situação inválida.'; end if;
  update descoberta_avisos
     set status = p_status,
         decidido_em = case when p_status = 'pendente' then null else now() end,
         decidido_por = case when p_status = 'pendente' then null else auth.uid() end
   where id = p_aviso and advogado_id = auth.uid() and status <> 'cadastrado';
  if not found then raise exception 'Aviso não encontrado.'; end if;
end $$;
grant execute on function public.decidir_descoberta(uuid, text) to authenticated;

-- Processo cadastrado com o mesmo número: todos os avisos dele passam a "cadastrado"
create or replace function public.tg_processo_fecha_descoberta()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- quem já tinha marcado "visualizado" mantém o registro; só os pendentes passam a "cadastrado"
  update descoberta_avisos av
     set processo_id = new.id,
         status = case when av.status = 'pendente' then 'cadastrado' else av.status end,
         decidido_em = case when av.status = 'pendente' then now() else av.decidido_em end,
         decidido_por = case when av.status = 'pendente' then coalesce(auth.uid(), new.criado_por) else av.decidido_por end
    from descobertas d
   where d.id = av.descoberta_id and d.numero_cnj = new.numero_cnj and av.processo_id is null;
  return new;
end $$;
drop trigger if exists processo_fecha_descoberta on public.processos;
create trigger processo_fecha_descoberta after insert on public.processos
  for each row execute function public.tg_processo_fecha_descoberta();

-- Lista para a tela "Processos novos" e o histórico (log)
create view public.vw_descobertas with (security_invoker = on) as
select av.id as aviso_id, av.advogado_id, av.notificado_em, av.status, av.decidido_em, av.processo_id,
       (av.advogado_id = auth.uid()) as meu,
       na.nome as advogado_nome, nd.nome as decidido_por_nome,
       d.id as descoberta_id, d.cliente_id, c.nome as cliente_nome, c.nome_fantasia as cliente_fantasia,
       d.numero_cnj, d.tribunal, d.orgao_julgador, d.classe, d.partes, d.polo_cliente, d.publicacoes,
       d.primeira, d.ultima, d.ultimo_tipo, d.trecho, d.link, d.termo, d.encontrado_em
from public.descoberta_avisos av
join public.descobertas d on d.id = av.descoberta_id
join public.clientes c on c.id = d.cliente_id
join public.advogados na on na.id = av.advogado_id
left join public.advogados nd on nd.id = av.decidido_por;
grant select on public.vw_descobertas to authenticated;

insert into public.configuracoes (chave, valor, descricao) values
  ('descoberta_dias_primeira_busca', '30', 'Na primeira busca diária de um nome, quantos dias de publicações olhar.')
on conflict (chave) do nothing;

-- =====================================================================
-- FASE 3.0 · VÁRIOS ESCRITÓRIOS NO MESMO ORBEO
--  • Cada escritório só enxerga os próprios dados (clientes, processos, prazos, suspensões...)
--  • Escritórios são criados só pelo dono da plataforma
--  • Papéis: admin (sócio administrador), advogado, estagiário
--  • Visão geral: o sócio administrador decide quem vê todos os processos do escritório
--  • Estagiário: só consulta e dá cumprimento (com observação) aos prazos designados a ele
--  • Suspensão manual específica de um escritório vira SUGESTÃO para os outros que tenham processos alcançados
--  • Prazos: responsável e histórico (quem lançou, cumpriu, observou)
--  Os dados que já existem passam para o "Escritório principal".
-- =====================================================================

-- ---------- Escritórios e dono da plataforma ----------
create table public.escritorios (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null,
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);
alter table public.escritorios enable row level security;

create table public.plataforma_donos (
  usuario_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.plataforma_donos enable row level security;

insert into public.escritorios (id, nome) values ('00000000-0000-0000-0000-0000000000e1', 'Escritório principal');

alter table public.advogados
  add column escritorio_id uuid references public.escritorios(id),
  add column papel         text not null default 'advogado' check (papel in ('admin','advogado','estagiario')),
  add column visao_geral   boolean not null default false;
update public.advogados set escritorio_id = '00000000-0000-0000-0000-0000000000e1',
       papel = case when admin then 'admin' else 'advogado' end, visao_geral = false;  -- o sigilo de hoje continua: visão geral só se o sócio administrador ligar
insert into public.plataforma_donos (usuario_id) select id from public.advogados where admin on conflict do nothing;

-- Funções de apoio (usadas nas regras de acesso)
create or replace function public.meu_escritorio() returns uuid
language sql stable security definer set search_path = public as $$
  select escritorio_id from advogados where id = auth.uid();
$$;
create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from advogados where id = auth.uid() and ativo;
$$;
create or replace function public.sou_estagiario() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() = 'estagiario', true);
$$;
create or replace function public.sou_dono_plataforma() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from plataforma_donos where usuario_id = auth.uid());
$$;
create or replace function public.sou_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from advogados where id = auth.uid() and papel = 'admin' and ativo);
$$;
create or replace function public.mesmo_escritorio(p_adv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from advogados where id = p_adv and escritorio_id = public.meu_escritorio());
$$;
grant execute on function public.meu_escritorio(), public.meu_papel(), public.sou_estagiario(),
  public.sou_dono_plataforma(), public.sou_admin(), public.mesmo_escritorio(uuid) to authenticated;

alter table public.advogados alter column escritorio_id set default public.meu_escritorio();
alter table public.advogados alter column escritorio_id set not null;

create policy esc_ler on public.escritorios for select to authenticated
  using (id = public.meu_escritorio() or public.sou_dono_plataforma());
create policy dono_ler on public.plataforma_donos for select to authenticated using (usuario_id = auth.uid());
grant select on public.escritorios, public.plataforma_donos to authenticated;

-- admin (coluna antiga) acompanha o papel
create or replace function public.tg_advogado_papel()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.admin and new.papel <> 'admin' then new.papel := 'admin'; end if;
  elsif new.papel is distinct from old.papel then
    null;
  elsif new.admin is distinct from old.admin then
    new.papel := case when new.admin then 'admin' when old.papel = 'admin' then 'advogado' else old.papel end;
  end if;
  new.admin := (new.papel = 'admin');
  return new;
end $$;
drop trigger if exists advogado_papel on public.advogados;
create trigger advogado_papel before insert or update on public.advogados
  for each row execute function public.tg_advogado_papel();

-- Ninguém muda o próprio papel, visão geral ou escritório; o admin só mexe no próprio escritório
create or replace function public.tg_protege_advogado()
returns trigger language plpgsql set search_path = public as $$
declare servidor boolean := current_user in ('service_role','postgres','supabase_admin');
begin
  if servidor then return new; end if;
  if tg_op = 'INSERT' then
    new.admin := false; new.papel := 'advogado'; new.visao_geral := false; new.ativo := true; new.trocar_senha := false;
    new.escritorio_id := public.meu_escritorio();
    return new;
  end if;
  if new.escritorio_id is distinct from old.escritorio_id then raise exception 'Não é possível mudar o escritório de um usuário.'; end if;
  if public.sou_admin() and old.escritorio_id = public.meu_escritorio() then return new; end if;
  if new.admin is distinct from old.admin or new.ativo is distinct from old.ativo
     or new.papel is distinct from old.papel or new.visao_geral is distinct from old.visao_geral then
    raise exception 'Apenas o sócio administrador altera perfil de acesso.';
  end if;
  if new.trocar_senha and not old.trocar_senha then raise exception 'Apenas o administrador exige troca de senha.'; end if;
  return new;
end $$;

drop policy if exists adv_ler on public.advogados;
drop policy if exists adv_admin_editar on public.advogados;
create policy adv_ler on public.advogados for select to authenticated
  using (escritorio_id = public.meu_escritorio() or id = auth.uid());
create policy adv_admin_editar on public.advogados for update to authenticated
  using (public.sou_admin() and escritorio_id = public.meu_escritorio());

drop policy if exists oab_ler on public.advogado_oabs;
create policy oab_ler on public.advogado_oabs for select to authenticated
  using (public.mesmo_escritorio(advogado_id) or advogado_id = auth.uid());
create or replace function public.pode_editar_oabs(p_adv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_adv = auth.uid() or (public.sou_admin() and public.mesmo_escritorio(p_adv));
$$;

-- ---------- Clientes e processos ganham o escritório ----------
alter table public.clientes add column escritorio_id uuid references public.escritorios(id);
alter table public.processos add column escritorio_id uuid references public.escritorios(id);
update public.clientes set escritorio_id = '00000000-0000-0000-0000-0000000000e1';
update public.processos set escritorio_id = '00000000-0000-0000-0000-0000000000e1';
alter table public.clientes alter column escritorio_id set default public.meu_escritorio();
alter table public.processos alter column escritorio_id set default public.meu_escritorio();
alter table public.clientes alter column escritorio_id set not null;
alter table public.processos alter column escritorio_id set not null;
create index on public.clientes (escritorio_id);
create index on public.processos (escritorio_id);

-- O mesmo processo pode estar em dois escritórios (ex.: autor e réu usam o Orbeo)
alter table public.processos drop constraint if exists processos_numero_cnj_key;
alter table public.processos add constraint processos_escritorio_numero_key unique (escritorio_id, numero_cnj);

-- Processo e cliente sempre no mesmo escritório
create or replace function public.tg_processo_escritorio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select escritorio_id into new.escritorio_id from clientes where id = new.cliente_id;
  return new;
end $$;
drop trigger if exists processo_escritorio on public.processos;
create trigger processo_escritorio before insert or update of cliente_id on public.processos
  for each row execute function public.tg_processo_escritorio();

-- Quem enxerga o quê
create or replace function public.tenho_visao_geral() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select visao_geral from advogados where id = auth.uid() and ativo), false);
$$;
create or replace function public.pode_ver_processo(p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from processos pr
     where pr.id = p and pr.escritorio_id = public.meu_escritorio()
       and (public.tenho_visao_geral()
            or exists (select 1 from processo_advogados pa where pa.processo_id = p and pa.advogado_id = auth.uid())
            or exists (select 1 from prazos z where z.processo_id = p and z.responsavel_id = auth.uid())));
$$;
create or replace function public.pode_ver_cliente(c uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from clientes cl
     where cl.id = c and cl.escritorio_id = public.meu_escritorio()
       and (public.tenho_visao_geral()
            or exists (select 1 from cliente_advogados ca where ca.cliente_id = c and ca.advogado_id = auth.uid())
            or exists (select 1 from processos pr where pr.cliente_id = c and public.pode_ver_processo(pr.id))));
$$;
create or replace function public.posso_editar() returns boolean
language sql stable security definer set search_path = public as $$
  select not public.sou_estagiario();
$$;
grant execute on function public.tenho_visao_geral(), public.posso_editar() to authenticated;

drop policy if exists cli_ler on public.clientes;
drop policy if exists cli_criar on public.clientes;
drop policy if exists cli_editar on public.clientes;
drop policy if exists cli_excluir on public.clientes;
create policy cli_ler on public.clientes for select to authenticated
  using (public.pode_ver_cliente(id) or (criado_por = auth.uid() and escritorio_id = public.meu_escritorio()));
create policy cli_criar on public.clientes for insert to authenticated
  with check (criado_por = auth.uid() and escritorio_id = public.meu_escritorio() and public.posso_editar());
create policy cli_editar on public.clientes for update to authenticated
  using (public.pode_ver_cliente(id) and public.posso_editar()) with check (escritorio_id = public.meu_escritorio());
create policy cli_excluir on public.clientes for delete to authenticated
  using (criado_por = auth.uid() and public.posso_editar());

drop policy if exists cliadv_criar on public.cliente_advogados;
create policy cliadv_criar on public.cliente_advogados for insert to authenticated
  with check (public.pode_ver_cliente(cliente_id) and public.mesmo_escritorio(advogado_id) and public.posso_editar());
drop policy if exists cliadv_tirar on public.cliente_advogados;
create policy cliadv_tirar on public.cliente_advogados for delete to authenticated
  using (public.pode_ver_cliente(cliente_id) and public.posso_editar());

drop policy if exists proc_ler on public.processos;
drop policy if exists proc_criar on public.processos;
drop policy if exists proc_editar on public.processos;
drop policy if exists proc_excluir on public.processos;
create policy proc_ler on public.processos for select to authenticated
  using (public.pode_ver_processo(id) or (criado_por = auth.uid() and escritorio_id = public.meu_escritorio()));
create policy proc_criar on public.processos for insert to authenticated
  with check (criado_por = auth.uid() and public.pode_ver_cliente(cliente_id) and public.posso_editar());
create policy proc_editar on public.processos for update to authenticated
  using (public.pode_ver_processo(id) and public.posso_editar());
create policy proc_excluir on public.processos for delete to authenticated
  using (public.pode_ver_processo(id) and public.posso_editar());

drop policy if exists procadv_criar on public.processo_advogados;
drop policy if exists procadv_tirar on public.processo_advogados;
create policy procadv_criar on public.processo_advogados for insert to authenticated
  with check (public.pode_ver_processo(processo_id) and public.mesmo_escritorio(advogado_id) and public.posso_editar());
create policy procadv_tirar on public.processo_advogados for delete to authenticated
  using (public.pode_ver_processo(processo_id) and public.posso_editar());

-- Estagiário só consulta (cumprimento de prazo é pela função cumprir_prazo)
drop policy if exists prz_tudo on public.prazos;
create policy prz_ler on public.prazos for select to authenticated using (public.pode_ver_processo(processo_id));
create policy prz_criar on public.prazos for insert to authenticated with check (public.pode_ver_processo(processo_id) and public.posso_editar());
create policy prz_editar on public.prazos for update to authenticated using (public.pode_ver_processo(processo_id) and public.posso_editar());
create policy prz_excluir on public.prazos for delete to authenticated using (public.pode_ver_processo(processo_id) and public.posso_editar());

drop policy if exists dec_tudo on public.decisoes;
create policy dec_ler on public.decisoes for select to authenticated using (public.pode_ver_processo(processo_id));
create policy dec_escrever on public.decisoes for all to authenticated
  using (public.pode_ver_processo(processo_id) and public.posso_editar())
  with check (public.pode_ver_processo(processo_id) and public.posso_editar());

drop policy if exists aud_tudo on public.audiencias;
create policy aud_ler on public.audiencias for select to authenticated using (public.pode_ver_processo(processo_id));
create policy aud_escrever on public.audiencias for all to authenticated
  using (public.pode_ver_processo(processo_id) and public.posso_editar())
  with check (public.pode_ver_processo(processo_id) and public.posso_editar());

-- Responsável pelo prazo: alguém do mesmo escritório
create or replace function public.tg_prazo_responsavel()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.responsavel_id is not null and not exists (
       select 1 from advogados a join processos p on p.escritorio_id = a.escritorio_id
        where a.id = new.responsavel_id and p.id = new.processo_id) then
    raise exception 'O responsável precisa ser do mesmo escritório.';
  end if;
  return new;
end $$;
drop trigger if exists prazo_responsavel on public.prazos;
create trigger prazo_responsavel before insert or update of responsavel_id on public.prazos
  for each row execute function public.tg_prazo_responsavel();

-- Publicações: o mesmo número pode existir em dois escritórios
alter table public.publicacoes drop constraint if exists publicacoes_djen_id_key;
create unique index if not exists publicacoes_djen_processo on public.publicacoes (djen_id, processo_id);
create or replace function public.tg_liga_publicacoes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update publicacoes u set processo_id = new.id
   where u.numero_cnj = new.numero_cnj and u.processo_id is null
     and exists (select 1 from advogados a where a.id = u.advogado_id and a.escritorio_id = new.escritorio_id);
  return new;
end $$;

-- Processos novos: "já está no Orbeo" vale para o escritório do cliente
create or replace function public.tg_processo_fecha_descoberta()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update descoberta_avisos av
     set processo_id = new.id,
         status = case when av.status = 'pendente' then 'cadastrado' else av.status end,
         decidido_em = case when av.status = 'pendente' then now() else av.decidido_em end,
         decidido_por = case when av.status = 'pendente' then coalesce(auth.uid(), new.criado_por) else av.decidido_por end
    from descobertas d join clientes c on c.id = d.cliente_id
   where d.id = av.descoberta_id and d.numero_cnj = new.numero_cnj and c.escritorio_id = new.escritorio_id and av.processo_id is null;
  return new;
end $$;

-- ---------- Suspensões: de cada escritório, com sugestão para os outros ----------
alter table public.suspensoes add column escritorio_id uuid references public.escritorios(id);
update public.suspensoes set escritorio_id = '00000000-0000-0000-0000-0000000000e1' where fonte <> 'regra';
alter table public.sugestoes add column escritorio_id uuid references public.escritorios(id);
update public.sugestoes set escritorio_id = '00000000-0000-0000-0000-0000000000e1' where tipo = 'suspensao';

create or replace function public.tg_suspensao_escritorio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.fonte = 'regra' then new.escritorio_id := null;
  elsif new.escritorio_id is null then new.escritorio_id := public.meu_escritorio();
  end if;
  return new;
end $$;
drop trigger if exists suspensao_escritorio on public.suspensoes;
create trigger suspensao_escritorio before insert on public.suspensoes
  for each row execute function public.tg_suspensao_escritorio();

drop policy if exists sus_ler on public.suspensoes;
drop policy if exists sus_criar on public.suspensoes;
drop policy if exists sus_editar on public.suspensoes;
drop policy if exists sus_excluir on public.suspensoes;
create policy sus_ler on public.suspensoes for select to authenticated
  using (escritorio_id is null or escritorio_id = public.meu_escritorio());
create policy sus_criar on public.suspensoes for insert to authenticated
  with check (criado_por = auth.uid() and fonte <> 'regra' and public.posso_editar());
create policy sus_editar on public.suspensoes for update to authenticated
  using (fonte <> 'regra' and escritorio_id = public.meu_escritorio() and public.posso_editar());
create policy sus_excluir on public.suspensoes for delete to authenticated
  using (fonte <> 'regra' and escritorio_id = public.meu_escritorio() and public.posso_editar());

drop policy if exists sug_ler on public.sugestoes;
drop policy if exists sug_decidir on public.sugestoes;
create policy sug_ler on public.sugestoes for select to authenticated
  using ((tipo = 'suspensao' and (escritorio_id is null or escritorio_id = public.meu_escritorio()))
      or (processo_id is not null and public.pode_ver_processo(processo_id))
      or (processo_id is null and tipo <> 'suspensao' and advogado_id = auth.uid()));
create policy sug_decidir on public.sugestoes for update to authenticated
  using (public.posso_editar() and (
         (tipo = 'suspensao' and (escritorio_id is null or escritorio_id = public.meu_escritorio()))
      or (processo_id is not null and public.pode_ver_processo(processo_id))
      or (processo_id is null and advogado_id = auth.uid())));

-- Suspensão manual de comarca, vara ou tribunal → sugestão para os outros escritórios com processos alcançados
create or replace function public.tg_suspensao_sugere_outros()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.fonte <> 'manual' or new.escritorio_id is null then return null; end if;
  insert into sugestoes (tipo, escritorio_id, dados, justificativa)
  select 'suspensao', e.escritorio_id,
         jsonb_strip_nulls(jsonb_build_object('abrangencia', new.abrangencia, 'tribunal', new.tribunal, 'comarca', new.comarca,
           'orgao', new.orgao, 'instancia', new.instancia, 'data_inicio', new.data_inicio, 'data_fim', new.data_fim,
           'hora_inicio', new.hora_inicio, 'tipo', new.tipo, 'motivo', new.motivo, 'numero_ato', new.numero_ato, 'link_ato', new.link_ato,
           'origem_suspensao', new.id)),
         'Cadastrada manualmente por outro escritório que usa o Orbeo e alcança processos seus. Confira o ato antes de confirmar.'
    from (select distinct p.escritorio_id from processos p
           where p.escritorio_id <> new.escritorio_id and p.situacao in ('ativo','suspenso')
             and (new.abrangencia = 'nacional' or p.tribunal = new.tribunal)
             and (new.abrangencia not in ('comarca','orgao') or lower(coalesce(p.comarca,'')) = lower(new.comarca))
             and (new.instancia = 'todas' or coalesce(p.instancia,'1g') = new.instancia)) e
   where not exists (select 1 from suspensoes s where s.escritorio_id = e.escritorio_id
                       and s.data_inicio = new.data_inicio and s.data_fim = new.data_fim
                       and coalesce(s.tribunal,'') = coalesce(new.tribunal,'') and lower(coalesce(s.comarca,'')) = lower(coalesce(new.comarca,'')))
     and not exists (select 1 from sugestoes g where g.escritorio_id = e.escritorio_id and g.tipo = 'suspensao'
                       and g.dados->>'origem_suspensao' = new.id::text);
  return null;
end $$;
drop trigger if exists suspensao_sugere_outros on public.suspensoes;
create trigger suspensao_sugere_outros after insert on public.suspensoes
  for each row execute function public.tg_suspensao_sugere_outros();

create or replace function public.confirmar_sugestao_suspensao(p_sugestao uuid, p_dados jsonb default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s sugestoes; d jsonb; novo uuid;
begin
  if auth.uid() is null or public.sou_estagiario() then raise exception 'Sem permissão.'; end if;
  select * into s from sugestoes where id = p_sugestao and tipo = 'suspensao' and status = 'pendente'
     and (escritorio_id is null or escritorio_id = public.meu_escritorio()) for update;
  if not found then raise exception 'Sugestão não encontrada ou já decidida.'; end if;
  d := s.dados || coalesce(p_dados, '{}'::jsonb);
  insert into suspensoes (abrangencia, tribunal, comarca, orgao, instancia, data_inicio, data_fim, hora_inicio,
                          tipo, motivo, numero_ato, link_ato, fonte, criado_por, escritorio_id)
  values (coalesce(d->>'abrangencia','tribunal'), d->>'tribunal', d->>'comarca', d->>'orgao', coalesce(d->>'instancia','todas'),
          (d->>'data_inicio')::date, coalesce(d->>'data_fim', d->>'data_inicio')::date,
          nullif(d->>'hora_inicio','')::time, coalesce(d->>'tipo','ato'), d->>'motivo',
          d->>'numero_ato', d->>'link_ato', 'sugestao', auth.uid(), public.meu_escritorio())
  returning id into novo;
  update sugestoes set status = case when p_dados is null or p_dados = '{}'::jsonb then 'aceita' else 'ajustada' end,
         decidido_por = auth.uid(), decidido_em = now(), dados = d
   where id = p_sugestao;
  return novo;
end $$;

create or replace function public.tribunais_em_uso()
returns table (tribunal text, comarca text)
language sql stable security definer set search_path = public as $$
  select distinct tribunal, comarca from processos where situacao = 'ativo' and escritorio_id = public.meu_escritorio()
  order by tribunal, comarca;
$$;

-- Cálculo do prazo: regras nacionais + suspensões do próprio escritório
drop function if exists public.calcular_prazo(date, text, int, text, text, text, text, text);
drop function if exists public.proximo_dia_util(date, text, text, text, text);
drop function if exists public.eh_dia_util(date, text, text, text, text);
drop function if exists public.situacao_do_dia(date, text, text, text, text);

create function public.situacao_do_dia(d date, trib text, com text, org text, inst text default '1g', esc uuid default null)
returns text language sql stable security definer set search_path = public as $$
  select case
    when bool_or(s.hora_inicio is null and s.tipo in ('recesso','ato','indisponibilidade')) then 'suspenso'
    when bool_or(s.hora_inicio is null) then 'nao_util'
    when bool_or(s.hora_inicio is not null) then 'parcial'
  end
  from suspensoes s
  where d between s.data_inicio and s.data_fim
    and (s.escritorio_id is null or s.escritorio_id = esc)
    and (s.instancia = 'todas' or s.instancia = coalesce(inst, '1g'))
    and (s.abrangencia = 'nacional'
      or (s.tribunal = trib and (
            s.abrangencia = 'tribunal'
         or (s.abrangencia = 'comarca' and lower(coalesce(com,'')) = lower(s.comarca))
         or (s.abrangencia = 'orgao' and lower(coalesce(com,'')) = lower(s.comarca)
             and coalesce(org,'') ilike '%' || s.orgao || '%'))));
$$;
create function public.eh_dia_util(d date, trib text, com text, org text, inst text default '1g', esc uuid default null)
returns boolean language sql stable security definer set search_path = public as $$
  select extract(isodow from d) < 6 and coalesce(public.situacao_do_dia(d, trib, com, org, inst, esc), 'ok') in ('ok','parcial');
$$;
create function public.proximo_dia_util(d date, trib text, com text, org text, inst text default '1g', esc uuid default null)
returns date language plpgsql stable security definer set search_path = public as $$
declare x date := d + 1;
begin
  while not public.eh_dia_util(x, trib, com, org, inst, esc) loop x := x + 1; end loop;
  return x;
end $$;
create function public.calcular_prazo(p_data date, p_origem text, p_dias int, p_contagem text,
                                      trib text, com text, org text, inst text default '1g', esc uuid default null,
                                      out inicio date, out fatal date)
language plpgsql stable security definer set search_path = public as $$
declare base date := p_data; n int := 1; d date; sit text; guarda int := 0;
begin
  if p_data is null or p_dias is null or p_dias < 1 then return; end if;
  if p_origem = 'ato' then
    inicio := p_data; d := p_data + p_dias;
    while not public.eh_dia_util(d, trib, com, org, inst, esc) or public.situacao_do_dia(d, trib, com, org, inst, esc) = 'parcial' loop d := d + 1; end loop;
    fatal := d; return;
  end if;
  if p_origem = 'disponibilizacao' then base := public.proximo_dia_util(base, trib, com, org, inst, esc); end if;
  inicio := public.proximo_dia_util(base, trib, com, org, inst, esc);
  d := inicio;
  while n < p_dias loop
    d := d + 1; guarda := guarda + 1;
    if guarda > 2000 then raise exception 'Prazo longo demais para calcular.'; end if;
    if p_contagem = 'uteis' then
      if public.eh_dia_util(d, trib, com, org, inst, esc) then n := n + 1; end if;
    else
      sit := public.situacao_do_dia(d, trib, com, org, inst, esc);
      if sit is distinct from 'suspenso' then n := n + 1; end if;
    end if;
  end loop;
  while not public.eh_dia_util(d, trib, com, org, inst, esc) or public.situacao_do_dia(d, trib, com, org, inst, esc) = 'parcial' loop
    d := d + 1;
  end loop;
  fatal := d;
end $$;
grant execute on function public.calcular_prazo(date, text, int, text, text, text, text, text, uuid) to authenticated;

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
                                               p.tribunal, p.comarca, p.orgao_julgador, p.instancia, p.escritorio_id);
    new.data_inicio_contagem := r.inicio;
    if tg_op = 'UPDATE' and old.prazo_fatal is distinct from r.fatal and old.status = 'aberto'
       and new.data_recebimento = old.data_recebimento and new.dias = old.dias and new.contagem = old.contagem
       and new.origem_contagem = old.origem_contagem then
      new.prazo_fatal_anterior := old.prazo_fatal; new.recalculado_em := now();
    end if;
    new.prazo_fatal := r.fatal;
  end if;
  if new.prazo_fatal is null then raise exception 'Informe o prazo fatal ou os dias do prazo.'; end if;
  if new.data_elaboracao is not null and new.data_elaboracao > new.prazo_fatal
     and (tg_op = 'INSERT' or new.data_elaboracao is distinct from old.data_elaboracao) then
    raise exception 'A data de elaboração não pode ser posterior ao prazo fatal (%).', to_char(new.prazo_fatal, 'DD/MM/YYYY');
  end if;
  return new;
end $$;

-- ---------- Prazos: cumprimento com observação e histórico ----------
alter table public.prazos
  add column if not exists cumprido_por uuid references public.advogados(id) on delete set null,
  add column if not exists cumprimento_obs text;

create table public.prazo_historico (
  id        uuid primary key default gen_random_uuid(),
  prazo_id  uuid not null references public.prazos(id) on delete cascade,
  acao      text not null check (acao in ('criado','cumprido','reaberto','responsavel','observacao','editado')),
  texto     text,
  autor_id  uuid references public.advogados(id) on delete set null,
  em        timestamptz not null default now()
);
create index on public.prazo_historico (prazo_id, em);
alter table public.prazo_historico enable row level security;
create policy przh_ler on public.prazo_historico for select to authenticated
  using (exists (select 1 from prazos z where z.id = prazo_id and public.pode_ver_processo(z.processo_id)));
grant select on public.prazo_historico to authenticated;

create or replace function public.tg_prazo_historico()
returns trigger language plpgsql security definer set search_path = public as $$
declare quem uuid := coalesce(auth.uid(), new.responsavel_id); nome_resp text;
begin
  if tg_op = 'INSERT' then
    select nome into nome_resp from advogados where id = new.responsavel_id;
    insert into prazo_historico (prazo_id, acao, texto, autor_id)
    values (new.id, 'criado', new.tipo || ' · fatal ' || to_char(new.prazo_fatal, 'DD/MM/YYYY') || coalesce(' · responsável: ' || nome_resp, ''), quem);
    return new;
  end if;
  if new.status = 'cumprido' and old.status <> 'cumprido' then
    insert into prazo_historico (prazo_id, acao, texto, autor_id)
    values (new.id, 'cumprido', 'Cumprido em ' || to_char(new.data_cumprimento, 'DD/MM/YYYY') || coalesce(E'\n' || nullif(trim(new.cumprimento_obs), ''), ''), coalesce(new.cumprido_por, quem));
  elsif old.status = 'cumprido' and new.status = 'aberto' then
    insert into prazo_historico (prazo_id, acao, texto, autor_id) values (new.id, 'reaberto', null, quem);
  end if;
  if new.responsavel_id is distinct from old.responsavel_id then
    select nome into nome_resp from advogados where id = new.responsavel_id;
    insert into prazo_historico (prazo_id, acao, texto, autor_id) values (new.id, 'responsavel', 'Responsável: ' || coalesce(nome_resp, 'ninguém'), quem);
  end if;
  return new;
end $$;
drop trigger if exists prazo_historico on public.prazos;
create trigger prazo_historico after insert or update on public.prazos
  for each row execute function public.tg_prazo_historico();

-- Cumprir: advogados do processo ou o responsável designado (inclusive estagiário)
create or replace function public.cumprir_prazo(p_id uuid, p_data date, p_obs text default null)
returns void language plpgsql security definer set search_path = public as $$
declare z prazos;
begin
  select * into z from prazos where id = p_id;
  if z.id is null or not public.pode_ver_processo(z.processo_id) then raise exception 'Prazo não encontrado.'; end if;
  if public.sou_estagiario() and z.responsavel_id is distinct from auth.uid() then
    raise exception 'O estagiário só dá cumprimento aos prazos designados a ele.';
  end if;
  if z.status <> 'aberto' then raise exception 'Este prazo não está em aberto.'; end if;
  update prazos set status = 'cumprido', data_cumprimento = coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date),
         cumprido_por = auth.uid(), cumprimento_obs = nullif(trim(coalesce(p_obs,'')), '')
   where id = p_id;
end $$;

create or replace function public.observar_prazo(p_id uuid, p_texto text)
returns void language plpgsql security definer set search_path = public as $$
declare z prazos;
begin
  select * into z from prazos where id = p_id;
  if z.id is null or not public.pode_ver_processo(z.processo_id) then raise exception 'Prazo não encontrado.'; end if;
  if public.sou_estagiario() and z.responsavel_id is distinct from auth.uid() then raise exception 'Sem permissão.'; end if;
  if coalesce(trim(p_texto), '') = '' then raise exception 'Escreva a observação.'; end if;
  insert into prazo_historico (prazo_id, acao, texto, autor_id) values (p_id, 'observacao', trim(p_texto), auth.uid());
end $$;
grant execute on function public.cumprir_prazo(uuid, date, text), public.observar_prazo(uuid, text) to authenticated;

-- Histórico com nome de quem lançou
create view public.vw_prazo_historico with (security_invoker = on) as
select h.*, a.nome as autor_nome from public.prazo_historico h left join public.advogados a on a.id = h.autor_id;
grant select on public.vw_prazo_historico to authenticated;

-- vw_prazos com responsável, quem cumpriu e a observação
drop view if exists public.vw_prazos;
create view public.vw_prazos with (security_invoker = on) as
select pz.*,
       p.numero_cnj, p.tribunal, p.comarca, p.orgao_julgador, p.instancia, p.polo, p.tipo_acao, p.rito, p.cliente_id, p.parte_contraria, p.escritorio_id, c.nome as cliente,
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
       (select a.papel from public.advogados a where a.id = pz.responsavel_id) as responsavel_papel,
       (select a.nome from public.advogados a where a.id = pz.cumprido_por) as cumprido_por_nome,
       (select au.data_hora from public.audiencias au where au.id = pz.audiencia_id) as audiencia_data_hora
from public.prazos pz
join public.processos p on p.id = pz.processo_id
join public.clientes  c on c.id = p.cliente_id;
grant select on public.vw_prazos to authenticated;

-- Excluir usuário: "exclusivo" passa a considerar o escritório
create or replace function public.exclusivos_do_advogado(p uuid)
returns table (processos bigint, clientes bigint)
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from processo_advogados pa where pa.advogado_id = p
       and not exists (select 1 from processo_advogados o where o.processo_id = pa.processo_id and o.advogado_id <> p)),
    (select count(*) from cliente_advogados ca where ca.advogado_id = p
       and not exists (select 1 from cliente_advogados o where o.cliente_id = ca.cliente_id and o.advogado_id <> p));
$$;

-- Configurações e fontes: só o dono da plataforma altera
drop policy if exists cfg_editar on public.configuracoes;
create policy cfg_editar on public.configuracoes for update to authenticated
  using (public.sou_dono_plataforma()) with check (atualizado_por = auth.uid());
drop policy if exists fon_editar on public.fontes_atos;
drop policy if exists fon_criar on public.fontes_atos;
create policy fon_editar on public.fontes_atos for update to authenticated using (public.sou_dono_plataforma());
create policy fon_criar on public.fontes_atos for insert to authenticated with check (public.sou_dono_plataforma());

-- Lista de escritórios para o dono da plataforma
create or replace function public.listar_escritorios()
returns table (id uuid, nome text, ativo boolean, criado_em timestamptz, usuarios bigint, processos bigint)
language sql stable security definer set search_path = public as $$
  select e.id, e.nome, e.ativo, e.criado_em,
         (select count(*) from advogados a where a.escritorio_id = e.id),
         (select count(*) from processos p where p.escritorio_id = e.id)
    from escritorios e
   where public.sou_dono_plataforma()
   order by e.criado_em;
$$;
grant execute on function public.listar_escritorios() to authenticated;

update public.prazos set atualizado_em = now() where status = 'aberto' and calculo_auto and dias is not null;

-- =====================================================================
-- FASE 3.1 · UM LOGIN, VÁRIOS ESPAÇOS (escritórios e espaço autônomo)
--  • escritorio_membros: a mesma pessoa pode estar em vários escritórios, com papel e visão geral próprios em cada um
--  • Espaço autônomo: um "escritório" de uma pessoa só (tipo = 'autonomo')
--  • advogados.escritorio_id passa a ser o ESPAÇO EM USO (troca pelo seletor); papel e visão geral
--    em advogados espelham o vínculo do espaço em uso
--  • Saída do escritório: processos exclusivos passam a um sucessor escolhido pelo sócio;
--    o sócio pode autorizar cópia de processos para o espaço autônomo do advogado
-- =====================================================================
alter table public.escritorios
  add column tipo text not null default 'escritorio' check (tipo in ('escritorio','autonomo')),
  add column titular_id uuid references public.advogados(id) on delete set null;

create table public.escritorio_membros (
  advogado_id   uuid not null references public.advogados(id) on delete cascade,
  escritorio_id uuid not null references public.escritorios(id) on delete cascade,
  papel         text not null default 'advogado' check (papel in ('admin','advogado','estagiario')),
  visao_geral   boolean not null default false,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  primary key (advogado_id, escritorio_id)
);
create index on public.escritorio_membros (escritorio_id);
alter table public.escritorio_membros enable row level security;

insert into public.escritorio_membros (advogado_id, escritorio_id, papel, visao_geral, ativo)
select id, escritorio_id, papel, visao_geral, true from public.advogados
on conflict do nothing;

-- Espaço em uso só vale se o vínculo e o escritório estiverem ativos
create or replace function public.meu_escritorio() returns uuid
language sql stable security definer set search_path = public as $$
  select a.escritorio_id from advogados a
    join escritorio_membros m on m.advogado_id = a.id and m.escritorio_id = a.escritorio_id and m.ativo
    join escritorios e on e.id = a.escritorio_id and e.ativo
   where a.id = auth.uid();
$$;
create or replace function public.mesmo_escritorio(p_adv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from escritorio_membros where advogado_id = p_adv and escritorio_id = public.meu_escritorio() and ativo);
$$;
create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select m.papel from escritorio_membros m where m.advogado_id = auth.uid() and m.escritorio_id = public.meu_escritorio();
$$;
create or replace function public.sou_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() = 'admin', false) and exists (select 1 from advogados where id = auth.uid() and ativo);
$$;
create or replace function public.tenho_visao_geral() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select m.visao_geral from escritorio_membros m where m.advogado_id = auth.uid() and m.escritorio_id = public.meu_escritorio()), false);
$$;

-- Espelha papel/visão do vínculo do espaço em uso em advogados (compatibilidade com o que já existe)
create or replace function public.tg_membro_espelha()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update advogados a set papel = new.papel, admin = (new.papel = 'admin'), visao_geral = new.visao_geral
   where a.id = new.advogado_id and a.escritorio_id = new.escritorio_id
     and (a.papel is distinct from new.papel or a.visao_geral is distinct from new.visao_geral);
  return null;
end $$;
drop trigger if exists membro_espelha on public.escritorio_membros;
create trigger membro_espelha after insert or update on public.escritorio_membros
  for each row execute function public.tg_membro_espelha();

-- Colegas = vínculos ativos no espaço em uso
drop policy if exists adv_ler on public.advogados;
create policy adv_ler on public.advogados for select to authenticated
  using (id = auth.uid() or exists (select 1 from escritorio_membros m where m.advogado_id = advogados.id
                                     and m.escritorio_id = public.meu_escritorio() and m.ativo));
create policy membros_ler on public.escritorio_membros for select to authenticated
  using (advogado_id = auth.uid() or escritorio_id = public.meu_escritorio());
grant select on public.escritorio_membros to authenticated;
drop policy if exists esc_ler on public.escritorios;
create policy esc_ler on public.escritorios for select to authenticated
  using (public.sou_dono_plataforma() or exists (select 1 from escritorio_membros m where m.escritorio_id = escritorios.id and m.advogado_id = auth.uid() and m.ativo));

-- O espaço em uso só muda pela função trocar_espaco
create or replace function public.tg_protege_advogado()
returns trigger language plpgsql set search_path = public as $$
declare servidor boolean := current_user in ('service_role','postgres','supabase_admin');
begin
  if servidor then return new; end if;
  if tg_op = 'INSERT' then raise exception 'O cadastro de usuários é feito pelo administrador.'; end if;
  if new.escritorio_id is distinct from old.escritorio_id then raise exception 'Use a troca de espaço para mudar de escritório.'; end if;
  if new.admin is distinct from old.admin or new.ativo is distinct from old.ativo
     or new.papel is distinct from old.papel or new.visao_geral is distinct from old.visao_geral then
    raise exception 'Papel e visão geral são alterados pelo sócio administrador, em Usuários.';
  end if;
  if new.trocar_senha and not old.trocar_senha then raise exception 'Apenas o administrador exige troca de senha.'; end if;
  return new;
end $$;

create or replace function public.trocar_espaco(p_escritorio uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m escritorio_membros;
begin
  select * into m from escritorio_membros where advogado_id = auth.uid() and escritorio_id = p_escritorio and ativo;
  if m.advogado_id is null or not exists (select 1 from escritorios where id = p_escritorio and ativo) then
    raise exception 'Você não tem acesso a este espaço.';
  end if;
  update advogados set escritorio_id = p_escritorio, papel = m.papel, admin = (m.papel = 'admin'), visao_geral = m.visao_geral
   where id = auth.uid();
end $$;
grant execute on function public.trocar_espaco(uuid) to authenticated;

-- Meus espaços (para o seletor)
create or replace view public.vw_meus_espacos with (security_invoker = on) as
select e.id, e.nome, e.tipo, m.papel, m.visao_geral, (a.escritorio_id = e.id) as em_uso
  from public.escritorio_membros m
  join public.escritorios e on e.id = m.escritorio_id and e.ativo
  join public.advogados a on a.id = m.advogado_id
 where m.advogado_id = auth.uid() and m.ativo;
grant select on public.vw_meus_espacos to authenticated;

-- Responsável pelo prazo: alguém com vínculo ativo no escritório do processo
create or replace function public.tg_prazo_responsavel()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.responsavel_id is not null and not exists (
       select 1 from escritorio_membros m join processos p on p.escritorio_id = m.escritorio_id
        where m.advogado_id = new.responsavel_id and m.ativo and p.id = new.processo_id) then
    raise exception 'O responsável precisa ser do mesmo escritório.';
  end if;
  return new;
end $$;

-- ---------- Saída do escritório e cópia de processos (usadas só pela função de administração) ----------
-- Copia um processo (cliente, andamentos, publicações, audiências, prazos com histórico, anotações e decisões) para outro espaço
create or replace function public.copiar_processo(p_proc uuid, p_destino uuid, p_adv uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr processos; cli clientes; novo_cli uuid; novo uuid; r record; nid uuid;
begin
  select * into pr from processos where id = p_proc;
  if pr.id is null then raise exception 'Processo não encontrado.'; end if;
  select id into novo from processos where escritorio_id = p_destino and numero_cnj = pr.numero_cnj;
  if novo is not null then return novo; end if;   -- já existe no destino
  select * into cli from clientes where id = pr.cliente_id;
  select id into novo_cli from clientes
   where escritorio_id = p_destino and ((cli.cpf_cnpj is not null and cpf_cnpj = cli.cpf_cnpj) or lower(nome) = lower(cli.nome)) limit 1;
  if novo_cli is null then
    insert into clientes select (jsonb_populate_record(null::clientes, to_jsonb(cli)
      || jsonb_build_object('id', gen_random_uuid(), 'escritorio_id', p_destino, 'criado_por', p_adv))).* returning id into novo_cli;
  end if;
  insert into cliente_advogados values (novo_cli, p_adv) on conflict do nothing;
  insert into processos select (jsonb_populate_record(null::processos, to_jsonb(pr)
    || jsonb_build_object('id', gen_random_uuid(), 'cliente_id', novo_cli, 'escritorio_id', p_destino, 'criado_por', p_adv))).* returning id into novo;
  insert into processo_advogados values (novo, p_adv) on conflict do nothing;

  create temp table if not exists _mapa (antigo uuid primary key, novo uuid) on commit drop;
  delete from _mapa;
  for r in select * from movimentacoes where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into movimentacoes select (jsonb_populate_record(null::movimentacoes, to_jsonb(r) || jsonb_build_object('id', nid, 'processo_id', novo))).*;
  end loop;
  for r in select * from publicacoes where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into publicacoes select (jsonb_populate_record(null::publicacoes, to_jsonb(r) || jsonb_build_object('id', nid, 'processo_id', novo, 'advogado_id', null))).*;
  end loop;
  for r in select * from audiencias where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into audiencias select (jsonb_populate_record(null::audiencias, to_jsonb(r)
      || jsonb_build_object('id', nid, 'processo_id', novo, 'responsavel_id', p_adv, 'sugestao_id', null))).*;
  end loop;
  for r in select * from prazos where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into prazos select (jsonb_populate_record(null::prazos, to_jsonb(r) || jsonb_build_object('id', nid, 'processo_id', novo,
      'responsavel_id', p_adv, 'cumprido_por', case when r.cumprido_por = p_adv then p_adv end,
      'audiencia_id', (select m.novo from _mapa m where m.antigo = r.audiencia_id),
      'publicacao_id', (select m.novo from _mapa m where m.antigo = r.publicacao_id)))).*;
    insert into prazo_historico (prazo_id, acao, texto, autor_id, em)
      select nid, h.acao, h.texto, h.autor_id, h.em from prazo_historico h where h.prazo_id = r.id;
  end loop;
  for r in select * from anotacoes where processo_id = p_proc loop
    insert into anotacoes select (jsonb_populate_record(null::anotacoes, to_jsonb(r) || jsonb_build_object('id', gen_random_uuid(), 'processo_id', novo,
      'movimentacao_id', (select m.novo from _mapa m where m.antigo = r.movimentacao_id),
      'publicacao_id', (select m.novo from _mapa m where m.antigo = r.publicacao_id)))).*;
  end loop;
  for r in select * from decisoes where processo_id = p_proc loop
    insert into decisoes select (jsonb_populate_record(null::decisoes, to_jsonb(r) || jsonb_build_object('id', gen_random_uuid(), 'processo_id', novo,
      'publicacao_id', (select m.novo from _mapa m where m.antigo = r.publicacao_id)))).*;
  end loop;
  return novo;
end $$;

-- Prévia da saída: processos do advogado no escritório, quais são só dele e quais espaços ele tem
create or replace function public.previa_saida(p_adv uuid, p_escritorio uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'processos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'numero_cnj', p.numero_cnj, 'cliente', c.nome,
                    'exclusivo', not exists (select 1 from processo_advogados o where o.processo_id = p.id and o.advogado_id <> p_adv))
                    order by c.nome, p.numero_cnj)
                  from processo_advogados pa join processos p on p.id = pa.processo_id join clientes c on c.id = p.cliente_id
                 where pa.advogado_id = p_adv and p.escritorio_id = p_escritorio), '[]'::jsonb),
    'prazos_abertos', (select count(*) from prazos z join processos p on p.id = z.processo_id
                        where z.responsavel_id = p_adv and z.status = 'aberto' and p.escritorio_id = p_escritorio),
    'outros_espacos', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'tipo', e.tipo))
                  from escritorio_membros m join escritorios e on e.id = m.escritorio_id
                 where m.advogado_id = p_adv and m.escritorio_id <> p_escritorio and m.ativo), '[]'::jsonb));
$$;

-- Executa a saída: sucessor assume os exclusivos e os prazos em aberto; o vínculo é apagado
create or replace function public.executar_saida(p_adv uuid, p_escritorio uuid, p_sucessor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare exclusivos int;
begin
  select count(*) into exclusivos from processo_advogados pa join processos p on p.id = pa.processo_id
   where pa.advogado_id = p_adv and p.escritorio_id = p_escritorio
     and not exists (select 1 from processo_advogados o where o.processo_id = pa.processo_id and o.advogado_id <> p_adv);
  if p_sucessor is not null and not exists (select 1 from escritorio_membros where advogado_id = p_sucessor and escritorio_id = p_escritorio and ativo and advogado_id <> p_adv) then
    raise exception 'O sucessor precisa ser outro membro ativo do escritório.';
  end if;
  if exclusivos > 0 and p_sucessor is null then raise exception 'Escolha quem assume os % processo(s) que só este advogado acompanha.', exclusivos; end if;
  if p_sucessor is not null then
    insert into processo_advogados (processo_id, advogado_id)
      select pa.processo_id, p_sucessor from processo_advogados pa join processos p on p.id = pa.processo_id
       where pa.advogado_id = p_adv and p.escritorio_id = p_escritorio
         and not exists (select 1 from processo_advogados o where o.processo_id = pa.processo_id and o.advogado_id <> p_adv)
    on conflict do nothing;
    insert into cliente_advogados (cliente_id, advogado_id)
      select ca.cliente_id, p_sucessor from cliente_advogados ca join clientes c on c.id = ca.cliente_id
       where ca.advogado_id = p_adv and c.escritorio_id = p_escritorio
    on conflict do nothing;
  end if;
  update prazos z set responsavel_id = p_sucessor
    from processos p where p.id = z.processo_id and p.escritorio_id = p_escritorio and z.responsavel_id = p_adv and z.status = 'aberto';
  update audiencias a set responsavel_id = p_sucessor
    from processos p where p.id = a.processo_id and p.escritorio_id = p_escritorio and a.responsavel_id = p_adv and a.status = 'agendada';
  delete from processo_advogados pa using processos p where p.id = pa.processo_id and p.escritorio_id = p_escritorio and pa.advogado_id = p_adv;
  delete from cliente_advogados ca using clientes c where c.id = ca.cliente_id and c.escritorio_id = p_escritorio and ca.advogado_id = p_adv;
  delete from descoberta_avisos av using descobertas d join clientes c on c.id = d.cliente_id
   where d.id = av.descoberta_id and c.escritorio_id = p_escritorio and av.advogado_id = p_adv and av.status = 'pendente';
  delete from escritorio_membros where advogado_id = p_adv and escritorio_id = p_escritorio;
  -- espaço em uso passa para outro vínculo (se houver)
  update advogados a set escritorio_id = coalesce((select m.escritorio_id from escritorio_membros m join escritorios e on e.id = m.escritorio_id
                                                    where m.advogado_id = p_adv and m.ativo and e.ativo order by (e.tipo = 'autonomo'), m.criado_em limit 1), a.escritorio_id)
   where a.id = p_adv and a.escritorio_id = p_escritorio;
  update advogados a set papel = m.papel, admin = (m.papel = 'admin'), visao_geral = m.visao_geral
    from escritorio_membros m where a.id = p_adv and m.advogado_id = a.id and m.escritorio_id = a.escritorio_id;
end $$;

-- Cria (ou devolve) o espaço autônomo de um advogado
create or replace function public.garantir_autonomo(p_adv uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare e uuid; nome_adv text;
begin
  select id into e from escritorios where tipo = 'autonomo' and titular_id = p_adv;
  if e is null then
    select nome into nome_adv from advogados where id = p_adv;
    insert into escritorios (nome, tipo, titular_id) values (nome_adv || ' (autônomo)', 'autonomo', p_adv) returning id into e;
  end if;
  insert into escritorio_membros (advogado_id, escritorio_id, papel, visao_geral, ativo) values (p_adv, e, 'admin', true, true)
  on conflict (advogado_id, escritorio_id) do update set ativo = true;
  return e;
end $$;

revoke all on function public.copiar_processo(uuid, uuid, uuid), public.previa_saida(uuid, uuid),
  public.executar_saida(uuid, uuid, uuid), public.garantir_autonomo(uuid) from public, authenticated;
grant execute on function public.copiar_processo(uuid, uuid, uuid), public.previa_saida(uuid, uuid),
  public.executar_saida(uuid, uuid, uuid), public.garantir_autonomo(uuid) to service_role;

-- Lista de escritórios (dono) com o tipo
drop function if exists public.listar_escritorios();
create function public.listar_escritorios()
returns table (id uuid, nome text, tipo text, ativo boolean, criado_em timestamptz, usuarios bigint, processos bigint)
language sql stable security definer set search_path = public as $$
  select e.id, e.nome, e.tipo, e.ativo, e.criado_em,
         (select count(*) from escritorio_membros m where m.escritorio_id = e.id and m.ativo),
         (select count(*) from processos p where p.escritorio_id = e.id)
    from escritorios e
   where public.sou_dono_plataforma()
   order by e.tipo, e.criado_em;
$$;
grant execute on function public.listar_escritorios() to authenticated;

-- =====================================================================
-- FASE 3.2 · DONO DA PLATAFORMA: MODO LEITURA E ADVOGADOS AUTÔNOMOS
--  • O dono pode entrar em qualquer espaço (escritório ou autônomo) só para LER:
--    vê todos os processos daquele espaço e não altera nada
--  • Exclusão de advogado autônomo apaga o login e o espaço dele (feita pela função de administração)
-- =====================================================================
create or replace function public.meu_escritorio() returns uuid
language sql stable security definer set search_path = public as $$
  select a.escritorio_id from advogados a
    join escritorios e on e.id = a.escritorio_id
   where a.id = auth.uid()
     and ( (e.ativo and exists (select 1 from escritorio_membros m where m.advogado_id = a.id and m.escritorio_id = a.escritorio_id and m.ativo))
        or exists (select 1 from plataforma_donos d where d.usuario_id = a.id) );
$$;

-- Observador = dono dentro de um espaço do qual não é membro
create or replace function public.sou_observador() returns boolean
language sql stable security definer set search_path = public as $$
  select public.sou_dono_plataforma() and not exists (
    select 1 from escritorio_membros m join advogados a on a.id = m.advogado_id
     where m.advogado_id = auth.uid() and m.escritorio_id = a.escritorio_id and m.ativo);
$$;
create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select m.papel from escritorio_membros m where m.advogado_id = auth.uid() and m.escritorio_id = public.meu_escritorio() and m.ativo),
    case when public.sou_observador() then 'observador' end);
$$;
-- Só sócio e advogado alteram dados (estagiário e observador apenas leem)
create or replace function public.sou_estagiario() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() not in ('admin','advogado'), true);
$$;
create or replace function public.posso_editar() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() in ('admin','advogado'), false);
$$;
create or replace function public.tenho_visao_geral() returns boolean
language sql stable security definer set search_path = public as $$
  select public.sou_observador() or coalesce((select m.visao_geral from escritorio_membros m
    where m.advogado_id = auth.uid() and m.escritorio_id = public.meu_escritorio() and m.ativo), false);
$$;
grant execute on function public.sou_observador() to authenticated;

create or replace function public.trocar_espaco(p_escritorio uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m escritorio_membros;
begin
  select * into m from escritorio_membros where advogado_id = auth.uid() and escritorio_id = p_escritorio and ativo;
  if m.advogado_id is not null and exists (select 1 from escritorios where id = p_escritorio and ativo) then
    update advogados set escritorio_id = p_escritorio, papel = m.papel, admin = (m.papel = 'admin'), visao_geral = m.visao_geral where id = auth.uid();
  elsif public.sou_dono_plataforma() and exists (select 1 from escritorios where id = p_escritorio) then
    update advogados set escritorio_id = p_escritorio where id = auth.uid();   -- modo leitura
  else
    raise exception 'Você não tem acesso a este espaço.';
  end if;
end $$;

-- O que estou vendo agora (para a faixa de "modo leitura")
create or replace function public.espaco_atual()
returns table (id uuid, nome text, tipo text, papel text, observador boolean)
language sql stable security definer set search_path = public as $$
  select e.id, e.nome, e.tipo, public.meu_papel(), public.sou_observador()
    from escritorios e where e.id = public.meu_escritorio();
$$;
grant execute on function public.espaco_atual() to authenticated;

-- Exclusão de um advogado autônomo: apaga os dados do espaço autônomo (o login é apagado pela função)
create or replace function public.apagar_espaco(p_escritorio uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from escritorios where id = p_escritorio and tipo = 'autonomo') then
    raise exception 'Só espaços autônomos podem ser apagados por aqui.';
  end if;
  delete from publicacoes where processo_id in (select id from processos where escritorio_id = p_escritorio);
  delete from processos where escritorio_id = p_escritorio;
  delete from clientes where escritorio_id = p_escritorio;
  delete from suspensoes where escritorio_id = p_escritorio;
  delete from sugestoes where escritorio_id = p_escritorio;
  delete from escritorios where id = p_escritorio;
end $$;
revoke all on function public.apagar_espaco(uuid) from public, authenticated;
grant execute on function public.apagar_espaco(uuid) to service_role;
-- =====================================================================
-- ORBEO · 13 · Calendário local (feriados estaduais e municipais)
-- O cálculo automático continua com o cenário nacional (feriados nacionais, Carnaval,
-- Corpus Christi e recesso de 20/12 a 20/01). Esta migração cria um catálogo de
-- feriados estaduais (27 UFs) e dos municipais das comarcas do TJBA (Decreto
-- Judiciário nº 09/2026) e transforma cada data em SUGESTÃO de suspensão para os
-- escritórios que têm processos naquele tribunal/comarca. Nada entra na contagem
-- antes de alguém do escritório confirmar.
-- Pode rodar de novo sem problema.
-- =====================================================================

create table if not exists public.calendario_local (
  id             uuid primary key default gen_random_uuid(),
  uf             char(2) not null,
  comarca        text,                 -- vazio = feriado estadual (vale para o tribunal todo)
  mes            int check (mes between 1 and 12),
  dia            int check (dia between 1 and 31),
  pascoa_offset  int,                  -- feriado móvel: dias após a Páscoa
  motivo         text not null,
  base_legal     text,
  link           text,
  tribunais      text[] not null,      -- siglas alcançadas (ex.: {TJBA,TRT5})
  instancia      text not null default 'todas' check (instancia in ('todas','1g','2g')),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  check ((mes is not null and dia is not null) or pascoa_offset is not null)
);
create unique index if not exists calendario_local_unico
  on public.calendario_local (uf, coalesce(comarca,''), coalesce(mes,0), coalesce(dia,0), coalesce(pascoa_offset,-999), motivo);
alter table public.calendario_local enable row level security;
drop policy if exists cal_ler on public.calendario_local;
create policy cal_ler on public.calendario_local for select to authenticated using (true);
grant select on public.calendario_local to authenticated;
grant all on public.calendario_local to service_role;

-- Comparação de nomes de comarca sem acento, maiúsculas, espaços ou apóstrofo
create or replace function public.sem_acento(t text) returns text
language sql immutable as $$
  select regexp_replace(lower(translate(coalesce(t,''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc')), '[^a-z0-9]', '', 'g');
$$;


-- Comarca passa a ser comparada sem acento ("Dias d'Ávila" = "DIAS DAVILA")
create or replace function public.situacao_do_dia(d date, trib text, com text, org text, inst text default '1g', esc uuid default null)
returns text language sql stable security definer set search_path = public as $$
  select case
    when bool_or(s.hora_inicio is null and s.tipo in ('recesso','ato','indisponibilidade')) then 'suspenso'
    when bool_or(s.hora_inicio is null) then 'nao_util'
    when bool_or(s.hora_inicio is not null) then 'parcial'
  end
  from suspensoes s
  where d between s.data_inicio and s.data_fim
    and (s.escritorio_id is null or s.escritorio_id = esc)
    and (s.instancia = 'todas' or s.instancia = coalesce(inst, '1g'))
    and (s.abrangencia = 'nacional'
      or (s.tribunal = trib and (
            s.abrangencia = 'tribunal'
         or (s.abrangencia = 'comarca' and public.sem_acento(com) = public.sem_acento(s.comarca))
         or (s.abrangencia = 'orgao' and public.sem_acento(com) = public.sem_acento(s.comarca)
             and coalesce(org,'') ilike '%' || s.orgao || '%'))));
$$;

-- Gera as sugestões dos próximos p_dias (padrão: 1 ano). p_escritorio limita a um escritório.
create or replace function public.gerar_sugestoes_calendario(p_dias int default 370, p_escritorio uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with uso as (
    select escritorio_id, tribunal, min(comarca) as comarca, sem_acento(comarca) as nc
      from processos
     where situacao in ('ativo','suspenso') and escritorio_id is not null and tribunal is not null
       and (p_escritorio is null or escritorio_id = p_escritorio)
     group by escritorio_id, tribunal, sem_acento(comarca)
  ),
  datas as (
    select c.id, c.uf, c.comarca, c.motivo, c.base_legal, c.link, c.tribunais, c.instancia, x.d
      from calendario_local c
     cross join generate_series(extract(year from current_date)::int, extract(year from current_date + p_dias)::int) y
     cross join lateral (select case when c.pascoa_offset is not null then pascoa(y) + c.pascoa_offset
                                     else make_date(y, c.mes, c.dia) end as d) x
     where c.ativo and x.d between current_date and current_date + p_dias and extract(isodow from x.d) < 6
  ),
  alvo as (
    select distinct on (u.escritorio_id, dt.id, dt.d, u.tribunal)
           u.escritorio_id, u.tribunal, case when dt.comarca is null then null else u.comarca end as comarca_proc,
           dt.*, dt.id::text || ':' || dt.d::text || ':' || u.tribunal as chave
      from datas dt
      join uso u on u.tribunal = any(dt.tribunais)
                and (dt.comarca is null or u.nc = sem_acento(dt.comarca))
  )
  insert into sugestoes (tipo, escritorio_id, dados, justificativa)
  select 'suspensao', a.escritorio_id,
         jsonb_strip_nulls(jsonb_build_object(
           'abrangencia', case when a.comarca is null then 'tribunal' else 'comarca' end,
           'tribunal', a.tribunal, 'comarca', a.comarca_proc, 'instancia', a.instancia,
           'data_inicio', a.d, 'data_fim', a.d, 'tipo', 'feriado', 'motivo', a.motivo,
           'numero_ato', a.base_legal, 'link_ato', a.link, 'origem', 'calendario', 'chave', a.chave)),
         case when a.comarca is null then
           format('Feriado estadual (%s) do calendário do Orbeo. Antes de confirmar, verifique se o %s suspendeu o expediente e os prazos nesta data; em geral consta do calendário anual do tribunal.', a.uf, a.tribunal)
         else
           format('Feriado municipal da comarca de %s, da relação publicada pelo TJBA no Decreto Judiciário nº 09/2026.%s', a.comarca_proc,
                  case when extract(year from a.d) > 2026 then format(' Para %s, confira se o decreto do ano manteve a data.', extract(year from a.d)) else '' end)
         end
    from alvo a
   where not exists (select 1 from sugestoes g where g.escritorio_id = a.escritorio_id and g.tipo = 'suspensao'
                       and g.dados->>'chave' = a.chave)
     and not exists (select 1 from suspensoes s
                      where a.d between s.data_inicio and s.data_fim and s.hora_inicio is null
                        and (s.escritorio_id is null or s.escritorio_id = a.escritorio_id)
                        and (s.abrangencia = 'nacional'
                          or (s.tribunal = a.tribunal and (s.abrangencia = 'tribunal'
                              or (a.comarca is not null and s.abrangencia = 'comarca'
                                  and sem_acento(s.comarca) = sem_acento(a.comarca_proc))))));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.gerar_sugestoes_calendario(int, uuid) from public, anon, authenticated;

-- Processo novo em tribunal/comarca nova → sugestões na hora, só para aquele escritório
create or replace function public.tg_processo_calendario()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.escritorio_id is not null and new.tribunal is not null
     and not exists (select 1 from processos p where p.id <> new.id and p.escritorio_id = new.escritorio_id
                       and p.tribunal = new.tribunal and sem_acento(p.comarca) = sem_acento(new.comarca)
                       and p.situacao in ('ativo','suspenso')) then
    perform public.gerar_sugestoes_calendario(370, new.escritorio_id);
  end if;
  return null;
end $$;
drop trigger if exists processo_calendario on public.processos;
create trigger processo_calendario after insert or update of tribunal, comarca on public.processos
  for each row execute function public.tg_processo_calendario();

-- Catálogo
insert into public.calendario_local (uf, comarca, mes, dia, pascoa_offset, motivo, base_legal, link, tribunais, instancia) values
('AC', null, 1, 20, null, 'Feriado estadual: Dia do Católico', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAC'], 'todas'),
('AC', null, 1, 23, null, 'Feriado estadual: Dia do Evangélico', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAC'], 'todas'),
('AC', null, 3, 8, null, 'Feriado estadual: Dia Internacional da Mulher', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAC'], 'todas'),
('AC', null, 6, 15, null, 'Feriado estadual: Aniversário do Acre', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAC'], 'todas'),
('AC', null, 9, 5, null, 'Feriado estadual: Dia da Amazônia', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAC'], 'todas'),
('AC', null, 11, 17, null, 'Feriado estadual: Tratado de Petrópolis', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAC'], 'todas'),
('AL', null, 6, 24, null, 'Feriado estadual: São João', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAL','TRT19'], 'todas'),
('AL', null, 9, 16, null, 'Feriado estadual: Emancipação Política de Alagoas', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAL','TRT19'], 'todas'),
('AL', null, 11, 30, null, 'Feriado estadual: Dia do Evangélico', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAL','TRT19'], 'todas'),
('AP', null, 3, 19, null, 'Feriado estadual: Dia de São José', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAP'], 'todas'),
('AP', null, 5, 15, null, 'Feriado estadual: Dia de Cabralzinho', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAP'], 'todas'),
('AP', null, 9, 13, null, 'Feriado estadual: Criação do Território Federal do Amapá', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAP'], 'todas'),
('AM', null, 9, 5, null, 'Feriado estadual: Elevação do Amazonas à categoria de Província', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJAM'], 'todas'),
('BA', null, 7, 2, null, 'Feriado estadual: Independência da Bahia', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJBA','TRT5'], 'todas'),
('CE', null, 3, 25, null, 'Feriado estadual: Data Magna do Ceará', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJCE','TRT7'], 'todas'),
('DF', null, 11, 30, null, 'Feriado estadual: Dia do Evangélico', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJDF','TJDFT'], 'todas'),
('ES', null, null, null, 8, 'Feriado estadual: Nossa Senhora da Penha', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJES','TRT17'], 'todas'),
('MA', null, 7, 28, null, 'Feriado estadual: Adesão do Maranhão à Independência', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJMA','TRT16'], 'todas'),
('MS', null, 10, 11, null, 'Feriado estadual: Criação do Estado de Mato Grosso do Sul', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJMS','TRT24'], 'todas'),
('PA', null, 8, 15, null, 'Feriado estadual: Adesão do Grão-Pará à Independência', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJPA'], 'todas'),
('PB', null, 8, 5, null, 'Feriado estadual: Fundação do Estado da Paraíba', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJPB','TRT13'], 'todas'),
('PE', null, 3, 6, null, 'Feriado estadual: Data Magna de Pernambuco (Revolução Pernambucana)', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJPE','TRT6'], 'todas'),
('PI', null, 10, 19, null, 'Feriado estadual: Dia do Piauí', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJPI','TRT22'], 'todas'),
('RJ', null, 4, 23, null, 'Feriado estadual: Dia de São Jorge', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJRJ','TRT1'], 'todas'),
('RN', null, 10, 3, null, 'Feriado estadual: Mártires de Cunhaú e Uruaçu', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJRN','TRT21'], 'todas'),
('RS', null, 9, 20, null, 'Feriado estadual: Revolução Farroupilha', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJRS','TRT4'], 'todas'),
('RO', null, 1, 4, null, 'Feriado estadual: Criação do Estado de Rondônia', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJRO'], 'todas'),
('RR', null, 10, 5, null, 'Feriado estadual: Criação do Estado de Roraima', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJRR'], 'todas'),
('SP', null, 7, 9, null, 'Feriado estadual: Revolução Constitucionalista', 'Lei estadual 9.497/1997', null, array['TJSP','TRT2','TRT15'], 'todas'),
('SE', null, 7, 8, null, 'Feriado estadual: Emancipação Política de Sergipe', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJSE','TRT20'], 'todas'),
('TO', null, 8, 15, null, 'Feriado estadual: Dia do Senhor do Bonfim', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJTO'], 'todas'),
('TO', null, 9, 8, null, 'Feriado estadual: Nossa Senhora da Natividade', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJTO'], 'todas'),
('TO', null, 10, 5, null, 'Feriado estadual: Criação do Estado do Tocantins', 'Lei 9.093/1995, art. 1º, II (data magna fixada em lei estadual)', null, array['TJTO'], 'todas'),
('BA', 'Alagoinhas', 6, 13, null, 'Feriado municipal de Alagoinhas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Alagoinhas', 6, 24, null, 'Feriado municipal de Alagoinhas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Alagoinhas', 11, 20, null, 'Feriado municipal de Alagoinhas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Amargosa', 4, 26, null, 'Feriado municipal de Amargosa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Amargosa', 6, 19, null, 'Feriado municipal de Amargosa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Amélia Rodrigues', 5, 31, null, 'Feriado municipal de Amélia Rodrigues', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Amélia Rodrigues', 10, 20, null, 'Feriado municipal de Amélia Rodrigues', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Anagé', 4, 5, null, 'Feriado municipal de Anagé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Anagé', 6, 24, null, 'Feriado municipal de Anagé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Andaraí', 4, 28, null, 'Feriado municipal de Andaraí', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Andaraí', 8, 15, null, 'Feriado municipal de Andaraí', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Antas', 8, 13, null, 'Feriado municipal de Antas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Araci', 3, 8, null, 'Feriado municipal de Araci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Araci', 4, 7, null, 'Feriado municipal de Araci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Araci', 6, 24, null, 'Feriado municipal de Araci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Araci', 10, 28, null, 'Feriado municipal de Araci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Araci', 12, 8, null, 'Feriado municipal de Araci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Baianópolis', 6, 21, null, 'Feriado municipal de Baianópolis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Baianópolis', 7, 30, null, 'Feriado municipal de Baianópolis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Baianópolis', 9, 10, null, 'Feriado municipal de Baianópolis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Baianópolis', 9, 30, null, 'Feriado municipal de Baianópolis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra', 6, 16, null, 'Feriado municipal de Barra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra', 7, 10, null, 'Feriado municipal de Barra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra', 10, 4, null, 'Feriado municipal de Barra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra da Estiva', 7, 15, null, 'Feriado municipal de Barra da Estiva', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra da Estiva', 8, 6, null, 'Feriado municipal de Barra da Estiva', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra do Choça', 6, 22, null, 'Feriado municipal de Barra do Choça', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra do Choça', 11, 20, null, 'Feriado municipal de Barra do Choça', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra do Mendes', 6, 23, null, 'Feriado municipal de Barra do Mendes', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra do Mendes', 6, 24, null, 'Feriado municipal de Barra do Mendes', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra do Mendes', 8, 14, null, 'Feriado municipal de Barra do Mendes', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barra do Mendes', 12, 8, null, 'Feriado municipal de Barra do Mendes', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barreiras', 5, 26, null, 'Feriado municipal de Barreiras', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barreiras', 6, 24, null, 'Feriado municipal de Barreiras', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Barreiras', 8, 2, null, 'Feriado municipal de Barreiras', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Belmonte', 1, 20, null, 'Feriado municipal de Belmonte', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Belmonte', 5, 23, null, 'Feriado municipal de Belmonte', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Belmonte', 7, 16, null, 'Feriado municipal de Belmonte', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Belmonte', 7, 19, null, 'Feriado municipal de Belmonte', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Belo Campo', 1, 20, null, 'Feriado municipal de Belo Campo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Belo Campo', 2, 22, null, 'Feriado municipal de Belo Campo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Belo Campo', 6, 24, null, 'Feriado municipal de Belo Campo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Bom Jesus da Lapa', 8, 6, null, 'Feriado municipal de Bom Jesus da Lapa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Bom Jesus da Lapa', 8, 31, null, 'Feriado municipal de Bom Jesus da Lapa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Bom Jesus da Lapa', 9, 15, null, 'Feriado municipal de Bom Jesus da Lapa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Brumado', 1, 20, null, 'Feriado municipal de Brumado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Brumado', 6, 11, null, 'Feriado municipal de Brumado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Brumado', 6, 24, null, 'Feriado municipal de Brumado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Brumado', 8, 6, null, 'Feriado municipal de Brumado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Buerarema', 7, 26, null, 'Feriado municipal de Buerarema', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Buerarema', 9, 17, null, 'Feriado municipal de Buerarema', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Buerarema', 10, 30, null, 'Feriado municipal de Buerarema', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cachoeira', 3, 13, null, 'Feriado municipal de Cachoeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cachoeira', 6, 25, null, 'Feriado municipal de Cachoeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cachoeira', 8, 15, null, 'Feriado municipal de Cachoeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cachoeira', 10, 7, null, 'Feriado municipal de Cachoeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cachoeira', 12, 8, null, 'Feriado municipal de Cachoeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caculé', 6, 24, null, 'Feriado municipal de Caculé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caculé', 8, 14, null, 'Feriado municipal de Caculé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caculé', 9, 8, null, 'Feriado municipal de Caculé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caculé', 11, 6, null, 'Feriado municipal de Caculé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caculé', 11, 20, null, 'Feriado municipal de Caculé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caetité', 4, 5, null, 'Feriado municipal de Caetité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caetité', 7, 12, null, 'Feriado municipal de Caetité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caetité', 7, 26, null, 'Feriado municipal de Caetité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caetité', 11, 20, null, 'Feriado municipal de Caetité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camacan', 1, 20, null, 'Feriado municipal de Camacan', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camacan', 8, 31, null, 'Feriado municipal de Camacan', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camaçari', 1, 7, null, 'Feriado municipal de Camaçari', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camaçari', 9, 28, null, 'Feriado municipal de Camaçari', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camamu', 6, 27, null, 'Feriado municipal de Camamu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camamu', 8, 15, null, 'Feriado municipal de Camamu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camamu', 9, 17, null, 'Feriado municipal de Camamu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camamu', 10, 26, null, 'Feriado municipal de Camamu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Camamu', 12, 31, null, 'Feriado municipal de Camamu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Canarana', 7, 16, null, 'Feriado municipal de Canarana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Canarana', 8, 15, null, 'Feriado municipal de Canarana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Canarana', 9, 23, null, 'Feriado municipal de Canarana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Canavieiras', 1, 20, null, 'Feriado municipal de Canavieiras', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Canavieiras', 5, 25, null, 'Feriado municipal de Canavieiras', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Canavieiras', 7, 14, null, 'Feriado municipal de Canavieiras', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Candeias', 6, 24, null, 'Feriado municipal de Candeias', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Candeias', 2, 2, null, 'Feriado municipal de Candeias', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Candeias', 8, 14, null, 'Feriado municipal de Candeias', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cândido Sales', 6, 5, null, 'Feriado municipal de Cândido Sales', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cândido Sales', 7, 5, null, 'Feriado municipal de Cândido Sales', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cândido Sales', 11, 27, null, 'Feriado municipal de Cândido Sales', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cansanção', 7, 26, null, 'Feriado municipal de Cansanção', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cansanção', 9, 23, null, 'Feriado municipal de Cansanção', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capela do Alto Alegre', 3, 19, null, 'Feriado municipal de Capela do Alto Alegre', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capela do Alto Alegre', 4, 17, null, 'Feriado municipal de Capela do Alto Alegre', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capela do Alto Alegre', 6, 13, null, 'Feriado municipal de Capela do Alto Alegre', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capela do Alto Alegre', 9, 23, null, 'Feriado municipal de Capela do Alto Alegre', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capim Grosso', 5, 9, null, 'Feriado municipal de Capim Grosso', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capim Grosso', 6, 25, null, 'Feriado municipal de Capim Grosso', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capim Grosso', 7, 25, null, 'Feriado municipal de Capim Grosso', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Capim Grosso', 12, 8, null, 'Feriado municipal de Capim Grosso', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caravelas', 4, 23, null, 'Feriado municipal de Caravelas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caravelas', 6, 13, null, 'Feriado municipal de Caravelas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caravelas', 11, 3, null, 'Feriado municipal de Caravelas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Caravelas', 11, 30, null, 'Feriado municipal de Caravelas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Carinhanha', 3, 8, null, 'Feriado municipal de Carinhanha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Carinhanha', 6, 24, null, 'Feriado municipal de Carinhanha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Carinhanha', 8, 17, null, 'Feriado municipal de Carinhanha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Carinhanha', 11, 20, null, 'Feriado municipal de Carinhanha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Casa Nova', 6, 20, null, 'Feriado municipal de Casa Nova', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Castro Alves', 3, 14, null, 'Feriado municipal de Castro Alves', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Castro Alves', 6, 26, null, 'Feriado municipal de Castro Alves', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Castro Alves', 10, 30, null, 'Feriado municipal de Castro Alves', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Castro Alves', 12, 8, null, 'Feriado municipal de Castro Alves', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Catu', 6, 24, null, 'Feriado municipal de Catu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Catu', 6, 26, null, 'Feriado municipal de Catu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Catu', 7, 26, null, 'Feriado municipal de Catu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Central', 5, 6, null, 'Feriado municipal de Central', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Central', 8, 12, null, 'Feriado municipal de Central', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Central', 10, 1, null, 'Feriado municipal de Central', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Chorrochó', 9, 12, null, 'Feriado municipal de Chorrochó', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cícero Dantas', 6, 9, null, 'Feriado municipal de Cícero Dantas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cícero Dantas', 8, 15, null, 'Feriado municipal de Cícero Dantas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cícero Dantas', 9, 15, null, 'Feriado municipal de Cícero Dantas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cipó', 6, 12, null, 'Feriado municipal de Cipó', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cipó', 7, 8, null, 'Feriado municipal de Cipó', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cipó', 9, 8, null, 'Feriado municipal de Cipó', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cipó', 12, 4, null, 'Feriado municipal de Cipó', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coaraci', 2, 11, null, 'Feriado municipal de Coaraci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coaraci', 12, 12, null, 'Feriado municipal de Coaraci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cocos', 5, 27, null, 'Feriado municipal de Cocos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cocos', 10, 28, null, 'Feriado municipal de Cocos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Almeida', 7, 18, null, 'Feriado municipal de Conceição do Almeida', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Almeida', 11, 20, null, 'Feriado municipal de Conceição do Almeida', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Coité', 6, 24, null, 'Feriado municipal de Conceição do Coité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Coité', 7, 7, null, 'Feriado municipal de Conceição do Coité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Coité', 8, 16, null, 'Feriado municipal de Conceição do Coité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Coité', 9, 23, null, 'Feriado municipal de Conceição do Coité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Coité', 12, 8, null, 'Feriado municipal de Conceição do Coité', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Jacuípe', 6, 24, null, 'Feriado municipal de Conceição do Jacuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Jacuípe', 10, 20, null, 'Feriado municipal de Conceição do Jacuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conceição do Jacuípe', 12, 8, null, 'Feriado municipal de Conceição do Jacuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conde', 8, 10, null, 'Feriado municipal de Conde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Conde', 9, 8, null, 'Feriado municipal de Conde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Condeúba', 5, 14, null, 'Feriado municipal de Condeúba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Condeúba', 6, 13, null, 'Feriado municipal de Condeúba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Condeúba', 8, 6, null, 'Feriado municipal de Condeúba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coração de Maria', 6, 1, null, 'Feriado municipal de Coração de Maria', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coração de Maria', 6, 29, null, 'Feriado municipal de Coração de Maria', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coração de Maria', 8, 22, null, 'Feriado municipal de Coração de Maria', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coribe', 6, 23, null, 'Feriado municipal de Coribe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coribe', 6, 24, null, 'Feriado municipal de Coribe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coribe', 6, 25, null, 'Feriado municipal de Coribe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coribe', 8, 14, null, 'Feriado municipal de Coribe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Coribe', 9, 27, null, 'Feriado municipal de Coribe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Correntina', 3, 30, null, 'Feriado municipal de Correntina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Correntina', 8, 15, null, 'Feriado municipal de Correntina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Correntina', 9, 1, null, 'Feriado municipal de Correntina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cotegipe', 5, 3, null, 'Feriado municipal de Cotegipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cotegipe', 6, 30, null, 'Feriado municipal de Cotegipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cotegipe', 9, 30, null, 'Feriado municipal de Cotegipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cotegipe', 11, 20, null, 'Feriado municipal de Cotegipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cruz das Almas', 7, 29, null, 'Feriado municipal de Cruz das Almas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cruz das Almas', 9, 15, null, 'Feriado municipal de Cruz das Almas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Cruz das Almas', 11, 20, null, 'Feriado municipal de Cruz das Almas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Curaçá', 6, 24, null, 'Feriado municipal de Curaçá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Curaçá', 7, 6, null, 'Feriado municipal de Curaçá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Curaçá', 11, 1, null, 'Feriado municipal de Curaçá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Curaçá', 12, 31, null, 'Feriado municipal de Curaçá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Dias d''Ávila', 2, 25, null, 'Feriado municipal de Dias d''Ávila', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Dias d''Ávila', 6, 24, null, 'Feriado municipal de Dias d''Ávila', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Dias d''Ávila', 8, 15, null, 'Feriado municipal de Dias d''Ávila', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Dias d''Ávila', 11, 20, null, 'Feriado municipal de Dias d''Ávila', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Encruzilhada', 5, 31, null, 'Feriado municipal de Encruzilhada', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Encruzilhada', 12, 4, null, 'Feriado municipal de Encruzilhada', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Encruzilhada', 12, 12, null, 'Feriado municipal de Encruzilhada', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Entre Rios', 4, 3, null, 'Feriado municipal de Entre Rios', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Entre Rios', 8, 15, null, 'Feriado municipal de Entre Rios', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Euclides da Cunha', 6, 24, null, 'Feriado municipal de Euclides da Cunha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Euclides da Cunha', 9, 19, null, 'Feriado municipal de Euclides da Cunha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Euclides da Cunha', 12, 8, null, 'Feriado municipal de Euclides da Cunha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Eunápolis', 5, 12, null, 'Feriado municipal de Eunápolis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Eunápolis', 5, 24, null, 'Feriado municipal de Eunápolis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Feira de Santana', 6, 24, null, 'Feriado municipal de Feira de Santana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Feira de Santana', 7, 26, null, 'Feriado municipal de Feira de Santana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Formosa do Rio Preto', 12, 22, null, 'Feriado municipal de Formosa do Rio Preto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gandu', 3, 19, null, 'Feriado municipal de Gandu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gandu', 6, 24, null, 'Feriado municipal de Gandu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gandu', 7, 28, null, 'Feriado municipal de Gandu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gandu', 8, 16, null, 'Feriado municipal de Gandu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gentio do Ouro', 6, 24, null, 'Feriado municipal de Gentio do Ouro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gentio do Ouro', 7, 9, null, 'Feriado municipal de Gentio do Ouro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gentio do Ouro', 8, 14, null, 'Feriado municipal de Gentio do Ouro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Gentio do Ouro', 10, 25, null, 'Feriado municipal de Gentio do Ouro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Governador Mangabeira', 3, 14, null, 'Feriado municipal de Governador Mangabeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Governador Mangabeira', 8, 27, null, 'Feriado municipal de Governador Mangabeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Governador Mangabeira', 11, 20, null, 'Feriado municipal de Governador Mangabeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Governador Mangabeira', 12, 8, null, 'Feriado municipal de Governador Mangabeira', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Guanambi', 6, 13, null, 'Feriado municipal de Guanambi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Guanambi', 8, 14, null, 'Feriado municipal de Guanambi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Guaratinga', 8, 31, null, 'Feriado municipal de Guaratinga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Guaratinga', 12, 8, null, 'Feriado municipal de Guaratinga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iaçu', 8, 14, null, 'Feriado municipal de Iaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iaçu', 9, 25, null, 'Feriado municipal de Iaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iaçu', 12, 13, null, 'Feriado municipal de Iaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ibicaraí', 2, 2, null, 'Feriado municipal de Ibicaraí', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ibicaraí', 10, 22, null, 'Feriado municipal de Ibicaraí', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ibirataia', 3, 19, null, 'Feriado municipal de Ibirataia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ibirataia', 6, 13, null, 'Feriado municipal de Ibirataia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ibirataia', 6, 24, null, 'Feriado municipal de Ibirataia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ibirataia', 11, 10, null, 'Feriado municipal de Ibirataia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ibotirama', 8, 14, null, 'Feriado municipal de Ibotirama', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Igaporã', 9, 1, null, 'Feriado municipal de Igaporã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Igaporã', 9, 8, null, 'Feriado municipal de Igaporã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Igaporã', 8, 31, null, 'Feriado municipal de Igaporã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iguaí', 6, 24, null, 'Feriado municipal de Iguaí', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iguaí', 10, 28, null, 'Feriado municipal de Iguaí', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iguaí', 12, 12, null, 'Feriado municipal de Iguaí', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ilhéus', 4, 23, null, 'Feriado municipal de Ilhéus', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ilhéus', 6, 24, null, 'Feriado municipal de Ilhéus', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ilhéus', 6, 28, null, 'Feriado municipal de Ilhéus', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ilhéus', 8, 15, null, 'Feriado municipal de Ilhéus', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Inhambupe', 3, 8, null, 'Feriado municipal de Inhambupe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Inhambupe', 8, 6, null, 'Feriado municipal de Inhambupe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Inhambupe', 11, 20, null, 'Feriado municipal de Inhambupe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Inhambupe', 12, 8, null, 'Feriado municipal de Inhambupe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ipiaú', 8, 16, null, 'Feriado municipal de Ipiaú', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ipiaú', 11, 2, null, 'Feriado municipal de Ipiaú', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ipiaú', 12, 2, null, 'Feriado municipal de Ipiaú', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ipirá', 4, 20, null, 'Feriado municipal de Ipirá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ipirá', 6, 24, null, 'Feriado municipal de Ipirá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ipirá', 7, 26, null, 'Feriado municipal de Ipirá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iraquara', 7, 5, null, 'Feriado municipal de Iraquara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Iraquara', 9, 8, null, 'Feriado municipal de Iraquara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Irará', 2, 2, null, 'Feriado municipal de Irará', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Irará', 5, 27, null, 'Feriado municipal de Irará', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Irará', 9, 23, null, 'Feriado municipal de Irará', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Irará', 12, 8, null, 'Feriado municipal de Irará', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Irecê', 8, 2, null, 'Feriado municipal de Irecê', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itabela', 6, 14, null, 'Feriado municipal de Itabela', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itabela', 6, 24, null, 'Feriado municipal de Itabela', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itaberaba', 3, 26, null, 'Feriado municipal de Itaberaba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itabuna', 6, 24, null, 'Feriado municipal de Itabuna', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itabuna', 3, 19, null, 'Feriado municipal de Itabuna', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itabuna', 7, 28, null, 'Feriado municipal de Itabuna', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itabuna', 10, 30, null, 'Feriado municipal de Itabuna', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itacaré', 1, 26, null, 'Feriado municipal de Itacaré', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itacaré', 9, 29, null, 'Feriado municipal de Itacaré', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itagibá', 7, 6, null, 'Feriado municipal de Itagibá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itagibá', 8, 14, null, 'Feriado municipal de Itagibá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itajuípe', 10, 30, null, 'Feriado municipal de Itajuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itajuípe', 12, 12, null, 'Feriado municipal de Itajuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itamaraju', 9, 26, null, 'Feriado municipal de Itamaraju', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itamaraju', 10, 5, null, 'Feriado municipal de Itamaraju', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itambé', 1, 20, null, 'Feriado municipal de Itambé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itambé', 8, 12, null, 'Feriado municipal de Itambé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itambé', 11, 2, null, 'Feriado municipal de Itambé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itanhém', 6, 24, null, 'Feriado municipal de Itanhém', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itanhém', 8, 14, null, 'Feriado municipal de Itanhém', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itanhém', 8, 15, null, 'Feriado municipal de Itanhém', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itaparica', 7, 31, null, 'Feriado municipal de Itaparica', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itaparica', 9, 14, null, 'Feriado municipal de Itaparica', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itaparica', 11, 20, null, 'Feriado municipal de Itaparica', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itapetinga', 3, 19, null, 'Feriado municipal de Itapetinga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itapetinga', 12, 12, null, 'Feriado municipal de Itapetinga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itapicuru', 4, 28, null, 'Feriado municipal de Itapicuru', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itapicuru', 6, 24, null, 'Feriado municipal de Itapicuru', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itarantim', 5, 20, null, 'Feriado municipal de Itarantim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itarantim', 6, 13, null, 'Feriado municipal de Itarantim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itarantim', 6, 15, null, 'Feriado municipal de Itarantim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Itarantim', 6, 24, null, 'Feriado municipal de Itarantim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituaçu', 6, 24, null, 'Feriado municipal de Ituaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituaçu', 8, 15, null, 'Feriado municipal de Ituaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituaçu', 8, 26, null, 'Feriado municipal de Ituaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituaçu', 9, 3, null, 'Feriado municipal de Ituaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituberá', 6, 24, null, 'Feriado municipal de Ituberá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituberá', 8, 14, null, 'Feriado municipal de Ituberá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituberá', 11, 30, null, 'Feriado municipal de Ituberá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ituberá', 12, 8, null, 'Feriado municipal de Ituberá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jacaraci', 6, 7, null, 'Feriado municipal de Jacaraci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jacaraci', 9, 8, null, 'Feriado municipal de Jacaraci', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jacobina', 6, 13, null, 'Feriado municipal de Jacobina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jacobina', 6, 24, null, 'Feriado municipal de Jacobina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jacobina', 12, 8, null, 'Feriado municipal de Jacobina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jaguaquara', 5, 18, null, 'Feriado municipal de Jaguaquara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jaguaquara', 5, 24, null, 'Feriado municipal de Jaguaquara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jaguarari', 6, 24, null, 'Feriado municipal de Jaguarari', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jaguarari', 8, 6, null, 'Feriado municipal de Jaguarari', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jequié', 6, 13, null, 'Feriado municipal de Jequié', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jequié', 8, 20, null, 'Feriado municipal de Jequié', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jequié', 10, 25, null, 'Feriado municipal de Jequié', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jeremoabo', 7, 6, null, 'Feriado municipal de Jeremoabo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jitaúna', 9, 23, null, 'Feriado municipal de Jitaúna', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Jitaúna', 12, 22, null, 'Feriado municipal de Jitaúna', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'João Dourado', 3, 19, null, 'Feriado municipal de João Dourado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'João Dourado', 5, 9, null, 'Feriado municipal de João Dourado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'João Dourado', 10, 31, null, 'Feriado municipal de João Dourado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Juazeiro', 7, 15, null, 'Feriado municipal de Juazeiro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Juazeiro', 9, 8, null, 'Feriado municipal de Juazeiro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Laje', 5, 20, null, 'Feriado municipal de Laje', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lapão', 5, 9, null, 'Feriado municipal de Lapão', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lauro de Freitas', 1, 15, null, 'Feriado municipal de Lauro de Freitas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lauro de Freitas', 6, 24, null, 'Feriado municipal de Lauro de Freitas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lauro de Freitas', 7, 31, null, 'Feriado municipal de Lauro de Freitas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lençóis', 2, 2, null, 'Feriado municipal de Lençóis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lençóis', 6, 24, null, 'Feriado municipal de Lençóis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lençóis', 12, 8, null, 'Feriado municipal de Lençóis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Lençóis', 12, 18, null, 'Feriado municipal de Lençóis', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Livramento de Nossa Senhora', 1, 28, null, 'Feriado municipal de Livramento de Nossa Senhora', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Livramento de Nossa Senhora', 8, 6, null, 'Feriado municipal de Livramento de Nossa Senhora', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Livramento de Nossa Senhora', 8, 15, null, 'Feriado municipal de Livramento de Nossa Senhora', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Livramento de Nossa Senhora', 10, 6, null, 'Feriado municipal de Livramento de Nossa Senhora', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Luís Eduardo Magalhães', 3, 30, null, 'Feriado municipal de Luís Eduardo Magalhães', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Luís Eduardo Magalhães', 6, 24, null, 'Feriado municipal de Luís Eduardo Magalhães', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Luís Eduardo Magalhães', 8, 2, null, 'Feriado municipal de Luís Eduardo Magalhães', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Macarani', 4, 3, null, 'Feriado municipal de Macarani', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Macarani', 6, 29, null, 'Feriado municipal de Macarani', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Macarani', 8, 18, null, 'Feriado municipal de Macarani', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Macaúbas', 6, 24, null, 'Feriado municipal de Macaúbas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Macaúbas', 6, 25, null, 'Feriado municipal de Macaúbas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Macaúbas', 7, 6, null, 'Feriado municipal de Macaúbas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Macaúbas', 12, 8, null, 'Feriado municipal de Macaúbas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mairi', 8, 5, null, 'Feriado municipal de Mairi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mairi', 9, 15, null, 'Feriado municipal de Mairi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mairi', 10, 31, null, 'Feriado municipal de Mairi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mairi', 11, 20, null, 'Feriado municipal de Mairi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Maracás', 4, 19, null, 'Feriado municipal de Maracás', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Maracás', 10, 31, null, 'Feriado municipal de Maracás', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Maracás', 11, 27, null, 'Feriado municipal de Maracás', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Maragojipe', 5, 8, null, 'Feriado municipal de Maragojipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Maragojipe', 11, 20, null, 'Feriado municipal de Maragojipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mata de São João', 4, 15, null, 'Feriado municipal de Mata de São João', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mata de São João', 6, 24, null, 'Feriado municipal de Mata de São João', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Medeiros Neto', 8, 14, null, 'Feriado municipal de Medeiros Neto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Medeiros Neto', 12, 8, null, 'Feriado municipal de Medeiros Neto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Miguel Calmon', 6, 24, null, 'Feriado municipal de Miguel Calmon', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Miguel Calmon', 8, 6, null, 'Feriado municipal de Miguel Calmon', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Miguel Calmon', 10, 31, null, 'Feriado municipal de Miguel Calmon', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Miguel Calmon', 12, 8, null, 'Feriado municipal de Miguel Calmon', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Monte Santo', 9, 14, null, 'Feriado municipal de Monte Santo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Monte Santo', 10, 1, null, 'Feriado municipal de Monte Santo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Monte Santo', 10, 31, null, 'Feriado municipal de Monte Santo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Monte Santo', 11, 1, null, 'Feriado municipal de Monte Santo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Morro do Chapéu', 8, 8, null, 'Feriado municipal de Morro do Chapéu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Morro do Chapéu', 9, 8, null, 'Feriado municipal de Morro do Chapéu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Morro do Chapéu', 10, 23, null, 'Feriado municipal de Morro do Chapéu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mucuri', 3, 19, null, 'Feriado municipal de Mucuri', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mucuri', 6, 29, null, 'Feriado municipal de Mucuri', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mucuri', 10, 10, null, 'Feriado municipal de Mucuri', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mucuri', 11, 30, null, 'Feriado municipal de Mucuri', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mundo Novo', 3, 1, null, 'Feriado municipal de Mundo Novo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mundo Novo', 9, 23, null, 'Feriado municipal de Mundo Novo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mundo Novo', 10, 10, null, 'Feriado municipal de Mundo Novo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mundo Novo', 12, 8, null, 'Feriado municipal de Mundo Novo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Muritiba', 6, 29, null, 'Feriado municipal de Muritiba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Muritiba', 8, 8, null, 'Feriado municipal de Muritiba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mutuípe', 6, 13, null, 'Feriado municipal de Mutuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mutuípe', 8, 16, null, 'Feriado municipal de Mutuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Mutuípe', 10, 31, null, 'Feriado municipal de Mutuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nazaré', 2, 2, null, 'Feriado municipal de Nazaré', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nazaré', 6, 24, null, 'Feriado municipal de Nazaré', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nazaré', 8, 16, null, 'Feriado municipal de Nazaré', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nazaré', 11, 10, null, 'Feriado municipal de Nazaré', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nova Soure', 5, 3, null, 'Feriado municipal de Nova Soure', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nova Soure', 6, 1, null, 'Feriado municipal de Nova Soure', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nova Soure', 6, 24, null, 'Feriado municipal de Nova Soure', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nova Soure', 12, 8, null, 'Feriado municipal de Nova Soure', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nova Viçosa', 10, 23, null, 'Feriado municipal de Nova Viçosa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Nova Viçosa', 11, 30, null, 'Feriado municipal de Nova Viçosa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Olindina', 8, 14, null, 'Feriado municipal de Olindina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Olindina', 12, 8, null, 'Feriado municipal de Olindina', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Oliveira dos Brejinhos', 5, 3, null, 'Feriado municipal de Oliveira dos Brejinhos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Oliveira dos Brejinhos', 9, 8, null, 'Feriado municipal de Oliveira dos Brejinhos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Oliveira dos Brejinhos', 9, 10, null, 'Feriado municipal de Oliveira dos Brejinhos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Palmas de Monte Alto', 5, 19, null, 'Feriado municipal de Palmas de Monte Alto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Palmas de Monte Alto', 9, 8, null, 'Feriado municipal de Palmas de Monte Alto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paramirim', 2, 2, null, 'Feriado municipal de Paramirim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paramirim', 6, 13, null, 'Feriado municipal de Paramirim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paramirim', 9, 15, null, 'Feriado municipal de Paramirim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paramirim', 9, 16, null, 'Feriado municipal de Paramirim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paripiranga', 6, 29, null, 'Feriado municipal de Paripiranga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paripiranga', 11, 30, null, 'Feriado municipal de Paripiranga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paripiranga', 12, 8, null, 'Feriado municipal de Paripiranga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paulo Afonso', 6, 24, null, 'Feriado municipal de Paulo Afonso', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paulo Afonso', 7, 28, null, 'Feriado municipal de Paulo Afonso', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Paulo Afonso', 10, 4, null, 'Feriado municipal de Paulo Afonso', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piatã', 7, 11, null, 'Feriado municipal de Piatã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piatã', 10, 7, null, 'Feriado municipal de Piatã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piatã', 10, 31, null, 'Feriado municipal de Piatã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piatã', 11, 20, null, 'Feriado municipal de Piatã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Pilão Arcado', 6, 13, null, 'Feriado municipal de Pilão Arcado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Pilão Arcado', 12, 30, null, 'Feriado municipal de Pilão Arcado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Pindobaçu', 10, 20, null, 'Feriado municipal de Pindobaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piritiba', 6, 24, null, 'Feriado municipal de Piritiba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piritiba', 8, 6, null, 'Feriado municipal de Piritiba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piritiba', 9, 27, null, 'Feriado municipal de Piritiba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Piritiba', 10, 31, null, 'Feriado municipal de Piritiba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Planalto', 4, 5, null, 'Feriado municipal de Planalto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Planalto', 5, 22, null, 'Feriado municipal de Planalto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Planalto', 6, 24, null, 'Feriado municipal de Planalto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Planalto', 11, 20, null, 'Feriado municipal de Planalto', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Poções', 6, 26, null, 'Feriado municipal de Poções', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Poções', 11, 20, null, 'Feriado municipal de Poções', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Pojuca', 1, 25, null, 'Feriado municipal de Pojuca', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Pojuca', 7, 29, null, 'Feriado municipal de Pojuca', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Porto Seguro', 4, 22, null, 'Feriado municipal de Porto Seguro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Porto Seguro', 6, 30, null, 'Feriado municipal de Porto Seguro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Porto Seguro', 8, 15, null, 'Feriado municipal de Porto Seguro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Porto Seguro', 9, 8, null, 'Feriado municipal de Porto Seguro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Prado', 2, 2, null, 'Feriado municipal de Prado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Prado', 8, 2, null, 'Feriado municipal de Prado', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Queimadas', 6, 13, null, 'Feriado municipal de Queimadas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Queimadas', 6, 20, null, 'Feriado municipal de Queimadas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Queimadas', 9, 23, null, 'Feriado municipal de Queimadas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Retirolândia', 3, 8, null, 'Feriado municipal de Retirolândia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Retirolândia', 6, 13, null, 'Feriado municipal de Retirolândia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Retirolândia', 7, 27, null, 'Feriado municipal de Retirolândia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Retirolândia', 9, 23, null, 'Feriado municipal de Retirolândia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riachão das Neves', 7, 19, null, 'Feriado municipal de Riachão das Neves', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riachão das Neves', 7, 26, null, 'Feriado municipal de Riachão das Neves', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riachão das Neves', 9, 20, null, 'Feriado municipal de Riachão das Neves', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riachão do Jacuípe', 6, 24, null, 'Feriado municipal de Riachão do Jacuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riachão do Jacuípe', 8, 16, null, 'Feriado municipal de Riachão do Jacuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riachão do Jacuípe', 12, 8, null, 'Feriado municipal de Riachão do Jacuípe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riacho de Santana', 5, 31, null, 'Feriado municipal de Riacho de Santana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Riacho de Santana', 8, 13, null, 'Feriado municipal de Riacho de Santana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ribeira do Pombal', 6, 24, null, 'Feriado municipal de Ribeira do Pombal', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ribeira do Pombal', 9, 19, null, 'Feriado municipal de Ribeira do Pombal', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ribeira do Pombal', 10, 15, null, 'Feriado municipal de Ribeira do Pombal', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Rio Real', 1, 6, null, 'Feriado municipal de Rio Real', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Rio Real', 7, 1, null, 'Feriado municipal de Rio Real', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Rio Real', 9, 8, null, 'Feriado municipal de Rio Real', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ruy Barbosa', 6, 13, null, 'Feriado municipal de Ruy Barbosa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ruy Barbosa', 8, 28, null, 'Feriado municipal de Ruy Barbosa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ruy Barbosa', 10, 31, null, 'Feriado municipal de Ruy Barbosa', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Salvador', 6, 24, null, 'Feriado municipal de Salvador', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Salvador', 12, 8, null, 'Feriado municipal de Salvador', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Bárbara', 8, 30, null, 'Feriado municipal de Santa Bárbara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Bárbara', 9, 23, null, 'Feriado municipal de Santa Bárbara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Bárbara', 12, 4, null, 'Feriado municipal de Santa Bárbara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Bárbara', 12, 14, null, 'Feriado municipal de Santa Bárbara', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Cruz Cabrália', 4, 19, null, 'Feriado municipal de Santa Cruz Cabrália', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Cruz Cabrália', 4, 26, null, 'Feriado municipal de Santa Cruz Cabrália', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Cruz Cabrália', 6, 29, null, 'Feriado municipal de Santa Cruz Cabrália', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Cruz Cabrália', 7, 23, null, 'Feriado municipal de Santa Cruz Cabrália', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Cruz Cabrália', 12, 8, null, 'Feriado municipal de Santa Cruz Cabrália', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Inês', 1, 21, null, 'Feriado municipal de Santa Inês', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Inês', 9, 30, null, 'Feriado municipal de Santa Inês', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Inês', 10, 26, null, 'Feriado municipal de Santa Inês', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Maria da Vitória', 6, 26, null, 'Feriado municipal de Santa Maria da Vitória', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Maria da Vitória', 9, 8, null, 'Feriado municipal de Santa Maria da Vitória', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Maria da Vitória', 10, 20, null, 'Feriado municipal de Santa Maria da Vitória', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Rita de Cássia', 3, 26, null, 'Feriado municipal de Santa Rita de Cássia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Rita de Cássia', 5, 22, null, 'Feriado municipal de Santa Rita de Cássia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Rita de Cássia', 8, 2, null, 'Feriado municipal de Santa Rita de Cássia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Rita de Cássia', 11, 1, null, 'Feriado municipal de Santa Rita de Cássia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Terezinha', 10, 1, null, 'Feriado municipal de Santa Terezinha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Terezinha', 10, 19, null, 'Feriado municipal de Santa Terezinha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santa Terezinha', 12, 8, null, 'Feriado municipal de Santa Terezinha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santaluz', 7, 18, null, 'Feriado municipal de Santaluz', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santaluz', 9, 23, null, 'Feriado municipal de Santaluz', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santaluz', 12, 13, null, 'Feriado municipal de Santaluz', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santana', 7, 26, null, 'Feriado municipal de Santana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santana', 12, 16, null, 'Feriado municipal de Santana', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santo Amaro', 1, 15, null, 'Feriado municipal de Santo Amaro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santo Amaro', 2, 2, null, 'Feriado municipal de Santo Amaro', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santo Antônio de Jesus', 5, 29, null, 'Feriado municipal de Santo Antônio de Jesus', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santo Antônio de Jesus', 6, 13, null, 'Feriado municipal de Santo Antônio de Jesus', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santo Antônio de Jesus', 6, 24, null, 'Feriado municipal de Santo Antônio de Jesus', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santo Estevão', 9, 21, null, 'Feriado municipal de Santo Estevão', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Santo Estevão', 12, 26, null, 'Feriado municipal de Santo Estevão', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Sapeaçu', 4, 27, null, 'Feriado municipal de Sapeaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Desidério', 2, 22, null, 'Feriado municipal de São Desidério', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Desidério', 8, 2, null, 'Feriado municipal de São Desidério', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Desidério', 9, 20, null, 'Feriado municipal de São Desidério', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Felipe', 5, 3, null, 'Feriado municipal de São Felipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Felipe', 5, 29, null, 'Feriado municipal de São Felipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Felipe', 11, 20, null, 'Feriado municipal de São Felipe', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Félix', 5, 18, null, 'Feriado municipal de São Félix', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Félix', 6, 25, null, 'Feriado municipal de São Félix', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Félix', 10, 25, null, 'Feriado municipal de São Félix', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Félix', 11, 2, null, 'Feriado municipal de São Félix', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Félix', 11, 20, null, 'Feriado municipal de São Félix', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Francisco do Conde', 1, 28, null, 'Feriado municipal de São Francisco do Conde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Francisco do Conde', 6, 29, null, 'Feriado municipal de São Francisco do Conde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Francisco do Conde', 10, 4, null, 'Feriado municipal de São Francisco do Conde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Gonçalo dos Campos', 1, 10, null, 'Feriado municipal de São Gonçalo dos Campos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Gonçalo dos Campos', 7, 28, null, 'Feriado municipal de São Gonçalo dos Campos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Gonçalo dos Campos', 9, 30, null, 'Feriado municipal de São Gonçalo dos Campos', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Sebastião do Passé', 1, 20, null, 'Feriado municipal de São Sebastião do Passé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Sebastião do Passé', 6, 24, null, 'Feriado municipal de São Sebastião do Passé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Sebastião do Passé', 8, 16, null, 'Feriado municipal de São Sebastião do Passé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'São Sebastião do Passé', 10, 12, null, 'Feriado municipal de São Sebastião do Passé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Saúde', 6, 1, null, 'Feriado municipal de Saúde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Saúde', 6, 24, null, 'Feriado municipal de Saúde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Saúde', 9, 8, null, 'Feriado municipal de Saúde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Saúde', 12, 25, null, 'Feriado municipal de Saúde', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Seabra', 1, 20, null, 'Feriado municipal de Seabra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Seabra', 5, 14, null, 'Feriado municipal de Seabra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Seabra', 6, 24, null, 'Feriado municipal de Seabra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Seabra', 12, 8, null, 'Feriado municipal de Seabra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Senhor do Bonfim', 1, 17, null, 'Feriado municipal de Senhor do Bonfim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Senhor do Bonfim', 5, 28, null, 'Feriado municipal de Senhor do Bonfim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Senhor do Bonfim', 6, 24, null, 'Feriado municipal de Senhor do Bonfim', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Sento Sé', 3, 19, null, 'Feriado municipal de Sento Sé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Sento Sé', 6, 24, null, 'Feriado municipal de Sento Sé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Sento Sé', 7, 6, null, 'Feriado municipal de Sento Sé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Sento Sé', 10, 16, null, 'Feriado municipal de Sento Sé', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serra Dourada', 1, 10, null, 'Feriado municipal de Serra Dourada', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serra Dourada', 4, 12, null, 'Feriado municipal de Serra Dourada', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serra Dourada', 5, 3, null, 'Feriado municipal de Serra Dourada', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serra Dourada', 9, 10, null, 'Feriado municipal de Serra Dourada', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serrinha', 6, 13, null, 'Feriado municipal de Serrinha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serrinha', 6, 24, null, 'Feriado municipal de Serrinha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serrinha', 7, 26, null, 'Feriado municipal de Serrinha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Serrinha', 9, 23, null, 'Feriado municipal de Serrinha', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Simões Filho', 9, 29, null, 'Feriado municipal de Simões Filho', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Simões Filho', 10, 12, null, 'Feriado municipal de Simões Filho', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Simões Filho', 11, 2, null, 'Feriado municipal de Simões Filho', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Simões Filho', 11, 7, null, 'Feriado municipal de Simões Filho', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Simões Filho', 12, 8, null, 'Feriado municipal de Simões Filho', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Sobradinho', 2, 24, null, 'Feriado municipal de Sobradinho', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Sobradinho', 7, 26, null, 'Feriado municipal de Sobradinho', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tanhaçu', 6, 25, null, 'Feriado municipal de Tanhaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tanhaçu', 7, 30, null, 'Feriado municipal de Tanhaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tanhaçu', 9, 22, null, 'Feriado municipal de Tanhaçu', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tanque Novo', 2, 25, null, 'Feriado municipal de Tanque Novo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tanque Novo', 6, 1, null, 'Feriado municipal de Tanque Novo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tanque Novo', 6, 24, null, 'Feriado municipal de Tanque Novo', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Taperoá', 2, 3, null, 'Feriado municipal de Taperoá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Taperoá', 2, 4, null, 'Feriado municipal de Taperoá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Taperoá', 8, 15, null, 'Feriado municipal de Taperoá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Taperoá', 12, 13, null, 'Feriado municipal de Taperoá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Teixeira de Freitas', 5, 9, null, 'Feriado municipal de Teixeira de Freitas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Teixeira de Freitas', 6, 29, null, 'Feriado municipal de Teixeira de Freitas', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Teofilândia', 4, 23, null, 'Feriado municipal de Teofilândia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Teofilândia', 6, 13, null, 'Feriado municipal de Teofilândia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Teofilândia', 6, 29, null, 'Feriado municipal de Teofilândia', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Terra Nova', 6, 24, null, 'Feriado municipal de Terra Nova', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Terra Nova', 8, 16, null, 'Feriado municipal de Terra Nova', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Terra Nova', 10, 20, null, 'Feriado municipal de Terra Nova', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Terra Nova', 11, 20, null, 'Feriado municipal de Terra Nova', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tremedal', 10, 15, null, 'Feriado municipal de Tremedal', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tremedal', 11, 5, null, 'Feriado municipal de Tremedal', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tucano', 3, 21, null, 'Feriado municipal de Tucano', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tucano', 6, 13, null, 'Feriado municipal de Tucano', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tucano', 7, 26, null, 'Feriado municipal de Tucano', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Tucano', 9, 23, null, 'Feriado municipal de Tucano', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Uauá', 7, 9, null, 'Feriado municipal de Uauá', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubaíra', 1, 23, null, 'Feriado municipal de Ubaíra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubaíra', 6, 24, null, 'Feriado municipal de Ubaíra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubaíra', 6, 30, null, 'Feriado municipal de Ubaíra', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubaitaba', 6, 13, null, 'Feriado municipal de Ubaitaba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubaitaba', 6, 24, null, 'Feriado municipal de Ubaitaba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubaitaba', 7, 27, null, 'Feriado municipal de Ubaitaba', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubatã', 9, 26, null, 'Feriado municipal de Ubatã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubatã', 10, 20, null, 'Feriado municipal de Ubatã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Ubatã', 12, 8, null, 'Feriado municipal de Ubatã', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Urandi', 6, 13, null, 'Feriado municipal de Urandi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Urandi', 6, 24, null, 'Feriado municipal de Urandi', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Uruçuca', 6, 24, null, 'Feriado municipal de Uruçuca', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Uruçuca', 6, 29, null, 'Feriado municipal de Uruçuca', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Uruçuca', 12, 8, null, 'Feriado municipal de Uruçuca', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Uruçuca', 12, 12, null, 'Feriado municipal de Uruçuca', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Utinga', 4, 27, null, 'Feriado municipal de Utinga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Utinga', 6, 25, null, 'Feriado municipal de Utinga', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Valença', 6, 24, null, 'Feriado municipal de Valença', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Valença', 11, 8, null, 'Feriado municipal de Valença', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Valença', 11, 10, null, 'Feriado municipal de Valença', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Valente', 3, 8, null, 'Feriado municipal de Valente', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Valente', 6, 24, null, 'Feriado municipal de Valente', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Valente', 8, 12, null, 'Feriado municipal de Valente', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Valente', 9, 23, null, 'Feriado municipal de Valente', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Vitória da Conquista', 8, 15, null, 'Feriado municipal de Vitória da Conquista', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Vitória da Conquista', 11, 9, null, 'Feriado municipal de Vitória da Conquista', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g'),
('BA', 'Wenceslau Guimarães', 7, 19, null, 'Feriado municipal de Wenceslau Guimarães', 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', 'https://www7.tjba.jus.br/secao/arquivo/9/41226/DJ%2009.2026%20-%20Texto%20compilado.pdf', array['TJBA'], '1g')
on conflict do nothing;

-- Primeira rodada agora
select public.gerar_sugestoes_calendario();

-- Rodada diária às 07:20 (Brasília) = 10:20 UTC, antes do aviso de sugestões das 8h.
-- Só SQL: não chama nenhuma função externa.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'orbeo-calendario-local';
    perform cron.schedule('orbeo-calendario-local', '20 10 * * *', 'select public.gerar_sugestoes_calendario()');
  end if;
end $$;
-- =====================================================================
-- ORBEO · 14 · Notificações pessoais
--  • Cada usuário (inclusive estagiário) escolhe o que quer receber e em que horário
--  • Toda notificação fica registrada no Orbeo (sino), mesmo que o celular não receba
--  • Mostra se o aviso chegou a algum aparelho, para descobrir por que não chegou
-- Pode rodar de novo sem problema.
-- =====================================================================

create table if not exists public.notif_preferencias (
  advogado_id      uuid primary key default auth.uid() references public.advogados(id) on delete cascade,
  prazos           boolean  not null default true,
  prazos_hora      smallint not null default 7  check (prazos_hora between 5 and 12),
  prazos_dias      smallint not null default 1  check (prazos_dias between 0 and 5),   -- 0 = só hoje; 1 = hoje e amanhã...
  prazos_elaborar  boolean  not null default true,                                    -- prazos marcados para elaborar hoje
  audiencias       boolean  not null default true,
  aud_vespera_hora smallint          default 18 check (aud_vespera_hora is null or aud_vespera_hora between 12 and 22),
  aud_horas_antes  smallint not null default 2  check (aud_horas_antes between 0 and 24),  -- 0 = não avisar
  publicacoes      boolean  not null default true,
  novos            boolean  not null default true,
  sugestoes        boolean  not null default true,
  sugestoes_hora   smallint not null default 8  check (sugestoes_hora between 6 and 20),
  escopo           text     not null default 'meus' check (escopo in ('meus','escritorio')),
  atualizado_em    timestamptz not null default now()
);
alter table public.notif_preferencias enable row level security;
drop policy if exists np_ler on public.notif_preferencias;
drop policy if exists np_criar on public.notif_preferencias;
drop policy if exists np_editar on public.notif_preferencias;
create policy np_ler    on public.notif_preferencias for select to authenticated using (advogado_id = auth.uid());
create policy np_criar  on public.notif_preferencias for insert to authenticated with check (advogado_id = auth.uid());
create policy np_editar on public.notif_preferencias for update to authenticated using (advogado_id = auth.uid()) with check (advogado_id = auth.uid());
grant select, insert, update on public.notif_preferencias to authenticated;
grant all on public.notif_preferencias to service_role;

-- Caixa de notificações (o sino do app)
create table if not exists public.notificacoes (
  id             uuid primary key default gen_random_uuid(),
  advogado_id    uuid not null references public.advogados(id) on delete cascade,
  tipo           text not null,             -- prazos, audiencia, publicacao, novos, sugestoes, teste
  titulo         text not null,
  texto          text,
  url            text,
  chave          text not null,
  criado_em      timestamptz not null default now(),
  lida_em        timestamptz,
  push_aparelhos int not null default 0,    -- em quantos aparelhos o aviso chegou
  push_motivo    text,                      -- por que não chegou (sem aparelho, falha...)
  unique (advogado_id, chave)
);
create index if not exists notificacoes_adv_data on public.notificacoes (advogado_id, criado_em desc);
alter table public.notificacoes enable row level security;
drop policy if exists notif_ler on public.notificacoes;
create policy notif_ler on public.notificacoes for select to authenticated using (advogado_id = auth.uid());
grant select on public.notificacoes to authenticated;
grant all on public.notificacoes to service_role;

create or replace function public.marcar_notificacoes_lidas(p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update notificacoes set lida_em = now()
   where advogado_id = auth.uid() and lida_em is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.marcar_notificacoes_lidas(uuid[]) to authenticated;

-- Aparelhos: o próprio usuário vê falhas e último envio
alter table public.push_inscricoes add column if not exists falhas int not null default 0;

-- Limpeza: notificações com mais de 90 dias (todo dia às 03:40 de Brasília)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'orbeo-limpa-notificacoes';
    perform cron.schedule('orbeo-limpa-notificacoes', '40 6 * * *',
      $q$delete from public.notificacoes where criado_em < now() - interval '90 days'; delete from public.push_enviados where enviado_em < now() - interval '90 days'$q$);
  end if;
end $$;

-- Processos novos ainda pendentes dos últimos 30 dias entram no sino de quem foi avisado
insert into public.notificacoes (advogado_id, tipo, titulo, texto, url, chave, criado_em, push_motivo)
select av.advogado_id, 'novos',
       'Processo novo · ' || coalesce(c.nome_fantasia, c.nome),
       d.numero_cnj || coalesce(' · ' || d.tribunal, '') || '. Toque para ver e decidir se cadastra.',
       '#/novos?id=' || d.id, 'novos:' || av.id, av.notificado_em,
       'Registrado na atualização do Orbeo (antes do sino existir).'
  from public.descoberta_avisos av
  join public.descobertas d on d.id = av.descoberta_id
  join public.clientes c on c.id = d.cliente_id
 where av.status = 'pendente' and av.notificado_em > now() - interval '30 days'
on conflict (advogado_id, chave) do nothing;
-- =====================================================================
-- ORBEO · 15 · Ajustes no processo
--  1. Várias partes em cada polo (litisconsórcio ativo e passivo)
--  2. Baixa do processo (com data, motivo e quem deu baixa; pode reativar)
--  3. Mais categorias de ação (criminal, tributário, previdenciário...)
--  4. Observações lançadas na linha do tempo, com data e autor
--  5. Avisos de processos novos só para quem é do escritório do cliente
--  6. Catálogo de comarcas/foros por tribunal (lista oficial + DataJud)
-- Pode rodar de novo sem problema. Rodar depois da 14.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3. Categorias de ação
-- ---------------------------------------------------------------------
alter table public.processos drop constraint if exists processos_tipo_acao_check;
alter table public.processos add constraint processos_tipo_acao_check check (tipo_acao in (
  'Cível','Consumidor','Trabalhista','Previdenciário','Tributário','Criminal','Família e Sucessões','Empresarial',
  'Administrativo','Bancário','Imobiliário','Ambiental','Eleitoral','Militar','Outro'));

-- ---------------------------------------------------------------------
-- 2. Baixa do processo
-- ---------------------------------------------------------------------
alter table public.processos drop constraint if exists processos_situacao_check;
alter table public.processos add constraint processos_situacao_check check (situacao in ('ativo','suspenso','arquivado','encerrado','baixado'));
alter table public.processos add column if not exists baixa_data   date;
alter table public.processos add column if not exists baixa_motivo text;
alter table public.processos add column if not exists baixa_por    uuid references public.advogados(id) on delete set null;

create or replace function public.dar_baixa(p_processo uuid, p_data date, p_motivo text, p_obs text default null, p_cancelar_prazos boolean default true)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; nome text;
begin
  if not public.pode_ver_processo(p_processo) or not public.posso_editar() then
    raise exception 'Sem permissão para dar baixa neste processo.';
  end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da baixa.'; end if;
  update processos set situacao = 'baixado', baixa_data = coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date),
         baixa_motivo = p_motivo, baixa_por = auth.uid(), atualizado_em = now()
   where id = p_processo;
  if p_cancelar_prazos then
    with c as (update prazos set status = 'cancelado' where processo_id = p_processo and status = 'aberto' returning id)
    insert into prazo_historico (prazo_id, acao, texto, autor_id)
      select id, 'editado', 'Prazo cancelado pela baixa do processo.', auth.uid() from c;
    get diagnostics n = row_count;
    update audiencias set status = 'cancelada' where processo_id = p_processo and status = 'agendada' and data_hora > now();
  end if;
  insert into anotacoes (processo_id, tipo, texto, autor_id)
    values (p_processo, 'observacao', 'Baixa do processo em ' || to_char(coalesce(p_data, current_date), 'DD/MM/YYYY') || ' · ' || p_motivo
            || coalesce(E'\n' || nullif(trim(p_obs), ''), ''), auth.uid());
  return n;
end $$;

create or replace function public.reativar_processo(p_processo uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_ver_processo(p_processo) or not public.posso_editar() then
    raise exception 'Sem permissão para reativar este processo.';
  end if;
  update processos set situacao = 'ativo', baixa_data = null, baixa_motivo = null, baixa_por = null, atualizado_em = now() where id = p_processo;
  insert into anotacoes (processo_id, tipo, texto, autor_id) values (p_processo, 'observacao', 'Processo reativado.', auth.uid());
end $$;
grant execute on function public.dar_baixa(uuid, date, text, text, boolean), public.reativar_processo(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 1. Partes (litisconsórcio)
-- ---------------------------------------------------------------------
create table if not exists public.processo_partes (
  id           uuid primary key default gen_random_uuid(),
  processo_id  uuid not null references public.processos(id) on delete cascade,
  polo         text not null check (polo in ('ativo','passivo')),
  nome         text not null,
  documento    text,
  cliente_id   uuid references public.clientes(id) on delete set null,
  ordem        int not null default 0,
  criado_em    timestamptz not null default now()
);
create index if not exists processo_partes_proc on public.processo_partes (processo_id, polo, ordem);
create index if not exists processo_partes_cli on public.processo_partes (cliente_id);
alter table public.processo_partes enable row level security;
drop policy if exists partes_ler on public.processo_partes;
create policy partes_ler on public.processo_partes for select to authenticated using (public.pode_ver_processo(processo_id));
grant select on public.processo_partes to authenticated;
grant all on public.processo_partes to service_role;

-- Grava todas as partes de uma vez. p_partes = [{polo, nome, documento?, cliente_id?}, ...]
-- O cliente principal do processo entra sempre no polo dele; "parte contrária" vira o resumo do outro polo.
create or replace function public.salvar_partes(p_processo uuid, p_partes jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare pr processos; meu_polo text; outro text; resumo text;
begin
  select * into pr from processos where id = p_processo;
  if pr.id is null or not public.pode_ver_processo(p_processo) or not public.posso_editar() then
    raise exception 'Sem permissão para alterar as partes deste processo.';
  end if;
  meu_polo := case when pr.polo = 'autor' then 'ativo' else 'passivo' end;
  outro    := case when meu_polo = 'ativo' then 'passivo' else 'ativo' end;
  delete from processo_partes where processo_id = p_processo;
  insert into processo_partes (processo_id, polo, nome, documento, cliente_id, ordem)
  select p_processo, x.polo, trim(x.nome), nullif(trim(x.documento), ''),
         case when x.cliente_id is not null and exists (select 1 from clientes c where c.id = x.cliente_id and c.escritorio_id = pr.escritorio_id) then x.cliente_id end,
         x.ord
    from rows from (jsonb_to_recordset(coalesce(p_partes, '[]')) as (polo text, nome text, documento text, cliente_id uuid)) with ordinality as x(polo, nome, documento, cliente_id, ord)
   where x.polo in ('ativo','passivo') and coalesce(trim(x.nome), '') <> '';
  -- cliente principal sempre presente no polo dele
  if not exists (select 1 from processo_partes where processo_id = p_processo and cliente_id = pr.cliente_id) then
    insert into processo_partes (processo_id, polo, nome, documento, cliente_id, ordem)
    select p_processo, meu_polo, c.nome, c.cpf_cnpj, c.id, 0 from clientes c where c.id = pr.cliente_id;
  end if;
  select string_agg(nome, ', ' order by ordem) into resumo from processo_partes where processo_id = p_processo and polo = outro;
  update processos set parte_contraria = resumo, atualizado_em = now() where id = p_processo;
end $$;
grant execute on function public.salvar_partes(uuid, jsonb) to authenticated;

-- Partes dos processos que já existem: o cliente no polo dele e a parte contrária no outro
insert into public.processo_partes (processo_id, polo, nome, documento, cliente_id, ordem)
select p.id, case when p.polo = 'autor' then 'ativo' else 'passivo' end, c.nome, c.cpf_cnpj, c.id, 0
  from public.processos p join public.clientes c on c.id = p.cliente_id
 where not exists (select 1 from public.processo_partes x where x.processo_id = p.id);
insert into public.processo_partes (processo_id, polo, nome, ordem)
select p.id, case when p.polo = 'autor' then 'passivo' else 'ativo' end, trim(p.parte_contraria), 1
  from public.processos p
 where coalesce(trim(p.parte_contraria), '') <> ''
   and not exists (select 1 from public.processo_partes x where x.processo_id = p.id and x.cliente_id is null);

-- Cópia de processo (saída de advogado) leva as partes e marca de qual cliente veio a cópia
alter table public.clientes add column if not exists copiado_de uuid references public.clientes(id) on delete set null;
alter table public.clientes add column if not exists contato_nome text;
drop trigger if exists processo_copia_partes on public.processos;

-- vw_processos com as partes
drop view if exists public.vw_processos;
create view public.vw_processos with (security_invoker = on) as
select p.*,
       c.nome as cliente_nome, c.tipo as cliente_tipo,
       coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nome',a.nome) order by a.nome)
                   from public.processo_advogados pa join public.advogados a on a.id = pa.advogado_id
                  where pa.processo_id = p.id), '[]') as advogados,
       coalesce((select jsonb_agg(jsonb_build_object('polo',x.polo,'nome',x.nome,'documento',x.documento,'cliente_id',x.cliente_id) order by x.polo, x.ordem)
                   from public.processo_partes x where x.processo_id = p.id), '[]') as partes,
       (select count(*) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as prazos_abertos,
       (select min(z.prazo_fatal) from public.prazos z where z.processo_id = p.id and z.status = 'aberto') as proximo_prazo,
       (select count(*) from public.publicacoes u where u.processo_id = p.id and u.status = 'nova')
         + (select count(*) from public.movimentacoes m where m.processo_id = p.id and m.vista_em is null) as novidades,
       (select min(au.data_hora) from public.audiencias au
         where au.processo_id = p.id and au.status = 'agendada' and au.data_hora >= now() - interval '6 hours') as proxima_audiencia,
       (select a.nome from public.advogados a where a.id = p.baixa_por) as baixa_por_nome
from public.processos p
join public.clientes c on c.id = p.cliente_id;
grant select on public.vw_processos to authenticated;

-- ---------------------------------------------------------------------
-- 4. Observações na linha do tempo (anotação solta, sem andamento nem publicação)
alter table public.anotacoes drop constraint if exists anotacoes_check;
-- ---------------------------------------------------------------------
-- 4b. Linha do tempo (anotação sem andamento/publicação)
-- ---------------------------------------------------------------------
create or replace view public.vw_linha_do_tempo with (security_invoker = on) as
select m.processo_id, 'movimentacao'::text as origem, m.id as item_id, m.data_hora as quando,
       m.nome as titulo, m.complemento as detalhe, (m.vista_em is null) as nova,
       coalesce((select jsonb_agg(jsonb_build_object('tipo',a.tipo,'texto',a.texto,'autor',a.autor_id,'autor_nome',ad.nome,'em',a.criado_em) order by a.criado_em)
                 from public.anotacoes a left join public.advogados ad on ad.id = a.autor_id where a.movimentacao_id = m.id), '[]') as anotacoes,
       null::jsonb as extra
from public.movimentacoes m
union all
select p.processo_id, 'publicacao', p.id,
       (p.data_disponibilizacao::timestamp + time '12:00') at time zone 'America/Sao_Paulo',
       coalesce(p.tipo_documento, p.tipo_comunicacao, 'Publicação'), p.texto,
       (p.status = 'nova'),
       coalesce((select jsonb_agg(jsonb_build_object('tipo',a.tipo,'texto',a.texto,'autor',a.autor_id,'autor_nome',ad.nome,'em',a.criado_em) order by a.criado_em)
                 from public.anotacoes a left join public.advogados ad on ad.id = a.autor_id where a.publicacao_id = p.id), '[]'),
       jsonb_build_object('tipo_comunicacao', p.tipo_comunicacao, 'orgao', p.orgao_julgador, 'link', p.link,
                          'disponibilizacao', p.data_disponibilizacao, 'publicacao', p.data_publicacao, 'status', p.status)
from public.publicacoes p
where p.processo_id is not null
union all
select a.processo_id, 'observacao', a.id, a.criado_em, 'Observação', a.texto, false, '[]'::jsonb,
       jsonb_build_object('autor_id', a.autor_id, 'autor_nome', ad.nome, 'editado', a.atualizado_em > a.criado_em + interval '1 minute')
from public.anotacoes a left join public.advogados ad on ad.id = a.autor_id
where a.movimentacao_id is null and a.publicacao_id is null;
grant select on public.vw_linha_do_tempo to authenticated;

-- ---------------------------------------------------------------------
-- 5. Processos novos: só para quem é do escritório do cliente, e só no espaço em uso
-- ---------------------------------------------------------------------
create or replace function public.recebi_descoberta(p_desc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from descoberta_avisos av
                   join descobertas d on d.id = av.descoberta_id
                   join clientes c on c.id = d.cliente_id
                  where av.descoberta_id = p_desc and av.advogado_id = auth.uid()
                    and c.escritorio_id = public.meu_escritorio());
$$;
-- Avisos pendentes de quem não é (mais) do escritório do cliente
delete from public.descoberta_avisos av
 using public.descobertas d, public.clientes c
 where d.id = av.descoberta_id and c.id = d.cliente_id and av.status = 'pendente'
   and not exists (select 1 from public.escritorio_membros m where m.advogado_id = av.advogado_id and m.escritorio_id = c.escritorio_id and m.ativo);
delete from public.notificacoes n
 where n.tipo = 'novos' and n.lida_em is null
   and not exists (select 1 from public.descoberta_avisos av where av.advogado_id = n.advogado_id and n.chave = 'novos:' || av.id);
-- Vínculos com clientes de escritórios dos quais o advogado nunca foi (ou não é mais) membro
delete from public.cliente_advogados ca using public.clientes c
 where c.id = ca.cliente_id
   and not exists (select 1 from public.escritorio_membros m where m.advogado_id = ca.advogado_id and m.escritorio_id = c.escritorio_id);

-- ---------------------------------------------------------------------
-- 6. Comarcas e foros por tribunal
-- ---------------------------------------------------------------------
create table if not exists public.municipios (
  codigo int primary key,
  nome   text not null,
  uf     char(2) not null
);
create table if not exists public.comarcas (
  tribunal       text not null,
  nome           text not null,
  municipio_ibge int,
  tipo           text not null default 'comarca' check (tipo in ('comarca','foro','subsecao','municipio')),
  fonte          text,
  atualizado_em  timestamptz not null default now(),
  primary key (tribunal, nome)
);
alter table public.municipios enable row level security;
alter table public.comarcas enable row level security;
drop policy if exists mun_ler on public.municipios;
drop policy if exists com_ler on public.comarcas;
create policy mun_ler on public.municipios for select to authenticated using (true);
create policy com_ler on public.comarcas for select to authenticated using (true);
grant select on public.municipios, public.comarcas to authenticated;
grant all on public.municipios, public.comarcas to service_role;

-- O DataJud entrega o código IBGE da sede de cada vara; a função grava aqui e esta rotina transforma em comarcas
create or replace function public.gravar_comarcas_datajud(p_tribunal text, p_codigos int[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into comarcas (tribunal, nome, municipio_ibge, tipo, fonte)
  select upper(p_tribunal), m.nome, m.codigo,
         case when upper(p_tribunal) like 'TRF%' then 'subsecao' else 'comarca' end, 'DataJud'
    from municipios m
   where m.codigo = any(p_codigos)
     and not (upper(p_tribunal) = 'TJSP' and m.codigo = 3550308)   -- Capital de SP: escolhe-se o foro
  on conflict (tribunal, nome) do update set municipio_ibge = excluded.municipio_ibge, atualizado_em = now();
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.gravar_comarcas_datajud(text, int[]) from public, anon, authenticated;

-- Cópia de processo (saída de advogado): leva as partes e marca de qual cliente veio a cópia
create or replace function public.copiar_processo(p_proc uuid, p_destino uuid, p_adv uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr processos; cli clientes; novo_cli uuid; novo uuid; r record; nid uuid;
begin
  select * into pr from processos where id = p_proc;
  if pr.id is null then raise exception 'Processo não encontrado.'; end if;
  select id into novo from processos where escritorio_id = p_destino and numero_cnj = pr.numero_cnj;
  if novo is not null then return novo; end if;   -- já existe no destino
  select * into cli from clientes where id = pr.cliente_id;
  select id into novo_cli from clientes
   where escritorio_id = p_destino and ((cli.cpf_cnpj is not null and cpf_cnpj = cli.cpf_cnpj) or lower(nome) = lower(cli.nome)) limit 1;
  if novo_cli is null then
    insert into clientes select (jsonb_populate_record(null::clientes, to_jsonb(cli)
      || jsonb_build_object('id', gen_random_uuid(), 'escritorio_id', p_destino, 'criado_por', p_adv, 'copiado_de', cli.id))).* returning id into novo_cli;
  end if;
  insert into cliente_advogados values (novo_cli, p_adv) on conflict do nothing;
  insert into processos select (jsonb_populate_record(null::processos, to_jsonb(pr)
    || jsonb_build_object('id', gen_random_uuid(), 'cliente_id', novo_cli, 'escritorio_id', p_destino, 'criado_por', p_adv))).* returning id into novo;
  insert into processo_advogados values (novo, p_adv) on conflict do nothing;
  insert into processo_partes (processo_id, polo, nome, documento, cliente_id, ordem)
    select novo, x.polo, x.nome, x.documento, case when x.cliente_id = pr.cliente_id then novo_cli end, x.ordem
      from processo_partes x where x.processo_id = p_proc;

  create temp table if not exists _mapa (antigo uuid primary key, novo uuid) on commit drop;
  delete from _mapa;
  for r in select * from movimentacoes where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into movimentacoes select (jsonb_populate_record(null::movimentacoes, to_jsonb(r) || jsonb_build_object('id', nid, 'processo_id', novo))).*;
  end loop;
  for r in select * from publicacoes where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into publicacoes select (jsonb_populate_record(null::publicacoes, to_jsonb(r) || jsonb_build_object('id', nid, 'processo_id', novo, 'advogado_id', null))).*;
  end loop;
  for r in select * from audiencias where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into audiencias select (jsonb_populate_record(null::audiencias, to_jsonb(r)
      || jsonb_build_object('id', nid, 'processo_id', novo, 'responsavel_id', p_adv, 'sugestao_id', null))).*;
  end loop;
  for r in select * from prazos where processo_id = p_proc loop
    nid := gen_random_uuid(); insert into _mapa values (r.id, nid);
    insert into prazos select (jsonb_populate_record(null::prazos, to_jsonb(r) || jsonb_build_object('id', nid, 'processo_id', novo,
      'responsavel_id', p_adv, 'cumprido_por', case when r.cumprido_por = p_adv then p_adv end,
      'audiencia_id', (select m.novo from _mapa m where m.antigo = r.audiencia_id),
      'publicacao_id', (select m.novo from _mapa m where m.antigo = r.publicacao_id)))).*;
    insert into prazo_historico (prazo_id, acao, texto, autor_id, em)
      select nid, h.acao, h.texto, h.autor_id, h.em from prazo_historico h where h.prazo_id = r.id;
  end loop;
  for r in select * from anotacoes where processo_id = p_proc loop
    insert into anotacoes select (jsonb_populate_record(null::anotacoes, to_jsonb(r) || jsonb_build_object('id', gen_random_uuid(), 'processo_id', novo,
      'movimentacao_id', (select m.novo from _mapa m where m.antigo = r.movimentacao_id),
      'publicacao_id', (select m.novo from _mapa m where m.antigo = r.publicacao_id)))).*;
  end loop;
  for r in select * from decisoes where processo_id = p_proc loop
    insert into decisoes select (jsonb_populate_record(null::decisoes, to_jsonb(r) || jsonb_build_object('id', gen_random_uuid(), 'processo_id', novo,
      'publicacao_id', (select m.novo from _mapa m where m.antigo = r.publicacao_id)))).*;
  end loop;
  return novo;
end $$;
-- Municípios (IBGE)
insert into public.municipios (codigo, nome, uf) values
(1100015,'Alta Floresta D''Oeste','RO'),(1100023,'Ariquemes','RO'),(1100031,'Cabixi','RO'),(1100049,'Cacoal','RO'),(1100056,'Cerejeiras','RO'),(1100064,'Colorado do Oeste','RO'),(1100072,'Corumbiara','RO'),(1100080,'Costa Marques','RO'),(1100098,'Espigão D''Oeste','RO'),(1100106,'Guajará-Mirim','RO'),(1100114,'Jaru','RO'),(1100122,'Ji-Paraná','RO'),(1100130,'Machadinho D''Oeste','RO'),(1100148,'Nova Brasilândia D''Oeste','RO'),(1100155,'Ouro Preto do Oeste','RO'),(1100189,'Pimenta Bueno','RO'),(1100205,'Porto Velho','RO'),(1100254,'Presidente Médici','RO'),(1100262,'Rio Crespo','RO'),(1100288,'Rolim de Moura','RO'),(1100296,'Santa Luzia D''Oeste','RO'),(1100304,'Vilhena','RO'),(1100320,'São Miguel do Guaporé','RO'),(1100338,'Nova Mamoré','RO'),(1100346,'Alvorada D''Oeste','RO'),(1100379,'Alto Alegre dos Parecis','RO'),(1100403,'Alto Paraíso','RO'),(1100452,'Buritis','RO'),(1100502,'Novo Horizonte do Oeste','RO'),(1100601,'Cacaulândia','RO'),(1100700,'Campo Novo de Rondônia','RO'),(1100809,'Candeias do Jamari','RO'),(1100908,'Castanheiras','RO'),(1100924,'Chupinguaia','RO'),(1100940,'Cujubim','RO'),(1101005,'Governador Jorge Teixeira','RO'),(1101104,'Itapuã do Oeste','RO'),(1101203,'Ministro Andreazza','RO'),(1101302,'Mirante da Serra','RO'),(1101401,'Monte Negro','RO'),(1101435,'Nova União','RO'),(1101450,'Parecis','RO'),(1101468,'Pimenteiras do Oeste','RO'),(1101476,'Primavera de Rondônia','RO'),(1101484,'São Felipe D''Oeste','RO'),(1101492,'São Francisco do Guaporé','RO'),(1101500,'Seringueiras','RO'),(1101559,'Teixeirópolis','RO'),(1101609,'Theobroma','RO'),(1101708,'Urupá','RO'),(1101757,'Vale do Anari','RO'),(1101807,'Vale do Paraíso','RO'),(1200013,'Acrelândia','AC'),(1200054,'Assis Brasil','AC'),(1200104,'Brasiléia','AC'),(1200138,'Bujari','AC'),(1200179,'Capixaba','AC'),(1200203,'Cruzeiro do Sul','AC'),(1200252,'Epitaciolândia','AC'),(1200302,'Feijó','AC'),(1200328,'Jordão','AC'),(1200336,'Mâncio Lima','AC'),(1200344,'Manoel Urbano','AC'),(1200351,'Marechal Thaumaturgo','AC'),(1200385,'Plácido de Castro','AC'),(1200393,'Porto Walter','AC'),(1200401,'Rio Branco','AC'),(1200427,'Rodrigues Alves','AC'),(1200435,'Santa Rosa do Purus','AC'),(1200450,'Senador Guiomard','AC'),(1200500,'Sena Madureira','AC'),(1200609,'Tarauacá','AC'),(1200708,'Xapuri','AC'),(1200807,'Porto Acre','AC'),(1300029,'Alvarães','AM'),(1300060,'Amaturá','AM'),(1300086,'Anamã','AM'),(1300102,'Anori','AM'),(1300144,'Apuí','AM'),(1300201,'Atalaia do Norte','AM'),(1300300,'Autazes','AM'),(1300409,'Barcelos','AM'),(1300508,'Barreirinha','AM'),(1300607,'Benjamin Constant','AM'),(1300631,'Beruri','AM'),(1300680,'Boa Vista do Ramos','AM'),(1300706,'Boca do Acre','AM'),(1300805,'Borba','AM'),(1300839,'Caapiranga','AM'),(1300904,'Canutama','AM'),(1301001,'Carauari','AM'),(1301100,'Careiro','AM'),(1301159,'Careiro da Várzea','AM'),(1301209,'Coari','AM'),(1301308,'Codajás','AM'),(1301407,'Eirunepé','AM'),(1301506,'Envira','AM'),(1301605,'Fonte Boa','AM'),(1301654,'Guajará','AM'),(1301704,'Humaitá','AM'),(1301803,'Ipixuna','AM'),(1301852,'Iranduba','AM'),(1301902,'Itacoatiara','AM'),(1301951,'Itamarati','AM'),(1302009,'Itapiranga','AM'),(1302108,'Japurá','AM'),(1302207,'Juruá','AM'),(1302306,'Jutaí','AM'),(1302405,'Lábrea','AM'),(1302504,'Manacapuru','AM'),(1302553,'Manaquiri','AM'),(1302603,'Manaus','AM'),(1302702,'Manicoré','AM'),(1302801,'Maraã','AM'),(1302900,'Maués','AM'),(1303007,'Nhamundá','AM'),(1303106,'Nova Olinda do Norte','AM'),(1303205,'Novo Airão','AM'),(1303304,'Novo Aripuanã','AM'),(1303403,'Parintins','AM'),(1303502,'Pauini','AM'),(1303536,'Presidente Figueiredo','AM'),(1303569,'Rio Preto da Eva','AM'),(1303601,'Santa Isabel do Rio Negro','AM'),(1303700,'Santo Antônio do Içá','AM'),(1303809,'São Gabriel da Cachoeira','AM'),(1303908,'São Paulo de Olivença','AM'),(1303957,'São Sebastião do Uatumã','AM'),(1304005,'Silves','AM'),(1304062,'Tabatinga','AM'),(1304104,'Tapauá','AM'),(1304203,'Tefé','AM'),(1304237,'Tonantins','AM'),(1304260,'Uarini','AM'),(1304302,'Urucará','AM'),(1304401,'Urucurituba','AM'),(1400027,'Amajari','RR'),(1400050,'Alto Alegre','RR'),(1400100,'Boa Vista','RR'),(1400159,'Bonfim','RR'),(1400175,'Cantá','RR'),(1400209,'Caracaraí','RR'),(1400233,'Caroebe','RR'),(1400282,'Iracema','RR'),(1400308,'Mucajaí','RR'),(1400407,'Normandia','RR'),(1400456,'Pacaraima','RR'),(1400472,'Rorainópolis','RR'),(1400506,'São João da Baliza','RR'),(1400605,'São Luiz','RR'),(1400704,'Uiramutã','RR'),(1500107,'Abaetetuba','PA'),(1500131,'Abel Figueiredo','PA'),(1500206,'Acará','PA'),(1500305,'Afuá','PA'),(1500347,'Água Azul do Norte','PA'),(1500404,'Alenquer','PA'),(1500503,'Almeirim','PA'),(1500602,'Altamira','PA'),(1500701,'Anajás','PA'),(1500800,'Ananindeua','PA'),(1500859,'Anapu','PA'),(1500909,'Augusto Corrêa','PA'),(1500958,'Aurora do Pará','PA'),(1501006,'Aveiro','PA'),(1501105,'Bagre','PA'),(1501204,'Baião','PA'),(1501253,'Bannach','PA'),(1501303,'Barcarena','PA'),(1501402,'Belém','PA'),(1501451,'Belterra','PA'),(1501501,'Benevides','PA'),(1501576,'Bom Jesus do Tocantins','PA'),(1501600,'Bonito','PA'),(1501709,'Bragança','PA'),(1501725,'Brasil Novo','PA'),(1501758,'Brejo Grande do Araguaia','PA'),(1501782,'Breu Branco','PA'),(1501808,'Breves','PA'),(1501907,'Bujaru','PA'),(1501956,'Cachoeira do Piriá','PA'),(1502004,'Cachoeira do Arari','PA'),(1502103,'Cametá','PA'),(1502152,'Canaã dos Carajás','PA'),(1502202,'Capanema','PA'),(1502301,'Capitão Poço','PA'),(1502400,'Castanhal','PA'),(1502509,'Chaves','PA'),(1502608,'Colares','PA'),(1502707,'Conceição do Araguaia','PA'),(1502756,'Concórdia do Pará','PA'),(1502764,'Cumaru do Norte','PA'),(1502772,'Curionópolis','PA'),(1502806,'Curralinho','PA'),(1502855,'Curuá','PA'),(1502905,'Curuçá','PA'),(1502939,'Dom Eliseu','PA'),(1502954,'Eldorado do Carajás','PA'),(1503002,'Faro','PA'),(1503044,'Floresta do Araguaia','PA'),(1503077,'Garrafão do Norte','PA'),(1503093,'Goianésia do Pará','PA'),(1503101,'Gurupá','PA'),(1503200,'Igarapé-Açu','PA'),(1503309,'Igarapé-Miri','PA'),(1503408,'Inhangapi','PA'),(1503457,'Ipixuna do Pará','PA'),(1503507,'Irituia','PA'),(1503606,'Itaituba','PA'),(1503705,'Itupiranga','PA'),(1503754,'Jacareacanga','PA'),(1503804,'Jacundá','PA'),(1503903,'Juruti','PA'),(1504000,'Limoeiro do Ajuru','PA'),(1504059,'Mãe do Rio','PA'),(1504109,'Magalhães Barata','PA'),(1504208,'Marabá','PA'),(1504307,'Maracanã','PA'),(1504406,'Marapanim','PA'),(1504422,'Marituba','PA'),(1504455,'Medicilândia','PA'),(1504505,'Melgaço','PA'),(1504604,'Mocajuba','PA'),(1504703,'Moju','PA'),(1504752,'Mojuí dos Campos','PA'),(1504802,'Monte Alegre','PA'),(1504901,'Muaná','PA'),(1504950,'Nova Esperança do Piriá','PA'),(1504976,'Nova Ipixuna','PA'),(1505007,'Nova Timboteua','PA'),(1505031,'Novo Progresso','PA'),(1505064,'Novo Repartimento','PA'),(1505106,'Óbidos','PA'),(1505205,'Oeiras do Pará','PA'),(1505304,'Oriximiná','PA'),(1505403,'Ourém','PA'),(1505437,'Ourilândia do Norte','PA'),(1505486,'Pacajá','PA'),(1505494,'Palestina do Pará','PA'),(1505502,'Paragominas','PA'),(1505536,'Parauapebas','PA'),(1505551,'Pau d''Arco','PA'),(1505601,'Peixe-Boi','PA'),(1505635,'Piçarra','PA'),(1505650,'Placas','PA'),(1505700,'Ponta de Pedras','PA'),(1505809,'Portel','PA'),(1505908,'Porto de Moz','PA'),(1506005,'Prainha','PA'),(1506104,'Primavera','PA'),(1506112,'Quatipuru','PA'),(1506138,'Redenção','PA'),(1506161,'Rio Maria','PA'),(1506187,'Rondon do Pará','PA'),(1506195,'Rurópolis','PA'),(1506203,'Salinópolis','PA'),(1506302,'Salvaterra','PA'),(1506351,'Santa Bárbara do Pará','PA'),(1506401,'Santa Cruz do Arari','PA'),(1506500,'Santa Izabel do Pará','PA'),(1506559,'Santa Luzia do Pará','PA'),(1506583,'Santa Maria das Barreiras','PA'),(1506609,'Santa Maria do Pará','PA'),(1506708,'Santana do Araguaia','PA'),(1506807,'Santarém','PA'),(1506906,'Santarém Novo','PA'),(1507003,'Santo Antônio do Tauá','PA'),(1507102,'São Caetano de Odivelas','PA'),(1507151,'São Domingos do Araguaia','PA'),(1507201,'São Domingos do Capim','PA'),(1507300,'São Félix do Xingu','PA'),(1507409,'São Francisco do Pará','PA'),(1507458,'São Geraldo do Araguaia','PA'),(1507466,'São João da Ponta','PA'),(1507474,'São João de Pirabas','PA'),(1507508,'São João do Araguaia','PA'),(1507607,'São Miguel do Guamá','PA'),(1507706,'São Sebastião da Boa Vista','PA'),(1507755,'Sapucaia','PA'),(1507805,'Senador José Porfírio','PA'),(1507904,'Soure','PA'),(1507953,'Tailândia','PA'),(1507961,'Terra Alta','PA'),(1507979,'Terra Santa','PA'),(1508001,'Tomé-Açu','PA'),(1508035,'Tracuateua','PA'),(1508050,'Trairão','PA'),(1508084,'Tucumã','PA'),(1508100,'Tucuruí','PA'),(1508126,'Ulianópolis','PA'),(1508159,'Uruará','PA'),(1508209,'Vigia','PA'),(1508308,'Viseu','PA'),(1508357,'Vitória do Xingu','PA'),(1508407,'Xinguara','PA'),(1600055,'Serra do Navio','AP'),(1600105,'Amapá','AP'),(1600154,'Pedra Branca do Amapari','AP'),(1600204,'Calçoene','AP'),(1600212,'Cutias','AP'),(1600238,'Ferreira Gomes','AP'),(1600253,'Itaubal','AP'),(1600279,'Laranjal do Jari','AP'),(1600303,'Macapá','AP'),(1600402,'Mazagão','AP'),(1600501,'Oiapoque','AP'),(1600535,'Porto Grande','AP'),(1600550,'Pracuúba','AP'),(1600600,'Santana','AP'),(1600709,'Tartarugalzinho','AP'),(1600808,'Vitória do Jari','AP'),(1700251,'Abreulândia','TO'),(1700301,'Aguiarnópolis','TO'),(1700350,'Aliança do Tocantins','TO'),(1700400,'Almas','TO'),(1700707,'Alvorada','TO'),(1701002,'Ananás','TO'),(1701051,'Angico','TO'),(1701101,'Aparecida do Rio Negro','TO'),(1701309,'Aragominas','TO'),(1701903,'Araguacema','TO'),(1702000,'Araguaçu','TO'),(1702109,'Araguaína','TO'),(1702158,'Araguanã','TO'),(1702208,'Araguatins','TO'),(1702307,'Arapoema','TO'),(1702406,'Arraias','TO'),(1702554,'Augustinópolis','TO'),(1702703,'Aurora do Tocantins','TO'),(1702901,'Axixá do Tocantins','TO'),(1703008,'Babaçulândia','TO'),(1703057,'Bandeirantes do Tocantins','TO'),(1703073,'Barra do Ouro','TO'),(1703107,'Barrolândia','TO'),(1703206,'Bernardo Sayão','TO'),(1703305,'Bom Jesus do Tocantins','TO'),(1703602,'Brasilândia do Tocantins','TO'),(1703701,'Brejinho de Nazaré','TO'),(1703800,'Buriti do Tocantins','TO'),(1703826,'Cachoeirinha','TO'),(1703842,'Campos Lindos','TO'),(1703867,'Cariri do Tocantins','TO'),(1703883,'Carmolândia','TO'),(1703891,'Carrasco Bonito','TO'),(1703909,'Caseara','TO'),(1704105,'Centenário','TO'),(1704600,'Chapada de Areia','TO'),(1705102,'Chapada da Natividade','TO'),(1705508,'Colinas do Tocantins','TO'),(1705557,'Combinado','TO'),(1705607,'Conceição do Tocantins','TO'),(1706001,'Couto Magalhães','TO'),(1706100,'Cristalândia','TO'),(1706258,'Crixás do Tocantins','TO'),(1706506,'Darcinópolis','TO'),(1707009,'Dianópolis','TO'),(1707108,'Divinópolis do Tocantins','TO'),(1707207,'Dois Irmãos do Tocantins','TO'),(1707306,'Dueré','TO'),(1707405,'Esperantina','TO'),(1707553,'Fátima','TO'),(1707652,'Figueirópolis','TO'),(1707702,'Filadélfia','TO'),(1708205,'Formoso do Araguaia','TO'),(1708254,'Fortaleza do Tabocão','TO'),(1708304,'Goianorte','TO'),(1709005,'Goiatins','TO'),(1709302,'Guaraí','TO'),(1709500,'Gurupi','TO'),(1709807,'Ipueiras','TO'),(1710508,'Itacajá','TO'),(1710706,'Itaguatins','TO'),(1710904,'Itapiratins','TO'),(1711100,'Itaporã do Tocantins','TO'),(1711506,'Jaú do Tocantins','TO'),(1711803,'Juarina','TO'),(1711902,'Lagoa da Confusão','TO'),(1711951,'Lagoa do Tocantins','TO'),(1712009,'Lajeado','TO'),(1712157,'Lavandeira','TO'),(1712405,'Lizarda','TO'),(1712454,'Luzinópolis','TO'),(1712504,'Marianópolis do Tocantins','TO'),(1712702,'Mateiros','TO'),(1712801,'Maurilândia do Tocantins','TO'),(1713205,'Miracema do Tocantins','TO'),(1713304,'Miranorte','TO'),(1713601,'Monte do Carmo','TO'),(1713700,'Monte Santo do Tocantins','TO'),(1713809,'Palmeiras do Tocantins','TO'),(1713957,'Muricilândia','TO'),(1714203,'Natividade','TO'),(1714302,'Nazaré','TO'),(1714880,'Nova Olinda','TO'),(1715002,'Nova Rosalândia','TO'),(1715101,'Novo Acordo','TO'),(1715150,'Novo Alegre','TO'),(1715259,'Novo Jardim','TO'),(1715507,'Oliveira de Fátima','TO'),(1715705,'Palmeirante','TO'),(1715754,'Palmeirópolis','TO'),(1716109,'Paraíso do Tocantins','TO'),(1716208,'Paranã','TO'),(1716307,'Pau D''Arco','TO'),(1716505,'Pedro Afonso','TO'),(1716604,'Peixe','TO'),(1716653,'Pequizeiro','TO'),(1716703,'Colméia','TO'),(1717008,'Pindorama do Tocantins','TO'),(1717206,'Piraquê','TO'),(1717503,'Pium','TO'),(1717800,'Ponte Alta do Bom Jesus','TO'),(1717909,'Ponte Alta do Tocantins','TO'),(1718006,'Porto Alegre do Tocantins','TO'),(1718204,'Porto Nacional','TO'),(1718303,'Praia Norte','TO'),(1718402,'Presidente Kennedy','TO'),(1718451,'Pugmil','TO'),(1718501,'Recursolândia','TO'),(1718550,'Riachinho','TO'),(1718659,'Rio da Conceição','TO'),(1718709,'Rio dos Bois','TO'),(1718758,'Rio Sono','TO'),(1718808,'Sampaio','TO'),(1718840,'Sandolândia','TO'),(1718865,'Santa Fé do Araguaia','TO'),(1718881,'Santa Maria do Tocantins','TO'),(1718899,'Santa Rita do Tocantins','TO'),(1718907,'Santa Rosa do Tocantins','TO'),(1719004,'Santa Tereza do Tocantins','TO'),(1720002,'Santa Terezinha do Tocantins','TO'),(1720101,'São Bento do Tocantins','TO'),(1720150,'São Félix do Tocantins','TO'),(1720200,'São Miguel do Tocantins','TO'),(1720259,'São Salvador do Tocantins','TO'),(1720309,'São Sebastião do Tocantins','TO'),(1720499,'São Valério','TO'),(1720655,'Silvanópolis','TO'),(1720804,'Sítio Novo do Tocantins','TO'),(1720853,'Sucupira','TO'),(1720903,'Taguatinga','TO'),(1720937,'Taipas do Tocantins','TO'),(1720978,'Talismã','TO'),(1721000,'Palmas','TO'),(1721109,'Tocantínia','TO'),(1721208,'Tocantinópolis','TO'),(1721257,'Tupirama','TO'),(1721307,'Tupiratins','TO'),(1722081,'Wanderlândia','TO'),(1722107,'Xambioá','TO'),(2100055,'Açailândia','MA'),(2100105,'Afonso Cunha','MA'),(2100154,'Água Doce do Maranhão','MA'),(2100204,'Alcântara','MA'),(2100303,'Aldeias Altas','MA'),(2100402,'Altamira do Maranhão','MA'),(2100436,'Alto Alegre do Maranhão','MA'),(2100477,'Alto Alegre do Pindaré','MA'),(2100501,'Alto Parnaíba','MA'),(2100550,'Amapá do Maranhão','MA'),(2100600,'Amarante do Maranhão','MA'),(2100709,'Anajatuba','MA'),(2100808,'Anapurus','MA'),(2100832,'Apicum-Açu','MA'),(2100873,'Araguanã','MA'),(2100907,'Araioses','MA'),(2100956,'Arame','MA'),(2101004,'Arari','MA'),(2101103,'Axixá','MA'),(2101202,'Bacabal','MA'),(2101251,'Bacabeira','MA'),(2101301,'Bacuri','MA'),(2101350,'Bacurituba','MA'),(2101400,'Balsas','MA'),(2101509,'Barão de Grajaú','MA'),(2101608,'Barra do Corda','MA'),(2101707,'Barreirinhas','MA'),(2101731,'Belágua','MA'),(2101772,'Bela Vista do Maranhão','MA'),(2101806,'Benedito Leite','MA'),(2101905,'Bequimão','MA'),(2101939,'Bernardo do Mearim','MA'),(2101970,'Boa Vista do Gurupi','MA'),(2102002,'Bom Jardim','MA'),(2102036,'Bom Jesus das Selvas','MA'),(2102077,'Bom Lugar','MA'),(2102101,'Brejo','MA'),(2102150,'Brejo de Areia','MA'),(2102200,'Buriti','MA'),(2102309,'Buriti Bravo','MA'),(2102325,'Buriticupu','MA'),(2102358,'Buritirana','MA'),(2102374,'Cachoeira Grande','MA'),(2102408,'Cajapió','MA'),(2102507,'Cajari','MA'),(2102556,'Campestre do Maranhão','MA'),(2102606,'Cândido Mendes','MA'),(2102705,'Cantanhede','MA'),(2102754,'Capinzal do Norte','MA'),(2102804,'Carolina','MA'),
(2102903,'Carutapera','MA'),(2103000,'Caxias','MA'),(2103109,'Cedral','MA'),(2103125,'Central do Maranhão','MA'),(2103158,'Centro do Guilherme','MA'),(2103174,'Centro Novo do Maranhão','MA'),(2103208,'Chapadinha','MA'),(2103257,'Cidelândia','MA'),(2103307,'Codó','MA'),(2103406,'Coelho Neto','MA'),(2103505,'Colinas','MA'),(2103554,'Conceição do Lago-Açu','MA'),(2103604,'Coroatá','MA'),(2103703,'Cururupu','MA'),(2103752,'Davinópolis','MA'),(2103802,'Dom Pedro','MA'),(2103901,'Duque Bacelar','MA'),(2104008,'Esperantinópolis','MA'),(2104057,'Estreito','MA'),(2104073,'Feira Nova do Maranhão','MA'),(2104081,'Fernando Falcão','MA'),(2104099,'Formosa da Serra Negra','MA'),(2104107,'Fortaleza dos Nogueiras','MA'),(2104206,'Fortuna','MA'),(2104305,'Godofredo Viana','MA'),(2104404,'Gonçalves Dias','MA'),(2104503,'Governador Archer','MA'),(2104552,'Governador Edison Lobão','MA'),(2104602,'Governador Eugênio Barros','MA'),(2104628,'Governador Luiz Rocha','MA'),(2104651,'Governador Newton Bello','MA'),(2104677,'Governador Nunes Freire','MA'),(2104701,'Graça Aranha','MA'),(2104800,'Grajaú','MA'),(2104909,'Guimarães','MA'),(2105005,'Humberto de Campos','MA'),(2105104,'Icatu','MA'),(2105153,'Igarapé do Meio','MA'),(2105203,'Igarapé Grande','MA'),(2105302,'Imperatriz','MA'),(2105351,'Itaipava do Grajaú','MA'),(2105401,'Itapecuru Mirim','MA'),(2105427,'Itinga do Maranhão','MA'),(2105450,'Jatobá','MA'),(2105476,'Jenipapo dos Vieiras','MA'),(2105500,'João Lisboa','MA'),(2105609,'Joselândia','MA'),(2105658,'Junco do Maranhão','MA'),(2105708,'Lago da Pedra','MA'),(2105807,'Lago do Junco','MA'),(2105906,'Lago Verde','MA'),(2105922,'Lagoa do Mato','MA'),(2105948,'Lago dos Rodrigues','MA'),(2105963,'Lagoa Grande do Maranhão','MA'),(2105989,'Lajeado Novo','MA'),(2106003,'Lima Campos','MA'),(2106102,'Loreto','MA'),(2106201,'Luís Domingues','MA'),(2106300,'Magalhães de Almeida','MA'),(2106326,'Maracaçumé','MA'),(2106359,'Marajá do Sena','MA'),(2106375,'Maranhãozinho','MA'),(2106409,'Mata Roma','MA'),(2106508,'Matinha','MA'),(2106607,'Matões','MA'),(2106631,'Matões do Norte','MA'),(2106672,'Milagres do Maranhão','MA'),(2106706,'Mirador','MA'),(2106755,'Miranda do Norte','MA'),(2106805,'Mirinzal','MA'),(2106904,'Monção','MA'),(2107001,'Montes Altos','MA'),(2107100,'Morros','MA'),(2107209,'Nina Rodrigues','MA'),(2107258,'Nova Colinas','MA'),(2107308,'Nova Iorque','MA'),(2107357,'Nova Olinda do Maranhão','MA'),(2107407,'Olho d''Água das Cunhãs','MA'),(2107456,'Olinda Nova do Maranhão','MA'),(2107506,'Paço do Lumiar','MA'),(2107605,'Palmeirândia','MA'),(2107704,'Paraibano','MA'),(2107803,'Parnarama','MA'),(2107902,'Passagem Franca','MA'),(2108009,'Pastos Bons','MA'),(2108058,'Paulino Neves','MA'),(2108108,'Paulo Ramos','MA'),(2108207,'Pedreiras','MA'),(2108256,'Pedro do Rosário','MA'),(2108306,'Penalva','MA'),(2108405,'Peri Mirim','MA'),(2108454,'Peritoró','MA'),(2108504,'Pindaré-Mirim','MA'),(2108603,'Pinheiro','MA'),(2108702,'Pio XII','MA'),(2108801,'Pirapemas','MA'),(2108900,'Poção de Pedras','MA'),(2109007,'Porto Franco','MA'),(2109056,'Porto Rico do Maranhão','MA'),(2109106,'Presidente Dutra','MA'),(2109205,'Presidente Juscelino','MA'),(2109239,'Presidente Médici','MA'),(2109270,'Presidente Sarney','MA'),(2109304,'Presidente Vargas','MA'),(2109403,'Primeira Cruz','MA'),(2109452,'Raposa','MA'),(2109502,'Riachão','MA'),(2109551,'Ribamar Fiquene','MA'),(2109601,'Rosário','MA'),(2109700,'Sambaíba','MA'),(2109759,'Santa Filomena do Maranhão','MA'),(2109809,'Santa Helena','MA'),(2109908,'Santa Inês','MA'),(2110005,'Santa Luzia','MA'),(2110039,'Santa Luzia do Paruá','MA'),(2110104,'Santa Quitéria do Maranhão','MA'),(2110203,'Santa Rita','MA'),(2110237,'Santana do Maranhão','MA'),(2110278,'Santo Amaro do Maranhão','MA'),(2110302,'Santo Antônio dos Lopes','MA'),(2110401,'São Benedito do Rio Preto','MA'),(2110500,'São Bento','MA'),(2110609,'São Bernardo','MA'),(2110658,'São Domingos do Azeitão','MA'),(2110708,'São Domingos do Maranhão','MA'),(2110807,'São Félix de Balsas','MA'),(2110856,'São Francisco do Brejão','MA'),(2110906,'São Francisco do Maranhão','MA'),(2111003,'São João Batista','MA'),(2111029,'São João do Carú','MA'),(2111052,'São João do Paraíso','MA'),(2111078,'São João do Soter','MA'),(2111102,'São João dos Patos','MA'),(2111201,'São José de Ribamar','MA'),(2111250,'São José dos Basílios','MA'),(2111300,'São Luís','MA'),(2111409,'São Luís Gonzaga do Maranhão','MA'),(2111508,'São Mateus do Maranhão','MA'),(2111532,'São Pedro da Água Branca','MA'),(2111573,'São Pedro dos Crentes','MA'),(2111607,'São Raimundo das Mangabeiras','MA'),(2111631,'São Raimundo do Doca Bezerra','MA'),(2111672,'São Roberto','MA'),(2111706,'São Vicente Ferrer','MA'),(2111722,'Satubinha','MA'),(2111748,'Senador Alexandre Costa','MA'),(2111763,'Senador La Rocque','MA'),(2111789,'Serrano do Maranhão','MA'),(2111805,'Sítio Novo','MA'),(2111904,'Sucupira do Norte','MA'),(2111953,'Sucupira do Riachão','MA'),(2112001,'Tasso Fragoso','MA'),(2112100,'Timbiras','MA'),(2112209,'Timon','MA'),(2112233,'Trizidela do Vale','MA'),(2112274,'Tufilândia','MA'),(2112308,'Tuntum','MA'),(2112407,'Turiaçu','MA'),(2112456,'Turilândia','MA'),(2112506,'Tutóia','MA'),(2112605,'Urbano Santos','MA'),(2112704,'Vargem Grande','MA'),(2112803,'Viana','MA'),(2112852,'Vila Nova dos Martírios','MA'),(2112902,'Vitória do Mearim','MA'),(2113009,'Vitorino Freire','MA'),(2114007,'Zé Doca','MA'),(2200053,'Acauã','PI'),(2200103,'Agricolândia','PI'),(2200202,'Água Branca','PI'),(2200251,'Alagoinha do Piauí','PI'),(2200277,'Alegrete do Piauí','PI'),(2200301,'Alto Longá','PI'),(2200400,'Altos','PI'),(2200459,'Alvorada do Gurguéia','PI'),(2200509,'Amarante','PI'),(2200608,'Angical do Piauí','PI'),(2200707,'Anísio de Abreu','PI'),(2200806,'Antônio Almeida','PI'),(2200905,'Aroazes','PI'),(2200954,'Aroeiras do Itaim','PI'),(2201002,'Arraial','PI'),(2201051,'Assunção do Piauí','PI'),(2201101,'Avelino Lopes','PI'),(2201150,'Baixa Grande do Ribeiro','PI'),(2201176,'Barra D''Alcântara','PI'),(2201200,'Barras','PI'),(2201309,'Barreiras do Piauí','PI'),(2201408,'Barro Duro','PI'),(2201507,'Batalha','PI'),(2201556,'Bela Vista do Piauí','PI'),(2201572,'Belém do Piauí','PI'),(2201606,'Beneditinos','PI'),(2201705,'Bertolínia','PI'),(2201739,'Betânia do Piauí','PI'),(2201770,'Boa Hora','PI'),(2201804,'Bocaina','PI'),(2201903,'Bom Jesus','PI'),(2201919,'Bom Princípio do Piauí','PI'),(2201929,'Bonfim do Piauí','PI'),(2201945,'Boqueirão do Piauí','PI'),(2201960,'Brasileira','PI'),(2201988,'Brejo do Piauí','PI'),(2202000,'Buriti dos Lopes','PI'),(2202026,'Buriti dos Montes','PI'),(2202059,'Cabeceiras do Piauí','PI'),(2202075,'Cajazeiras do Piauí','PI'),(2202083,'Cajueiro da Praia','PI'),(2202091,'Caldeirão Grande do Piauí','PI'),(2202109,'Campinas do Piauí','PI'),(2202117,'Campo Alegre do Fidalgo','PI'),(2202133,'Campo Grande do Piauí','PI'),(2202174,'Campo Largo do Piauí','PI'),(2202208,'Campo Maior','PI'),(2202251,'Canavieira','PI'),(2202307,'Canto do Buriti','PI'),(2202406,'Capitão de Campos','PI'),(2202455,'Capitão Gervásio Oliveira','PI'),(2202505,'Caracol','PI'),(2202539,'Caraúbas do Piauí','PI'),(2202554,'Caridade do Piauí','PI'),(2202604,'Castelo do Piauí','PI'),(2202653,'Caxingó','PI'),(2202703,'Cocal','PI'),(2202711,'Cocal de Telha','PI'),(2202729,'Cocal dos Alves','PI'),(2202737,'Coivaras','PI'),(2202752,'Colônia do Gurguéia','PI'),(2202778,'Colônia do Piauí','PI'),(2202802,'Conceição do Canindé','PI'),(2202851,'Coronel José Dias','PI'),(2202901,'Corrente','PI'),(2203008,'Cristalândia do Piauí','PI'),(2203107,'Cristino Castro','PI'),(2203206,'Curimatá','PI'),(2203230,'Currais','PI'),(2203255,'Curralinhos','PI'),(2203271,'Curral Novo do Piauí','PI'),(2203305,'Demerval Lobão','PI'),(2203354,'Dirceu Arcoverde','PI'),(2203404,'Dom Expedito Lopes','PI'),(2203420,'Domingos Mourão','PI'),(2203453,'Dom Inocêncio','PI'),(2203503,'Elesbão Veloso','PI'),(2203602,'Eliseu Martins','PI'),(2203701,'Esperantina','PI'),(2203750,'Fartura do Piauí','PI'),(2203800,'Flores do Piauí','PI'),(2203859,'Floresta do Piauí','PI'),(2203909,'Floriano','PI'),(2204006,'Francinópolis','PI'),(2204105,'Francisco Ayres','PI'),(2204154,'Francisco Macedo','PI'),(2204204,'Francisco Santos','PI'),(2204303,'Fronteiras','PI'),(2204352,'Geminiano','PI'),(2204402,'Gilbués','PI'),(2204501,'Guadalupe','PI'),(2204550,'Guaribas','PI'),(2204600,'Hugo Napoleão','PI'),(2204659,'Ilha Grande','PI'),(2204709,'Inhuma','PI'),(2204808,'Ipiranga do Piauí','PI'),(2204907,'Isaías Coelho','PI'),(2205003,'Itainópolis','PI'),(2205102,'Itaueira','PI'),(2205151,'Jacobina do Piauí','PI'),(2205201,'Jaicós','PI'),(2205250,'Jardim do Mulato','PI'),(2205276,'Jatobá do Piauí','PI'),(2205300,'Jerumenha','PI'),(2205359,'João Costa','PI'),(2205409,'Joaquim Pires','PI'),(2205458,'Joca Marques','PI'),(2205508,'José de Freitas','PI'),(2205516,'Juazeiro do Piauí','PI'),(2205524,'Júlio Borges','PI'),(2205532,'Jurema','PI'),(2205540,'Lagoinha do Piauí','PI'),(2205557,'Lagoa Alegre','PI'),(2205565,'Lagoa do Barro do Piauí','PI'),(2205573,'Lagoa de São Francisco','PI'),(2205581,'Lagoa do Piauí','PI'),(2205599,'Lagoa do Sítio','PI'),(2205607,'Landri Sales','PI'),(2205706,'Luís Correia','PI'),(2205805,'Luzilândia','PI'),(2205854,'Madeiro','PI'),(2205904,'Manoel Emídio','PI'),(2205953,'Marcolândia','PI'),(2206001,'Marcos Parente','PI'),(2206050,'Massapê do Piauí','PI'),(2206100,'Matias Olímpio','PI'),(2206209,'Miguel Alves','PI'),(2206308,'Miguel Leão','PI'),(2206357,'Milton Brandão','PI'),(2206407,'Monsenhor Gil','PI'),(2206506,'Monsenhor Hipólito','PI'),(2206605,'Monte Alegre do Piauí','PI'),(2206654,'Morro Cabeça no Tempo','PI'),(2206670,'Morro do Chapéu do Piauí','PI'),(2206696,'Murici dos Portelas','PI'),(2206704,'Nazaré do Piauí','PI'),(2206720,'Nazária','PI'),(2206753,'Nossa Senhora de Nazaré','PI'),(2206803,'Nossa Senhora dos Remédios','PI'),(2206902,'Novo Oriente do Piauí','PI'),(2206951,'Novo Santo Antônio','PI'),(2207009,'Oeiras','PI'),(2207108,'Olho D''Água do Piauí','PI'),(2207207,'Padre Marcos','PI'),(2207306,'Paes Landim','PI'),(2207355,'Pajeú do Piauí','PI'),(2207405,'Palmeira do Piauí','PI'),(2207504,'Palmeirais','PI'),(2207553,'Paquetá','PI'),(2207603,'Parnaguá','PI'),(2207702,'Parnaíba','PI'),(2207751,'Passagem Franca do Piauí','PI'),(2207777,'Patos do Piauí','PI'),(2207793,'Pau D''Arco do Piauí','PI'),(2207801,'Paulistana','PI'),(2207850,'Pavussu','PI'),(2207900,'Pedro II','PI'),(2207934,'Pedro Laurentino','PI'),(2207959,'Nova Santa Rita','PI'),(2208007,'Picos','PI'),(2208106,'Pimenteiras','PI'),(2208205,'Pio IX','PI'),(2208304,'Piracuruca','PI'),(2208403,'Piripiri','PI'),(2208502,'Porto','PI'),(2208551,'Porto Alegre do Piauí','PI'),(2208601,'Prata do Piauí','PI'),(2208650,'Queimada Nova','PI'),(2208700,'Redenção do Gurguéia','PI'),(2208809,'Regeneração','PI'),(2208858,'Riacho Frio','PI'),(2208874,'Ribeira do Piauí','PI'),(2208908,'Ribeiro Gonçalves','PI'),(2209005,'Rio Grande do Piauí','PI'),(2209104,'Santa Cruz do Piauí','PI'),(2209153,'Santa Cruz dos Milagres','PI'),(2209203,'Santa Filomena','PI'),(2209302,'Santa Luz','PI'),(2209351,'Santana do Piauí','PI'),(2209377,'Santa Rosa do Piauí','PI'),(2209401,'Santo Antônio de Lisboa','PI'),(2209450,'Santo Antônio dos Milagres','PI'),(2209500,'Santo Inácio do Piauí','PI'),(2209559,'São Braz do Piauí','PI'),(2209609,'São Félix do Piauí','PI'),(2209658,'São Francisco de Assis do Piauí','PI'),(2209708,'São Francisco do Piauí','PI'),(2209757,'São Gonçalo do Gurguéia','PI'),(2209807,'São Gonçalo do Piauí','PI'),(2209856,'São João da Canabrava','PI'),(2209872,'São João da Fronteira','PI'),(2209906,'São João da Serra','PI'),(2209955,'São João da Varjota','PI'),(2209971,'São João do Arraial','PI'),(2210003,'São João do Piauí','PI'),(2210052,'São José do Divino','PI'),(2210102,'São José do Peixe','PI'),(2210201,'São José do Piauí','PI'),(2210300,'São Julião','PI'),(2210359,'São Lourenço do Piauí','PI'),(2210375,'São Luis do Piauí','PI'),(2210383,'São Miguel da Baixa Grande','PI'),(2210391,'São Miguel do Fidalgo','PI'),(2210409,'São Miguel do Tapuio','PI'),(2210508,'São Pedro do Piauí','PI'),(2210607,'São Raimundo Nonato','PI'),(2210623,'Sebastião Barros','PI'),(2210631,'Sebastião Leal','PI'),(2210656,'Sigefredo Pacheco','PI'),(2210706,'Simões','PI'),(2210805,'Simplício Mendes','PI'),(2210904,'Socorro do Piauí','PI'),(2210938,'Sussuapara','PI'),(2210953,'Tamboril do Piauí','PI'),(2210979,'Tanque do Piauí','PI'),(2211001,'Teresina','PI'),(2211100,'União','PI'),(2211209,'Uruçuí','PI'),(2211308,'Valença do Piauí','PI'),(2211357,'Várzea Branca','PI'),(2211407,'Várzea Grande','PI'),(2211506,'Vera Mendes','PI'),(2211605,'Vila Nova do Piauí','PI'),(2211704,'Wall Ferraz','PI'),(2300101,'Abaiara','CE'),(2300150,'Acarape','CE'),(2300200,'Acaraú','CE'),(2300309,'Acopiara','CE'),(2300408,'Aiuaba','CE'),(2300507,'Alcântaras','CE'),(2300606,'Altaneira','CE'),(2300705,'Alto Santo','CE'),(2300754,'Amontada','CE'),(2300804,'Antonina do Norte','CE'),(2300903,'Apuiarés','CE'),(2301000,'Aquiraz','CE'),(2301109,'Aracati','CE'),(2301208,'Aracoiaba','CE'),(2301257,'Ararendá','CE'),(2301307,'Araripe','CE'),(2301406,'Aratuba','CE'),(2301505,'Arneiroz','CE'),(2301604,'Assaré','CE'),(2301703,'Aurora','CE'),(2301802,'Baixio','CE'),(2301851,'Banabuiú','CE'),(2301901,'Barbalha','CE'),(2301950,'Barreira','CE'),(2302008,'Barro','CE'),(2302057,'Barroquinha','CE'),(2302107,'Baturité','CE'),(2302206,'Beberibe','CE'),(2302305,'Bela Cruz','CE'),(2302404,'Boa Viagem','CE'),(2302503,'Brejo Santo','CE'),(2302602,'Camocim','CE'),(2302701,'Campos Sales','CE'),(2302800,'Canindé','CE'),(2302909,'Capistrano','CE'),(2303006,'Caridade','CE'),(2303105,'Cariré','CE'),(2303204,'Caririaçu','CE'),(2303303,'Cariús','CE'),(2303402,'Carnaubal','CE'),(2303501,'Cascavel','CE'),(2303600,'Catarina','CE'),(2303659,'Catunda','CE'),(2303709,'Caucaia','CE'),(2303808,'Cedro','CE'),(2303907,'Chaval','CE'),(2303931,'Choró','CE'),(2303956,'Chorozinho','CE'),(2304004,'Coreaú','CE'),(2304103,'Crateús','CE'),(2304202,'Crato','CE'),(2304236,'Croatá','CE'),(2304251,'Cruz','CE'),(2304269,'Deputado Irapuan Pinheiro','CE'),(2304277,'Ererê','CE'),(2304285,'Eusébio','CE'),(2304301,'Farias Brito','CE'),(2304350,'Forquilha','CE'),(2304400,'Fortaleza','CE'),(2304459,'Fortim','CE'),(2304509,'Frecheirinha','CE'),(2304608,'General Sampaio','CE'),(2304657,'Graça','CE'),(2304707,'Granja','CE'),(2304806,'Granjeiro','CE'),(2304905,'Groaíras','CE'),(2304954,'Guaiúba','CE'),(2305001,'Guaraciaba do Norte','CE'),(2305100,'Guaramiranga','CE'),(2305209,'Hidrolândia','CE'),(2305233,'Horizonte','CE'),(2305266,'Ibaretama','CE'),(2305308,'Ibiapina','CE'),(2305332,'Ibicuitinga','CE'),(2305357,'Icapuí','CE'),(2305407,'Icó','CE'),(2305506,'Iguatu','CE'),(2305605,'Independência','CE'),(2305654,'Ipaporanga','CE'),(2305704,'Ipaumirim','CE'),(2305803,'Ipu','CE'),(2305902,'Ipueiras','CE'),(2306009,'Iracema','CE'),(2306108,'Irauçuba','CE'),(2306207,'Itaiçaba','CE'),(2306256,'Itaitinga','CE'),(2306306,'Itapajé','CE'),(2306405,'Itapipoca','CE'),(2306504,'Itapiúna','CE'),(2306553,'Itarema','CE'),(2306603,'Itatira','CE'),(2306702,'Jaguaretama','CE'),(2306801,'Jaguaribara','CE'),(2306900,'Jaguaribe','CE'),(2307007,'Jaguaruana','CE'),(2307106,'Jardim','CE'),(2307205,'Jati','CE'),(2307254,'Jijoca de Jericoacoara','CE'),(2307304,'Juazeiro do Norte','CE'),(2307403,'Jucás','CE'),(2307502,'Lavras da Mangabeira','CE'),(2307601,'Limoeiro do Norte','CE'),(2307635,'Madalena','CE'),(2307650,'Maracanaú','CE'),(2307700,'Maranguape','CE'),(2307809,'Marco','CE'),(2307908,'Martinópole','CE'),(2308005,'Massapê','CE'),(2308104,'Mauriti','CE'),
(2308203,'Meruoca','CE'),(2308302,'Milagres','CE'),(2308351,'Milhã','CE'),(2308377,'Miraíma','CE'),(2308401,'Missão Velha','CE'),(2308500,'Mombaça','CE'),(2308609,'Monsenhor Tabosa','CE'),(2308708,'Morada Nova','CE'),(2308807,'Moraújo','CE'),(2308906,'Morrinhos','CE'),(2309003,'Mucambo','CE'),(2309102,'Mulungu','CE'),(2309201,'Nova Olinda','CE'),(2309300,'Nova Russas','CE'),(2309409,'Novo Oriente','CE'),(2309458,'Ocara','CE'),(2309508,'Orós','CE'),(2309607,'Pacajus','CE'),(2309706,'Pacatuba','CE'),(2309805,'Pacoti','CE'),(2309904,'Pacujá','CE'),(2310001,'Palhano','CE'),(2310100,'Palmácia','CE'),(2310209,'Paracuru','CE'),(2310258,'Paraipaba','CE'),(2310308,'Parambu','CE'),(2310407,'Paramoti','CE'),(2310506,'Pedra Branca','CE'),(2310605,'Penaforte','CE'),(2310704,'Pentecoste','CE'),(2310803,'Pereiro','CE'),(2310852,'Pindoretama','CE'),(2310902,'Piquet Carneiro','CE'),(2310951,'Pires Ferreira','CE'),(2311009,'Poranga','CE'),(2311108,'Porteiras','CE'),(2311207,'Potengi','CE'),(2311231,'Potiretama','CE'),(2311264,'Quiterianópolis','CE'),(2311306,'Quixadá','CE'),(2311355,'Quixelô','CE'),(2311405,'Quixeramobim','CE'),(2311504,'Quixeré','CE'),(2311603,'Redenção','CE'),(2311702,'Reriutaba','CE'),(2311801,'Russas','CE'),(2311900,'Saboeiro','CE'),(2311959,'Salitre','CE'),(2312007,'Santana do Acaraú','CE'),(2312106,'Santana do Cariri','CE'),(2312205,'Santa Quitéria','CE'),(2312304,'São Benedito','CE'),(2312403,'São Gonçalo do Amarante','CE'),(2312502,'São João do Jaguaribe','CE'),(2312601,'São Luís do Curu','CE'),(2312700,'Senador Pompeu','CE'),(2312809,'Senador Sá','CE'),(2312908,'Sobral','CE'),(2313005,'Solonópole','CE'),(2313104,'Tabuleiro do Norte','CE'),(2313203,'Tamboril','CE'),(2313252,'Tarrafas','CE'),(2313302,'Tauá','CE'),(2313351,'Tejuçuoca','CE'),(2313401,'Tianguá','CE'),(2313500,'Trairi','CE'),(2313559,'Tururu','CE'),(2313609,'Ubajara','CE'),(2313708,'Umari','CE'),(2313757,'Umirim','CE'),(2313807,'Uruburetama','CE'),(2313906,'Uruoca','CE'),(2313955,'Varjota','CE'),(2314003,'Várzea Alegre','CE'),(2314102,'Viçosa do Ceará','CE'),(2400109,'Acari','RN'),(2400208,'Açu','RN'),(2400307,'Afonso Bezerra','RN'),(2400406,'Água Nova','RN'),(2400505,'Alexandria','RN'),(2400604,'Almino Afonso','RN'),(2400703,'Alto do Rodrigues','RN'),(2400802,'Angicos','RN'),(2400901,'Antônio Martins','RN'),(2401008,'Apodi','RN'),(2401107,'Areia Branca','RN'),(2401206,'Arês','RN'),(2401305,'Augusto Severo (Campo Grande)','RN'),(2401404,'Baía Formosa','RN'),(2401453,'Baraúna','RN'),(2401503,'Barcelona','RN'),(2401602,'Bento Fernandes','RN'),(2401651,'Bodó','RN'),(2401701,'Bom Jesus','RN'),(2401800,'Brejinho','RN'),(2401859,'Caiçara do Norte','RN'),(2401909,'Caiçara do Rio do Vento','RN'),(2402006,'Caicó','RN'),(2402105,'Campo Redondo','RN'),(2402204,'Canguaretama','RN'),(2402303,'Caraúbas','RN'),(2402402,'Carnaúba dos Dantas','RN'),(2402501,'Carnaubais','RN'),(2402600,'Ceará-Mirim','RN'),(2402709,'Cerro Corá','RN'),(2402808,'Coronel Ezequiel','RN'),(2402907,'Coronel João Pessoa','RN'),(2403004,'Cruzeta','RN'),(2403103,'Currais Novos','RN'),(2403202,'Doutor Severiano','RN'),(2403251,'Parnamirim','RN'),(2403301,'Encanto','RN'),(2403400,'Equador','RN'),(2403509,'Espírito Santo','RN'),(2403608,'Extremoz','RN'),(2403707,'Felipe Guerra','RN'),(2403756,'Fernando Pedroza','RN'),(2403806,'Florânia','RN'),(2403905,'Francisco Dantas','RN'),(2404002,'Frutuoso Gomes','RN'),(2404101,'Galinhos','RN'),(2404200,'Goianinha','RN'),(2404309,'Governador Dix-Sept Rosado','RN'),(2404408,'Grossos','RN'),(2404507,'Guamaré','RN'),(2404606,'Ielmo Marinho','RN'),(2404705,'Ipanguaçu','RN'),(2404804,'Ipueira','RN'),(2404853,'Itajá','RN'),(2404903,'Itaú','RN'),(2405009,'Jaçanã','RN'),(2405108,'Jandaíra','RN'),(2405207,'Janduís','RN'),(2405306,'Januário Cicco (Boa Saúde)','RN'),(2405405,'Japi','RN'),(2405504,'Jardim de Angicos','RN'),(2405603,'Jardim de Piranhas','RN'),(2405702,'Jardim do Seridó','RN'),(2405801,'João Câmara','RN'),(2405900,'João Dias','RN'),(2406007,'José da Penha','RN'),(2406106,'Jucurutu','RN'),(2406155,'Jundiá','RN'),(2406205,'Lagoa d''Anta','RN'),(2406304,'Lagoa de Pedras','RN'),(2406403,'Lagoa de Velhos','RN'),(2406502,'Lagoa Nova','RN'),(2406601,'Lagoa Salgada','RN'),(2406700,'Lajes','RN'),(2406809,'Lajes Pintadas','RN'),(2406908,'Lucrécia','RN'),(2407005,'Luís Gomes','RN'),(2407104,'Macaíba','RN'),(2407203,'Macau','RN'),(2407252,'Major Sales','RN'),(2407302,'Marcelino Vieira','RN'),(2407401,'Martins','RN'),(2407500,'Maxaranguape','RN'),(2407609,'Messias Targino','RN'),(2407708,'Montanhas','RN'),(2407807,'Monte Alegre','RN'),(2407906,'Monte das Gameleiras','RN'),(2408003,'Mossoró','RN'),(2408102,'Natal','RN'),(2408201,'Nísia Floresta','RN'),(2408300,'Nova Cruz','RN'),(2408409,'Olho-d''Água do Borges','RN'),(2408508,'Ouro Branco','RN'),(2408607,'Paraná','RN'),(2408706,'Paraú','RN'),(2408805,'Parazinho','RN'),(2408904,'Parelhas','RN'),(2408953,'Rio do Fogo','RN'),(2409100,'Passa e Fica','RN'),(2409209,'Passagem','RN'),(2409308,'Patu','RN'),(2409332,'Santa Maria','RN'),(2409407,'Pau dos Ferros','RN'),(2409506,'Pedra Grande','RN'),(2409605,'Pedra Preta','RN'),(2409704,'Pedro Avelino','RN'),(2409803,'Pedro Velho','RN'),(2409902,'Pendências','RN'),(2410009,'Pilões','RN'),(2410108,'Poço Branco','RN'),(2410207,'Portalegre','RN'),(2410256,'Porto do Mangue','RN'),(2410306,'Serra Caiada','RN'),(2410405,'Pureza','RN'),(2410504,'Rafael Fernandes','RN'),(2410603,'Rafael Godeiro','RN'),(2410702,'Riacho da Cruz','RN'),(2410801,'Riacho de Santana','RN'),(2410900,'Riachuelo','RN'),(2411007,'Rodolfo Fernandes','RN'),(2411056,'Tibau','RN'),(2411106,'Ruy Barbosa','RN'),(2411205,'Santa Cruz','RN'),(2411403,'Santana do Matos','RN'),(2411429,'Santana do Seridó','RN'),(2411502,'Santo Antônio','RN'),(2411601,'São Bento do Norte','RN'),(2411700,'São Bento do Trairí','RN'),(2411809,'São Fernando','RN'),(2411908,'São Francisco do Oeste','RN'),(2412005,'São Gonçalo do Amarante','RN'),(2412104,'São João do Sabugi','RN'),(2412203,'São José de Mipibu','RN'),(2412302,'São José do Campestre','RN'),(2412401,'São José do Seridó','RN'),(2412500,'São Miguel','RN'),(2412559,'São Miguel do Gostoso','RN'),(2412609,'São Paulo do Potengi','RN'),(2412708,'São Pedro','RN'),(2412807,'São Rafael','RN'),(2412906,'São Tomé','RN'),(2413003,'São Vicente','RN'),(2413102,'Senador Elói de Souza','RN'),(2413201,'Senador Georgino Avelino','RN'),(2413300,'Serra de São Bento','RN'),(2413359,'Serra do Mel','RN'),(2413409,'Serra Negra do Norte','RN'),(2413508,'Serrinha','RN'),(2413557,'Serrinha dos Pintos','RN'),(2413607,'Severiano Melo','RN'),(2413706,'Sítio Novo','RN'),(2413805,'Taboleiro Grande','RN'),(2413904,'Taipu','RN'),(2414001,'Tangará','RN'),(2414100,'Tenente Ananias','RN'),(2414159,'Tenente Laurentino Cruz','RN'),(2414209,'Tibau do Sul','RN'),(2414308,'Timbaúba dos Batistas','RN'),(2414407,'Touros','RN'),(2414456,'Triunfo Potiguar','RN'),(2414506,'Umarizal','RN'),(2414605,'Upanema','RN'),(2414704,'Várzea','RN'),(2414753,'Venha-Ver','RN'),(2414803,'Vera Cruz','RN'),(2414902,'Viçosa','RN'),(2415008,'Vila Flor','RN'),(2500106,'Água Branca','PB'),(2500205,'Aguiar','PB'),(2500304,'Alagoa Grande','PB'),(2500403,'Alagoa Nova','PB'),(2500502,'Alagoinha','PB'),(2500536,'Alcantil','PB'),(2500577,'Algodão de Jandaíra','PB'),(2500601,'Alhandra','PB'),(2500700,'São João do Rio do Peixe','PB'),(2500734,'Amparo','PB'),(2500775,'Aparecida','PB'),(2500809,'Araçagi','PB'),(2500908,'Arara','PB'),(2501005,'Araruna','PB'),(2501104,'Areia','PB'),(2501153,'Areia de Baraúnas','PB'),(2501203,'Areial','PB'),(2501302,'Aroeiras','PB'),(2501351,'Assunção','PB'),(2501401,'Baía da Traição','PB'),(2501500,'Bananeiras','PB'),(2501534,'Baraúna','PB'),(2501575,'Barra de Santana','PB'),(2501609,'Barra de Santa Rosa','PB'),(2501708,'Barra de São Miguel','PB'),(2501807,'Bayeux','PB'),(2501906,'Belém','PB'),(2502003,'Belém do Brejo do Cruz','PB'),(2502052,'Bernardino Batista','PB'),(2502102,'Boa Ventura','PB'),(2502151,'Boa Vista','PB'),(2502201,'Bom Jesus','PB'),(2502300,'Bom Sucesso','PB'),(2502409,'Bonito de Santa Fé','PB'),(2502508,'Boqueirão','PB'),(2502607,'Igaracy','PB'),(2502706,'Borborema','PB'),(2502805,'Brejo do Cruz','PB'),(2502904,'Brejo dos Santos','PB'),(2503001,'Caaporã','PB'),(2503100,'Cabaceiras','PB'),(2503209,'Cabedelo','PB'),(2503308,'Cachoeira dos Índios','PB'),(2503407,'Cacimba de Areia','PB'),(2503506,'Cacimba de Dentro','PB'),(2503555,'Cacimbas','PB'),(2503605,'Caiçara','PB'),(2503704,'Cajazeiras','PB'),(2503753,'Cajazeirinhas','PB'),(2503803,'Caldas Brandão','PB'),(2503902,'Camalaú','PB'),(2504009,'Campina Grande','PB'),(2504033,'Capim','PB'),(2504074,'Caraúbas','PB'),(2504108,'Carrapateira','PB'),(2504157,'Casserengue','PB'),(2504207,'Catingueira','PB'),(2504306,'Catolé do Rocha','PB'),(2504355,'Caturité','PB'),(2504405,'Conceição','PB'),(2504504,'Condado','PB'),(2504603,'Conde','PB'),(2504702,'Congo','PB'),(2504801,'Coremas','PB'),(2504850,'Coxixola','PB'),(2504900,'Cruz do Espírito Santo','PB'),(2505006,'Cubati','PB'),(2505105,'Cuité','PB'),(2505204,'Cuitegi','PB'),(2505238,'Cuité de Mamanguape','PB'),(2505279,'Curral de Cima','PB'),(2505303,'Curral Velho','PB'),(2505352,'Damião','PB'),(2505402,'Desterro','PB'),(2505501,'Vista Serrana','PB'),(2505600,'Diamante','PB'),(2505709,'Dona Inês','PB'),(2505808,'Duas Estradas','PB'),(2505907,'Emas','PB'),(2506004,'Esperança','PB'),(2506103,'Fagundes','PB'),(2506202,'Frei Martinho','PB'),(2506251,'Gado Bravo','PB'),(2506301,'Guarabira','PB'),(2506400,'Gurinhém','PB'),(2506509,'Gurjão','PB'),(2506608,'Ibiara','PB'),(2506707,'Imaculada','PB'),(2506806,'Ingá','PB'),(2506905,'Itabaiana','PB'),(2507002,'Itaporanga','PB'),(2507101,'Itapororoca','PB'),(2507200,'Itatuba','PB'),(2507309,'Jacaraú','PB'),(2507408,'Jericó','PB'),(2507507,'João Pessoa','PB'),(2507606,'Juarez Távora','PB'),(2507705,'Juazeirinho','PB'),(2507804,'Junco do Seridó','PB'),(2507903,'Juripiranga','PB'),(2508000,'Juru','PB'),(2508109,'Lagoa','PB'),(2508208,'Lagoa de Dentro','PB'),(2508307,'Lagoa Seca','PB'),(2508406,'Lastro','PB'),(2508505,'Livramento','PB'),(2508554,'Logradouro','PB'),(2508604,'Lucena','PB'),(2508703,'Mãe d''Água','PB'),(2508802,'Malta','PB'),(2508901,'Mamanguape','PB'),(2509008,'Manaíra','PB'),(2509057,'Marcação','PB'),(2509107,'Mari','PB'),(2509156,'Marizópolis','PB'),(2509206,'Massaranduba','PB'),(2509305,'Mataraca','PB'),(2509339,'Matinhas','PB'),(2509370,'Mato Grosso','PB'),(2509396,'Maturéia','PB'),(2509404,'Mogeiro','PB'),(2509503,'Montadas','PB'),(2509602,'Monte Horebe','PB'),(2509701,'Monteiro','PB'),(2509800,'Mulungu','PB'),(2509909,'Natuba','PB'),(2510006,'Nazarezinho','PB'),(2510105,'Nova Floresta','PB'),(2510204,'Nova Olinda','PB'),(2510303,'Nova Palmeira','PB'),(2510402,'Olho d''Água','PB'),(2510501,'Olivedos','PB'),(2510600,'Ouro Velho','PB'),(2510659,'Parari','PB'),(2510709,'Passagem','PB'),(2510808,'Patos','PB'),(2510907,'Paulista','PB'),(2511004,'Pedra Branca','PB'),(2511103,'Pedra Lavrada','PB'),(2511202,'Pedras de Fogo','PB'),(2511301,'Piancó','PB'),(2511400,'Picuí','PB'),(2511509,'Pilar','PB'),(2511608,'Pilões','PB'),(2511707,'Pilõezinhos','PB'),(2511806,'Pirpirituba','PB'),(2511905,'Pitimbu','PB'),(2512002,'Pocinhos','PB'),(2512036,'Poço Dantas','PB'),(2512077,'Poço de José de Moura','PB'),(2512101,'Pombal','PB'),(2512200,'Prata','PB'),(2512309,'Princesa Isabel','PB'),(2512408,'Puxinanã','PB'),(2512507,'Queimadas','PB'),(2512606,'Quixabá','PB'),(2512705,'Remígio','PB'),(2512721,'Pedro Régis','PB'),(2512747,'Riachão','PB'),(2512754,'Riachão do Bacamarte','PB'),(2512762,'Riachão do Poço','PB'),(2512788,'Riacho de Santo Antônio','PB'),(2512804,'Riacho dos Cavalos','PB'),(2512903,'Rio Tinto','PB'),(2513000,'Salgadinho','PB'),(2513109,'Salgado de São Félix','PB'),(2513158,'Santa Cecília','PB'),(2513208,'Santa Cruz','PB'),(2513307,'Santa Helena','PB'),(2513356,'Santa Inês','PB'),(2513406,'Santa Luzia','PB'),(2513505,'Santana de Mangueira','PB'),(2513604,'Santana dos Garrotes','PB'),(2513653,'Joca Claudino','PB'),(2513703,'Santa Rita','PB'),(2513802,'Santa Teresinha','PB'),(2513851,'Santo André','PB'),(2513901,'São Bento','PB'),(2513927,'São Bentinho','PB'),(2513943,'São Domingos do Cariri','PB'),(2513968,'São Domingos','PB'),(2513984,'São Francisco','PB'),(2514008,'São João do Cariri','PB'),(2514107,'São João do Tigre','PB'),(2514206,'São José da Lagoa Tapada','PB'),(2514305,'São José de Caiana','PB'),(2514404,'São José de Espinharas','PB'),(2514453,'São José dos Ramos','PB'),(2514503,'São José de Piranhas','PB'),(2514552,'São José de Princesa','PB'),(2514602,'São José do Bonfim','PB'),(2514651,'São José do Brejo do Cruz','PB'),(2514701,'São José do Sabugi','PB'),(2514800,'São José dos Cordeiros','PB'),(2514909,'São Mamede','PB'),(2515005,'São Miguel de Taipu','PB'),(2515104,'São Sebastião de Lagoa de Roça','PB'),(2515203,'São Sebastião do Umbuzeiro','PB'),(2515302,'Sapé','PB'),(2515401,'São Vicente do Seridó','PB'),(2515500,'Serra Branca','PB'),(2515609,'Serra da Raiz','PB'),(2515708,'Serra Grande','PB'),(2515807,'Serra Redonda','PB'),(2515906,'Serraria','PB'),(2515930,'Sertãozinho','PB'),(2515971,'Sobrado','PB'),(2516003,'Solânea','PB'),(2516102,'Soledade','PB'),(2516151,'Sossêgo','PB'),(2516201,'Sousa','PB'),(2516300,'Sumé','PB'),(2516409,'Tacima','PB'),(2516508,'Taperoá','PB'),(2516607,'Tavares','PB'),(2516706,'Teixeira','PB'),(2516755,'Tenório','PB'),(2516805,'Triunfo','PB'),(2516904,'Uiraúna','PB'),(2517001,'Umbuzeiro','PB'),(2517100,'Várzea','PB'),(2517209,'Vieirópolis','PB'),(2517407,'Zabelê','PB'),(2600054,'Abreu e Lima','PE'),(2600104,'Afogados da Ingazeira','PE'),(2600203,'Afrânio','PE'),(2600302,'Agrestina','PE'),(2600401,'Água Preta','PE'),(2600500,'Águas Belas','PE'),(2600609,'Alagoinha','PE'),(2600708,'Aliança','PE'),(2600807,'Altinho','PE'),(2600906,'Amaraji','PE'),(2601003,'Angelim','PE'),(2601052,'Araçoiaba','PE'),(2601102,'Araripina','PE'),(2601201,'Arcoverde','PE'),(2601300,'Barra de Guabiraba','PE'),(2601409,'Barreiros','PE'),(2601508,'Belém de Maria','PE'),(2601607,'Belém do São Francisco','PE'),(2601706,'Belo Jardim','PE'),(2601805,'Betânia','PE'),(2601904,'Bezerros','PE'),(2602001,'Bodocó','PE'),(2602100,'Bom Conselho','PE'),(2602209,'Bom Jardim','PE'),(2602308,'Bonito','PE'),(2602407,'Brejão','PE'),(2602506,'Brejinho','PE'),(2602605,'Brejo da Madre de Deus','PE'),(2602704,'Buenos Aires','PE'),(2602803,'Buíque','PE'),(2602902,'Cabo de Santo Agostinho','PE'),(2603009,'Cabrobó','PE'),(2603108,'Cachoeirinha','PE'),(2603207,'Caetés','PE'),(2603306,'Calçado','PE'),
(2603405,'Calumbi','PE'),(2603454,'Camaragibe','PE'),(2603504,'Camocim de São Félix','PE'),(2603603,'Camutanga','PE'),(2603702,'Canhotinho','PE'),(2603801,'Capoeiras','PE'),(2603900,'Carnaíba','PE'),(2603926,'Carnaubeira da Penha','PE'),(2604007,'Carpina','PE'),(2604106,'Caruaru','PE'),(2604155,'Casinhas','PE'),(2604205,'Catende','PE'),(2604304,'Cedro','PE'),(2604403,'Chã de Alegria','PE'),(2604502,'Chã Grande','PE'),(2604601,'Condado','PE'),(2604700,'Correntes','PE'),(2604809,'Cortês','PE'),(2604908,'Cumaru','PE'),(2605004,'Cupira','PE'),(2605103,'Custódia','PE'),(2605152,'Dormentes','PE'),(2605202,'Escada','PE'),(2605301,'Exu','PE'),(2605400,'Feira Nova','PE'),(2605459,'Fernando de Noronha','PE'),(2605509,'Ferreiros','PE'),(2605608,'Flores','PE'),(2605707,'Floresta','PE'),(2605806,'Frei Miguelinho','PE'),(2605905,'Gameleira','PE'),(2606002,'Garanhuns','PE'),(2606101,'Glória do Goitá','PE'),(2606200,'Goiana','PE'),(2606309,'Granito','PE'),(2606408,'Gravatá','PE'),(2606507,'Iati','PE'),(2606606,'Ibimirim','PE'),(2606705,'Ibirajuba','PE'),(2606804,'Igarassu','PE'),(2606903,'Iguaracy','PE'),(2607000,'Inajá','PE'),(2607109,'Ingazeira','PE'),(2607208,'Ipojuca','PE'),(2607307,'Ipubi','PE'),(2607406,'Itacuruba','PE'),(2607505,'Itaíba','PE'),(2607604,'Ilha de Itamaracá','PE'),(2607653,'Itambé','PE'),(2607703,'Itapetim','PE'),(2607752,'Itapissuma','PE'),(2607802,'Itaquitinga','PE'),(2607901,'Jaboatão dos Guararapes','PE'),(2607950,'Jaqueira','PE'),(2608008,'Jataúba','PE'),(2608057,'Jatobá','PE'),(2608107,'João Alfredo','PE'),(2608206,'Joaquim Nabuco','PE'),(2608255,'Jucati','PE'),(2608305,'Jupi','PE'),(2608404,'Jurema','PE'),(2608453,'Lagoa do Carro','PE'),(2608503,'Lagoa de Itaenga','PE'),(2608602,'Lagoa do Ouro','PE'),(2608701,'Lagoa dos Gatos','PE'),(2608750,'Lagoa Grande','PE'),(2608800,'Lajedo','PE'),(2608909,'Limoeiro','PE'),(2609006,'Macaparana','PE'),(2609105,'Machados','PE'),(2609154,'Manari','PE'),(2609204,'Maraial','PE'),(2609303,'Mirandiba','PE'),(2609402,'Moreno','PE'),(2609501,'Nazaré da Mata','PE'),(2609600,'Olinda','PE'),(2609709,'Orobó','PE'),(2609808,'Orocó','PE'),(2609907,'Ouricuri','PE'),(2610004,'Palmares','PE'),(2610103,'Palmeirina','PE'),(2610202,'Panelas','PE'),(2610301,'Paranatama','PE'),(2610400,'Parnamirim','PE'),(2610509,'Passira','PE'),(2610608,'Paudalho','PE'),(2610707,'Paulista','PE'),(2610806,'Pedra','PE'),(2610905,'Pesqueira','PE'),(2611002,'Petrolândia','PE'),(2611101,'Petrolina','PE'),(2611200,'Poção','PE'),(2611309,'Pombos','PE'),(2611408,'Primavera','PE'),(2611507,'Quipapá','PE'),(2611533,'Quixaba','PE'),(2611606,'Recife','PE'),(2611705,'Riacho das Almas','PE'),(2611804,'Ribeirão','PE'),(2611903,'Rio Formoso','PE'),(2612000,'Sairé','PE'),(2612109,'Salgadinho','PE'),(2612208,'Salgueiro','PE'),(2612307,'Saloá','PE'),(2612406,'Sanharó','PE'),(2612455,'Santa Cruz','PE'),(2612471,'Santa Cruz da Baixa Verde','PE'),(2612505,'Santa Cruz do Capibaribe','PE'),(2612554,'Santa Filomena','PE'),(2612604,'Santa Maria da Boa Vista','PE'),(2612703,'Santa Maria do Cambucá','PE'),(2612802,'Santa Terezinha','PE'),(2612901,'São Benedito do Sul','PE'),(2613008,'São Bento do Una','PE'),(2613107,'São Caetano','PE'),(2613206,'São João','PE'),(2613305,'São Joaquim do Monte','PE'),(2613404,'São José da Coroa Grande','PE'),(2613503,'São José do Belmonte','PE'),(2613602,'São José do Egito','PE'),(2613701,'São Lourenço da Mata','PE'),(2613800,'São Vicente Ferrer','PE'),(2613909,'Serra Talhada','PE'),(2614006,'Serrita','PE'),(2614105,'Sertânia','PE'),(2614204,'Sirinhaém','PE'),(2614303,'Moreilândia','PE'),(2614402,'Solidão','PE'),(2614501,'Surubim','PE'),(2614600,'Tabira','PE'),(2614709,'Tacaimbó','PE'),(2614808,'Tacaratu','PE'),(2614857,'Tamandaré','PE'),(2615003,'Taquaritinga do Norte','PE'),(2615102,'Terezinha','PE'),(2615201,'Terra Nova','PE'),(2615300,'Timbaúba','PE'),(2615409,'Toritama','PE'),(2615508,'Tracunhaém','PE'),(2615607,'Trindade','PE'),(2615706,'Triunfo','PE'),(2615805,'Tupanatinga','PE'),(2615904,'Tuparetama','PE'),(2616001,'Venturosa','PE'),(2616100,'Verdejante','PE'),(2616183,'Vertente do Lério','PE'),(2616209,'Vertentes','PE'),(2616308,'Vicência','PE'),(2616407,'Vitória de Santo Antão','PE'),(2616506,'Xexéu','PE'),(2700102,'Água Branca','AL'),(2700201,'Anadia','AL'),(2700300,'Arapiraca','AL'),(2700409,'Atalaia','AL'),(2700508,'Barra de Santo Antônio','AL'),(2700607,'Barra de São Miguel','AL'),(2700706,'Batalha','AL'),(2700805,'Belém','AL'),(2700904,'Belo Monte','AL'),(2701001,'Boca da Mata','AL'),(2701100,'Branquinha','AL'),(2701209,'Cacimbinhas','AL'),(2701308,'Cajueiro','AL'),(2701357,'Campestre','AL'),(2701407,'Campo Alegre','AL'),(2701506,'Campo Grande','AL'),(2701605,'Canapi','AL'),(2701704,'Capela','AL'),(2701803,'Carneiros','AL'),(2701902,'Chã Preta','AL'),(2702009,'Coité do Nóia','AL'),(2702108,'Colônia Leopoldina','AL'),(2702207,'Coqueiro Seco','AL'),(2702306,'Coruripe','AL'),(2702355,'Craíbas','AL'),(2702405,'Delmiro Gouveia','AL'),(2702504,'Dois Riachos','AL'),(2702553,'Estrela de Alagoas','AL'),(2702603,'Feira Grande','AL'),(2702702,'Feliz Deserto','AL'),(2702801,'Flexeiras','AL'),(2702900,'Girau do Ponciano','AL'),(2703007,'Ibateguara','AL'),(2703106,'Igaci','AL'),(2703205,'Igreja Nova','AL'),(2703304,'Inhapi','AL'),(2703403,'Jacaré dos Homens','AL'),(2703502,'Jacuípe','AL'),(2703601,'Japaratinga','AL'),(2703700,'Jaramataia','AL'),(2703759,'Jequiá da Praia','AL'),(2703809,'Joaquim Gomes','AL'),(2703908,'Jundiá','AL'),(2704005,'Junqueiro','AL'),(2704104,'Lagoa da Canoa','AL'),(2704203,'Limoeiro de Anadia','AL'),(2704302,'Maceió','AL'),(2704401,'Major Isidoro','AL'),(2704500,'Maragogi','AL'),(2704609,'Maravilha','AL'),(2704708,'Marechal Deodoro','AL'),(2704807,'Maribondo','AL'),(2704906,'Mar Vermelho','AL'),(2705002,'Mata Grande','AL'),(2705101,'Matriz de Camaragibe','AL'),(2705200,'Messias','AL'),(2705309,'Minador do Negrão','AL'),(2705408,'Monteirópolis','AL'),(2705507,'Murici','AL'),(2705606,'Novo Lino','AL'),(2705705,'Olho d''Água das Flores','AL'),(2705804,'Olho d''Água do Casado','AL'),(2705903,'Olho d''Água Grande','AL'),(2706000,'Olivença','AL'),(2706109,'Ouro Branco','AL'),(2706208,'Palestina','AL'),(2706307,'Palmeira dos Índios','AL'),(2706406,'Pão de Açúcar','AL'),(2706422,'Pariconha','AL'),(2706448,'Paripueira','AL'),(2706505,'Passo de Camaragibe','AL'),(2706604,'Paulo Jacinto','AL'),(2706703,'Penedo','AL'),(2706802,'Piaçabuçu','AL'),(2706901,'Pilar','AL'),(2707008,'Pindoba','AL'),(2707107,'Piranhas','AL'),(2707206,'Poço das Trincheiras','AL'),(2707305,'Porto Calvo','AL'),(2707404,'Porto de Pedras','AL'),(2707503,'Porto Real do Colégio','AL'),(2707602,'Quebrangulo','AL'),(2707701,'Rio Largo','AL'),(2707800,'Roteiro','AL'),(2707909,'Santa Luzia do Norte','AL'),(2708006,'Santana do Ipanema','AL'),(2708105,'Santana do Mundaú','AL'),(2708204,'São Brás','AL'),(2708303,'São José da Laje','AL'),(2708402,'São José da Tapera','AL'),(2708501,'São Luís do Quitunde','AL'),(2708600,'São Miguel dos Campos','AL'),(2708709,'São Miguel dos Milagres','AL'),(2708808,'São Sebastião','AL'),(2708907,'Satuba','AL'),(2708956,'Senador Rui Palmeira','AL'),(2709004,'Tanque d''Arca','AL'),(2709103,'Taquarana','AL'),(2709152,'Teotônio Vilela','AL'),(2709202,'Traipu','AL'),(2709301,'União dos Palmares','AL'),(2709400,'Viçosa','AL'),(2800100,'Amparo de São Francisco','SE'),(2800209,'Aquidabã','SE'),(2800308,'Aracaju','SE'),(2800407,'Arauá','SE'),(2800506,'Areia Branca','SE'),(2800605,'Barra dos Coqueiros','SE'),(2800670,'Boquim','SE'),(2800704,'Brejo Grande','SE'),(2801009,'Campo do Brito','SE'),(2801108,'Canhoba','SE'),(2801207,'Canindé de São Francisco','SE'),(2801306,'Capela','SE'),(2801405,'Carira','SE'),(2801504,'Carmópolis','SE'),(2801603,'Cedro de São João','SE'),(2801702,'Cristinápolis','SE'),(2801900,'Cumbe','SE'),(2802007,'Divina Pastora','SE'),(2802106,'Estância','SE'),(2802205,'Feira Nova','SE'),(2802304,'Frei Paulo','SE'),(2802403,'Gararu','SE'),(2802502,'General Maynard','SE'),(2802601,'Gracho Cardoso','SE'),(2802700,'Ilha das Flores','SE'),(2802809,'Indiaroba','SE'),(2802908,'Itabaiana','SE'),(2803005,'Itabaianinha','SE'),(2803104,'Itabi','SE'),(2803203,'Itaporanga d''Ajuda','SE'),(2803302,'Japaratuba','SE'),(2803401,'Japoatã','SE'),(2803500,'Lagarto','SE'),(2803609,'Laranjeiras','SE'),(2803708,'Macambira','SE'),(2803807,'Malhada dos Bois','SE'),(2803906,'Malhador','SE'),(2804003,'Maruim','SE'),(2804102,'Moita Bonita','SE'),(2804201,'Monte Alegre de Sergipe','SE'),(2804300,'Muribeca','SE'),(2804409,'Neópolis','SE'),(2804458,'Nossa Senhora Aparecida','SE'),(2804508,'Nossa Senhora da Glória','SE'),(2804607,'Nossa Senhora das Dores','SE'),(2804706,'Nossa Senhora de Lourdes','SE'),(2804805,'Nossa Senhora do Socorro','SE'),(2804904,'Pacatuba','SE'),(2805000,'Pedra Mole','SE'),(2805109,'Pedrinhas','SE'),(2805208,'Pinhão','SE'),(2805307,'Pirambu','SE'),(2805406,'Poço Redondo','SE'),(2805505,'Poço Verde','SE'),(2805604,'Porto da Folha','SE'),(2805703,'Propriá','SE'),(2805802,'Riachão do Dantas','SE'),(2805901,'Riachuelo','SE'),(2806008,'Ribeirópolis','SE'),(2806107,'Rosário do Catete','SE'),(2806206,'Salgado','SE'),(2806305,'Santa Luzia do Itanhy','SE'),(2806404,'Santana do São Francisco','SE'),(2806503,'Santa Rosa de Lima','SE'),(2806602,'Santo Amaro das Brotas','SE'),(2806701,'São Cristóvão','SE'),(2806800,'São Domingos','SE'),(2806909,'São Francisco','SE'),(2807006,'São Miguel do Aleixo','SE'),(2807105,'Simão Dias','SE'),(2807204,'Siriri','SE'),(2807303,'Telha','SE'),(2807402,'Tobias Barreto','SE'),(2807501,'Tomar do Geru','SE'),(2807600,'Umbaúba','SE'),(2900108,'Abaíra','BA'),(2900207,'Abaré','BA'),(2900306,'Acajutiba','BA'),(2900355,'Adustina','BA'),(2900405,'Água Fria','BA'),(2900504,'Érico Cardoso','BA'),(2900603,'Aiquara','BA'),(2900702,'Alagoinhas','BA'),(2900801,'Alcobaça','BA'),(2900900,'Almadina','BA'),(2901007,'Amargosa','BA'),(2901106,'Amélia Rodrigues','BA'),(2901155,'América Dourada','BA'),(2901205,'Anagé','BA'),(2901304,'Andaraí','BA'),(2901353,'Andorinha','BA'),(2901403,'Angical','BA'),(2901502,'Anguera','BA'),(2901601,'Antas','BA'),(2901700,'Antônio Cardoso','BA'),(2901809,'Antônio Gonçalves','BA'),(2901908,'Aporá','BA'),(2901957,'Apuarema','BA'),(2902005,'Aracatu','BA'),(2902054,'Araças','BA'),(2902104,'Araci','BA'),(2902203,'Aramari','BA'),(2902252,'Arataca','BA'),(2902302,'Aratuípe','BA'),(2902401,'Aurelino Leal','BA'),(2902500,'Baianópolis','BA'),(2902609,'Baixa Grande','BA'),(2902658,'Banzaê','BA'),(2902708,'Barra','BA'),(2902807,'Barra da Estiva','BA'),(2902906,'Barra do Choça','BA'),(2903003,'Barra do Mendes','BA'),(2903102,'Barra do Rocha','BA'),(2903201,'Barreiras','BA'),(2903235,'Barro Alto','BA'),(2903276,'Barrocas','BA'),(2903300,'Barro Preto','BA'),(2903409,'Belmonte','BA'),(2903508,'Belo Campo','BA'),(2903607,'Biritinga','BA'),(2903706,'Boa Nova','BA'),(2903805,'Boa Vista do Tupim','BA'),(2903904,'Bom Jesus da Lapa','BA'),(2903953,'Bom Jesus da Serra','BA'),(2904001,'Boninal','BA'),(2904050,'Bonito','BA'),(2904100,'Boquira','BA'),(2904209,'Botuporã','BA'),(2904308,'Brejões','BA'),(2904407,'Brejolândia','BA'),(2904506,'Brotas de Macaúbas','BA'),(2904605,'Brumado','BA'),(2904704,'Buerarema','BA'),(2904753,'Buritirama','BA'),(2904803,'Caatiba','BA'),(2904852,'Cabaceiras do Paraguaçu','BA'),(2904902,'Cachoeira','BA'),(2905008,'Caculé','BA'),(2905107,'Caém','BA'),(2905156,'Caetanos','BA'),(2905206,'Caetité','BA'),(2905305,'Cafarnaum','BA'),(2905404,'Cairu','BA'),(2905503,'Caldeirão Grande','BA'),(2905602,'Camacan','BA'),(2905701,'Camaçari','BA'),(2905800,'Camamu','BA'),(2905909,'Campo Alegre de Lourdes','BA'),(2906006,'Campo Formoso','BA'),(2906105,'Canápolis','BA'),(2906204,'Canarana','BA'),(2906303,'Canavieiras','BA'),(2906402,'Candeal','BA'),(2906501,'Candeias','BA'),(2906600,'Candiba','BA'),(2906709,'Cândido Sales','BA'),(2906808,'Cansanção','BA'),(2906824,'Canudos','BA'),(2906857,'Capela do Alto Alegre','BA'),(2906873,'Capim Grosso','BA'),(2906899,'Caraíbas','BA'),(2906907,'Caravelas','BA'),(2907004,'Cardeal da Silva','BA'),(2907103,'Carinhanha','BA'),(2907202,'Casa Nova','BA'),(2907301,'Castro Alves','BA'),(2907400,'Catolândia','BA'),(2907509,'Catu','BA'),(2907558,'Caturama','BA'),(2907608,'Central','BA'),(2907707,'Chorrochó','BA'),(2907806,'Cícero Dantas','BA'),(2907905,'Cipó','BA'),(2908002,'Coaraci','BA'),(2908101,'Cocos','BA'),(2908200,'Conceição da Feira','BA'),(2908309,'Conceição do Almeida','BA'),(2908408,'Conceição do Coité','BA'),(2908507,'Conceição do Jacuípe','BA'),(2908606,'Conde','BA'),(2908705,'Condeúba','BA'),(2908804,'Contendas do Sincorá','BA'),(2908903,'Coração de Maria','BA'),(2909000,'Cordeiros','BA'),(2909109,'Coribe','BA'),(2909208,'Coronel João Sá','BA'),(2909307,'Correntina','BA'),(2909406,'Cotegipe','BA'),(2909505,'Cravolândia','BA'),(2909604,'Crisópolis','BA'),(2909703,'Cristópolis','BA'),(2909802,'Cruz das Almas','BA'),(2909901,'Curaçá','BA'),(2910008,'Dário Meira','BA'),(2910057,'Dias d''Ávila','BA'),(2910107,'Dom Basílio','BA'),(2910206,'Dom Macedo Costa','BA'),(2910305,'Elísio Medrado','BA'),(2910404,'Encruzilhada','BA'),(2910503,'Entre Rios','BA'),(2910602,'Esplanada','BA'),(2910701,'Euclides da Cunha','BA'),(2910727,'Eunápolis','BA'),(2910750,'Fátima','BA'),(2910776,'Feira da Mata','BA'),(2910800,'Feira de Santana','BA'),(2910859,'Filadélfia','BA'),(2910909,'Firmino Alves','BA'),(2911006,'Floresta Azul','BA'),(2911105,'Formosa do Rio Preto','BA'),(2911204,'Gandu','BA'),(2911253,'Gavião','BA'),(2911303,'Gentio do Ouro','BA'),(2911402,'Glória','BA'),(2911501,'Gongogi','BA'),(2911600,'Governador Mangabeira','BA'),(2911659,'Guajeru','BA'),(2911709,'Guanambi','BA'),(2911808,'Guaratinga','BA'),(2911857,'Heliópolis','BA'),(2911907,'Iaçu','BA'),(2912004,'Ibiassucê','BA'),(2912103,'Ibicaraí','BA'),(2912202,'Ibicoara','BA'),(2912301,'Ibicuí','BA'),(2912400,'Ibipeba','BA'),(2912509,'Ibipitanga','BA'),(2912608,'Ibiquera','BA'),(2912707,'Ibirapitanga','BA'),(2912806,'Ibirapuã','BA'),(2912905,'Ibirataia','BA'),(2913002,'Ibitiara','BA'),(2913101,'Ibititá','BA'),(2913200,'Ibotirama','BA'),(2913309,'Ichu','BA'),(2913408,'Igaporã','BA'),(2913457,'Igrapiúna','BA'),(2913507,'Iguaí','BA'),(2913606,'Ilhéus','BA'),(2913705,'Inhambupe','BA'),(2913804,'Ipecaetá','BA'),(2913903,'Ipiaú','BA'),(2914000,'Ipirá','BA'),(2914109,'Ipupiara','BA'),(2914208,'Irajuba','BA'),(2914307,'Iramaia','BA'),(2914406,'Iraquara','BA'),(2914505,'Irará','BA'),
(2914604,'Irecê','BA'),(2914653,'Itabela','BA'),(2914703,'Itaberaba','BA'),(2914802,'Itabuna','BA'),(2914901,'Itacaré','BA'),(2915007,'Itaeté','BA'),(2915106,'Itagi','BA'),(2915205,'Itagibá','BA'),(2915304,'Itagimirim','BA'),(2915353,'Itaguaçu da Bahia','BA'),(2915403,'Itaju do Colônia','BA'),(2915502,'Itajuípe','BA'),(2915601,'Itamaraju','BA'),(2915700,'Itamari','BA'),(2915809,'Itambé','BA'),(2915908,'Itanagra','BA'),(2916005,'Itanhém','BA'),(2916104,'Itaparica','BA'),(2916203,'Itapé','BA'),(2916302,'Itapebi','BA'),(2916401,'Itapetinga','BA'),(2916500,'Itapicuru','BA'),(2916609,'Itapitanga','BA'),(2916708,'Itaquara','BA'),(2916807,'Itarantim','BA'),(2916856,'Itatim','BA'),(2916906,'Itiruçu','BA'),(2917003,'Itiúba','BA'),(2917102,'Itororó','BA'),(2917201,'Ituaçu','BA'),(2917300,'Ituberá','BA'),(2917334,'Iuiú','BA'),(2917359,'Jaborandi','BA'),(2917409,'Jacaraci','BA'),(2917508,'Jacobina','BA'),(2917607,'Jaguaquara','BA'),(2917706,'Jaguarari','BA'),(2917805,'Jaguaripe','BA'),(2917904,'Jandaíra','BA'),(2918001,'Jequié','BA'),(2918100,'Jeremoabo','BA'),(2918209,'Jiquiriçá','BA'),(2918308,'Jitaúna','BA'),(2918357,'João Dourado','BA'),(2918407,'Juazeiro','BA'),(2918456,'Jucuruçu','BA'),(2918506,'Jussara','BA'),(2918555,'Jussari','BA'),(2918605,'Jussiape','BA'),(2918704,'Lafaiete Coutinho','BA'),(2918753,'Lagoa Real','BA'),(2918803,'Laje','BA'),(2918902,'Lajedão','BA'),(2919009,'Lajedinho','BA'),(2919058,'Lajedo do Tabocal','BA'),(2919108,'Lamarão','BA'),(2919157,'Lapão','BA'),(2919207,'Lauro de Freitas','BA'),(2919306,'Lençóis','BA'),(2919405,'Licínio de Almeida','BA'),(2919504,'Livramento de Nossa Senhora','BA'),(2919553,'Luís Eduardo Magalhães','BA'),(2919603,'Macajuba','BA'),(2919702,'Macarani','BA'),(2919801,'Macaúbas','BA'),(2919900,'Macururé','BA'),(2919926,'Madre de Deus','BA'),(2919959,'Maetinga','BA'),(2920007,'Maiquinique','BA'),(2920106,'Mairi','BA'),(2920205,'Malhada','BA'),(2920304,'Malhada de Pedras','BA'),(2920403,'Manoel Vitorino','BA'),(2920452,'Mansidão','BA'),(2920502,'Maracás','BA'),(2920601,'Maragogipe','BA'),(2920700,'Maraú','BA'),(2920809,'Marcionílio Souza','BA'),(2920908,'Mascote','BA'),(2921005,'Mata de São João','BA'),(2921054,'Matina','BA'),(2921104,'Medeiros Neto','BA'),(2921203,'Miguel Calmon','BA'),(2921302,'Milagres','BA'),(2921401,'Mirangaba','BA'),(2921450,'Mirante','BA'),(2921500,'Monte Santo','BA'),(2921609,'Morpará','BA'),(2921708,'Morro do Chapéu','BA'),(2921807,'Mortugaba','BA'),(2921906,'Mucugê','BA'),(2922003,'Mucuri','BA'),(2922052,'Mulungu do Morro','BA'),(2922102,'Mundo Novo','BA'),(2922201,'Muniz Ferreira','BA'),(2922250,'Muquém de São Francisco','BA'),(2922300,'Muritiba','BA'),(2922409,'Mutuípe','BA'),(2922508,'Nazaré','BA'),(2922607,'Nilo Peçanha','BA'),(2922656,'Nordestina','BA'),(2922706,'Nova Canaã','BA'),(2922730,'Nova Fátima','BA'),(2922755,'Nova Ibiá','BA'),(2922805,'Nova Itarana','BA'),(2922854,'Nova Redenção','BA'),(2922904,'Nova Soure','BA'),(2923001,'Nova Viçosa','BA'),(2923035,'Novo Horizonte','BA'),(2923050,'Novo Triunfo','BA'),(2923100,'Olindina','BA'),(2923209,'Oliveira dos Brejinhos','BA'),(2923308,'Ouriçangas','BA'),(2923357,'Ourolândia','BA'),(2923407,'Palmas de Monte Alto','BA'),(2923506,'Palmeiras','BA'),(2923605,'Paramirim','BA'),(2923704,'Paratinga','BA'),(2923803,'Paripiranga','BA'),(2923902,'Pau Brasil','BA'),(2924009,'Paulo Afonso','BA'),(2924058,'Pé de Serra','BA'),(2924108,'Pedrão','BA'),(2924207,'Pedro Alexandre','BA'),(2924306,'Piatã','BA'),(2924405,'Pilão Arcado','BA'),(2924504,'Pindaí','BA'),(2924603,'Pindobaçu','BA'),(2924652,'Pintadas','BA'),(2924678,'Piraí do Norte','BA'),(2924702,'Piripá','BA'),(2924801,'Piritiba','BA'),(2924900,'Planaltino','BA'),(2925006,'Planalto','BA'),(2925105,'Poções','BA'),(2925204,'Pojuca','BA'),(2925253,'Ponto Novo','BA'),(2925303,'Porto Seguro','BA'),(2925402,'Potiraguá','BA'),(2925501,'Prado','BA'),(2925600,'Presidente Dutra','BA'),(2925709,'Presidente Jânio Quadros','BA'),(2925758,'Presidente Tancredo Neves','BA'),(2925808,'Queimadas','BA'),(2925907,'Quijingue','BA'),(2925931,'Quixabeira','BA'),(2925956,'Rafael Jambeiro','BA'),(2926004,'Remanso','BA'),(2926103,'Retirolândia','BA'),(2926202,'Riachão das Neves','BA'),(2926301,'Riachão do Jacuípe','BA'),(2926400,'Riacho de Santana','BA'),(2926509,'Ribeira do Amparo','BA'),(2926608,'Ribeira do Pombal','BA'),(2926657,'Ribeirão do Largo','BA'),(2926707,'Rio de Contas','BA'),(2926806,'Rio do Antônio','BA'),(2926905,'Rio do Pires','BA'),(2927002,'Rio Real','BA'),(2927101,'Rodelas','BA'),(2927200,'Ruy Barbosa','BA'),(2927309,'Salinas da Margarida','BA'),(2927408,'Salvador','BA'),(2927507,'Santa Bárbara','BA'),(2927606,'Santa Brígida','BA'),(2927705,'Santa Cruz Cabrália','BA'),(2927804,'Santa Cruz da Vitória','BA'),(2927903,'Santa Inês','BA'),(2928000,'Santaluz','BA'),(2928059,'Santa Luzia','BA'),(2928109,'Santa Maria da Vitória','BA'),(2928208,'Santana','BA'),(2928307,'Santanópolis','BA'),(2928406,'Santa Rita de Cássia','BA'),(2928505,'Santa Teresinha','BA'),(2928604,'Santo Amaro','BA'),(2928703,'Santo Antônio de Jesus','BA'),(2928802,'Santo Estêvão','BA'),(2928901,'São Desidério','BA'),(2928950,'São Domingos','BA'),(2929008,'São Félix','BA'),(2929057,'São Félix do Coribe','BA'),(2929107,'São Felipe','BA'),(2929206,'São Francisco do Conde','BA'),(2929255,'São Gabriel','BA'),(2929305,'São Gonçalo dos Campos','BA'),(2929354,'São José da Vitória','BA'),(2929370,'São José do Jacuípe','BA'),(2929404,'São Miguel das Matas','BA'),(2929503,'São Sebastião do Passé','BA'),(2929602,'Sapeaçu','BA'),(2929701,'Sátiro Dias','BA'),(2929750,'Saubara','BA'),(2929800,'Saúde','BA'),(2929909,'Seabra','BA'),(2930006,'Sebastião Laranjeiras','BA'),(2930105,'Senhor do Bonfim','BA'),(2930154,'Serra do Ramalho','BA'),(2930204,'Sento Sé','BA'),(2930303,'Serra Dourada','BA'),(2930402,'Serra Preta','BA'),(2930501,'Serrinha','BA'),(2930600,'Serrolândia','BA'),(2930709,'Simões Filho','BA'),(2930758,'Sítio do Mato','BA'),(2930766,'Sítio do Quinto','BA'),(2930774,'Sobradinho','BA'),(2930808,'Souto Soares','BA'),(2930907,'Tabocas do Brejo Velho','BA'),(2931004,'Tanhaçu','BA'),(2931053,'Tanque Novo','BA'),(2931103,'Tanquinho','BA'),(2931202,'Taperoá','BA'),(2931301,'Tapiramutá','BA'),(2931350,'Teixeira de Freitas','BA'),(2931400,'Teodoro Sampaio','BA'),(2931509,'Teofilândia','BA'),(2931608,'Teolândia','BA'),(2931707,'Terra Nova','BA'),(2931806,'Tremedal','BA'),(2931905,'Tucano','BA'),(2932002,'Uauá','BA'),(2932101,'Ubaíra','BA'),(2932200,'Ubaitaba','BA'),(2932309,'Ubatã','BA'),(2932408,'Uibaí','BA'),(2932457,'Umburanas','BA'),(2932507,'Una','BA'),(2932606,'Urandi','BA'),(2932705,'Uruçuca','BA'),(2932804,'Utinga','BA'),(2932903,'Valença','BA'),(2933000,'Valente','BA'),(2933059,'Várzea da Roça','BA'),(2933109,'Várzea do Poço','BA'),(2933158,'Várzea Nova','BA'),(2933174,'Varzedo','BA'),(2933208,'Vera Cruz','BA'),(2933257,'Vereda','BA'),(2933307,'Vitória da Conquista','BA'),(2933406,'Wagner','BA'),(2933455,'Wanderley','BA'),(2933505,'Wenceslau Guimarães','BA'),(2933604,'Xique-Xique','BA'),(3100104,'Abadia dos Dourados','MG'),(3100203,'Abaeté','MG'),(3100302,'Abre Campo','MG'),(3100401,'Acaiaca','MG'),(3100500,'Açucena','MG'),(3100609,'Água Boa','MG'),(3100708,'Água Comprida','MG'),(3100807,'Aguanil','MG'),(3100906,'Águas Formosas','MG'),(3101003,'Águas Vermelhas','MG'),(3101102,'Aimorés','MG'),(3101201,'Aiuruoca','MG'),(3101300,'Alagoa','MG'),(3101409,'Albertina','MG'),(3101508,'Além Paraíba','MG'),(3101607,'Alfenas','MG'),(3101631,'Alfredo Vasconcelos','MG'),(3101706,'Almenara','MG'),(3101805,'Alpercata','MG'),(3101904,'Alpinópolis','MG'),(3102001,'Alterosa','MG'),(3102050,'Alto Caparaó','MG'),(3102100,'Alto Rio Doce','MG'),(3102209,'Alvarenga','MG'),(3102308,'Alvinópolis','MG'),(3102407,'Alvorada de Minas','MG'),(3102506,'Amparo do Serra','MG'),(3102605,'Andradas','MG'),(3102704,'Cachoeira de Pajeú','MG'),(3102803,'Andrelândia','MG'),(3102852,'Angelândia','MG'),(3102902,'Antônio Carlos','MG'),(3103009,'Antônio Dias','MG'),(3103108,'Antônio Prado de Minas','MG'),(3103207,'Araçaí','MG'),(3103306,'Aracitaba','MG'),(3103405,'Araçuaí','MG'),(3103504,'Araguari','MG'),(3103603,'Arantina','MG'),(3103702,'Araponga','MG'),(3103751,'Araporã','MG'),(3103801,'Arapuá','MG'),(3103900,'Araújos','MG'),(3104007,'Araxá','MG'),(3104106,'Arceburgo','MG'),(3104205,'Arcos','MG'),(3104304,'Areado','MG'),(3104403,'Argirita','MG'),(3104452,'Aricanduva','MG'),(3104502,'Arinos','MG'),(3104601,'Astolfo Dutra','MG'),(3104700,'Ataléia','MG'),(3104809,'Augusto de Lima','MG'),(3104908,'Baependi','MG'),(3105004,'Baldim','MG'),(3105103,'Bambuí','MG'),(3105202,'Bandeira','MG'),(3105301,'Bandeira do Sul','MG'),(3105400,'Barão de Cocais','MG'),(3105509,'Barão de Monte Alto','MG'),(3105608,'Barbacena','MG'),(3105707,'Barra Longa','MG'),(3105905,'Barroso','MG'),(3106002,'Bela Vista de Minas','MG'),(3106101,'Belmiro Braga','MG'),(3106200,'Belo Horizonte','MG'),(3106309,'Belo Oriente','MG'),(3106408,'Belo Vale','MG'),(3106507,'Berilo','MG'),(3106606,'Bertópolis','MG'),(3106655,'Berizal','MG'),(3106705,'Betim','MG'),(3106804,'Bias Fortes','MG'),(3106903,'Bicas','MG'),(3107000,'Biquinhas','MG'),(3107109,'Boa Esperança','MG'),(3107208,'Bocaina de Minas','MG'),(3107307,'Bocaiúva','MG'),(3107406,'Bom Despacho','MG'),(3107505,'Bom Jardim de Minas','MG'),(3107604,'Bom Jesus da Penha','MG'),(3107703,'Bom Jesus do Amparo','MG'),(3107802,'Bom Jesus do Galho','MG'),(3107901,'Bom Repouso','MG'),(3108008,'Bom Sucesso','MG'),(3108107,'Bonfim','MG'),(3108206,'Bonfinópolis de Minas','MG'),(3108255,'Bonito de Minas','MG'),(3108305,'Borda da Mata','MG'),(3108404,'Botelhos','MG'),(3108503,'Botumirim','MG'),(3108552,'Brasilândia de Minas','MG'),(3108602,'Brasília de Minas','MG'),(3108701,'Brás Pires','MG'),(3108800,'Braúnas','MG'),(3108909,'Brazópolis','MG'),(3109006,'Brumadinho','MG'),(3109105,'Bueno Brandão','MG'),(3109204,'Buenópolis','MG'),(3109253,'Bugre','MG'),(3109303,'Buritis','MG'),(3109402,'Buritizeiro','MG'),(3109451,'Cabeceira Grande','MG'),(3109501,'Cabo Verde','MG'),(3109600,'Cachoeira da Prata','MG'),(3109709,'Cachoeira de Minas','MG'),(3109808,'Cachoeira Dourada','MG'),(3109907,'Caetanópolis','MG'),(3110004,'Caeté','MG'),(3110103,'Caiana','MG'),(3110202,'Cajuri','MG'),(3110301,'Caldas','MG'),(3110400,'Camacho','MG'),(3110509,'Camanducaia','MG'),(3110608,'Cambuí','MG'),(3110707,'Cambuquira','MG'),(3110806,'Campanário','MG'),(3110905,'Campanha','MG'),(3111002,'Campestre','MG'),(3111101,'Campina Verde','MG'),(3111150,'Campo Azul','MG'),(3111200,'Campo Belo','MG'),(3111309,'Campo do Meio','MG'),(3111408,'Campo Florido','MG'),(3111507,'Campos Altos','MG'),(3111606,'Campos Gerais','MG'),(3111705,'Canaã','MG'),(3111804,'Canápolis','MG'),(3111903,'Cana Verde','MG'),(3112000,'Candeias','MG'),(3112059,'Cantagalo','MG'),(3112109,'Caparaó','MG'),(3112208,'Capela Nova','MG'),(3112307,'Capelinha','MG'),(3112406,'Capetinga','MG'),(3112505,'Capim Branco','MG'),(3112604,'Capinópolis','MG'),(3112653,'Capitão Andrade','MG'),(3112703,'Capitão Enéas','MG'),(3112802,'Capitólio','MG'),(3112901,'Caputira','MG'),(3113008,'Caraí','MG'),(3113107,'Caranaíba','MG'),(3113206,'Carandaí','MG'),(3113305,'Carangola','MG'),(3113404,'Caratinga','MG'),(3113503,'Carbonita','MG'),(3113602,'Careaçu','MG'),(3113701,'Carlos Chagas','MG'),(3113800,'Carmésia','MG'),(3113909,'Carmo da Cachoeira','MG'),(3114006,'Carmo da Mata','MG'),(3114105,'Carmo de Minas','MG'),(3114204,'Carmo do Cajuru','MG'),(3114303,'Carmo do Paranaíba','MG'),(3114402,'Carmo do Rio Claro','MG'),(3114501,'Carmópolis de Minas','MG'),(3114550,'Carneirinho','MG'),(3114600,'Carrancas','MG'),(3114709,'Carvalhópolis','MG'),(3114808,'Carvalhos','MG'),(3114907,'Casa Grande','MG'),(3115003,'Cascalho Rico','MG'),(3115102,'Cássia','MG'),(3115201,'Conceição da Barra de Minas','MG'),(3115300,'Cataguases','MG'),(3115359,'Catas Altas','MG'),(3115409,'Catas Altas da Noruega','MG'),(3115458,'Catuji','MG'),(3115474,'Catuti','MG'),(3115508,'Caxambu','MG'),(3115607,'Cedro do Abaeté','MG'),(3115706,'Central de Minas','MG'),(3115805,'Centralina','MG'),(3115904,'Chácara','MG'),(3116001,'Chalé','MG'),(3116100,'Chapada do Norte','MG'),(3116159,'Chapada Gaúcha','MG'),(3116209,'Chiador','MG'),(3116308,'Cipotânea','MG'),(3116407,'Claraval','MG'),(3116506,'Claro dos Poções','MG'),(3116605,'Cláudio','MG'),(3116704,'Coimbra','MG'),(3116803,'Coluna','MG'),(3116902,'Comendador Gomes','MG'),(3117009,'Comercinho','MG'),(3117108,'Conceição da Aparecida','MG'),(3117207,'Conceição das Pedras','MG'),(3117306,'Conceição das Alagoas','MG'),(3117405,'Conceição de Ipanema','MG'),(3117504,'Conceição do Mato Dentro','MG'),(3117603,'Conceição do Pará','MG'),(3117702,'Conceição do Rio Verde','MG'),(3117801,'Conceição dos Ouros','MG'),(3117836,'Cônego Marinho','MG'),(3117876,'Confins','MG'),(3117900,'Congonhal','MG'),(3118007,'Congonhas','MG'),(3118106,'Congonhas do Norte','MG'),(3118205,'Conquista','MG'),(3118304,'Conselheiro Lafaiete','MG'),(3118403,'Conselheiro Pena','MG'),(3118502,'Consolação','MG'),(3118601,'Contagem','MG'),(3118700,'Coqueiral','MG'),(3118809,'Coração de Jesus','MG'),(3118908,'Cordisburgo','MG'),(3119005,'Cordislândia','MG'),(3119104,'Corinto','MG'),(3119203,'Coroaci','MG'),(3119302,'Coromandel','MG'),(3119401,'Coronel Fabriciano','MG'),(3119500,'Coronel Murta','MG'),(3119609,'Coronel Pacheco','MG'),(3119708,'Coronel Xavier Chaves','MG'),(3119807,'Córrego Danta','MG'),(3119906,'Córrego do Bom Jesus','MG'),(3119955,'Córrego Fundo','MG'),(3120003,'Córrego Novo','MG'),(3120102,'Couto de Magalhães de Minas','MG'),(3120151,'Crisólita','MG'),(3120201,'Cristais','MG'),(3120300,'Cristália','MG'),(3120409,'Cristiano Otoni','MG'),(3120508,'Cristina','MG'),(3120607,'Crucilândia','MG'),(3120706,'Cruzeiro da Fortaleza','MG'),(3120805,'Cruzília','MG'),(3120839,'Cuparaque','MG'),(3120870,'Curral de Dentro','MG'),(3120904,'Curvelo','MG'),(3121001,'Datas','MG'),(3121100,'Delfim Moreira','MG'),(3121209,'Delfinópolis','MG'),(3121258,'Delta','MG'),(3121308,'Descoberto','MG'),(3121407,'Desterro de Entre Rios','MG'),(3121506,'Desterro do Melo','MG'),(3121605,'Diamantina','MG'),(3121704,'Diogo de Vasconcelos','MG'),(3121803,'Dionísio','MG'),(3121902,'Divinésia','MG'),(3122009,'Divino','MG'),(3122108,'Divino das Laranjeiras','MG'),(3122207,'Divinolândia de Minas','MG'),(3122306,'Divinópolis','MG'),(3122355,'Divisa Alegre','MG'),(3122405,'Divisa Nova','MG'),(3122454,'Divisópolis','MG'),(3122470,'Dom Bosco','MG'),(3122504,'Dom Cavati','MG'),(3122603,'Dom Joaquim','MG'),(3122702,'Dom Silvério','MG'),(3122801,'Dom Viçoso','MG'),(3122900,'Dona Eusébia','MG'),
(3123007,'Dores de Campos','MG'),(3123106,'Dores de Guanhães','MG'),(3123205,'Dores do Indaiá','MG'),(3123304,'Dores do Turvo','MG'),(3123403,'Doresópolis','MG'),(3123502,'Douradoquara','MG'),(3123528,'Durandé','MG'),(3123601,'Elói Mendes','MG'),(3123700,'Engenheiro Caldas','MG'),(3123809,'Engenheiro Navarro','MG'),(3123858,'Entre Folhas','MG'),(3123908,'Entre Rios de Minas','MG'),(3124005,'Ervália','MG'),(3124104,'Esmeraldas','MG'),(3124203,'Espera Feliz','MG'),(3124302,'Espinosa','MG'),(3124401,'Espírito Santo do Dourado','MG'),(3124500,'Estiva','MG'),(3124609,'Estrela Dalva','MG'),(3124708,'Estrela do Indaiá','MG'),(3124807,'Estrela do Sul','MG'),(3124906,'Eugenópolis','MG'),(3125002,'Ewbank da Câmara','MG'),(3125101,'Extrema','MG'),(3125200,'Fama','MG'),(3125309,'Faria Lemos','MG'),(3125408,'Felício dos Santos','MG'),(3125507,'São Gonçalo do Rio Preto','MG'),(3125606,'Felisburgo','MG'),(3125705,'Felixlândia','MG'),(3125804,'Fernandes Tourinho','MG'),(3125903,'Ferros','MG'),(3125952,'Fervedouro','MG'),(3126000,'Florestal','MG'),(3126109,'Formiga','MG'),(3126208,'Formoso','MG'),(3126307,'Fortaleza de Minas','MG'),(3126406,'Fortuna de Minas','MG'),(3126505,'Francisco Badaró','MG'),(3126604,'Francisco Dumont','MG'),(3126703,'Francisco Sá','MG'),(3126752,'Franciscópolis','MG'),(3126802,'Frei Gaspar','MG'),(3126901,'Frei Inocêncio','MG'),(3126950,'Frei Lagonegro','MG'),(3127008,'Fronteira','MG'),(3127057,'Fronteira dos Vales','MG'),(3127073,'Fruta de Leite','MG'),(3127107,'Frutal','MG'),(3127206,'Funilândia','MG'),(3127305,'Galiléia','MG'),(3127339,'Gameleiras','MG'),(3127354,'Glaucilândia','MG'),(3127370,'Goiabeira','MG'),(3127388,'Goianá','MG'),(3127404,'Gonçalves','MG'),(3127503,'Gonzaga','MG'),(3127602,'Gouveia','MG'),(3127701,'Governador Valadares','MG'),(3127800,'Grão Mogol','MG'),(3127909,'Grupiara','MG'),(3128006,'Guanhães','MG'),(3128105,'Guapé','MG'),(3128204,'Guaraciaba','MG'),(3128253,'Guaraciama','MG'),(3128303,'Guaranésia','MG'),(3128402,'Guarani','MG'),(3128501,'Guarará','MG'),(3128600,'Guarda-Mor','MG'),(3128709,'Guaxupé','MG'),(3128808,'Guidoval','MG'),(3128907,'Guimarânia','MG'),(3129004,'Guiricema','MG'),(3129103,'Gurinhatã','MG'),(3129202,'Heliodora','MG'),(3129301,'Iapu','MG'),(3129400,'Ibertioga','MG'),(3129509,'Ibiá','MG'),(3129608,'Ibiaí','MG'),(3129657,'Ibiracatu','MG'),(3129707,'Ibiraci','MG'),(3129806,'Ibirité','MG'),(3129905,'Ibitiúra de Minas','MG'),(3130002,'Ibituruna','MG'),(3130051,'Icaraí de Minas','MG'),(3130101,'Igarapé','MG'),(3130200,'Igaratinga','MG'),(3130309,'Iguatama','MG'),(3130408,'Ijaci','MG'),(3130507,'Ilicínea','MG'),(3130556,'Imbé de Minas','MG'),(3130606,'Inconfidentes','MG'),(3130655,'Indaiabira','MG'),(3130705,'Indianópolis','MG'),(3130804,'Ingaí','MG'),(3130903,'Inhapim','MG'),(3131000,'Inhaúma','MG'),(3131109,'Inimutaba','MG'),(3131158,'Ipaba','MG'),(3131208,'Ipanema','MG'),(3131307,'Ipatinga','MG'),(3131406,'Ipiaçu','MG'),(3131505,'Ipuiúna','MG'),(3131604,'Iraí de Minas','MG'),(3131703,'Itabira','MG'),(3131802,'Itabirinha','MG'),(3131901,'Itabirito','MG'),(3132008,'Itacambira','MG'),(3132107,'Itacarambi','MG'),(3132206,'Itaguara','MG'),(3132305,'Itaipé','MG'),(3132404,'Itajubá','MG'),(3132503,'Itamarandiba','MG'),(3132602,'Itamarati de Minas','MG'),(3132701,'Itambacuri','MG'),(3132800,'Itambé do Mato Dentro','MG'),(3132909,'Itamogi','MG'),(3133006,'Itamonte','MG'),(3133105,'Itanhandu','MG'),(3133204,'Itanhomi','MG'),(3133303,'Itaobim','MG'),(3133402,'Itapagipe','MG'),(3133501,'Itapecerica','MG'),(3133600,'Itapeva','MG'),(3133709,'Itatiaiuçu','MG'),(3133758,'Itaú de Minas','MG'),(3133808,'Itaúna','MG'),(3133907,'Itaverava','MG'),(3134004,'Itinga','MG'),(3134103,'Itueta','MG'),(3134202,'Ituiutaba','MG'),(3134301,'Itumirim','MG'),(3134400,'Iturama','MG'),(3134509,'Itutinga','MG'),(3134608,'Jaboticatubas','MG'),(3134707,'Jacinto','MG'),(3134806,'Jacuí','MG'),(3134905,'Jacutinga','MG'),(3135001,'Jaguaraçu','MG'),(3135050,'Jaíba','MG'),(3135076,'Jampruca','MG'),(3135100,'Janaúba','MG'),(3135209,'Januária','MG'),(3135308,'Japaraíba','MG'),(3135357,'Japonvar','MG'),(3135407,'Jeceaba','MG'),(3135456,'Jenipapo de Minas','MG'),(3135506,'Jequeri','MG'),(3135605,'Jequitaí','MG'),(3135704,'Jequitibá','MG'),(3135803,'Jequitinhonha','MG'),(3135902,'Jesuânia','MG'),(3136009,'Joaíma','MG'),(3136108,'Joanésia','MG'),(3136207,'João Monlevade','MG'),(3136306,'João Pinheiro','MG'),(3136405,'Joaquim Felício','MG'),(3136504,'Jordânia','MG'),(3136520,'José Gonçalves de Minas','MG'),(3136553,'José Raydan','MG'),(3136579,'Josenópolis','MG'),(3136603,'Nova União','MG'),(3136652,'Juatuba','MG'),(3136702,'Juiz de Fora','MG'),(3136801,'Juramento','MG'),(3136900,'Juruaia','MG'),(3136959,'Juvenília','MG'),(3137007,'Ladainha','MG'),(3137106,'Lagamar','MG'),(3137205,'Lagoa da Prata','MG'),(3137304,'Lagoa dos Patos','MG'),(3137403,'Lagoa Dourada','MG'),(3137502,'Lagoa Formosa','MG'),(3137536,'Lagoa Grande','MG'),(3137601,'Lagoa Santa','MG'),(3137700,'Lajinha','MG'),(3137809,'Lambari','MG'),(3137908,'Lamim','MG'),(3138005,'Laranjal','MG'),(3138104,'Lassance','MG'),(3138203,'Lavras','MG'),(3138302,'Leandro Ferreira','MG'),(3138351,'Leme do Prado','MG'),(3138401,'Leopoldina','MG'),(3138500,'Liberdade','MG'),(3138609,'Lima Duarte','MG'),(3138625,'Limeira do Oeste','MG'),(3138658,'Lontra','MG'),(3138674,'Luisburgo','MG'),(3138682,'Luislândia','MG'),(3138708,'Luminárias','MG'),(3138807,'Luz','MG'),(3138906,'Machacalis','MG'),(3139003,'Machado','MG'),(3139102,'Madre de Deus de Minas','MG'),(3139201,'Malacacheta','MG'),(3139250,'Mamonas','MG'),(3139300,'Manga','MG'),(3139409,'Manhuaçu','MG'),(3139508,'Manhumirim','MG'),(3139607,'Mantena','MG'),(3139706,'Maravilhas','MG'),(3139805,'Mar de Espanha','MG'),(3139904,'Maria da Fé','MG'),(3140001,'Mariana','MG'),(3140100,'Marilac','MG'),(3140159,'Mário Campos','MG'),(3140209,'Maripá de Minas','MG'),(3140308,'Marliéria','MG'),(3140407,'Marmelópolis','MG'),(3140506,'Martinho Campos','MG'),(3140530,'Martins Soares','MG'),(3140555,'Mata Verde','MG'),(3140605,'Materlândia','MG'),(3140704,'Mateus Leme','MG'),(3140803,'Matias Barbosa','MG'),(3140852,'Matias Cardoso','MG'),(3140902,'Matipó','MG'),(3141009,'Mato Verde','MG'),(3141108,'Matozinhos','MG'),(3141207,'Matutina','MG'),(3141306,'Medeiros','MG'),(3141405,'Medina','MG'),(3141504,'Mendes Pimentel','MG'),(3141603,'Mercês','MG'),(3141702,'Mesquita','MG'),(3141801,'Minas Novas','MG'),(3141900,'Minduri','MG'),(3142007,'Mirabela','MG'),(3142106,'Miradouro','MG'),(3142205,'Miraí','MG'),(3142254,'Miravânia','MG'),(3142304,'Moeda','MG'),(3142403,'Moema','MG'),(3142502,'Monjolos','MG'),(3142601,'Monsenhor Paulo','MG'),(3142700,'Montalvânia','MG'),(3142809,'Monte Alegre de Minas','MG'),(3142908,'Monte Azul','MG'),(3143005,'Monte Belo','MG'),(3143104,'Monte Carmelo','MG'),(3143153,'Monte Formoso','MG'),(3143203,'Monte Santo de Minas','MG'),(3143302,'Montes Claros','MG'),(3143401,'Monte Sião','MG'),(3143450,'Montezuma','MG'),(3143500,'Morada Nova de Minas','MG'),(3143609,'Morro da Garça','MG'),(3143708,'Morro do Pilar','MG'),(3143807,'Munhoz','MG'),(3143906,'Muriaé','MG'),(3144003,'Mutum','MG'),(3144102,'Muzambinho','MG'),(3144201,'Nacip Raydan','MG'),(3144300,'Nanuque','MG'),(3144359,'Naque','MG'),(3144375,'Natalândia','MG'),(3144409,'Natércia','MG'),(3144508,'Nazareno','MG'),(3144607,'Nepomuceno','MG'),(3144656,'Ninheira','MG'),(3144672,'Nova Belém','MG'),(3144706,'Nova Era','MG'),(3144805,'Nova Lima','MG'),(3144904,'Nova Módica','MG'),(3145000,'Nova Ponte','MG'),(3145059,'Nova Porteirinha','MG'),(3145109,'Nova Resende','MG'),(3145208,'Nova Serrana','MG'),(3145307,'Novo Cruzeiro','MG'),(3145356,'Novo Oriente de Minas','MG'),(3145372,'Novorizonte','MG'),(3145406,'Olaria','MG'),(3145455,'Olhos d''Água','MG'),(3145505,'Olímpio Noronha','MG'),(3145604,'Oliveira','MG'),(3145703,'Oliveira Fortes','MG'),(3145802,'Onça de Pitangui','MG'),(3145851,'Oratórios','MG'),(3145877,'Orizânia','MG'),(3145901,'Ouro Branco','MG'),(3146008,'Ouro Fino','MG'),(3146107,'Ouro Preto','MG'),(3146206,'Ouro Verde de Minas','MG'),(3146255,'Padre Carvalho','MG'),(3146305,'Padre Paraíso','MG'),(3146404,'Paineiras','MG'),(3146503,'Pains','MG'),(3146552,'Pai Pedro','MG'),(3146602,'Paiva','MG'),(3146701,'Palma','MG'),(3146750,'Palmópolis','MG'),(3146909,'Papagaios','MG'),(3147006,'Paracatu','MG'),(3147105,'Pará de Minas','MG'),(3147204,'Paraguaçu','MG'),(3147303,'Paraisópolis','MG'),(3147402,'Paraopeba','MG'),(3147501,'Passabém','MG'),(3147600,'Passa Quatro','MG'),(3147709,'Passa Tempo','MG'),(3147808,'Passa-Vinte','MG'),(3147907,'Passos','MG'),(3147956,'Patis','MG'),(3148004,'Patos de Minas','MG'),(3148103,'Patrocínio','MG'),(3148202,'Patrocínio do Muriaé','MG'),(3148301,'Paula Cândido','MG'),(3148400,'Paulistas','MG'),(3148509,'Pavão','MG'),(3148608,'Peçanha','MG'),(3148707,'Pedra Azul','MG'),(3148756,'Pedra Bonita','MG'),(3148806,'Pedra do Anta','MG'),(3148905,'Pedra do Indaiá','MG'),(3149002,'Pedra Dourada','MG'),(3149101,'Pedralva','MG'),(3149150,'Pedras de Maria da Cruz','MG'),(3149200,'Pedrinópolis','MG'),(3149309,'Pedro Leopoldo','MG'),(3149408,'Pedro Teixeira','MG'),(3149507,'Pequeri','MG'),(3149606,'Pequi','MG'),(3149705,'Perdigão','MG'),(3149804,'Perdizes','MG'),(3149903,'Perdões','MG'),(3149952,'Periquito','MG'),(3150000,'Pescador','MG'),(3150109,'Piau','MG'),(3150158,'Piedade de Caratinga','MG'),(3150208,'Piedade de Ponte Nova','MG'),(3150307,'Piedade do Rio Grande','MG'),(3150406,'Piedade dos Gerais','MG'),(3150505,'Pimenta','MG'),(3150539,'Pingo-d''Água','MG'),(3150570,'Pintópolis','MG'),(3150604,'Piracema','MG'),(3150703,'Pirajuba','MG'),(3150802,'Piranga','MG'),(3150901,'Piranguçu','MG'),(3151008,'Piranguinho','MG'),(3151107,'Pirapetinga','MG'),(3151206,'Pirapora','MG'),(3151305,'Piraúba','MG'),(3151404,'Pitangui','MG'),(3151503,'Piumhi','MG'),(3151602,'Planura','MG'),(3151701,'Poço Fundo','MG'),(3151800,'Poços de Caldas','MG'),(3151909,'Pocrane','MG'),(3152006,'Pompéu','MG'),(3152105,'Ponte Nova','MG'),(3152131,'Ponto Chique','MG'),(3152170,'Ponto dos Volantes','MG'),(3152204,'Porteirinha','MG'),(3152303,'Porto Firme','MG'),(3152402,'Poté','MG'),(3152501,'Pouso Alegre','MG'),(3152600,'Pouso Alto','MG'),(3152709,'Prados','MG'),(3152808,'Prata','MG'),(3152907,'Pratápolis','MG'),(3153004,'Pratinha','MG'),(3153103,'Presidente Bernardes','MG'),(3153202,'Presidente Juscelino','MG'),(3153301,'Presidente Kubitschek','MG'),(3153400,'Presidente Olegário','MG'),(3153509,'Alto Jequitibá','MG'),(3153608,'Prudente de Morais','MG'),(3153707,'Quartel Geral','MG'),(3153806,'Queluzito','MG'),(3153905,'Raposos','MG'),(3154002,'Raul Soares','MG'),(3154101,'Recreio','MG'),(3154150,'Reduto','MG'),(3154200,'Resende Costa','MG'),(3154309,'Resplendor','MG'),(3154408,'Ressaquinha','MG'),(3154457,'Riachinho','MG'),(3154507,'Riacho dos Machados','MG'),(3154606,'Ribeirão das Neves','MG'),(3154705,'Ribeirão Vermelho','MG'),(3154804,'Rio Acima','MG'),(3154903,'Rio Casca','MG'),(3155009,'Rio Doce','MG'),(3155108,'Rio do Prado','MG'),(3155207,'Rio Espera','MG'),(3155306,'Rio Manso','MG'),(3155405,'Rio Novo','MG'),(3155504,'Rio Paranaíba','MG'),(3155603,'Rio Pardo de Minas','MG'),(3155702,'Rio Piracicaba','MG'),(3155801,'Rio Pomba','MG'),(3155900,'Rio Preto','MG'),(3156007,'Rio Vermelho','MG'),(3156106,'Ritápolis','MG'),(3156205,'Rochedo de Minas','MG'),(3156304,'Rodeiro','MG'),(3156403,'Romaria','MG'),(3156452,'Rosário da Limeira','MG'),(3156502,'Rubelita','MG'),(3156601,'Rubim','MG'),(3156700,'Sabará','MG'),(3156809,'Sabinópolis','MG'),(3156908,'Sacramento','MG'),(3157005,'Salinas','MG'),(3157104,'Salto da Divisa','MG'),(3157203,'Santa Bárbara','MG'),(3157252,'Santa Bárbara do Leste','MG'),(3157278,'Santa Bárbara do Monte Verde','MG'),(3157302,'Santa Bárbara do Tugúrio','MG'),(3157336,'Santa Cruz de Minas','MG'),(3157377,'Santa Cruz de Salinas','MG'),(3157401,'Santa Cruz do Escalvado','MG'),(3157500,'Santa Efigênia de Minas','MG'),(3157609,'Santa Fé de Minas','MG'),(3157658,'Santa Helena de Minas','MG'),(3157708,'Santa Juliana','MG'),(3157807,'Santa Luzia','MG'),(3157906,'Santa Margarida','MG'),(3158003,'Santa Maria de Itabira','MG'),(3158102,'Santa Maria do Salto','MG'),(3158201,'Santa Maria do Suaçuí','MG'),(3158300,'Santana da Vargem','MG'),(3158409,'Santana de Cataguases','MG'),(3158508,'Santana de Pirapama','MG'),(3158607,'Santana do Deserto','MG'),(3158706,'Santana do Garambéu','MG'),(3158805,'Santana do Jacaré','MG'),(3158904,'Santana do Manhuaçu','MG'),(3158953,'Santana do Paraíso','MG'),(3159001,'Santana do Riacho','MG'),(3159100,'Santana dos Montes','MG'),(3159209,'Santa Rita de Caldas','MG'),(3159308,'Santa Rita de Jacutinga','MG'),(3159357,'Santa Rita de Minas','MG'),(3159407,'Santa Rita de Ibitipoca','MG'),(3159506,'Santa Rita do Itueto','MG'),(3159605,'Santa Rita do Sapucaí','MG'),(3159704,'Santa Rosa da Serra','MG'),(3159803,'Santa Vitória','MG'),(3159902,'Santo Antônio do Amparo','MG'),(3160009,'Santo Antônio do Aventureiro','MG'),(3160108,'Santo Antônio do Grama','MG'),(3160207,'Santo Antônio do Itambé','MG'),(3160306,'Santo Antônio do Jacinto','MG'),(3160405,'Santo Antônio do Monte','MG'),(3160454,'Santo Antônio do Retiro','MG'),(3160504,'Santo Antônio do Rio Abaixo','MG'),(3160603,'Santo Hipólito','MG'),(3160702,'Santos Dumont','MG'),(3160801,'São Bento Abade','MG'),(3160900,'São Brás do Suaçuí','MG'),(3160959,'São Domingos das Dores','MG'),(3161007,'São Domingos do Prata','MG'),(3161056,'São Félix de Minas','MG'),(3161106,'São Francisco','MG'),(3161205,'São Francisco de Paula','MG'),(3161304,'São Francisco de Sales','MG'),(3161403,'São Francisco do Glória','MG'),(3161502,'São Geraldo','MG'),(3161601,'São Geraldo da Piedade','MG'),(3161650,'São Geraldo do Baixio','MG'),(3161700,'São Gonçalo do Abaeté','MG'),(3161809,'São Gonçalo do Pará','MG'),(3161908,'São Gonçalo do Rio Abaixo','MG'),(3162005,'São Gonçalo do Sapucaí','MG'),(3162104,'São Gotardo','MG'),(3162203,'São João Batista do Glória','MG'),(3162252,'São João da Lagoa','MG'),(3162302,'São João da Mata','MG'),(3162401,'São João da Ponte','MG'),(3162450,'São João das Missões','MG'),(3162500,'São João del Rei','MG'),(3162559,'São João do Manhuaçu','MG'),(3162575,'São João do Manteninha','MG'),(3162609,'São João do Oriente','MG'),(3162658,'São João do Pacuí','MG'),(3162708,'São João do Paraíso','MG'),(3162807,'São João Evangelista','MG'),(3162906,'São João Nepomuceno','MG'),(3162922,'São Joaquim de Bicas','MG'),(3162948,'São José da Barra','MG'),(3162955,'São José da Lapa','MG'),(3163003,'São José da Safira','MG'),(3163102,'São José da Varginha','MG'),(3163201,'São José do Alegre','MG'),(3163300,'São José do Divino','MG'),(3163409,'São José do Goiabal','MG'),(3163508,'São José do Jacuri','MG'),(3163607,'São José do Mantimento','MG'),(3163706,'São Lourenço','MG'),(3163805,'São Miguel do Anta','MG'),(3163904,'São Pedro da União','MG'),(3164001,'São Pedro dos Ferros','MG'),(3164100,'São Pedro do Suaçuí','MG'),(3164209,'São Romão','MG'),(3164308,'São Roque de Minas','MG'),(3164407,'São Sebastião da Bela Vista','MG'),(3164431,'São Sebastião da Vargem Alegre','MG'),
(3164472,'São Sebastião do Anta','MG'),(3164506,'São Sebastião do Maranhão','MG'),(3164605,'São Sebastião do Oeste','MG'),(3164704,'São Sebastião do Paraíso','MG'),(3164803,'São Sebastião do Rio Preto','MG'),(3164902,'São Sebastião do Rio Verde','MG'),(3165008,'São Tiago','MG'),(3165107,'São Tomás de Aquino','MG'),(3165206,'São Thomé das Letras','MG'),(3165305,'São Vicente de Minas','MG'),(3165404,'Sapucaí-Mirim','MG'),(3165503,'Sardoá','MG'),(3165537,'Sarzedo','MG'),(3165552,'Setubinha','MG'),(3165560,'Sem-Peixe','MG'),(3165578,'Senador Amaral','MG'),(3165602,'Senador Cortes','MG'),(3165701,'Senador Firmino','MG'),(3165800,'Senador José Bento','MG'),(3165909,'Senador Modestino Gonçalves','MG'),(3166006,'Senhora de Oliveira','MG'),(3166105,'Senhora do Porto','MG'),(3166204,'Senhora dos Remédios','MG'),(3166303,'Sericita','MG'),(3166402,'Seritinga','MG'),(3166501,'Serra Azul de Minas','MG'),(3166600,'Serra da Saudade','MG'),(3166709,'Serra dos Aimorés','MG'),(3166808,'Serra do Salitre','MG'),(3166907,'Serrania','MG'),(3166956,'Serranópolis de Minas','MG'),(3167004,'Serranos','MG'),(3167103,'Serro','MG'),(3167202,'Sete Lagoas','MG'),(3167301,'Silveirânia','MG'),(3167400,'Silvianópolis','MG'),(3167509,'Simão Pereira','MG'),(3167608,'Simonésia','MG'),(3167707,'Sobrália','MG'),(3167806,'Soledade de Minas','MG'),(3167905,'Tabuleiro','MG'),(3168002,'Taiobeiras','MG'),(3168051,'Taparuba','MG'),(3168101,'Tapira','MG'),(3168200,'Tapiraí','MG'),(3168309,'Taquaraçu de Minas','MG'),(3168408,'Tarumirim','MG'),(3168507,'Teixeiras','MG'),(3168606,'Teófilo Otoni','MG'),(3168705,'Timóteo','MG'),(3168804,'Tiradentes','MG'),(3168903,'Tiros','MG'),(3169000,'Tocantins','MG'),(3169059,'Tocos do Moji','MG'),(3169109,'Toledo','MG'),(3169208,'Tombos','MG'),(3169307,'Três Corações','MG'),(3169356,'Três Marias','MG'),(3169406,'Três Pontas','MG'),(3169505,'Tumiritinga','MG'),(3169604,'Tupaciguara','MG'),(3169703,'Turmalina','MG'),(3169802,'Turvolândia','MG'),(3169901,'Ubá','MG'),(3170008,'Ubaí','MG'),(3170057,'Ubaporanga','MG'),(3170107,'Uberaba','MG'),(3170206,'Uberlândia','MG'),(3170305,'Umburatiba','MG'),(3170404,'Unaí','MG'),(3170438,'União de Minas','MG'),(3170479,'Uruana de Minas','MG'),(3170503,'Urucânia','MG'),(3170529,'Urucuia','MG'),(3170578,'Vargem Alegre','MG'),(3170602,'Vargem Bonita','MG'),(3170651,'Vargem Grande do Rio Pardo','MG'),(3170701,'Varginha','MG'),(3170750,'Varjão de Minas','MG'),(3170800,'Várzea da Palma','MG'),(3170909,'Varzelândia','MG'),(3171006,'Vazante','MG'),(3171030,'Verdelândia','MG'),(3171071,'Veredinha','MG'),(3171105,'Veríssimo','MG'),(3171154,'Vermelho Novo','MG'),(3171204,'Vespasiano','MG'),(3171303,'Viçosa','MG'),(3171402,'Vieiras','MG'),(3171501,'Mathias Lobato','MG'),(3171600,'Virgem da Lapa','MG'),(3171709,'Virgínia','MG'),(3171808,'Virginópolis','MG'),(3171907,'Virgolândia','MG'),(3172004,'Visconde do Rio Branco','MG'),(3172103,'Volta Grande','MG'),(3172202,'Wenceslau Braz','MG'),(3200102,'Afonso Cláudio','ES'),(3200136,'Águia Branca','ES'),(3200169,'Água Doce do Norte','ES'),(3200201,'Alegre','ES'),(3200300,'Alfredo Chaves','ES'),(3200359,'Alto Rio Novo','ES'),(3200409,'Anchieta','ES'),(3200508,'Apiacá','ES'),(3200607,'Aracruz','ES'),(3200706,'Atilio Vivacqua','ES'),(3200805,'Baixo Guandu','ES'),(3200904,'Barra de São Francisco','ES'),(3201001,'Boa Esperança','ES'),(3201100,'Bom Jesus do Norte','ES'),(3201159,'Brejetuba','ES'),(3201209,'Cachoeiro de Itapemirim','ES'),(3201308,'Cariacica','ES'),(3201407,'Castelo','ES'),(3201506,'Colatina','ES'),(3201605,'Conceição da Barra','ES'),(3201704,'Conceição do Castelo','ES'),(3201803,'Divino de São Lourenço','ES'),(3201902,'Domingos Martins','ES'),(3202009,'Dores do Rio Preto','ES'),(3202108,'Ecoporanga','ES'),(3202207,'Fundão','ES'),(3202256,'Governador Lindenberg','ES'),(3202306,'Guaçuí','ES'),(3202405,'Guarapari','ES'),(3202454,'Ibatiba','ES'),(3202504,'Ibiraçu','ES'),(3202553,'Ibitirama','ES'),(3202603,'Iconha','ES'),(3202652,'Irupi','ES'),(3202702,'Itaguaçu','ES'),(3202801,'Itapemirim','ES'),(3202900,'Itarana','ES'),(3203007,'Iúna','ES'),(3203056,'Jaguaré','ES'),(3203106,'Jerônimo Monteiro','ES'),(3203130,'João Neiva','ES'),(3203163,'Laranja da Terra','ES'),(3203205,'Linhares','ES'),(3203304,'Mantenópolis','ES'),(3203320,'Marataízes','ES'),(3203346,'Marechal Floriano','ES'),(3203353,'Marilândia','ES'),(3203403,'Mimoso do Sul','ES'),(3203502,'Montanha','ES'),(3203601,'Mucurici','ES'),(3203700,'Muniz Freire','ES'),(3203809,'Muqui','ES'),(3203908,'Nova Venécia','ES'),(3204005,'Pancas','ES'),(3204054,'Pedro Canário','ES'),(3204104,'Pinheiros','ES'),(3204203,'Piúma','ES'),(3204252,'Ponto Belo','ES'),(3204302,'Presidente Kennedy','ES'),(3204351,'Rio Bananal','ES'),(3204401,'Rio Novo do Sul','ES'),(3204500,'Santa Leopoldina','ES'),(3204559,'Santa Maria de Jetibá','ES'),(3204609,'Santa Teresa','ES'),(3204658,'São Domingos do Norte','ES'),(3204708,'São Gabriel da Palha','ES'),(3204807,'São José do Calçado','ES'),(3204906,'São Mateus','ES'),(3204955,'São Roque do Canaã','ES'),(3205002,'Serra','ES'),(3205010,'Sooretama','ES'),(3205036,'Vargem Alta','ES'),(3205069,'Venda Nova do Imigrante','ES'),(3205101,'Viana','ES'),(3205150,'Vila Pavão','ES'),(3205176,'Vila Valério','ES'),(3205200,'Vila Velha','ES'),(3205309,'Vitória','ES'),(3300100,'Angra dos Reis','RJ'),(3300159,'Aperibé','RJ'),(3300209,'Araruama','RJ'),(3300225,'Areal','RJ'),(3300233,'Armação dos Búzios','RJ'),(3300258,'Arraial do Cabo','RJ'),(3300308,'Barra do Piraí','RJ'),(3300407,'Barra Mansa','RJ'),(3300456,'Belford Roxo','RJ'),(3300506,'Bom Jardim','RJ'),(3300605,'Bom Jesus do Itabapoana','RJ'),(3300704,'Cabo Frio','RJ'),(3300803,'Cachoeiras de Macacu','RJ'),(3300902,'Cambuci','RJ'),(3300936,'Carapebus','RJ'),(3300951,'Comendador Levy Gasparian','RJ'),(3301009,'Campos dos Goytacazes','RJ'),(3301108,'Cantagalo','RJ'),(3301157,'Cardoso Moreira','RJ'),(3301207,'Carmo','RJ'),(3301306,'Casimiro de Abreu','RJ'),(3301405,'Conceição de Macabu','RJ'),(3301504,'Cordeiro','RJ'),(3301603,'Duas Barras','RJ'),(3301702,'Duque de Caxias','RJ'),(3301801,'Engenheiro Paulo de Frontin','RJ'),(3301850,'Guapimirim','RJ'),(3301876,'Iguaba Grande','RJ'),(3301900,'Itaboraí','RJ'),(3302007,'Itaguaí','RJ'),(3302056,'Italva','RJ'),(3302106,'Itaocara','RJ'),(3302205,'Itaperuna','RJ'),(3302254,'Itatiaia','RJ'),(3302270,'Japeri','RJ'),(3302304,'Laje do Muriaé','RJ'),(3302403,'Macaé','RJ'),(3302452,'Macuco','RJ'),(3302502,'Magé','RJ'),(3302601,'Mangaratiba','RJ'),(3302700,'Maricá','RJ'),(3302809,'Mendes','RJ'),(3302858,'Mesquita','RJ'),(3302908,'Miguel Pereira','RJ'),(3303005,'Miracema','RJ'),(3303104,'Natividade','RJ'),(3303203,'Nilópolis','RJ'),(3303302,'Niterói','RJ'),(3303401,'Nova Friburgo','RJ'),(3303500,'Nova Iguaçu','RJ'),(3303609,'Paracambi','RJ'),(3303708,'Paraíba do Sul','RJ'),(3303807,'Paraty','RJ'),(3303856,'Paty do Alferes','RJ'),(3303906,'Petrópolis','RJ'),(3303955,'Pinheiral','RJ'),(3304003,'Piraí','RJ'),(3304102,'Porciúncula','RJ'),(3304110,'Porto Real','RJ'),(3304128,'Quatis','RJ'),(3304144,'Queimados','RJ'),(3304151,'Quissamã','RJ'),(3304201,'Resende','RJ'),(3304300,'Rio Bonito','RJ'),(3304409,'Rio Claro','RJ'),(3304508,'Rio das Flores','RJ'),(3304524,'Rio das Ostras','RJ'),(3304557,'Rio de Janeiro','RJ'),(3304607,'Santa Maria Madalena','RJ'),(3304706,'Santo Antônio de Pádua','RJ'),(3304755,'São Francisco de Itabapoana','RJ'),(3304805,'São Fidélis','RJ'),(3304904,'São Gonçalo','RJ'),(3305000,'São João da Barra','RJ'),(3305109,'São João de Meriti','RJ'),(3305133,'São José de Ubá','RJ'),(3305158,'São José do Vale do Rio Preto','RJ'),(3305208,'São Pedro da Aldeia','RJ'),(3305307,'São Sebastião do Alto','RJ'),(3305406,'Sapucaia','RJ'),(3305505,'Saquarema','RJ'),(3305554,'Seropédica','RJ'),(3305604,'Silva Jardim','RJ'),(3305703,'Sumidouro','RJ'),(3305752,'Tanguá','RJ'),(3305802,'Teresópolis','RJ'),(3305901,'Trajano de Moraes','RJ'),(3306008,'Três Rios','RJ'),(3306107,'Valença','RJ'),(3306156,'Varre-Sai','RJ'),(3306206,'Vassouras','RJ'),(3306305,'Volta Redonda','RJ'),(3500105,'Adamantina','SP'),(3500204,'Adolfo','SP'),(3500303,'Aguaí','SP'),(3500402,'Águas da Prata','SP'),(3500501,'Águas de Lindóia','SP'),(3500550,'Águas de Santa Bárbara','SP'),(3500600,'Águas de São Pedro','SP'),(3500709,'Agudos','SP'),(3500758,'Alambari','SP'),(3500808,'Alfredo Marcondes','SP'),(3500907,'Altair','SP'),(3501004,'Altinópolis','SP'),(3501103,'Alto Alegre','SP'),(3501152,'Alumínio','SP'),(3501202,'Álvares Florence','SP'),(3501301,'Álvares Machado','SP'),(3501400,'Álvaro de Carvalho','SP'),(3501509,'Alvinlândia','SP'),(3501608,'Americana','SP'),(3501707,'Américo Brasiliense','SP'),(3501806,'Américo de Campos','SP'),(3501905,'Amparo','SP'),(3502002,'Analândia','SP'),(3502101,'Andradina','SP'),(3502200,'Angatuba','SP'),(3502309,'Anhembi','SP'),(3502408,'Anhumas','SP'),(3502507,'Aparecida','SP'),(3502606,'Aparecida d''Oeste','SP'),(3502705,'Apiaí','SP'),(3502754,'Araçariguama','SP'),(3502804,'Araçatuba','SP'),(3502903,'Araçoiaba da Serra','SP'),(3503000,'Aramina','SP'),(3503109,'Arandu','SP'),(3503158,'Arapeí','SP'),(3503208,'Araraquara','SP'),(3503307,'Araras','SP'),(3503356,'Arco-Íris','SP'),(3503406,'Arealva','SP'),(3503505,'Areias','SP'),(3503604,'Areiópolis','SP'),(3503703,'Ariranha','SP'),(3503802,'Artur Nogueira','SP'),(3503901,'Arujá','SP'),(3503950,'Aspásia','SP'),(3504008,'Assis','SP'),(3504107,'Atibaia','SP'),(3504206,'Auriflama','SP'),(3504305,'Avaí','SP'),(3504404,'Avanhandava','SP'),(3504503,'Avaré','SP'),(3504602,'Bady Bassitt','SP'),(3504701,'Balbinos','SP'),(3504800,'Bálsamo','SP'),(3504909,'Bananal','SP'),(3505005,'Barão de Antonina','SP'),(3505104,'Barbosa','SP'),(3505203,'Bariri','SP'),(3505302,'Barra Bonita','SP'),(3505351,'Barra do Chapéu','SP'),(3505401,'Barra do Turvo','SP'),(3505500,'Barretos','SP'),(3505609,'Barrinha','SP'),(3505708,'Barueri','SP'),(3505807,'Bastos','SP'),(3505906,'Batatais','SP'),(3506003,'Bauru','SP'),(3506102,'Bebedouro','SP'),(3506201,'Bento de Abreu','SP'),(3506300,'Bernardino de Campos','SP'),(3506359,'Bertioga','SP'),(3506409,'Bilac','SP'),(3506508,'Birigui','SP'),(3506607,'Biritiba-Mirim','SP'),(3506706,'Boa Esperança do Sul','SP'),(3506805,'Bocaina','SP'),(3506904,'Bofete','SP'),(3507001,'Boituva','SP'),(3507100,'Bom Jesus dos Perdões','SP'),(3507159,'Bom Sucesso de Itararé','SP'),(3507209,'Borá','SP'),(3507308,'Boracéia','SP'),(3507407,'Borborema','SP'),(3507456,'Borebi','SP'),(3507506,'Botucatu','SP'),(3507605,'Bragança Paulista','SP'),(3507704,'Braúna','SP'),(3507753,'Brejo Alegre','SP'),(3507803,'Brodowski','SP'),(3507902,'Brotas','SP'),(3508009,'Buri','SP'),(3508108,'Buritama','SP'),(3508207,'Buritizal','SP'),(3508306,'Cabrália Paulista','SP'),(3508405,'Cabreúva','SP'),(3508504,'Caçapava','SP'),(3508603,'Cachoeira Paulista','SP'),(3508702,'Caconde','SP'),(3508801,'Cafelândia','SP'),(3508900,'Caiabu','SP'),(3509007,'Caieiras','SP'),(3509106,'Caiuá','SP'),(3509205,'Cajamar','SP'),(3509254,'Cajati','SP'),(3509304,'Cajobi','SP'),(3509403,'Cajuru','SP'),(3509452,'Campina do Monte Alegre','SP'),(3509502,'Campinas','SP'),(3509601,'Campo Limpo Paulista','SP'),(3509700,'Campos do Jordão','SP'),(3509809,'Campos Novos Paulista','SP'),(3509908,'Cananéia','SP'),(3509957,'Canas','SP'),(3510005,'Cândido Mota','SP'),(3510104,'Cândido Rodrigues','SP'),(3510153,'Canitar','SP'),(3510203,'Capão Bonito','SP'),(3510302,'Capela do Alto','SP'),(3510401,'Capivari','SP'),(3510500,'Caraguatatuba','SP'),(3510609,'Carapicuíba','SP'),(3510708,'Cardoso','SP'),(3510807,'Casa Branca','SP'),(3510906,'Cássia dos Coqueiros','SP'),(3511003,'Castilho','SP'),(3511102,'Catanduva','SP'),(3511201,'Catiguá','SP'),(3511300,'Cedral','SP'),(3511409,'Cerqueira César','SP'),(3511508,'Cerquilho','SP'),(3511607,'Cesário Lange','SP'),(3511706,'Charqueada','SP'),(3511904,'Clementina','SP'),(3512001,'Colina','SP'),(3512100,'Colômbia','SP'),(3512209,'Conchal','SP'),(3512308,'Conchas','SP'),(3512407,'Cordeirópolis','SP'),(3512506,'Coroados','SP'),(3512605,'Coronel Macedo','SP'),(3512704,'Corumbataí','SP'),(3512803,'Cosmópolis','SP'),(3512902,'Cosmorama','SP'),(3513009,'Cotia','SP'),(3513108,'Cravinhos','SP'),(3513207,'Cristais Paulista','SP'),(3513306,'Cruzália','SP'),(3513405,'Cruzeiro','SP'),(3513504,'Cubatão','SP'),(3513603,'Cunha','SP'),(3513702,'Descalvado','SP'),(3513801,'Diadema','SP'),(3513850,'Dirce Reis','SP'),(3513900,'Divinolândia','SP'),(3514007,'Dobrada','SP'),(3514106,'Dois Córregos','SP'),(3514205,'Dolcinópolis','SP'),(3514304,'Dourado','SP'),(3514403,'Dracena','SP'),(3514502,'Duartina','SP'),(3514601,'Dumont','SP'),(3514700,'Echaporã','SP'),(3514809,'Eldorado','SP'),(3514908,'Elias Fausto','SP'),(3514924,'Elisiário','SP'),(3514957,'Embaúba','SP'),(3515004,'Embu das Artes','SP'),(3515103,'Embu-Guaçu','SP'),(3515129,'Emilianópolis','SP'),(3515152,'Engenheiro Coelho','SP'),(3515186,'Espírito Santo do Pinhal','SP'),(3515194,'Espírito Santo do Turvo','SP'),(3515202,'Estrela d''Oeste','SP'),(3515301,'Estrela do Norte','SP'),(3515350,'Euclides da Cunha Paulista','SP'),(3515400,'Fartura','SP'),(3515509,'Fernandópolis','SP'),(3515608,'Fernando Prestes','SP'),(3515657,'Fernão','SP'),(3515707,'Ferraz de Vasconcelos','SP'),(3515806,'Flora Rica','SP'),(3515905,'Floreal','SP'),(3516002,'Flórida Paulista','SP'),(3516101,'Florínia','SP'),(3516200,'Franca','SP'),(3516309,'Francisco Morato','SP'),(3516408,'Franco da Rocha','SP'),(3516507,'Gabriel Monteiro','SP'),(3516606,'Gália','SP'),(3516705,'Garça','SP'),(3516804,'Gastão Vidigal','SP'),(3516853,'Gavião Peixoto','SP'),(3516903,'General Salgado','SP'),(3517000,'Getulina','SP'),(3517109,'Glicério','SP'),(3517208,'Guaiçara','SP'),(3517307,'Guaimbê','SP'),(3517406,'Guaíra','SP'),(3517505,'Guapiaçu','SP'),(3517604,'Guapiara','SP'),(3517703,'Guará','SP'),(3517802,'Guaraçaí','SP'),(3517901,'Guaraci','SP'),(3518008,'Guarani d''Oeste','SP'),(3518107,'Guarantã','SP'),(3518206,'Guararapes','SP'),(3518305,'Guararema','SP'),(3518404,'Guaratinguetá','SP'),(3518503,'Guareí','SP'),(3518602,'Guariba','SP'),(3518701,'Guarujá','SP'),(3518800,'Guarulhos','SP'),(3518859,'Guatapará','SP'),(3518909,'Guzolândia','SP'),(3519006,'Herculândia','SP'),(3519055,'Holambra','SP'),(3519071,'Hortolândia','SP'),(3519105,'Iacanga','SP'),(3519204,'Iacri','SP'),(3519253,'Iaras','SP'),(3519303,'Ibaté','SP'),(3519402,'Ibirá','SP'),(3519501,'Ibirarema','SP'),(3519600,'Ibitinga','SP'),(3519709,'Ibiúna','SP'),(3519808,'Icém','SP'),(3519907,'Iepê','SP'),(3520004,'Igaraçu do Tietê','SP'),(3520103,'Igarapava','SP'),(3520202,'Igaratá','SP'),(3520301,'Iguape','SP'),(3520400,'Ilhabela','SP'),
(3520426,'Ilha Comprida','SP'),(3520442,'Ilha Solteira','SP'),(3520509,'Indaiatuba','SP'),(3520608,'Indiana','SP'),(3520707,'Indiaporã','SP'),(3520806,'Inúbia Paulista','SP'),(3520905,'Ipaussu','SP'),(3521002,'Iperó','SP'),(3521101,'Ipeúna','SP'),(3521150,'Ipiguá','SP'),(3521200,'Iporanga','SP'),(3521309,'Ipuã','SP'),(3521408,'Iracemápolis','SP'),(3521507,'Irapuã','SP'),(3521606,'Irapuru','SP'),(3521705,'Itaberá','SP'),(3521804,'Itaí','SP'),(3521903,'Itajobi','SP'),(3522000,'Itaju','SP'),(3522109,'Itanhaém','SP'),(3522158,'Itaóca','SP'),(3522208,'Itapecerica da Serra','SP'),(3522307,'Itapetininga','SP'),(3522406,'Itapeva','SP'),(3522505,'Itapevi','SP'),(3522604,'Itapira','SP'),(3522653,'Itapirapuã Paulista','SP'),(3522703,'Itápolis','SP'),(3522802,'Itaporanga','SP'),(3522901,'Itapuí','SP'),(3523008,'Itapura','SP'),(3523107,'Itaquaquecetuba','SP'),(3523206,'Itararé','SP'),(3523305,'Itariri','SP'),(3523404,'Itatiba','SP'),(3523503,'Itatinga','SP'),(3523602,'Itirapina','SP'),(3523701,'Itirapuã','SP'),(3523800,'Itobi','SP'),(3523909,'Itu','SP'),(3524006,'Itupeva','SP'),(3524105,'Ituverava','SP'),(3524204,'Jaborandi','SP'),(3524303,'Jaboticabal','SP'),(3524402,'Jacareí','SP'),(3524501,'Jaci','SP'),(3524600,'Jacupiranga','SP'),(3524709,'Jaguariúna','SP'),(3524808,'Jales','SP'),(3524907,'Jambeiro','SP'),(3525003,'Jandira','SP'),(3525102,'Jardinópolis','SP'),(3525201,'Jarinu','SP'),(3525300,'Jaú','SP'),(3525409,'Jeriquara','SP'),(3525508,'Joanópolis','SP'),(3525607,'João Ramalho','SP'),(3525706,'José Bonifácio','SP'),(3525805,'Júlio Mesquita','SP'),(3525854,'Jumirim','SP'),(3525904,'Jundiaí','SP'),(3526001,'Junqueirópolis','SP'),(3526100,'Juquiá','SP'),(3526209,'Juquitiba','SP'),(3526308,'Lagoinha','SP'),(3526407,'Laranjal Paulista','SP'),(3526506,'Lavínia','SP'),(3526605,'Lavrinhas','SP'),(3526704,'Leme','SP'),(3526803,'Lençóis Paulista','SP'),(3526902,'Limeira','SP'),(3527009,'Lindóia','SP'),(3527108,'Lins','SP'),(3527207,'Lorena','SP'),(3527256,'Lourdes','SP'),(3527306,'Louveira','SP'),(3527405,'Lucélia','SP'),(3527504,'Lucianópolis','SP'),(3527603,'Luís Antônio','SP'),(3527702,'Luiziânia','SP'),(3527801,'Lupércio','SP'),(3527900,'Lutécia','SP'),(3528007,'Macatuba','SP'),(3528106,'Macaubal','SP'),(3528205,'Macedônia','SP'),(3528304,'Magda','SP'),(3528403,'Mairinque','SP'),(3528502,'Mairiporã','SP'),(3528601,'Manduri','SP'),(3528700,'Marabá Paulista','SP'),(3528809,'Maracaí','SP'),(3528858,'Marapoama','SP'),(3528908,'Mariápolis','SP'),(3529005,'Marília','SP'),(3529104,'Marinópolis','SP'),(3529203,'Martinópolis','SP'),(3529302,'Matão','SP'),(3529401,'Mauá','SP'),(3529500,'Mendonça','SP'),(3529609,'Meridiano','SP'),(3529658,'Mesópolis','SP'),(3529708,'Miguelópolis','SP'),(3529807,'Mineiros do Tietê','SP'),(3529906,'Miracatu','SP'),(3530003,'Mira Estrela','SP'),(3530102,'Mirandópolis','SP'),(3530201,'Mirante do Paranapanema','SP'),(3530300,'Mirassol','SP'),(3530409,'Mirassolândia','SP'),(3530508,'Mococa','SP'),(3530607,'Mogi das Cruzes','SP'),(3530706,'Mogi Guaçu','SP'),(3530805,'Mogi Mirim','SP'),(3530904,'Mombuca','SP'),(3531001,'Monções','SP'),(3531100,'Mongaguá','SP'),(3531209,'Monte Alegre do Sul','SP'),(3531308,'Monte Alto','SP'),(3531407,'Monte Aprazível','SP'),(3531506,'Monte Azul Paulista','SP'),(3531605,'Monte Castelo','SP'),(3531704,'Monteiro Lobato','SP'),(3531803,'Monte Mor','SP'),(3531902,'Morro Agudo','SP'),(3532009,'Morungaba','SP'),(3532058,'Motuca','SP'),(3532108,'Murutinga do Sul','SP'),(3532157,'Nantes','SP'),(3532207,'Narandiba','SP'),(3532306,'Natividade da Serra','SP'),(3532405,'Nazaré Paulista','SP'),(3532504,'Neves Paulista','SP'),(3532603,'Nhandeara','SP'),(3532702,'Nipoã','SP'),(3532801,'Nova Aliança','SP'),(3532827,'Nova Campina','SP'),(3532843,'Nova Canaã Paulista','SP'),(3532868,'Nova Castilho','SP'),(3532900,'Nova Europa','SP'),(3533007,'Nova Granada','SP'),(3533106,'Nova Guataporanga','SP'),(3533205,'Nova Independência','SP'),(3533254,'Novais','SP'),(3533304,'Nova Luzitânia','SP'),(3533403,'Nova Odessa','SP'),(3533502,'Novo Horizonte','SP'),(3533601,'Nuporanga','SP'),(3533700,'Ocauçu','SP'),(3533809,'Óleo','SP'),(3533908,'Olímpia','SP'),(3534005,'Onda Verde','SP'),(3534104,'Oriente','SP'),(3534203,'Orindiúva','SP'),(3534302,'Orlândia','SP'),(3534401,'Osasco','SP'),(3534500,'Oscar Bressane','SP'),(3534609,'Osvaldo Cruz','SP'),(3534708,'Ourinhos','SP'),(3534757,'Ouroeste','SP'),(3534807,'Ouro Verde','SP'),(3534906,'Pacaembu','SP'),(3535002,'Palestina','SP'),(3535101,'Palmares Paulista','SP'),(3535200,'Palmeira d''Oeste','SP'),(3535309,'Palmital','SP'),(3535408,'Panorama','SP'),(3535507,'Paraguaçu Paulista','SP'),(3535606,'Paraibuna','SP'),(3535705,'Paraíso','SP'),(3535804,'Paranapanema','SP'),(3535903,'Paranapuã','SP'),(3536000,'Parapuã','SP'),(3536109,'Pardinho','SP'),(3536208,'Pariquera-Açu','SP'),(3536257,'Parisi','SP'),(3536307,'Patrocínio Paulista','SP'),(3536406,'Paulicéia','SP'),(3536505,'Paulínia','SP'),(3536570,'Paulistânia','SP'),(3536604,'Paulo de Faria','SP'),(3536703,'Pederneiras','SP'),(3536802,'Pedra Bela','SP'),(3536901,'Pedranópolis','SP'),(3537008,'Pedregulho','SP'),(3537107,'Pedreira','SP'),(3537156,'Pedrinhas Paulista','SP'),(3537206,'Pedro de Toledo','SP'),(3537305,'Penápolis','SP'),(3537404,'Pereira Barreto','SP'),(3537503,'Pereiras','SP'),(3537602,'Peruíbe','SP'),(3537701,'Piacatu','SP'),(3537800,'Piedade','SP'),(3537909,'Pilar do Sul','SP'),(3538006,'Pindamonhangaba','SP'),(3538105,'Pindorama','SP'),(3538204,'Pinhalzinho','SP'),(3538303,'Piquerobi','SP'),(3538501,'Piquete','SP'),(3538600,'Piracaia','SP'),(3538709,'Piracicaba','SP'),(3538808,'Piraju','SP'),(3538907,'Pirajuí','SP'),(3539004,'Pirangi','SP'),(3539103,'Pirapora do Bom Jesus','SP'),(3539202,'Pirapozinho','SP'),(3539301,'Pirassununga','SP'),(3539400,'Piratininga','SP'),(3539509,'Pitangueiras','SP'),(3539608,'Planalto','SP'),(3539707,'Platina','SP'),(3539806,'Poá','SP'),(3539905,'Poloni','SP'),(3540002,'Pompéia','SP'),(3540101,'Pongaí','SP'),(3540200,'Pontal','SP'),(3540259,'Pontalinda','SP'),(3540309,'Pontes Gestal','SP'),(3540408,'Populina','SP'),(3540507,'Porangaba','SP'),(3540606,'Porto Feliz','SP'),(3540705,'Porto Ferreira','SP'),(3540754,'Potim','SP'),(3540804,'Potirendaba','SP'),(3540853,'Pracinha','SP'),(3540903,'Pradópolis','SP'),(3541000,'Praia Grande','SP'),(3541059,'Pratânia','SP'),(3541109,'Presidente Alves','SP'),(3541208,'Presidente Bernardes','SP'),(3541307,'Presidente Epitácio','SP'),(3541406,'Presidente Prudente','SP'),(3541505,'Presidente Venceslau','SP'),(3541604,'Promissão','SP'),(3541653,'Quadra','SP'),(3541703,'Quatá','SP'),(3541802,'Queiroz','SP'),(3541901,'Queluz','SP'),(3542008,'Quintana','SP'),(3542107,'Rafard','SP'),(3542206,'Rancharia','SP'),(3542305,'Redenção da Serra','SP'),(3542404,'Regente Feijó','SP'),(3542503,'Reginópolis','SP'),(3542602,'Registro','SP'),(3542701,'Restinga','SP'),(3542800,'Ribeira','SP'),(3542909,'Ribeirão Bonito','SP'),(3543006,'Ribeirão Branco','SP'),(3543105,'Ribeirão Corrente','SP'),(3543204,'Ribeirão do Sul','SP'),(3543238,'Ribeirão dos Índios','SP'),(3543253,'Ribeirão Grande','SP'),(3543303,'Ribeirão Pires','SP'),(3543402,'Ribeirão Preto','SP'),(3543501,'Riversul','SP'),(3543600,'Rifaina','SP'),(3543709,'Rincão','SP'),(3543808,'Rinópolis','SP'),(3543907,'Rio Claro','SP'),(3544004,'Rio das Pedras','SP'),(3544103,'Rio Grande da Serra','SP'),(3544202,'Riolândia','SP'),(3544251,'Rosana','SP'),(3544301,'Roseira','SP'),(3544400,'Rubiácea','SP'),(3544509,'Rubinéia','SP'),(3544608,'Sabino','SP'),(3544707,'Sagres','SP'),(3544806,'Sales','SP'),(3544905,'Sales Oliveira','SP'),(3545001,'Salesópolis','SP'),(3545100,'Salmourão','SP'),(3545159,'Saltinho','SP'),(3545209,'Salto','SP'),(3545308,'Salto de Pirapora','SP'),(3545407,'Salto Grande','SP'),(3545506,'Sandovalina','SP'),(3545605,'Santa Adélia','SP'),(3545704,'Santa Albertina','SP'),(3545803,'Santa Bárbara d''Oeste','SP'),(3546009,'Santa Branca','SP'),(3546108,'Santa Clara d''Oeste','SP'),(3546207,'Santa Cruz da Conceição','SP'),(3546256,'Santa Cruz da Esperança','SP'),(3546306,'Santa Cruz das Palmeiras','SP'),(3546405,'Santa Cruz do Rio Pardo','SP'),(3546504,'Santa Ernestina','SP'),(3546603,'Santa Fé do Sul','SP'),(3546702,'Santa Gertrudes','SP'),(3546801,'Santa Isabel','SP'),(3546900,'Santa Lúcia','SP'),(3547007,'Santa Maria da Serra','SP'),(3547106,'Santa Mercedes','SP'),(3547205,'Santana da Ponte Pensa','SP'),(3547304,'Santana de Parnaíba','SP'),(3547403,'Santa Rita d''Oeste','SP'),(3547502,'Santa Rita do Passa Quatro','SP'),(3547601,'Santa Rosa de Viterbo','SP'),(3547650,'Santa Salete','SP'),(3547700,'Santo Anastácio','SP'),(3547809,'Santo André','SP'),(3547908,'Santo Antônio da Alegria','SP'),(3548005,'Santo Antônio de Posse','SP'),(3548054,'Santo Antônio do Aracanguá','SP'),(3548104,'Santo Antônio do Jardim','SP'),(3548203,'Santo Antônio do Pinhal','SP'),(3548302,'Santo Expedito','SP'),(3548401,'Santópolis do Aguapeí','SP'),(3548500,'Santos','SP'),(3548609,'São Bento do Sapucaí','SP'),(3548708,'São Bernardo do Campo','SP'),(3548807,'São Caetano do Sul','SP'),(3548906,'São Carlos','SP'),(3549003,'São Francisco','SP'),(3549102,'São João da Boa Vista','SP'),(3549201,'São João das Duas Pontes','SP'),(3549250,'São João de Iracema','SP'),(3549300,'São João do Pau d''Alho','SP'),(3549409,'São Joaquim da Barra','SP'),(3549508,'São José da Bela Vista','SP'),(3549607,'São José do Barreiro','SP'),(3549706,'São José do Rio Pardo','SP'),(3549805,'São José do Rio Preto','SP'),(3549904,'São José dos Campos','SP'),(3549953,'São Lourenço da Serra','SP'),(3550001,'São Luiz do Paraitinga','SP'),(3550100,'São Manuel','SP'),(3550209,'São Miguel Arcanjo','SP'),(3550308,'São Paulo','SP'),(3550407,'São Pedro','SP'),(3550506,'São Pedro do Turvo','SP'),(3550605,'São Roque','SP'),(3550704,'São Sebastião','SP'),(3550803,'São Sebastião da Grama','SP'),(3550902,'São Simão','SP'),(3551009,'São Vicente','SP'),(3551108,'Sarapuí','SP'),(3551207,'Sarutaiá','SP'),(3551306,'Sebastianópolis do Sul','SP'),(3551405,'Serra Azul','SP'),(3551504,'Serrana','SP'),(3551603,'Serra Negra','SP'),(3551702,'Sertãozinho','SP'),(3551801,'Sete Barras','SP'),(3551900,'Severínia','SP'),(3552007,'Silveiras','SP'),(3552106,'Socorro','SP'),(3552205,'Sorocaba','SP'),(3552304,'Sud Mennucci','SP'),(3552403,'Sumaré','SP'),(3552502,'Suzano','SP'),(3552551,'Suzanápolis','SP'),(3552601,'Tabapuã','SP'),(3552700,'Tabatinga','SP'),(3552809,'Taboão da Serra','SP'),(3552908,'Taciba','SP'),(3553005,'Taguaí','SP'),(3553104,'Taiaçu','SP'),(3553203,'Taiúva','SP'),(3553302,'Tambaú','SP'),(3553401,'Tanabi','SP'),(3553500,'Tapiraí','SP'),(3553609,'Tapiratiba','SP'),(3553658,'Taquaral','SP'),(3553708,'Taquaritinga','SP'),(3553807,'Taquarituba','SP'),(3553856,'Taquarivaí','SP'),(3553906,'Tarabai','SP'),(3553955,'Tarumã','SP'),(3554003,'Tatuí','SP'),(3554102,'Taubaté','SP'),(3554201,'Tejupá','SP'),(3554300,'Teodoro Sampaio','SP'),(3554409,'Terra Roxa','SP'),(3554508,'Tietê','SP'),(3554607,'Timburi','SP'),(3554656,'Torre de Pedra','SP'),(3554706,'Torrinha','SP'),(3554755,'Trabiju','SP'),(3554805,'Tremembé','SP'),(3554904,'Três Fronteiras','SP'),(3554953,'Tuiuti','SP'),(3555000,'Tupã','SP'),(3555109,'Tupi Paulista','SP'),(3555208,'Turiúba','SP'),(3555307,'Turmalina','SP'),(3555356,'Ubarana','SP'),(3555406,'Ubatuba','SP'),(3555505,'Ubirajara','SP'),(3555604,'Uchoa','SP'),(3555703,'União Paulista','SP'),(3555802,'Urânia','SP'),(3555901,'Uru','SP'),(3556008,'Urupês','SP'),(3556107,'Valentim Gentil','SP'),(3556206,'Valinhos','SP'),(3556305,'Valparaíso','SP'),(3556354,'Vargem','SP'),(3556404,'Vargem Grande do Sul','SP'),(3556453,'Vargem Grande Paulista','SP'),(3556503,'Várzea Paulista','SP'),(3556602,'Vera Cruz','SP'),(3556701,'Vinhedo','SP'),(3556800,'Viradouro','SP'),(3556909,'Vista Alegre do Alto','SP'),(3556958,'Vitória Brasil','SP'),(3557006,'Votorantim','SP'),(3557105,'Votuporanga','SP'),(3557154,'Zacarias','SP'),(3557204,'Chavantes','SP'),(3557303,'Estiva Gerbi','SP'),(4100103,'Abatiá','PR'),(4100202,'Adrianópolis','PR'),(4100301,'Agudos do Sul','PR'),(4100400,'Almirante Tamandaré','PR'),(4100459,'Altamira do Paraná','PR'),(4100509,'Altônia','PR'),(4100608,'Alto Paraná','PR'),(4100707,'Alto Piquiri','PR'),(4100806,'Alvorada do Sul','PR'),(4100905,'Amaporã','PR'),(4101002,'Ampére','PR'),(4101051,'Anahy','PR'),(4101101,'Andirá','PR'),(4101150,'Ângulo','PR'),(4101200,'Antonina','PR'),(4101309,'Antônio Olinto','PR'),(4101408,'Apucarana','PR'),(4101507,'Arapongas','PR'),(4101606,'Arapoti','PR'),(4101655,'Arapuã','PR'),(4101705,'Araruna','PR'),(4101804,'Araucária','PR'),(4101853,'Ariranha do Ivaí','PR'),(4101903,'Assaí','PR'),(4102000,'Assis Chateaubriand','PR'),(4102109,'Astorga','PR'),(4102208,'Atalaia','PR'),(4102307,'Balsa Nova','PR'),(4102406,'Bandeirantes','PR'),(4102505,'Barbosa Ferraz','PR'),(4102604,'Barracão','PR'),(4102703,'Barra do Jacaré','PR'),(4102752,'Bela Vista da Caroba','PR'),(4102802,'Bela Vista do Paraíso','PR'),(4102901,'Bituruna','PR'),(4103008,'Boa Esperança','PR'),(4103024,'Boa Esperança do Iguaçu','PR'),(4103040,'Boa Ventura de São Roque','PR'),(4103057,'Boa Vista da Aparecida','PR'),(4103107,'Bocaiúva do Sul','PR'),(4103156,'Bom Jesus do Sul','PR'),(4103206,'Bom Sucesso','PR'),(4103222,'Bom Sucesso do Sul','PR'),(4103305,'Borrazópolis','PR'),(4103354,'Braganey','PR'),(4103370,'Brasilândia do Sul','PR'),(4103404,'Cafeara','PR'),(4103453,'Cafelândia','PR'),(4103479,'Cafezal do Sul','PR'),(4103503,'Califórnia','PR'),(4103602,'Cambará','PR'),(4103701,'Cambé','PR'),(4103800,'Cambira','PR'),(4103909,'Campina da Lagoa','PR'),(4103958,'Campina do Simão','PR'),(4104006,'Campina Grande do Sul','PR'),(4104055,'Campo Bonito','PR'),(4104105,'Campo do Tenente','PR'),(4104204,'Campo Largo','PR'),(4104253,'Campo Magro','PR'),(4104303,'Campo Mourão','PR'),(4104402,'Cândido de Abreu','PR'),(4104428,'Candói','PR'),(4104451,'Cantagalo','PR'),(4104501,'Capanema','PR'),(4104600,'Capitão Leônidas Marques','PR'),(4104659,'Carambeí','PR'),(4104709,'Carlópolis','PR'),(4104808,'Cascavel','PR'),(4104907,'Castro','PR'),(4105003,'Catanduvas','PR'),(4105102,'Centenário do Sul','PR'),(4105201,'Cerro Azul','PR'),(4105300,'Céu Azul','PR'),(4105409,'Chopinzinho','PR'),(4105508,'Cianorte','PR'),(4105607,'Cidade Gaúcha','PR'),(4105706,'Clevelândia','PR'),(4105805,'Colombo','PR'),(4105904,'Colorado','PR'),(4106001,'Congonhinhas','PR'),(4106100,'Conselheiro Mairinck','PR'),(4106209,'Contenda','PR'),(4106308,'Corbélia','PR'),(4106407,'Cornélio Procópio','PR'),(4106456,'Coronel Domingos Soares','PR'),(4106506,'Coronel Vivida','PR'),(4106555,'Corumbataí do Sul','PR'),
(4106571,'Cruzeiro do Iguaçu','PR'),(4106605,'Cruzeiro do Oeste','PR'),(4106704,'Cruzeiro do Sul','PR'),(4106803,'Cruz Machado','PR'),(4106852,'Cruzmaltina','PR'),(4106902,'Curitiba','PR'),(4107009,'Curiúva','PR'),(4107108,'Diamante do Norte','PR'),(4107124,'Diamante do Sul','PR'),(4107157,'Diamante D''Oeste','PR'),(4107207,'Dois Vizinhos','PR'),(4107256,'Douradina','PR'),(4107306,'Doutor Camargo','PR'),(4107405,'Enéas Marques','PR'),(4107504,'Engenheiro Beltrão','PR'),(4107520,'Esperança Nova','PR'),(4107538,'Entre Rios do Oeste','PR'),(4107546,'Espigão Alto do Iguaçu','PR'),(4107553,'Farol','PR'),(4107603,'Faxinal','PR'),(4107652,'Fazenda Rio Grande','PR'),(4107702,'Fênix','PR'),(4107736,'Fernandes Pinheiro','PR'),(4107751,'Figueira','PR'),(4107801,'Floraí','PR'),(4107850,'Flor da Serra do Sul','PR'),(4107900,'Floresta','PR'),(4108007,'Florestópolis','PR'),(4108106,'Flórida','PR'),(4108205,'Formosa do Oeste','PR'),(4108304,'Foz do Iguaçu','PR'),(4108320,'Francisco Alves','PR'),(4108403,'Francisco Beltrão','PR'),(4108452,'Foz do Jordão','PR'),(4108502,'General Carneiro','PR'),(4108551,'Godoy Moreira','PR'),(4108601,'Goioerê','PR'),(4108650,'Goioxim','PR'),(4108700,'Grandes Rios','PR'),(4108809,'Guaíra','PR'),(4108908,'Guairaçá','PR'),(4108957,'Guamiranga','PR'),(4109005,'Guapirama','PR'),(4109104,'Guaporema','PR'),(4109203,'Guaraci','PR'),(4109302,'Guaraniaçu','PR'),(4109401,'Guarapuava','PR'),(4109500,'Guaraqueçaba','PR'),(4109609,'Guaratuba','PR'),(4109658,'Honório Serpa','PR'),(4109708,'Ibaiti','PR'),(4109757,'Ibema','PR'),(4109807,'Ibiporã','PR'),(4109906,'Icaraíma','PR'),(4110003,'Iguaraçu','PR'),(4110052,'Iguatu','PR'),(4110078,'Imbaú','PR'),(4110102,'Imbituva','PR'),(4110201,'Inácio Martins','PR'),(4110300,'Inajá','PR'),(4110409,'Indianópolis','PR'),(4110508,'Ipiranga','PR'),(4110607,'Iporã','PR'),(4110656,'Iracema do Oeste','PR'),(4110706,'Irati','PR'),(4110805,'Iretama','PR'),(4110904,'Itaguajé','PR'),(4110953,'Itaipulândia','PR'),(4111001,'Itambaracá','PR'),(4111100,'Itambé','PR'),(4111209,'Itapejara d''Oeste','PR'),(4111258,'Itaperuçu','PR'),(4111308,'Itaúna do Sul','PR'),(4111407,'Ivaí','PR'),(4111506,'Ivaiporã','PR'),(4111555,'Ivaté','PR'),(4111605,'Ivatuba','PR'),(4111704,'Jaboti','PR'),(4111803,'Jacarezinho','PR'),(4111902,'Jaguapitã','PR'),(4112009,'Jaguariaíva','PR'),(4112108,'Jandaia do Sul','PR'),(4112207,'Janiópolis','PR'),(4112306,'Japira','PR'),(4112405,'Japurá','PR'),(4112504,'Jardim Alegre','PR'),(4112603,'Jardim Olinda','PR'),(4112702,'Jataizinho','PR'),(4112751,'Jesuítas','PR'),(4112801,'Joaquim Távora','PR'),(4112900,'Jundiaí do Sul','PR'),(4112959,'Juranda','PR'),(4113007,'Jussara','PR'),(4113106,'Kaloré','PR'),(4113205,'Lapa','PR'),(4113254,'Laranjal','PR'),(4113304,'Laranjeiras do Sul','PR'),(4113403,'Leópolis','PR'),(4113429,'Lidianópolis','PR'),(4113452,'Lindoeste','PR'),(4113502,'Loanda','PR'),(4113601,'Lobato','PR'),(4113700,'Londrina','PR'),(4113734,'Luiziana','PR'),(4113759,'Lunardelli','PR'),(4113809,'Lupionópolis','PR'),(4113908,'Mallet','PR'),(4114005,'Mamborê','PR'),(4114104,'Mandaguaçu','PR'),(4114203,'Mandaguari','PR'),(4114302,'Mandirituba','PR'),(4114351,'Manfrinópolis','PR'),(4114401,'Mangueirinha','PR'),(4114500,'Manoel Ribas','PR'),(4114609,'Marechal Cândido Rondon','PR'),(4114708,'Maria Helena','PR'),(4114807,'Marialva','PR'),(4114906,'Marilândia do Sul','PR'),(4115002,'Marilena','PR'),(4115101,'Mariluz','PR'),(4115200,'Maringá','PR'),(4115309,'Mariópolis','PR'),(4115358,'Maripá','PR'),(4115408,'Marmeleiro','PR'),(4115457,'Marquinho','PR'),(4115507,'Marumbi','PR'),(4115606,'Matelândia','PR'),(4115705,'Matinhos','PR'),(4115739,'Mato Rico','PR'),(4115754,'Mauá da Serra','PR'),(4115804,'Medianeira','PR'),(4115853,'Mercedes','PR'),(4115903,'Mirador','PR'),(4116000,'Miraselva','PR'),(4116059,'Missal','PR'),(4116109,'Moreira Sales','PR'),(4116208,'Morretes','PR'),(4116307,'Munhoz de Melo','PR'),(4116406,'Nossa Senhora das Graças','PR'),(4116505,'Nova Aliança do Ivaí','PR'),(4116604,'Nova América da Colina','PR'),(4116703,'Nova Aurora','PR'),(4116802,'Nova Cantu','PR'),(4116901,'Nova Esperança','PR'),(4116950,'Nova Esperança do Sudoeste','PR'),(4117008,'Nova Fátima','PR'),(4117057,'Nova Laranjeiras','PR'),(4117107,'Nova Londrina','PR'),(4117206,'Nova Olímpia','PR'),(4117214,'Nova Santa Bárbara','PR'),(4117222,'Nova Santa Rosa','PR'),(4117255,'Nova Prata do Iguaçu','PR'),(4117271,'Nova Tebas','PR'),(4117297,'Novo Itacolomi','PR'),(4117305,'Ortigueira','PR'),(4117404,'Ourizona','PR'),(4117453,'Ouro Verde do Oeste','PR'),(4117503,'Paiçandu','PR'),(4117602,'Palmas','PR'),(4117701,'Palmeira','PR'),(4117800,'Palmital','PR'),(4117909,'Palotina','PR'),(4118006,'Paraíso do Norte','PR'),(4118105,'Paranacity','PR'),(4118204,'Paranaguá','PR'),(4118303,'Paranapoema','PR'),(4118402,'Paranavaí','PR'),(4118451,'Pato Bragado','PR'),(4118501,'Pato Branco','PR'),(4118600,'Paula Freitas','PR'),(4118709,'Paulo Frontin','PR'),(4118808,'Peabiru','PR'),(4118857,'Perobal','PR'),(4118907,'Pérola','PR'),(4119004,'Pérola d''Oeste','PR'),(4119103,'Piên','PR'),(4119152,'Pinhais','PR'),(4119202,'Pinhalão','PR'),(4119251,'Pinhal de São Bento','PR'),(4119301,'Pinhão','PR'),(4119400,'Piraí do Sul','PR'),(4119509,'Piraquara','PR'),(4119608,'Pitanga','PR'),(4119657,'Pitangueiras','PR'),(4119707,'Planaltina do Paraná','PR'),(4119806,'Planalto','PR'),(4119905,'Ponta Grossa','PR'),(4119954,'Pontal do Paraná','PR'),(4120002,'Porecatu','PR'),(4120101,'Porto Amazonas','PR'),(4120150,'Porto Barreiro','PR'),(4120200,'Porto Rico','PR'),(4120309,'Porto Vitória','PR'),(4120333,'Prado Ferreira','PR'),(4120358,'Pranchita','PR'),(4120408,'Presidente Castelo Branco','PR'),(4120507,'Primeiro de Maio','PR'),(4120606,'Prudentópolis','PR'),(4120655,'Quarto Centenário','PR'),(4120705,'Quatiguá','PR'),(4120804,'Quatro Barras','PR'),(4120853,'Quatro Pontes','PR'),(4120903,'Quedas do Iguaçu','PR'),(4121000,'Querência do Norte','PR'),(4121109,'Quinta do Sol','PR'),(4121208,'Quitandinha','PR'),(4121257,'Ramilândia','PR'),(4121307,'Rancho Alegre','PR'),(4121356,'Rancho Alegre D''Oeste','PR'),(4121406,'Realeza','PR'),(4121505,'Rebouças','PR'),(4121604,'Renascença','PR'),(4121703,'Reserva','PR'),(4121752,'Reserva do Iguaçu','PR'),(4121802,'Ribeirão Claro','PR'),(4121901,'Ribeirão do Pinhal','PR'),(4122008,'Rio Azul','PR'),(4122107,'Rio Bom','PR'),(4122156,'Rio Bonito do Iguaçu','PR'),(4122172,'Rio Branco do Ivaí','PR'),(4122206,'Rio Branco do Sul','PR'),(4122305,'Rio Negro','PR'),(4122404,'Rolândia','PR'),(4122503,'Roncador','PR'),(4122602,'Rondon','PR'),(4122651,'Rosário do Ivaí','PR'),(4122701,'Sabáudia','PR'),(4122800,'Salgado Filho','PR'),(4122909,'Salto do Itararé','PR'),(4123006,'Salto do Lontra','PR'),(4123105,'Santa Amélia','PR'),(4123204,'Santa Cecília do Pavão','PR'),(4123303,'Santa Cruz de Monte Castelo','PR'),(4123402,'Santa Fé','PR'),(4123501,'Santa Helena','PR'),(4123600,'Santa Inês','PR'),(4123709,'Santa Isabel do Ivaí','PR'),(4123808,'Santa Izabel do Oeste','PR'),(4123824,'Santa Lúcia','PR'),(4123857,'Santa Maria do Oeste','PR'),(4123907,'Santa Mariana','PR'),(4123956,'Santa Mônica','PR'),(4124004,'Santana do Itararé','PR'),(4124020,'Santa Tereza do Oeste','PR'),(4124053,'Santa Terezinha de Itaipu','PR'),(4124103,'Santo Antônio da Platina','PR'),(4124202,'Santo Antônio do Caiuá','PR'),(4124301,'Santo Antônio do Paraíso','PR'),(4124400,'Santo Antônio do Sudoeste','PR'),(4124509,'Santo Inácio','PR'),(4124608,'São Carlos do Ivaí','PR'),(4124707,'São Jerônimo da Serra','PR'),(4124806,'São João','PR'),(4124905,'São João do Caiuá','PR'),(4125001,'São João do Ivaí','PR'),(4125100,'São João do Triunfo','PR'),(4125209,'São Jorge d''Oeste','PR'),(4125308,'São Jorge do Ivaí','PR'),(4125357,'São Jorge do Patrocínio','PR'),(4125407,'São José da Boa Vista','PR'),(4125456,'São José das Palmeiras','PR'),(4125506,'São José dos Pinhais','PR'),(4125555,'São Manoel do Paraná','PR'),(4125605,'São Mateus do Sul','PR'),(4125704,'São Miguel do Iguaçu','PR'),(4125753,'São Pedro do Iguaçu','PR'),(4125803,'São Pedro do Ivaí','PR'),(4125902,'São Pedro do Paraná','PR'),(4126009,'São Sebastião da Amoreira','PR'),(4126108,'São Tomé','PR'),(4126207,'Sapopema','PR'),(4126256,'Sarandi','PR'),(4126272,'Saudade do Iguaçu','PR'),(4126306,'Sengés','PR'),(4126355,'Serranópolis do Iguaçu','PR'),(4126405,'Sertaneja','PR'),(4126504,'Sertanópolis','PR'),(4126603,'Siqueira Campos','PR'),(4126652,'Sulina','PR'),(4126678,'Tamarana','PR'),(4126702,'Tamboara','PR'),(4126801,'Tapejara','PR'),(4126900,'Tapira','PR'),(4127007,'Teixeira Soares','PR'),(4127106,'Telêmaco Borba','PR'),(4127205,'Terra Boa','PR'),(4127304,'Terra Rica','PR'),(4127403,'Terra Roxa','PR'),(4127502,'Tibagi','PR'),(4127601,'Tijucas do Sul','PR'),(4127700,'Toledo','PR'),(4127809,'Tomazina','PR'),(4127858,'Três Barras do Paraná','PR'),(4127882,'Tunas do Paraná','PR'),(4127908,'Tuneiras do Oeste','PR'),(4127957,'Tupãssi','PR'),(4127965,'Turvo','PR'),(4128005,'Ubiratã','PR'),(4128104,'Umuarama','PR'),(4128203,'União da Vitória','PR'),(4128302,'Uniflor','PR'),(4128401,'Uraí','PR'),(4128500,'Wenceslau Braz','PR'),(4128534,'Ventania','PR'),(4128559,'Vera Cruz do Oeste','PR'),(4128609,'Verê','PR'),(4128625,'Alto Paraíso','PR'),(4128633,'Doutor Ulysses','PR'),(4128658,'Virmond','PR'),(4128708,'Vitorino','PR'),(4128807,'Xambrê','PR'),(4200051,'Abdon Batista','SC'),(4200101,'Abelardo Luz','SC'),(4200200,'Agrolândia','SC'),(4200309,'Agronômica','SC'),(4200408,'Água Doce','SC'),(4200507,'Águas de Chapecó','SC'),(4200556,'Águas Frias','SC'),(4200606,'Águas Mornas','SC'),(4200705,'Alfredo Wagner','SC'),(4200754,'Alto Bela Vista','SC'),(4200804,'Anchieta','SC'),(4200903,'Angelina','SC'),(4201000,'Anita Garibaldi','SC'),(4201109,'Anitápolis','SC'),(4201208,'Antônio Carlos','SC'),(4201257,'Apiúna','SC'),(4201273,'Arabutã','SC'),(4201307,'Araquari','SC'),(4201406,'Araranguá','SC'),(4201505,'Armazém','SC'),(4201604,'Arroio Trinta','SC'),(4201653,'Arvoredo','SC'),(4201703,'Ascurra','SC'),(4201802,'Atalanta','SC'),(4201901,'Aurora','SC'),(4201950,'Balneário Arroio do Silva','SC'),(4202008,'Balneário Camboriú','SC'),(4202057,'Balneário Barra do Sul','SC'),(4202073,'Balneário Gaivota','SC'),(4202081,'Bandeirante','SC'),(4202099,'Barra Bonita','SC'),(4202107,'Barra Velha','SC'),(4202131,'Bela Vista do Toldo','SC'),(4202156,'Belmonte','SC'),(4202206,'Benedito Novo','SC'),(4202305,'Biguaçu','SC'),(4202404,'Blumenau','SC'),(4202438,'Bocaina do Sul','SC'),(4202453,'Bombinhas','SC'),(4202503,'Bom Jardim da Serra','SC'),(4202537,'Bom Jesus','SC'),(4202578,'Bom Jesus do Oeste','SC'),(4202602,'Bom Retiro','SC'),(4202701,'Botuverá','SC'),(4202800,'Braço do Norte','SC'),(4202859,'Braço do Trombudo','SC'),(4202875,'Brunópolis','SC'),(4202909,'Brusque','SC'),(4203006,'Caçador','SC'),(4203105,'Caibi','SC'),(4203154,'Calmon','SC'),(4203204,'Camboriú','SC'),(4203253,'Capão Alto','SC'),(4203303,'Campo Alegre','SC'),(4203402,'Campo Belo do Sul','SC'),(4203501,'Campo Erê','SC'),(4203600,'Campos Novos','SC'),(4203709,'Canelinha','SC'),(4203808,'Canoinhas','SC'),(4203907,'Capinzal','SC'),(4203956,'Capivari de Baixo','SC'),(4204004,'Catanduvas','SC'),(4204103,'Caxambu do Sul','SC'),(4204152,'Celso Ramos','SC'),(4204178,'Cerro Negro','SC'),(4204194,'Chapadão do Lageado','SC'),(4204202,'Chapecó','SC'),(4204251,'Cocal do Sul','SC'),(4204301,'Concórdia','SC'),(4204350,'Cordilheira Alta','SC'),(4204400,'Coronel Freitas','SC'),(4204459,'Coronel Martins','SC'),(4204509,'Corupá','SC'),(4204558,'Correia Pinto','SC'),(4204608,'Criciúma','SC'),(4204707,'Cunha Porã','SC'),(4204756,'Cunhataí','SC'),(4204806,'Curitibanos','SC'),(4204905,'Descanso','SC'),(4205001,'Dionísio Cerqueira','SC'),(4205100,'Dona Emma','SC'),(4205159,'Doutor Pedrinho','SC'),(4205175,'Entre Rios','SC'),(4205191,'Ermo','SC'),(4205209,'Erval Velho','SC'),(4205308,'Faxinal dos Guedes','SC'),(4205357,'Flor do Sertão','SC'),(4205407,'Florianópolis','SC'),(4205431,'Formosa do Sul','SC'),(4205456,'Forquilhinha','SC'),(4205506,'Fraiburgo','SC'),(4205555,'Frei Rogério','SC'),(4205605,'Galvão','SC'),(4205704,'Garopaba','SC'),(4205803,'Garuva','SC'),(4205902,'Gaspar','SC'),(4206009,'Governador Celso Ramos','SC'),(4206108,'Grão Pará','SC'),(4206207,'Gravatal','SC'),(4206306,'Guabiruba','SC'),(4206405,'Guaraciaba','SC'),(4206504,'Guaramirim','SC'),(4206603,'Guarujá do Sul','SC'),(4206652,'Guatambú','SC'),(4206702,'Herval d''Oeste','SC'),(4206751,'Ibiam','SC'),(4206801,'Ibicaré','SC'),(4206900,'Ibirama','SC'),(4207007,'Içara','SC'),(4207106,'Ilhota','SC'),(4207205,'Imaruí','SC'),(4207304,'Imbituba','SC'),(4207403,'Imbuia','SC'),(4207502,'Indaial','SC'),(4207577,'Iomerê','SC'),(4207601,'Ipira','SC'),(4207650,'Iporã do Oeste','SC'),(4207684,'Ipuaçu','SC'),(4207700,'Ipumirim','SC'),(4207759,'Iraceminha','SC'),(4207809,'Irani','SC'),(4207858,'Irati','SC'),(4207908,'Irineópolis','SC'),(4208005,'Itá','SC'),(4208104,'Itaiópolis','SC'),(4208203,'Itajaí','SC'),(4208302,'Itapema','SC'),(4208401,'Itapiranga','SC'),(4208450,'Itapoá','SC'),(4208500,'Ituporanga','SC'),(4208609,'Jaborá','SC'),(4208708,'Jacinto Machado','SC'),(4208807,'Jaguaruna','SC'),(4208906,'Jaraguá do Sul','SC'),(4208955,'Jardinópolis','SC'),(4209003,'Joaçaba','SC'),(4209102,'Joinville','SC'),(4209151,'José Boiteux','SC'),(4209177,'Jupiá','SC'),(4209201,'Lacerdópolis','SC'),(4209300,'Lages','SC'),(4209409,'Laguna','SC'),(4209458,'Lajeado Grande','SC'),(4209508,'Laurentino','SC'),(4209607,'Lauro Muller','SC'),(4209706,'Lebon Régis','SC'),(4209805,'Leoberto Leal','SC'),(4209854,'Lindóia do Sul','SC'),(4209904,'Lontras','SC'),(4210001,'Luiz Alves','SC'),(4210035,'Luzerna','SC'),(4210050,'Macieira','SC'),(4210100,'Mafra','SC'),(4210209,'Major Gercino','SC'),(4210308,'Major Vieira','SC'),(4210407,'Maracajá','SC'),(4210506,'Maravilha','SC'),(4210555,'Marema','SC'),(4210605,'Massaranduba','SC'),(4210704,'Matos Costa','SC'),(4210803,'Meleiro','SC'),(4210852,'Mirim Doce','SC'),(4210902,'Modelo','SC'),(4211009,'Mondaí','SC'),(4211058,'Monte Carlo','SC'),(4211108,'Monte Castelo','SC'),(4211207,'Morro da Fumaça','SC'),(4211256,'Morro Grande','SC'),(4211306,'Navegantes','SC'),(4211405,'Nova Erechim','SC'),(4211454,'Nova Itaberaba','SC'),(4211504,'Nova Trento','SC'),(4211603,'Nova Veneza','SC'),(4211652,'Novo Horizonte','SC'),(4211702,'Orleans','SC'),(4211751,'Otacílio Costa','SC'),(4211801,'Ouro','SC'),(4211850,'Ouro Verde','SC'),(4211876,'Paial','SC'),(4211892,'Painel','SC'),(4211900,'Palhoça','SC'),(4212007,'Palma Sola','SC'),(4212056,'Palmeira','SC'),(4212106,'Palmitos','SC'),(4212205,'Papanduva','SC'),(4212239,'Paraíso','SC'),(4212254,'Passo de Torres','SC'),(4212270,'Passos Maia','SC'),(4212304,'Paulo Lopes','SC'),
(4212403,'Pedras Grandes','SC'),(4212502,'Penha','SC'),(4212601,'Peritiba','SC'),(4212650,'Pescaria Brava','SC'),(4212700,'Petrolândia','SC'),(4212809,'Balneário Piçarras','SC'),(4212908,'Pinhalzinho','SC'),(4213005,'Pinheiro Preto','SC'),(4213104,'Piratuba','SC'),(4213153,'Planalto Alegre','SC'),(4213203,'Pomerode','SC'),(4213302,'Ponte Alta','SC'),(4213351,'Ponte Alta do Norte','SC'),(4213401,'Ponte Serrada','SC'),(4213500,'Porto Belo','SC'),(4213609,'Porto União','SC'),(4213708,'Pouso Redondo','SC'),(4213807,'Praia Grande','SC'),(4213906,'Presidente Castello Branco','SC'),(4214003,'Presidente Getúlio','SC'),(4214102,'Presidente Nereu','SC'),(4214151,'Princesa','SC'),(4214201,'Quilombo','SC'),(4214300,'Rancho Queimado','SC'),(4214409,'Rio das Antas','SC'),(4214508,'Rio do Campo','SC'),(4214607,'Rio do Oeste','SC'),(4214706,'Rio dos Cedros','SC'),(4214805,'Rio do Sul','SC'),(4214904,'Rio Fortuna','SC'),(4215000,'Rio Negrinho','SC'),(4215059,'Rio Rufino','SC'),(4215075,'Riqueza','SC'),(4215109,'Rodeio','SC'),(4215208,'Romelândia','SC'),(4215307,'Salete','SC'),(4215356,'Saltinho','SC'),(4215406,'Salto Veloso','SC'),(4215455,'Sangão','SC'),(4215505,'Santa Cecília','SC'),(4215554,'Santa Helena','SC'),(4215604,'Santa Rosa de Lima','SC'),(4215653,'Santa Rosa do Sul','SC'),(4215679,'Santa Terezinha','SC'),(4215687,'Santa Terezinha do Progresso','SC'),(4215695,'Santiago do Sul','SC'),(4215703,'Santo Amaro da Imperatriz','SC'),(4215752,'São Bernardino','SC'),(4215802,'São Bento do Sul','SC'),(4215901,'São Bonifácio','SC'),(4216008,'São Carlos','SC'),(4216057,'São Cristovão do Sul','SC'),(4216107,'São Domingos','SC'),(4216206,'São Francisco do Sul','SC'),(4216255,'São João do Oeste','SC'),(4216305,'São João Batista','SC'),(4216354,'São João do Itaperiú','SC'),(4216404,'São João do Sul','SC'),(4216503,'São Joaquim','SC'),(4216602,'São José','SC'),(4216701,'São José do Cedro','SC'),(4216800,'São José do Cerrito','SC'),(4216909,'São Lourenço do Oeste','SC'),(4217006,'São Ludgero','SC'),(4217105,'São Martinho','SC'),(4217154,'São Miguel da Boa Vista','SC'),(4217204,'São Miguel do Oeste','SC'),(4217253,'São Pedro de Alcântara','SC'),(4217303,'Saudades','SC'),(4217402,'Schroeder','SC'),(4217501,'Seara','SC'),(4217550,'Serra Alta','SC'),(4217600,'Siderópolis','SC'),(4217709,'Sombrio','SC'),(4217758,'Sul Brasil','SC'),(4217808,'Taió','SC'),(4217907,'Tangará','SC'),(4217956,'Tigrinhos','SC'),(4218004,'Tijucas','SC'),(4218103,'Timbé do Sul','SC'),(4218202,'Timbó','SC'),(4218251,'Timbó Grande','SC'),(4218301,'Três Barras','SC'),(4218350,'Treviso','SC'),(4218400,'Treze de Maio','SC'),(4218509,'Treze Tílias','SC'),(4218608,'Trombudo Central','SC'),(4218707,'Tubarão','SC'),(4218756,'Tunápolis','SC'),(4218806,'Turvo','SC'),(4218855,'União do Oeste','SC'),(4218905,'Urubici','SC'),(4218954,'Urupema','SC'),(4219002,'Urussanga','SC'),(4219101,'Vargeão','SC'),(4219150,'Vargem','SC'),(4219176,'Vargem Bonita','SC'),(4219200,'Vidal Ramos','SC'),(4219309,'Videira','SC'),(4219358,'Vitor Meireles','SC'),(4219408,'Witmarsum','SC'),(4219507,'Xanxerê','SC'),(4219606,'Xavantina','SC'),(4219705,'Xaxim','SC'),(4219853,'Zortéa','SC'),(4220000,'Balneário Rincão','SC'),(4300034,'Aceguá','RS'),(4300059,'Água Santa','RS'),(4300109,'Agudo','RS'),(4300208,'Ajuricaba','RS'),(4300307,'Alecrim','RS'),(4300406,'Alegrete','RS'),(4300455,'Alegria','RS'),(4300471,'Almirante Tamandaré do Sul','RS'),(4300505,'Alpestre','RS'),(4300554,'Alto Alegre','RS'),(4300570,'Alto Feliz','RS'),(4300604,'Alvorada','RS'),(4300638,'Amaral Ferrador','RS'),(4300646,'Ametista do Sul','RS'),(4300661,'André da Rocha','RS'),(4300703,'Anta Gorda','RS'),(4300802,'Antônio Prado','RS'),(4300851,'Arambaré','RS'),(4300877,'Araricá','RS'),(4300901,'Aratiba','RS'),(4301008,'Arroio do Meio','RS'),(4301057,'Arroio do Sal','RS'),(4301073,'Arroio do Padre','RS'),(4301107,'Arroio dos Ratos','RS'),(4301206,'Arroio do Tigre','RS'),(4301305,'Arroio Grande','RS'),(4301404,'Arvorezinha','RS'),(4301503,'Augusto Pestana','RS'),(4301552,'Áurea','RS'),(4301602,'Bagé','RS'),(4301636,'Balneário Pinhal','RS'),(4301651,'Barão','RS'),(4301701,'Barão de Cotegipe','RS'),(4301750,'Barão do Triunfo','RS'),(4301800,'Barracão','RS'),(4301859,'Barra do Guarita','RS'),(4301875,'Barra do Quaraí','RS'),(4301909,'Barra do Ribeiro','RS'),(4301925,'Barra do Rio Azul','RS'),(4301958,'Barra Funda','RS'),(4302006,'Barros Cassal','RS'),(4302055,'Benjamin Constant do Sul','RS'),(4302105,'Bento Gonçalves','RS'),(4302154,'Boa Vista das Missões','RS'),(4302204,'Boa Vista do Buricá','RS'),(4302220,'Boa Vista do Cadeado','RS'),(4302238,'Boa Vista do Incra','RS'),(4302253,'Boa Vista do Sul','RS'),(4302303,'Bom Jesus','RS'),(4302352,'Bom Princípio','RS'),(4302378,'Bom Progresso','RS'),(4302402,'Bom Retiro do Sul','RS'),(4302451,'Boqueirão do Leão','RS'),(4302501,'Bossoroca','RS'),(4302584,'Bozano','RS'),(4302600,'Braga','RS'),(4302659,'Brochier','RS'),(4302709,'Butiá','RS'),(4302808,'Caçapava do Sul','RS'),(4302907,'Cacequi','RS'),(4303004,'Cachoeira do Sul','RS'),(4303103,'Cachoeirinha','RS'),(4303202,'Cacique Doble','RS'),(4303301,'Caibaté','RS'),(4303400,'Caiçara','RS'),(4303509,'Camaquã','RS'),(4303558,'Camargo','RS'),(4303608,'Cambará do Sul','RS'),(4303673,'Campestre da Serra','RS'),(4303707,'Campina das Missões','RS'),(4303806,'Campinas do Sul','RS'),(4303905,'Campo Bom','RS'),(4304002,'Campo Novo','RS'),(4304101,'Campos Borges','RS'),(4304200,'Candelária','RS'),(4304309,'Cândido Godói','RS'),(4304358,'Candiota','RS'),(4304408,'Canela','RS'),(4304507,'Canguçu','RS'),(4304606,'Canoas','RS'),(4304614,'Canudos do Vale','RS'),(4304622,'Capão Bonito do Sul','RS'),(4304630,'Capão da Canoa','RS'),(4304655,'Capão do Cipó','RS'),(4304663,'Capão do Leão','RS'),(4304671,'Capivari do Sul','RS'),(4304689,'Capela de Santana','RS'),(4304697,'Capitão','RS'),(4304705,'Carazinho','RS'),(4304713,'Caraá','RS'),(4304804,'Carlos Barbosa','RS'),(4304853,'Carlos Gomes','RS'),(4304903,'Casca','RS'),(4304952,'Caseiros','RS'),(4305009,'Catuípe','RS'),(4305108,'Caxias do Sul','RS'),(4305116,'Centenário','RS'),(4305124,'Cerrito','RS'),(4305132,'Cerro Branco','RS'),(4305157,'Cerro Grande','RS'),(4305173,'Cerro Grande do Sul','RS'),(4305207,'Cerro Largo','RS'),(4305306,'Chapada','RS'),(4305355,'Charqueadas','RS'),(4305371,'Charrua','RS'),(4305405,'Chiapetta','RS'),(4305439,'Chuí','RS'),(4305447,'Chuvisca','RS'),(4305454,'Cidreira','RS'),(4305504,'Ciríaco','RS'),(4305587,'Colinas','RS'),(4305603,'Colorado','RS'),(4305702,'Condor','RS'),(4305801,'Constantina','RS'),(4305835,'Coqueiro Baixo','RS'),(4305850,'Coqueiros do Sul','RS'),(4305871,'Coronel Barros','RS'),(4305900,'Coronel Bicaco','RS'),(4305934,'Coronel Pilar','RS'),(4305959,'Cotiporã','RS'),(4305975,'Coxilha','RS'),(4306007,'Crissiumal','RS'),(4306056,'Cristal','RS'),(4306072,'Cristal do Sul','RS'),(4306106,'Cruz Alta','RS'),(4306130,'Cruzaltense','RS'),(4306205,'Cruzeiro do Sul','RS'),(4306304,'David Canabarro','RS'),(4306320,'Derrubadas','RS'),(4306353,'Dezesseis de Novembro','RS'),(4306379,'Dilermando de Aguiar','RS'),(4306403,'Dois Irmãos','RS'),(4306429,'Dois Irmãos das Missões','RS'),(4306452,'Dois Lajeados','RS'),(4306502,'Dom Feliciano','RS'),(4306551,'Dom Pedro de Alcântara','RS'),(4306601,'Dom Pedrito','RS'),(4306700,'Dona Francisca','RS'),(4306734,'Doutor Maurício Cardoso','RS'),(4306759,'Doutor Ricardo','RS'),(4306767,'Eldorado do Sul','RS'),(4306809,'Encantado','RS'),(4306908,'Encruzilhada do Sul','RS'),(4306924,'Engenho Velho','RS'),(4306932,'Entre-Ijuís','RS'),(4306957,'Entre Rios do Sul','RS'),(4306973,'Erebango','RS'),(4307005,'Erechim','RS'),(4307054,'Ernestina','RS'),(4307104,'Herval','RS'),(4307203,'Erval Grande','RS'),(4307302,'Erval Seco','RS'),(4307401,'Esmeralda','RS'),(4307450,'Esperança do Sul','RS'),(4307500,'Espumoso','RS'),(4307559,'Estação','RS'),(4307609,'Estância Velha','RS'),(4307708,'Esteio','RS'),(4307807,'Estrela','RS'),(4307815,'Estrela Velha','RS'),(4307831,'Eugênio de Castro','RS'),(4307864,'Fagundes Varela','RS'),(4307906,'Farroupilha','RS'),(4308003,'Faxinal do Soturno','RS'),(4308052,'Faxinalzinho','RS'),(4308078,'Fazenda Vilanova','RS'),(4308102,'Feliz','RS'),(4308201,'Flores da Cunha','RS'),(4308250,'Floriano Peixoto','RS'),(4308300,'Fontoura Xavier','RS'),(4308409,'Formigueiro','RS'),(4308433,'Forquetinha','RS'),(4308458,'Fortaleza dos Valos','RS'),(4308508,'Frederico Westphalen','RS'),(4308607,'Garibaldi','RS'),(4308656,'Garruchos','RS'),(4308706,'Gaurama','RS'),(4308805,'General Câmara','RS'),(4308854,'Gentil','RS'),(4308904,'Getúlio Vargas','RS'),(4309001,'Giruá','RS'),(4309050,'Glorinha','RS'),(4309100,'Gramado','RS'),(4309126,'Gramado dos Loureiros','RS'),(4309159,'Gramado Xavier','RS'),(4309209,'Gravataí','RS'),(4309258,'Guabiju','RS'),(4309308,'Guaíba','RS'),(4309407,'Guaporé','RS'),(4309506,'Guarani das Missões','RS'),(4309555,'Harmonia','RS'),(4309571,'Herveiras','RS'),(4309605,'Horizontina','RS'),(4309654,'Hulha Negra','RS'),(4309704,'Humaitá','RS'),(4309753,'Ibarama','RS'),(4309803,'Ibiaçá','RS'),(4309902,'Ibiraiaras','RS'),(4309951,'Ibirapuitã','RS'),(4310009,'Ibirubá','RS'),(4310108,'Igrejinha','RS'),(4310207,'Ijuí','RS'),(4310306,'Ilópolis','RS'),(4310330,'Imbé','RS'),(4310363,'Imigrante','RS'),(4310405,'Independência','RS'),(4310413,'Inhacorá','RS'),(4310439,'Ipê','RS'),(4310462,'Ipiranga do Sul','RS'),(4310504,'Iraí','RS'),(4310538,'Itaara','RS'),(4310553,'Itacurubi','RS'),(4310579,'Itapuca','RS'),(4310603,'Itaqui','RS'),(4310652,'Itati','RS'),(4310702,'Itatiba do Sul','RS'),(4310751,'Ivorá','RS'),(4310801,'Ivoti','RS'),(4310850,'Jaboticaba','RS'),(4310876,'Jacuizinho','RS'),(4310900,'Jacutinga','RS'),(4311007,'Jaguarão','RS'),(4311106,'Jaguari','RS'),(4311122,'Jaquirana','RS'),(4311130,'Jari','RS'),(4311155,'Jóia','RS'),(4311205,'Júlio de Castilhos','RS'),(4311239,'Lagoa Bonita do Sul','RS'),(4311254,'Lagoão','RS'),(4311270,'Lagoa dos Três Cantos','RS'),(4311304,'Lagoa Vermelha','RS'),(4311403,'Lajeado','RS'),(4311429,'Lajeado do Bugre','RS'),(4311502,'Lavras do Sul','RS'),(4311601,'Liberato Salzano','RS'),(4311627,'Lindolfo Collor','RS'),(4311643,'Linha Nova','RS'),(4311700,'Machadinho','RS'),(4311718,'Maçambará','RS'),(4311734,'Mampituba','RS'),(4311759,'Manoel Viana','RS'),(4311775,'Maquiné','RS'),(4311791,'Maratá','RS'),(4311809,'Marau','RS'),(4311908,'Marcelino Ramos','RS'),(4311981,'Mariana Pimentel','RS'),(4312005,'Mariano Moro','RS'),(4312054,'Marques de Souza','RS'),(4312104,'Mata','RS'),(4312138,'Mato Castelhano','RS'),(4312153,'Mato Leitão','RS'),(4312179,'Mato Queimado','RS'),(4312203,'Maximiliano de Almeida','RS'),(4312252,'Minas do Leão','RS'),(4312302,'Miraguaí','RS'),(4312351,'Montauri','RS'),(4312377,'Monte Alegre dos Campos','RS'),(4312385,'Monte Belo do Sul','RS'),(4312401,'Montenegro','RS'),(4312427,'Mormaço','RS'),(4312443,'Morrinhos do Sul','RS'),(4312450,'Morro Redondo','RS'),(4312476,'Morro Reuter','RS'),(4312500,'Mostardas','RS'),(4312609,'Muçum','RS'),(4312617,'Muitos Capões','RS'),(4312625,'Muliterno','RS'),(4312658,'Não-Me-Toque','RS'),(4312674,'Nicolau Vergueiro','RS'),(4312708,'Nonoai','RS'),(4312757,'Nova Alvorada','RS'),(4312807,'Nova Araçá','RS'),(4312906,'Nova Bassano','RS'),(4312955,'Nova Boa Vista','RS'),(4313003,'Nova Bréscia','RS'),(4313011,'Nova Candelária','RS'),(4313037,'Nova Esperança do Sul','RS'),(4313060,'Nova Hartz','RS'),(4313086,'Nova Pádua','RS'),(4313102,'Nova Palma','RS'),(4313201,'Nova Petrópolis','RS'),(4313300,'Nova Prata','RS'),(4313334,'Nova Ramada','RS'),(4313359,'Nova Roma do Sul','RS'),(4313375,'Nova Santa Rita','RS'),(4313391,'Novo Cabrais','RS'),(4313409,'Novo Hamburgo','RS'),(4313425,'Novo Machado','RS'),(4313441,'Novo Tiradentes','RS'),(4313466,'Novo Xingu','RS'),(4313490,'Novo Barreiro','RS'),(4313508,'Osório','RS'),(4313607,'Paim Filho','RS'),(4313656,'Palmares do Sul','RS'),(4313706,'Palmeira das Missões','RS'),(4313805,'Palmitinho','RS'),(4313904,'Panambi','RS'),(4313953,'Pantano Grande','RS'),(4314001,'Paraí','RS'),(4314027,'Paraíso do Sul','RS'),(4314035,'Pareci Novo','RS'),(4314050,'Parobé','RS'),(4314068,'Passa Sete','RS'),(4314076,'Passo do Sobrado','RS'),(4314100,'Passo Fundo','RS'),(4314134,'Paulo Bento','RS'),(4314159,'Paverama','RS'),(4314175,'Pedras Altas','RS'),(4314209,'Pedro Osório','RS'),(4314308,'Pejuçara','RS'),(4314407,'Pelotas','RS'),(4314423,'Picada Café','RS'),(4314456,'Pinhal','RS'),(4314464,'Pinhal da Serra','RS'),(4314472,'Pinhal Grande','RS'),(4314498,'Pinheirinho do Vale','RS'),(4314506,'Pinheiro Machado','RS'),(4314548,'Pinto Bandeira','RS'),(4314555,'Pirapó','RS'),(4314605,'Piratini','RS'),(4314704,'Planalto','RS'),(4314753,'Poço das Antas','RS'),(4314779,'Pontão','RS'),(4314787,'Ponte Preta','RS'),(4314803,'Portão','RS'),(4314902,'Porto Alegre','RS'),(4315008,'Porto Lucena','RS'),(4315057,'Porto Mauá','RS'),(4315073,'Porto Vera Cruz','RS'),(4315107,'Porto Xavier','RS'),(4315131,'Pouso Novo','RS'),(4315149,'Presidente Lucena','RS'),(4315156,'Progresso','RS'),(4315172,'Protásio Alves','RS'),(4315206,'Putinga','RS'),(4315305,'Quaraí','RS'),(4315313,'Quatro Irmãos','RS'),(4315321,'Quevedos','RS'),(4315354,'Quinze de Novembro','RS'),(4315404,'Redentora','RS'),(4315453,'Relvado','RS'),(4315503,'Restinga Sêca','RS'),(4315552,'Rio dos Índios','RS'),(4315602,'Rio Grande','RS'),(4315701,'Rio Pardo','RS'),(4315750,'Riozinho','RS'),(4315800,'Roca Sales','RS'),(4315909,'Rodeio Bonito','RS'),(4315958,'Rolador','RS'),(4316006,'Rolante','RS'),(4316105,'Ronda Alta','RS'),(4316204,'Rondinha','RS'),(4316303,'Roque Gonzales','RS'),(4316402,'Rosário do Sul','RS'),(4316428,'Sagrada Família','RS'),(4316436,'Saldanha Marinho','RS'),(4316451,'Salto do Jacuí','RS'),(4316477,'Salvador das Missões','RS'),(4316501,'Salvador do Sul','RS'),(4316600,'Sananduva','RS'),(4316709,'Santa Bárbara do Sul','RS'),(4316733,'Santa Cecília do Sul','RS'),(4316758,'Santa Clara do Sul','RS'),(4316808,'Santa Cruz do Sul','RS'),(4316907,'Santa Maria','RS'),(4316956,'Santa Maria do Herval','RS'),(4316972,'Santa Margarida do Sul','RS'),(4317004,'Santana da Boa Vista','RS'),(4317103,'Sant''Ana do Livramento','RS'),(4317202,'Santa Rosa','RS'),(4317251,'Santa Tereza','RS'),(4317301,'Santa Vitória do Palmar','RS'),(4317400,'Santiago','RS'),(4317509,'Santo Ângelo','RS'),(4317558,'Santo Antônio do Palma','RS'),(4317608,'Santo Antônio da Patrulha','RS'),(4317707,'Santo Antônio das Missões','RS'),(4317756,'Santo Antônio do Planalto','RS'),(4317806,'Santo Augusto','RS'),(4317905,'Santo Cristo','RS'),(4317954,'Santo Expedito do Sul','RS'),(4318002,'São Borja','RS'),(4318051,'São Domingos do Sul','RS'),(4318101,'São Francisco de Assis','RS'),(4318200,'São Francisco de Paula','RS'),(4318309,'São Gabriel','RS'),(4318408,'São Jerônimo','RS'),(4318424,'São João da Urtiga','RS'),(4318432,'São João do Polêsine','RS'),(4318440,'São Jorge','RS'),(4318457,'São José das Missões','RS'),(4318465,'São José do Herval','RS'),(4318481,'São José do Hortêncio','RS'),(4318499,'São José do Inhacorá','RS'),
(4318507,'São José do Norte','RS'),(4318606,'São José do Ouro','RS'),(4318614,'São José do Sul','RS'),(4318622,'São José dos Ausentes','RS'),(4318705,'São Leopoldo','RS'),(4318804,'São Lourenço do Sul','RS'),(4318903,'São Luiz Gonzaga','RS'),(4319000,'São Marcos','RS'),(4319109,'São Martinho','RS'),(4319125,'São Martinho da Serra','RS'),(4319158,'São Miguel das Missões','RS'),(4319208,'São Nicolau','RS'),(4319307,'São Paulo das Missões','RS'),(4319356,'São Pedro da Serra','RS'),(4319364,'São Pedro das Missões','RS'),(4319372,'São Pedro do Butiá','RS'),(4319406,'São Pedro do Sul','RS'),(4319505,'São Sebastião do Caí','RS'),(4319604,'São Sepé','RS'),(4319703,'São Valentim','RS'),(4319711,'São Valentim do Sul','RS'),(4319737,'São Valério do Sul','RS'),(4319752,'São Vendelino','RS'),(4319802,'São Vicente do Sul','RS'),(4319901,'Sapiranga','RS'),(4320008,'Sapucaia do Sul','RS'),(4320107,'Sarandi','RS'),(4320206,'Seberi','RS'),(4320230,'Sede Nova','RS'),(4320263,'Segredo','RS'),(4320305,'Selbach','RS'),(4320321,'Senador Salgado Filho','RS'),(4320354,'Sentinela do Sul','RS'),(4320404,'Serafina Corrêa','RS'),(4320453,'Sério','RS'),(4320503,'Sertão','RS'),(4320552,'Sertão Santana','RS'),(4320578,'Sete de Setembro','RS'),(4320602,'Severiano de Almeida','RS'),(4320651,'Silveira Martins','RS'),(4320677,'Sinimbu','RS'),(4320701,'Sobradinho','RS'),(4320800,'Soledade','RS'),(4320859,'Tabaí','RS'),(4320909,'Tapejara','RS'),(4321006,'Tapera','RS'),(4321105,'Tapes','RS'),(4321204,'Taquara','RS'),(4321303,'Taquari','RS'),(4321329,'Taquaruçu do Sul','RS'),(4321352,'Tavares','RS'),(4321402,'Tenente Portela','RS'),(4321436,'Terra de Areia','RS'),(4321451,'Teutônia','RS'),(4321469,'Tio Hugo','RS'),(4321477,'Tiradentes do Sul','RS'),(4321493,'Toropi','RS'),(4321501,'Torres','RS'),(4321600,'Tramandaí','RS'),(4321626,'Travesseiro','RS'),(4321634,'Três Arroios','RS'),(4321667,'Três Cachoeiras','RS'),(4321709,'Três Coroas','RS'),(4321808,'Três de Maio','RS'),(4321832,'Três Forquilhas','RS'),(4321857,'Três Palmeiras','RS'),(4321907,'Três Passos','RS'),(4321956,'Trindade do Sul','RS'),(4322004,'Triunfo','RS'),(4322103,'Tucunduva','RS'),(4322152,'Tunas','RS'),(4322186,'Tupanci do Sul','RS'),(4322202,'Tupanciretã','RS'),(4322251,'Tupandi','RS'),(4322301,'Tuparendi','RS'),(4322327,'Turuçu','RS'),(4322343,'Ubiretama','RS'),(4322350,'União da Serra','RS'),(4322376,'Unistalda','RS'),(4322400,'Uruguaiana','RS'),(4322509,'Vacaria','RS'),(4322525,'Vale Verde','RS'),(4322533,'Vale do Sol','RS'),(4322541,'Vale Real','RS'),(4322558,'Vanini','RS'),(4322608,'Venâncio Aires','RS'),(4322707,'Vera Cruz','RS'),(4322806,'Veranópolis','RS'),(4322855,'Vespasiano Corrêa','RS'),(4322905,'Viadutos','RS'),(4323002,'Viamão','RS'),(4323101,'Vicente Dutra','RS'),(4323200,'Victor Graeff','RS'),(4323309,'Vila Flores','RS'),(4323358,'Vila Lângaro','RS'),(4323408,'Vila Maria','RS'),(4323457,'Vila Nova do Sul','RS'),(4323507,'Vista Alegre','RS'),(4323606,'Vista Alegre do Prata','RS'),(4323705,'Vista Gaúcha','RS'),(4323754,'Vitória das Missões','RS'),(4323770,'Westfália','RS'),(4323804,'Xangri-lá','RS'),(5000203,'Água Clara','MS'),(5000252,'Alcinópolis','MS'),(5000609,'Amambai','MS'),(5000708,'Anastácio','MS'),(5000807,'Anaurilândia','MS'),(5000856,'Angélica','MS'),(5000906,'Antônio João','MS'),(5001003,'Aparecida do Taboado','MS'),(5001102,'Aquidauana','MS'),(5001243,'Aral Moreira','MS'),(5001508,'Bandeirantes','MS'),(5001904,'Bataguassu','MS'),(5002001,'Batayporã','MS'),(5002100,'Bela Vista','MS'),(5002159,'Bodoquena','MS'),(5002209,'Bonito','MS'),(5002308,'Brasilândia','MS'),(5002407,'Caarapó','MS'),(5002605,'Camapuã','MS'),(5002704,'Campo Grande','MS'),(5002803,'Caracol','MS'),(5002902,'Cassilândia','MS'),(5002951,'Chapadão do Sul','MS'),(5003108,'Corguinho','MS'),(5003157,'Coronel Sapucaia','MS'),(5003207,'Corumbá','MS'),(5003256,'Costa Rica','MS'),(5003306,'Coxim','MS'),(5003454,'Deodápolis','MS'),(5003488,'Dois Irmãos do Buriti','MS'),(5003504,'Douradina','MS'),(5003702,'Dourados','MS'),(5003751,'Eldorado','MS'),(5003801,'Fátima do Sul','MS'),(5003900,'Figueirão','MS'),(5004007,'Glória de Dourados','MS'),(5004106,'Guia Lopes da Laguna','MS'),(5004304,'Iguatemi','MS'),(5004403,'Inocência','MS'),(5004502,'Itaporã','MS'),(5004601,'Itaquiraí','MS'),(5004700,'Ivinhema','MS'),(5004809,'Japorã','MS'),(5004908,'Jaraguari','MS'),(5005004,'Jardim','MS'),(5005103,'Jateí','MS'),(5005152,'Juti','MS'),(5005202,'Ladário','MS'),(5005251,'Laguna Carapã','MS'),(5005400,'Maracaju','MS'),(5005608,'Miranda','MS'),(5005681,'Mundo Novo','MS'),(5005707,'Naviraí','MS'),(5005806,'Nioaque','MS'),(5006002,'Nova Alvorada do Sul','MS'),(5006200,'Nova Andradina','MS'),(5006259,'Novo Horizonte do Sul','MS'),(5006275,'Paraíso das Águas','MS'),(5006309,'Paranaíba','MS'),(5006358,'Paranhos','MS'),(5006408,'Pedro Gomes','MS'),(5006606,'Ponta Porã','MS'),(5006903,'Porto Murtinho','MS'),(5007109,'Ribas do Rio Pardo','MS'),(5007208,'Rio Brilhante','MS'),(5007307,'Rio Negro','MS'),(5007406,'Rio Verde de Mato Grosso','MS'),(5007505,'Rochedo','MS'),(5007554,'Santa Rita do Pardo','MS'),(5007695,'São Gabriel do Oeste','MS'),(5007703,'Sete Quedas','MS'),(5007802,'Selvíria','MS'),(5007901,'Sidrolândia','MS'),(5007935,'Sonora','MS'),(5007950,'Tacuru','MS'),(5007976,'Taquarussu','MS'),(5008008,'Terenos','MS'),(5008305,'Três Lagoas','MS'),(5008404,'Vicentina','MS'),(5100102,'Acorizal','MT'),(5100201,'Água Boa','MT'),(5100250,'Alta Floresta','MT'),(5100300,'Alto Araguaia','MT'),(5100359,'Alto Boa Vista','MT'),(5100409,'Alto Garças','MT'),(5100508,'Alto Paraguai','MT'),(5100607,'Alto Taquari','MT'),(5100805,'Apiacás','MT'),(5101001,'Araguaiana','MT'),(5101209,'Araguainha','MT'),(5101258,'Araputanga','MT'),(5101308,'Arenápolis','MT'),(5101407,'Aripuanã','MT'),(5101605,'Barão de Melgaço','MT'),(5101704,'Barra do Bugres','MT'),(5101803,'Barra do Garças','MT'),(5101837,'Boa Esperança do Norte','MT'),(5101852,'Bom Jesus do Araguaia','MT'),(5101902,'Brasnorte','MT'),(5102504,'Cáceres','MT'),(5102603,'Campinápolis','MT'),(5102637,'Campo Novo do Parecis','MT'),(5102678,'Campo Verde','MT'),(5102686,'Campos de Júlio','MT'),(5102694,'Canabrava do Norte','MT'),(5102702,'Canarana','MT'),(5102793,'Carlinda','MT'),(5102850,'Castanheira','MT'),(5103007,'Chapada dos Guimarães','MT'),(5103056,'Cláudia','MT'),(5103106,'Cocalinho','MT'),(5103205,'Colíder','MT'),(5103254,'Colniza','MT'),(5103304,'Comodoro','MT'),(5103353,'Confresa','MT'),(5103361,'Conquista D''Oeste','MT'),(5103379,'Cotriguaçu','MT'),(5103403,'Cuiabá','MT'),(5103437,'Curvelândia','MT'),(5103452,'Denise','MT'),(5103502,'Diamantino','MT'),(5103601,'Dom Aquino','MT'),(5103700,'Feliz Natal','MT'),(5103809,'Figueirópolis D''Oeste','MT'),(5103858,'Gaúcha do Norte','MT'),(5103908,'General Carneiro','MT'),(5103957,'Glória D''Oeste','MT'),(5104104,'Guarantã do Norte','MT'),(5104203,'Guiratinga','MT'),(5104500,'Indiavaí','MT'),(5104526,'Ipiranga do Norte','MT'),(5104542,'Itanhangá','MT'),(5104559,'Itaúba','MT'),(5104609,'Itiquira','MT'),(5104807,'Jaciara','MT'),(5104906,'Jangada','MT'),(5105002,'Jauru','MT'),(5105101,'Juara','MT'),(5105150,'Juína','MT'),(5105176,'Juruena','MT'),(5105200,'Juscimeira','MT'),(5105234,'Lambari D''Oeste','MT'),(5105259,'Lucas do Rio Verde','MT'),(5105309,'Luciara','MT'),(5105507,'Vila Bela da Santíssima Trindade','MT'),(5105580,'Marcelândia','MT'),(5105606,'Matupá','MT'),(5105622,'Mirassol d''Oeste','MT'),(5105903,'Nobres','MT'),(5106000,'Nortelândia','MT'),(5106109,'Nossa Senhora do Livramento','MT'),(5106158,'Nova Bandeirantes','MT'),(5106174,'Nova Nazaré','MT'),(5106182,'Nova Lacerda','MT'),(5106190,'Nova Santa Helena','MT'),(5106208,'Nova Brasilândia','MT'),(5106216,'Nova Canaã do Norte','MT'),(5106224,'Nova Mutum','MT'),(5106232,'Nova Olímpia','MT'),(5106240,'Nova Ubiratã','MT'),(5106257,'Nova Xavantina','MT'),(5106265,'Novo Mundo','MT'),(5106273,'Novo Horizonte do Norte','MT'),(5106281,'Novo São Joaquim','MT'),(5106299,'Paranaíta','MT'),(5106307,'Paranatinga','MT'),(5106315,'Novo Santo Antônio','MT'),(5106372,'Pedra Preta','MT'),(5106422,'Peixoto de Azevedo','MT'),(5106455,'Planalto da Serra','MT'),(5106505,'Poconé','MT'),(5106653,'Pontal do Araguaia','MT'),(5106703,'Ponte Branca','MT'),(5106752,'Pontes e Lacerda','MT'),(5106778,'Porto Alegre do Norte','MT'),(5106802,'Porto dos Gaúchos','MT'),(5106828,'Porto Esperidião','MT'),(5106851,'Porto Estrela','MT'),(5107008,'Poxoréu','MT'),(5107040,'Primavera do Leste','MT'),(5107065,'Querência','MT'),(5107107,'São José dos Quatro Marcos','MT'),(5107156,'Reserva do Cabaçal','MT'),(5107180,'Ribeirão Cascalheira','MT'),(5107198,'Ribeirãozinho','MT'),(5107206,'Rio Branco','MT'),(5107248,'Santa Carmem','MT'),(5107263,'Santo Afonso','MT'),(5107297,'São José do Povo','MT'),(5107305,'São José do Rio Claro','MT'),(5107354,'São José do Xingu','MT'),(5107404,'São Pedro da Cipa','MT'),(5107578,'Rondolândia','MT'),(5107602,'Rondonópolis','MT'),(5107701,'Rosário Oeste','MT'),(5107743,'Santa Cruz do Xingu','MT'),(5107750,'Salto do Céu','MT'),(5107768,'Santa Rita do Trivelato','MT'),(5107776,'Santa Terezinha','MT'),(5107792,'Santo Antônio do Leste','MT'),(5107800,'Santo Antônio do Leverger','MT'),(5107859,'São Félix do Araguaia','MT'),(5107875,'Sapezal','MT'),(5107883,'Serra Nova Dourada','MT'),(5107909,'Sinop','MT'),(5107925,'Sorriso','MT'),(5107941,'Tabaporã','MT'),(5107958,'Tangará da Serra','MT'),(5108006,'Tapurah','MT'),(5108055,'Terra Nova do Norte','MT'),(5108105,'Tesouro','MT'),(5108204,'Torixoréu','MT'),(5108303,'União do Sul','MT'),(5108352,'Vale de São Domingos','MT'),(5108402,'Várzea Grande','MT'),(5108501,'Vera','MT'),(5108600,'Vila Rica','MT'),(5108808,'Nova Guarita','MT'),(5108857,'Nova Marilândia','MT'),(5108907,'Nova Maringá','MT'),(5108956,'Nova Monte Verde','MT'),(5200050,'Abadia de Goiás','GO'),(5200100,'Abadiânia','GO'),(5200134,'Acreúna','GO'),(5200159,'Adelândia','GO'),(5200175,'Água Fria de Goiás','GO'),(5200209,'Água Limpa','GO'),(5200258,'Águas Lindas de Goiás','GO'),(5200308,'Alexânia','GO'),(5200506,'Aloândia','GO'),(5200555,'Alto Horizonte','GO'),(5200605,'Alto Paraíso de Goiás','GO'),(5200803,'Alvorada do Norte','GO'),(5200829,'Amaralina','GO'),(5200852,'Americano do Brasil','GO'),(5200902,'Amorinópolis','GO'),(5201108,'Anápolis','GO'),(5201207,'Anhanguera','GO'),(5201306,'Anicuns','GO'),(5201405,'Aparecida de Goiânia','GO'),(5201454,'Aparecida do Rio Doce','GO'),(5201504,'Aporé','GO'),(5201603,'Araçu','GO'),(5201702,'Aragarças','GO'),(5201801,'Aragoiânia','GO'),(5202155,'Araguapaz','GO'),(5202353,'Arenópolis','GO'),(5202502,'Aruanã','GO'),(5202601,'Aurilândia','GO'),(5202809,'Avelinópolis','GO'),(5203104,'Baliza','GO'),(5203203,'Barro Alto','GO'),(5203302,'Bela Vista de Goiás','GO'),(5203401,'Bom Jardim de Goiás','GO'),(5203500,'Bom Jesus de Goiás','GO'),(5203559,'Bonfinópolis','GO'),(5203575,'Bonópolis','GO'),(5203609,'Brazabrantes','GO'),(5203807,'Britânia','GO'),(5203906,'Buriti Alegre','GO'),(5203939,'Buriti de Goiás','GO'),(5203962,'Buritinópolis','GO'),(5204003,'Cabeceiras','GO'),(5204102,'Cachoeira Alta','GO'),(5204201,'Cachoeira de Goiás','GO'),(5204250,'Cachoeira Dourada','GO'),(5204300,'Caçu','GO'),(5204409,'Caiapônia','GO'),(5204508,'Caldas Novas','GO'),(5204557,'Caldazinha','GO'),(5204607,'Campestre de Goiás','GO'),(5204656,'Campinaçu','GO'),(5204706,'Campinorte','GO'),(5204805,'Campo Alegre de Goiás','GO'),(5204854,'Campo Limpo de Goiás','GO'),(5204904,'Campos Belos','GO'),(5204953,'Campos Verdes','GO'),(5205000,'Carmo do Rio Verde','GO'),(5205059,'Castelândia','GO'),(5205109,'Catalão','GO'),(5205208,'Caturaí','GO'),(5205307,'Cavalcante','GO'),(5205406,'Ceres','GO'),(5205455,'Cezarina','GO'),(5205471,'Chapadão do Céu','GO'),(5205497,'Cidade Ocidental','GO'),(5205513,'Cocalzinho de Goiás','GO'),(5205521,'Colinas do Sul','GO'),(5205703,'Córrego do Ouro','GO'),(5205802,'Corumbá de Goiás','GO'),(5205901,'Corumbaíba','GO'),(5206206,'Cristalina','GO'),(5206305,'Cristianópolis','GO'),(5206404,'Crixás','GO'),(5206503,'Cromínia','GO'),(5206602,'Cumari','GO'),(5206701,'Damianópolis','GO'),(5206800,'Damolândia','GO'),(5206909,'Davinópolis','GO'),(5207105,'Diorama','GO'),(5207253,'Doverlândia','GO'),(5207352,'Edealina','GO'),(5207402,'Edéia','GO'),(5207501,'Estrela do Norte','GO'),(5207535,'Faina','GO'),(5207600,'Fazenda Nova','GO'),(5207808,'Firminópolis','GO'),(5207907,'Flores de Goiás','GO'),(5208004,'Formosa','GO'),(5208103,'Formoso','GO'),(5208152,'Gameleira de Goiás','GO'),(5208301,'Divinópolis de Goiás','GO'),(5208400,'Goianápolis','GO'),(5208509,'Goiandira','GO'),(5208608,'Goianésia','GO'),(5208707,'Goiânia','GO'),(5208806,'Goianira','GO'),(5208905,'Goiás','GO'),(5209101,'Goiatuba','GO'),(5209150,'Gouvelândia','GO'),(5209200,'Guapó','GO'),(5209291,'Guaraíta','GO'),(5209408,'Guarani de Goiás','GO'),(5209457,'Guarinos','GO'),(5209606,'Heitoraí','GO'),(5209705,'Hidrolândia','GO'),(5209804,'Hidrolina','GO'),(5209903,'Iaciara','GO'),(5209937,'Inaciolândia','GO'),(5209952,'Indiara','GO'),(5210000,'Inhumas','GO'),(5210109,'Ipameri','GO'),(5210158,'Ipiranga de Goiás','GO'),(5210208,'Iporá','GO'),(5210307,'Israelândia','GO'),(5210406,'Itaberaí','GO'),(5210562,'Itaguari','GO'),(5210604,'Itaguaru','GO'),(5210802,'Itajá','GO'),(5210901,'Itapaci','GO'),(5211008,'Itapirapuã','GO'),(5211206,'Itapuranga','GO'),(5211305,'Itarumã','GO'),(5211404,'Itauçu','GO'),(5211503,'Itumbiara','GO'),(5211602,'Ivolândia','GO'),(5211701,'Jandaia','GO'),(5211800,'Jaraguá','GO'),(5211909,'Jataí','GO'),(5212006,'Jaupaci','GO'),(5212055,'Jesúpolis','GO'),(5212105,'Joviânia','GO'),(5212204,'Jussara','GO'),(5212253,'Lagoa Santa','GO'),(5212303,'Leopoldo de Bulhões','GO'),(5212501,'Luziânia','GO'),(5212600,'Mairipotaba','GO'),(5212709,'Mambaí','GO'),(5212808,'Mara Rosa','GO'),(5212907,'Marzagão','GO'),(5212956,'Matrinchã','GO'),(5213004,'Maurilândia','GO'),(5213053,'Mimoso de Goiás','GO'),(5213087,'Minaçu','GO'),(5213103,'Mineiros','GO'),(5213400,'Moiporá','GO'),(5213509,'Monte Alegre de Goiás','GO'),(5213707,'Montes Claros de Goiás','GO'),(5213756,'Montividiu','GO'),(5213772,'Montividiu do Norte','GO'),(5213806,'Morrinhos','GO'),(5213855,'Morro Agudo de Goiás','GO'),(5213905,'Mossâmedes','GO'),(5214002,'Mozarlândia','GO'),(5214051,'Mundo Novo','GO'),(5214101,'Mutunópolis','GO'),(5214408,'Nazário','GO'),(5214507,'Nerópolis','GO'),(5214606,'Niquelândia','GO'),(5214705,'Nova América','GO'),(5214804,'Nova Aurora','GO'),(5214838,'Nova Crixás','GO'),(5214861,'Nova Glória','GO'),(5214879,'Nova Iguaçu de Goiás','GO'),(5214903,'Nova Roma','GO'),(5215009,'Nova Veneza','GO'),(5215207,'Novo Brasil','GO'),(5215231,'Novo Gama','GO'),(5215256,'Novo Planalto','GO'),(5215306,'Orizona','GO'),(5215405,'Ouro Verde de Goiás','GO'),(5215504,'Ouvidor','GO'),(5215603,'Padre Bernardo','GO'),(5215652,'Palestina de Goiás','GO'),(5215702,'Palmeiras de Goiás','GO'),(5215801,'Palmelo','GO'),(5215900,'Palminópolis','GO'),
(5216007,'Panamá','GO'),(5216304,'Paranaiguara','GO'),(5216403,'Paraúna','GO'),(5216452,'Perolândia','GO'),(5216809,'Petrolina de Goiás','GO'),(5216908,'Pilar de Goiás','GO'),(5217104,'Piracanjuba','GO'),(5217203,'Piranhas','GO'),(5217302,'Pirenópolis','GO'),(5217401,'Pires do Rio','GO'),(5217609,'Planaltina','GO'),(5217708,'Pontalina','GO'),(5218003,'Porangatu','GO'),(5218052,'Porteirão','GO'),(5218102,'Portelândia','GO'),(5218300,'Posse','GO'),(5218391,'Professor Jamil','GO'),(5218508,'Quirinópolis','GO'),(5218607,'Rialma','GO'),(5218706,'Rianápolis','GO'),(5218789,'Rio Quente','GO'),(5218805,'Rio Verde','GO'),(5218904,'Rubiataba','GO'),(5219001,'Sanclerlândia','GO'),(5219100,'Santa Bárbara de Goiás','GO'),(5219209,'Santa Cruz de Goiás','GO'),(5219258,'Santa Fé de Goiás','GO'),(5219308,'Santa Helena de Goiás','GO'),(5219357,'Santa Isabel','GO'),(5219407,'Santa Rita do Araguaia','GO'),(5219456,'Santa Rita do Novo Destino','GO'),(5219506,'Santa Rosa de Goiás','GO'),(5219605,'Santa Tereza de Goiás','GO'),(5219704,'Santa Terezinha de Goiás','GO'),(5219712,'Santo Antônio da Barra','GO'),(5219738,'Santo Antônio de Goiás','GO'),(5219753,'Santo Antônio do Descoberto','GO'),(5219803,'São Domingos','GO'),(5219902,'São Francisco de Goiás','GO'),(5220009,'São João d''Aliança','GO'),(5220058,'São João da Paraúna','GO'),(5220108,'São Luís de Montes Belos','GO'),(5220157,'São Luiz do Norte','GO'),(5220207,'São Miguel do Araguaia','GO'),(5220264,'São Miguel do Passa Quatro','GO'),(5220280,'São Patrício','GO'),(5220405,'São Simão','GO'),(5220454,'Senador Canedo','GO'),(5220504,'Serranópolis','GO'),(5220603,'Silvânia','GO'),(5220686,'Simolândia','GO'),(5220702,'Sítio d''Abadia','GO'),(5221007,'Taquaral de Goiás','GO'),(5221080,'Teresina de Goiás','GO'),(5221197,'Terezópolis de Goiás','GO'),(5221304,'Três Ranchos','GO'),(5221403,'Trindade','GO'),(5221452,'Trombas','GO'),(5221502,'Turvânia','GO'),(5221551,'Turvelândia','GO'),(5221577,'Uirapuru','GO'),(5221601,'Uruaçu','GO'),(5221700,'Uruana','GO'),(5221809,'Urutaí','GO'),(5221858,'Valparaíso de Goiás','GO'),(5221908,'Varjão','GO'),(5222005,'Vianópolis','GO'),(5222054,'Vicentinópolis','GO'),(5222203,'Vila Boa','GO'),(5222302,'Vila Propício','GO'),(5300108,'Brasília','DF')
on conflict (codigo) do update set nome = excluded.nome, uf = excluded.uf;

-- Comarcas conhecidas (listas oficiais)
insert into public.comarcas (tribunal, nome, tipo, fonte) values
('TJSP','São Paulo - Foro Central Cível','foro','TJSP'),
('TJSP','São Paulo - Foro Central Criminal (Barra Funda)','foro','TJSP'),
('TJSP','São Paulo - Foro Central da Fazenda Pública','foro','TJSP'),
('TJSP','São Paulo - Foro Central do Juizado Especial Cível (Vergueiro)','foro','TJSP'),
('TJSP','São Paulo - Foro Central da Infância e Juventude','foro','TJSP'),
('TJSP','São Paulo - Foro das Execuções Fiscais','foro','TJSP'),
('TJSP','São Paulo - Foro Regional I - Santana','foro','TJSP'),
('TJSP','São Paulo - Foro Regional II - Santo Amaro','foro','TJSP'),
('TJSP','São Paulo - Foro Regional III - Jabaquara','foro','TJSP'),
('TJSP','São Paulo - Foro Regional IV - Lapa','foro','TJSP'),
('TJSP','São Paulo - Foro Regional V - São Miguel Paulista','foro','TJSP'),
('TJSP','São Paulo - Foro Regional VI - Penha de França','foro','TJSP'),
('TJSP','São Paulo - Foro Regional VII - Itaquera','foro','TJSP'),
('TJSP','São Paulo - Foro Regional VIII - Tatuapé','foro','TJSP'),
('TJSP','São Paulo - Foro Regional IX - Vila Prudente','foro','TJSP'),
('TJSP','São Paulo - Foro Regional X - Ipiranga','foro','TJSP'),
('TJSP','São Paulo - Foro Regional XI - Pinheiros','foro','TJSP'),
('TJSP','São Paulo - Foro Regional XII - Nossa Senhora do Ó','foro','TJSP'),
('TJSP','São Paulo - Foro Regional XV - Butantã','foro','TJSP'),
('TJBA','Alagoinhas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Amargosa','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Amélia Rodrigues','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Anagé','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Andaraí','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Antas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Araci','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Baianópolis','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Barra','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Barra da Estiva','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Barra do Choça','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Barra do Mendes','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Barreiras','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Belmonte','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Belo Campo','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Bom Jesus da Lapa','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Brumado','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Buerarema','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cachoeira','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Caculé','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Caetité','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Camacan','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Camaçari','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Camamu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Canarana','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Canavieiras','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Candeias','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cândido Sales','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cansanção','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Capela do Alto Alegre','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Capim Grosso','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Caravelas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Carinhanha','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Casa Nova','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Castro Alves','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Catu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Central','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Chorrochó','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cícero Dantas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cipó','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Coaraci','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cocos','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Conceição do Almeida','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Conceição do Coité','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Conceição do Jacuípe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Conde','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Condeúba','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Coração de Maria','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Coribe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Correntina','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cotegipe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Cruz das Almas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Curaçá','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Dias d''Ávila','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Encruzilhada','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Entre Rios','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Euclides da Cunha','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Eunápolis','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Feira de Santana','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Formosa do Rio Preto','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Gandu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Gentio do Ouro','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Governador Mangabeira','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Guanambi','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Guaratinga','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Iaçu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ibicaraí','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ibirataia','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ibotirama','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Igaporã','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Iguaí','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ilhéus','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Inhambupe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ipiaú','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ipirá','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Iraquara','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Irará','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Irecê','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itabela','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itaberaba','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itabuna','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itacaré','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itagibá','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itajuípe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itamaraju','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itambé','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itanhém','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itaparica','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itapetinga','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itapicuru','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Itarantim','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ituaçu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ituberá','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Jacaraci','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Jacobina','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Jaguaquara','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Jaguarari','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Jequié','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Jeremoabo','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Jitaúna','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','João Dourado','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Juazeiro','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Laje','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Lapão','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Lauro de Freitas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Lençóis','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Livramento de Nossa Senhora','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Luís Eduardo Magalhães','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Macarani','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Macaúbas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Mairi','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Maracás','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Maragojipe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Mata de São João','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Medeiros Neto','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Miguel Calmon','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Monte Santo','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Morro do Chapéu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Mucuri','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Mundo Novo','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Muritiba','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Mutuípe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Nazaré','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Nova Soure','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Nova Viçosa','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Olindina','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Oliveira dos Brejinhos','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Palmas de Monte Alto','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Paramirim','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Paripiranga','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Paulo Afonso','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Piatã','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Pilão Arcado','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Pindobaçu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Piritiba','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Planalto','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Poções','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Pojuca','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Porto Seguro','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Prado','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Queimadas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Retirolândia','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Riachão das Neves','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Riachão do Jacuípe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Riacho de Santana','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ribeira do Pombal','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Rio Real','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ruy Barbosa','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Salvador','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santa Bárbara','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santa Cruz Cabrália','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santa Inês','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santa Maria da Vitória','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santa Rita de Cássia','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santa Terezinha','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santaluz','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santana','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santo Amaro','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santo Antônio de Jesus','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Santo Estêvão','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','São Desidério','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','São Felipe','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','São Félix','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','São Francisco do Conde','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','São Gonçalo dos Campos','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','São Sebastião do Passé','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Sapeaçu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Saúde','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Seabra','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Senhor do Bonfim','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Sento Sé','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Serra Dourada','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Serrinha','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Simões Filho','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Sobradinho','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Tanhaçu','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Tanque Novo','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Taperoá','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Teixeira de Freitas','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Teofilândia','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Terra Nova','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Tremedal','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Tucano','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Uauá','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ubaíra','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ubaitaba','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Ubatã','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Urandi','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Uruçuca','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Utinga','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Valença','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Valente','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Vitória da Conquista','comarca','TJBA · Decreto Judiciário nº 09/2026'),
('TJBA','Wenceslau Guimarães','comarca','TJBA · Decreto Judiciário nº 09/2026')
on conflict (tribunal, nome) do nothing;

create table if not exists public.comarcas_sync (
  tribunal text primary key,
  em       timestamptz,
  total    int,
  erro     text
);
alter table public.comarcas_sync enable row level security;
grant all on public.comarcas_sync to service_role;

-- Catálogo pelo DataJud: todo dia 1º, entre 02:00 e 02:50 (Brasília); a primeira vez roda agora.
do $$
declare corpo text := $job$
  select net.http_post(
    url := 'https://humbhyghezmhwdtwcztr.supabase.co/functions/v1/datajud-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'orbeo_cron')),
    body := '{"acao":"rodada_comarcas"}'::jsonb, timeout_milliseconds := 150000);
$job$;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'orbeo-comarcas';
    perform cron.schedule('orbeo-comarcas', '*/10 5 1 * *', corpo);
    perform cron.unschedule(jobid) from cron.job where jobname = 'orbeo-comarcas-agora';
    -- primeira montagem: a cada 5 minutos na próxima hora (cada chamada faz alguns tribunais); depois se desliga sozinha
    perform cron.schedule('orbeo-comarcas-agora', '*/5 * * * *', corpo || format($x$ select cron.unschedule(jobid) from cron.job where jobname = 'orbeo-comarcas-agora' and ((select count(*) from public.comarcas_sync where erro is null) >= 57 or now() > %L::timestamptz); $x$, now() + interval '1 day'));
  end if;
end $$;
