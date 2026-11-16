-- Migração: descoberta diária de processos novos. Rode uma vez no SQL Editor (depois da 08).

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
