-- Migração: espaço autônomo, vários escritórios por advogado, saída com sucessor. Rode uma vez no SQL Editor (depois da 10).

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
