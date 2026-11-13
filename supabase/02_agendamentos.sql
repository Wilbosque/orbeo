-- =====================================================================
-- ORBEO · AGENDAMENTOS (rodar no SQL Editor DEPOIS de publicar a função datajud-sync)
-- Consulta diária ao DataJud de madrugada, em lotes, respeitando o limite do CNJ.
-- Pode rodar de novo sem problema: ele substitui o agendamento anterior.
-- =====================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- Segredo que só o agendamento e a função conhecem (gerado aqui, guardado no Vault)
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'orbeo_cron') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'orbeo_cron',
                                'Segredo do agendamento Orbeo');
  end if;
end $$;

-- Remove agendamento anterior com o mesmo nome, se houver
select cron.unschedule(jobid) from cron.job where jobname = 'orbeo-datajud-diario';

-- A cada 10 minutos entre 03:00 e 05:50 (Brasília) = 06:00–08:50 UTC.
-- Cada chamada processa um lote; processos já consultados hoje são pulados.
select cron.schedule(
  'orbeo-datajud-diario',
  '*/10 6-8 * * *',
  $job$
  select net.http_post(
    url := 'https://humbhyghezmhwdtwcztr.supabase.co/functions/v1/datajud-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'orbeo_cron')
    ),
    body := '{"acao":"rodada"}'::jsonb,
    timeout_milliseconds := 150000
  );
  $job$
);

-- Conferência: deve listar o agendamento
select jobname, schedule, active from cron.job where jobname like 'orbeo-%';
