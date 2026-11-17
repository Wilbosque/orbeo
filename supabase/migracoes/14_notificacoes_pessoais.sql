-- =====================================================================
-- ORBEO · 14 · Notificações pessoais
--  • Cada usuário (inclusive estagiário) escolhe o que quer receber e em que horário
--  • Toda notificação fica registrada no Orbeo (sino), mesmo que o celular não receba
--  • Mostra se o aviso chegou a algum aparelho, para descobrir por que não chegou
-- Pode rodar de novo sem problema.
-- =====================================================================

create table if not exists public.notif_preferencias (
  advogado_id      uuid primary key default auth.uid() references public.advogados(id) on delete cascade,
  prazos           boolean  not null default true,
  prazos_hora      smallint not null default 7  check (prazos_hora between 5 and 12),
  prazos_dias      smallint not null default 1  check (prazos_dias between 0 and 5),   -- 0 = só hoje; 1 = hoje e amanhã...
  prazos_elaborar  boolean  not null default true,                                    -- prazos marcados para elaborar hoje
  audiencias       boolean  not null default true,
  aud_vespera_hora smallint          default 18 check (aud_vespera_hora is null or aud_vespera_hora between 12 and 22),
  aud_horas_antes  smallint not null default 2  check (aud_horas_antes between 0 and 24),  -- 0 = não avisar
  publicacoes      boolean  not null default true,
  novos            boolean  not null default true,
  sugestoes        boolean  not null default true,
  sugestoes_hora   smallint not null default 8  check (sugestoes_hora between 6 and 20),
  escopo           text     not null default 'meus' check (escopo in ('meus','escritorio')),
  atualizado_em    timestamptz not null default now()
);
alter table public.notif_preferencias enable row level security;
drop policy if exists np_ler on public.notif_preferencias;
drop policy if exists np_criar on public.notif_preferencias;
drop policy if exists np_editar on public.notif_preferencias;
create policy np_ler    on public.notif_preferencias for select to authenticated using (advogado_id = auth.uid());
create policy np_criar  on public.notif_preferencias for insert to authenticated with check (advogado_id = auth.uid());
create policy np_editar on public.notif_preferencias for update to authenticated using (advogado_id = auth.uid()) with check (advogado_id = auth.uid());
grant select, insert, update on public.notif_preferencias to authenticated;
grant all on public.notif_preferencias to service_role;

-- Caixa de notificações (o sino do app)
create table if not exists public.notificacoes (
  id             uuid primary key default gen_random_uuid(),
  advogado_id    uuid not null references public.advogados(id) on delete cascade,
  tipo           text not null,             -- prazos, audiencia, publicacao, novos, sugestoes, teste
  titulo         text not null,
  texto          text,
  url            text,
  chave          text not null,
  criado_em      timestamptz not null default now(),
  lida_em        timestamptz,
  push_aparelhos int not null default 0,    -- em quantos aparelhos o aviso chegou
  push_motivo    text,                      -- por que não chegou (sem aparelho, falha...)
  unique (advogado_id, chave)
);
create index if not exists notificacoes_adv_data on public.notificacoes (advogado_id, criado_em desc);
alter table public.notificacoes enable row level security;
drop policy if exists notif_ler on public.notificacoes;
create policy notif_ler on public.notificacoes for select to authenticated using (advogado_id = auth.uid());
grant select on public.notificacoes to authenticated;
grant all on public.notificacoes to service_role;

create or replace function public.marcar_notificacoes_lidas(p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update notificacoes set lida_em = now()
   where advogado_id = auth.uid() and lida_em is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.marcar_notificacoes_lidas(uuid[]) to authenticated;

-- Aparelhos: o próprio usuário vê falhas e último envio
alter table public.push_inscricoes add column if not exists falhas int not null default 0;

-- Limpeza: notificações com mais de 90 dias (todo dia às 03:40 de Brasília)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'orbeo-limpa-notificacoes';
    perform cron.schedule('orbeo-limpa-notificacoes', '40 6 * * *',
      $q$delete from public.notificacoes where criado_em < now() - interval '90 days'; delete from public.push_enviados where enviado_em < now() - interval '90 days'$q$);
  end if;
end $$;

-- Processos novos ainda pendentes dos últimos 30 dias entram no sino de quem foi avisado
insert into public.notificacoes (advogado_id, tipo, titulo, texto, url, chave, criado_em, push_motivo)
select av.advogado_id, 'novos',
       'Processo novo · ' || coalesce(c.nome_fantasia, c.nome),
       d.numero_cnj || coalesce(' · ' || d.tribunal, '') || '. Toque para ver e decidir se cadastra.',
       '#/novos?id=' || d.id, 'novos:' || av.id, av.notificado_em,
       'Registrado na atualização do Orbeo (antes do sino existir).'
  from public.descoberta_avisos av
  join public.descobertas d on d.id = av.descoberta_id
  join public.clientes c on c.id = d.cliente_id
 where av.status = 'pendente' and av.notificado_em > now() - interval '30 days'
on conflict (advogado_id, chave) do nothing;
