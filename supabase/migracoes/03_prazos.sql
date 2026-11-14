-- Migração: cálculo automático de prazos. Rode uma vez no SQL Editor (depois da 02_audiencias.sql).

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
