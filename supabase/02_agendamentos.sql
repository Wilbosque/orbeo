-- =====================================================================
-- ORBEO · AGENDAMENTOS (rodar no SQL Editor DEPOIS de publicar a função datajud-sync)
-- Consulta diária ao DataJud (madrugada) e ao DJEN (início da manhã), em lotes, respeitando os limites do CNJ.
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

-- DJEN: a cada 10 minutos entre 06:05 e 07:55 (Brasília) = 09:05–10:55 UTC.
-- Busca as publicações pelo número de cada processo, 19 consultas por minuto (limite: 20).
-- x-region = sa-east-1: a função roda em São Paulo, porque o DJEN só aceita conexões do Brasil.
select cron.unschedule(jobid) from cron.job where jobname = 'orbeo-djen-diario';
select cron.schedule(
  'orbeo-djen-diario',
  '5-55/10 9-10 * * *',
  $job$
  select net.http_post(
    url := 'https://humbhyghezmhwdtwcztr.supabase.co/functions/v1/datajud-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-region', 'sa-east-1',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'orbeo_cron')
    ),
    body := '{"acao":"rodada_djen"}'::jsonb,
    timeout_milliseconds := 150000
  );
  $job$
);

-- Notificações no celular: a cada 15 minutos entre 06:00 e 22:45 (Brasília) = 09:00–01:45 UTC.
-- Cada aviso é enviado uma vez só (prazos às 7h, audiência na véspera e 2h antes, publicações novas, sugestões às 8h).
select cron.unschedule(jobid) from cron.job where jobname = 'orbeo-avisos';
select cron.schedule(
  'orbeo-avisos',
  '*/15 0-1,9-23 * * *',
  $job$
  select net.http_post(
    url := 'https://humbhyghezmhwdtwcztr.supabase.co/functions/v1/datajud-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'orbeo_cron')
    ),
    body := '{"acao":"rodada_avisos"}'::jsonb,
    timeout_milliseconds := 60000
  );
  $job$
);

-- Conferência: deve listar os três agendamentos
select jobname, schedule, active from cron.job where jobname like 'orbeo-%';
