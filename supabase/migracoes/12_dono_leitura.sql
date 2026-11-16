-- Migração: modo leitura do dono e exclusão de advogado autônomo. Rode uma vez no SQL Editor (depois da 11).

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
