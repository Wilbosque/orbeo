-- Migração: vários escritórios, papéis e histórico de prazos. Rode uma vez no SQL Editor (depois da 09).

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
