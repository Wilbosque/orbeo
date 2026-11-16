-- Migração: DJEN pelo número do processo. Rode uma vez no SQL Editor (depois da 05).

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
