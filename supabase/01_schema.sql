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
