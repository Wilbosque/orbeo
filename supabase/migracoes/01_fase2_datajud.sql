-- Migração para quem JÁ rodou o 01_schema.sql antes de 13/11/2026 (fase 1).
-- Rode este arquivo uma vez no SQL Editor.

-- =====================================================================
-- FASE 2.1 · DATAJUD
-- A rotina "datajud-sync" (Edge Function) grava os andamentos.
-- O agendamento diário fica em 02_agendamentos.sql.
-- =====================================================================

-- Confere o segredo do agendamento guardado no Vault do Supabase.
-- Só a função no servidor (service_role) pode chamar.
create or replace function public.cron_segredo_confere(p text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare s text;
begin
  select decrypted_secret into s from vault.decrypted_secrets where name = 'orbeo_cron' limit 1;
  return s is not null and p is not null and s = p;
end $$;
revoke all on function public.cron_segredo_confere(text) from public, anon, authenticated;
grant execute on function public.cron_segredo_confere(text) to service_role;

-- Marcar andamentos como vistos ao abrir a linha do tempo
create or replace function public.marcar_movimentacoes_vistas(p_processo uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.pode_ver_processo(p_processo) then return 0; end if;
  update movimentacoes set vista_em = now() where processo_id = p_processo and vista_em is null;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.marcar_movimentacoes_vistas(uuid) to authenticated;

create index if not exists processos_sync_idx on public.processos (situacao, datajud_sync_em nulls first);
