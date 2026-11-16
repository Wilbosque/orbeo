-- Migração: mais de uma OAB por advogado. Rode uma vez no SQL Editor (depois da 07).

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
