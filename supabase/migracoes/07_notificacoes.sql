-- Migração: notificações no celular. Rode uma vez no SQL Editor (depois da 06).

-- =====================================================================
-- FASE 2.7 · NOTIFICAÇÕES NO CELULAR (web push)
--  • Cada advogado ativa no(s) próprio(s) aparelho(s)
--  • As chaves de envio (VAPID) são geradas pela própria função, na 1ª vez, e ficam só no servidor
--  • Cada aviso é enviado uma vez só (tabela de controle)
-- =====================================================================
create table public.push_inscricoes (
  id           uuid primary key default gen_random_uuid(),
  advogado_id  uuid not null default auth.uid() references public.advogados(id) on delete cascade,
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  aparelho     text,
  criado_em    timestamptz not null default now(),
  ultimo_envio timestamptz,
  falhas       int not null default 0
);
alter table public.push_inscricoes enable row level security;
create policy push_ler on public.push_inscricoes for select to authenticated using (advogado_id = auth.uid());
create policy push_criar on public.push_inscricoes for insert to authenticated with check (advogado_id = auth.uid());
create policy push_editar on public.push_inscricoes for update to authenticated using (advogado_id = auth.uid()) with check (advogado_id = auth.uid());
create policy push_apagar on public.push_inscricoes for delete to authenticated using (advogado_id = auth.uid());

-- Chaves VAPID: sem nenhuma política = ninguém lê pelo app; só a função (chave de serviço)
create table public.push_chaves (
  id          int primary key default 1 check (id = 1),
  publica     text not null,
  privada_jwk jsonb not null,
  criado_em   timestamptz not null default now()
);
alter table public.push_chaves enable row level security;

-- Controle: cada aviso (chave) vai uma vez para cada advogado
create table public.push_enviados (
  advogado_id uuid not null references public.advogados(id) on delete cascade,
  chave       text not null,
  enviado_em  timestamptz not null default now(),
  primary key (advogado_id, chave)
);
alter table public.push_enviados enable row level security;

insert into public.configuracoes (chave, valor, descricao) values
  ('push_hora_prazos', '7', 'Hora (Brasília) do resumo de prazos que vencem hoje e amanhã.'),
  ('push_hora_vespera_audiencia', '18', 'Hora (Brasília) do aviso de audiência na véspera.'),
  ('push_horas_antes_audiencia', '2', 'Quantas horas antes da audiência vai o segundo aviso.'),
  ('push_hora_sugestoes', '8', 'Hora (Brasília) do aviso de sugestões pendentes.')
on conflict (chave) do nothing;
