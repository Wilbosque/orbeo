-- Migração: ritos (Juizados, Trabalhista) e prazos especiais. Rode uma vez no SQL Editor (depois da 03_prazos.sql).

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
