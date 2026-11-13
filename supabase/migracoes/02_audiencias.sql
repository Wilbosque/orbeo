-- Migração: audiências. Rode uma vez no SQL Editor (depois da 01_fase2_datajud.sql).

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
