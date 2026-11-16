-- Teste: dois escritórios (E1: W admin, C advogado, S estagiário; E2: X admin)
\set ON_ERROR_STOP on
insert into auth.users values
 ('11111111-1111-1111-1111-111111111111','w@x'), ('22222222-2222-2222-2222-222222222222','c@x'),
 ('33333333-3333-3333-3333-333333333333','s@x'), ('44444444-4444-4444-4444-444444444444','x@x');
insert into escritorios (id, nome) values ('00000000-0000-0000-0000-0000000000e2', 'Outro Escritório');
insert into advogados (id,nome,oab_numero,oab_uf,escritorio_id,papel) values
 ('11111111-1111-1111-1111-111111111111','Wilquer','11111','BA','00000000-0000-0000-0000-0000000000e1','admin'),
 ('22222222-2222-2222-2222-222222222222','Colega','22222','BA','00000000-0000-0000-0000-0000000000e1','advogado'),
 ('33333333-3333-3333-3333-333333333333','Estagiária','33333E','BA','00000000-0000-0000-0000-0000000000e1','estagiario'),
 ('44444444-4444-4444-4444-444444444444','Xavier','44444','BA','00000000-0000-0000-0000-0000000000e2','admin');
insert into plataforma_donos values ('11111111-1111-1111-1111-111111111111');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into clientes (id,tipo,nome) values ('aaaaaaaa-0000-0000-0000-000000000001','PJ','Marques Turismo');
insert into processos (id,numero_cnj,cliente_id,polo,tribunal,comarca) values
 ('bbbbbbbb-0000-0000-0000-000000000001','0000001-11.2026.8.05.0001','aaaaaaaa-0000-0000-0000-000000000001','reu','TJBA','Salvador');
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into clientes (id,tipo,nome) values ('aaaaaaaa-0000-0000-0000-000000000002','PF','Cliente da colega');
insert into processos (id,numero_cnj,cliente_id,polo,tribunal,comarca) values
 ('bbbbbbbb-0000-0000-0000-000000000002','0000002-11.2026.8.05.0001','aaaaaaaa-0000-0000-0000-000000000002','autor','TJBA','Salvador');
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
insert into clientes (id,tipo,nome) values ('aaaaaaaa-0000-0000-0000-000000000009','PJ','Cliente do outro');
\echo '--- E2 cadastra o MESMO número que E1 já tem (permitido: escritórios diferentes):'
insert into processos (id,numero_cnj,cliente_id,polo,tribunal,comarca) values
 ('bbbbbbbb-0000-0000-0000-000000000009','0000001-11.2026.8.05.0001','aaaaaaaa-0000-0000-0000-000000000009','autor','TJBA','Salvador');
\echo '--- X (E2) vê só o próprio:'
select numero_cnj, cliente_id from processos; select nome from clientes; select nome from advogados order by 1;

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\echo '--- W (admin, sem visão geral) vê só os dele:'
select numero_cnj from processos order by 1; select nome from advogados order by 1;
\set ON_ERROR_STOP off
\echo '--- W tenta incluir Xavier (outro escritório) no processo: ERRO'
insert into processo_advogados values ('bbbbbbbb-0000-0000-0000-000000000001','44444444-4444-4444-4444-444444444444');
\set ON_ERROR_STOP on
\echo '--- W liga a visão geral da Colega e designa prazo à Estagiária'
update advogados set visao_geral = true where id = '22222222-2222-2222-2222-222222222222';
insert into prazos (id, processo_id, tipo, data_recebimento, dias, contagem, responsavel_id) values
 ('cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','Réplica','2026-11-13',15,'uteis','33333333-3333-3333-3333-333333333333');
\set ON_ERROR_STOP off
\echo '--- responsável de outro escritório: ERRO'
insert into prazos (processo_id, tipo, data_recebimento, dias, contagem, responsavel_id) values
 ('bbbbbbbb-0000-0000-0000-000000000001','Manifestação','2026-11-13',5,'uteis','44444444-4444-4444-4444-444444444444');
\set ON_ERROR_STOP on

set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\echo '--- Colega com visão geral vê os 2 processos do E1 (e não o do E2):'
select numero_cnj, escritorio_id = '00000000-0000-0000-0000-0000000000e1' as e1 from processos order by 1;
\set ON_ERROR_STOP off
\echo '--- Colega tenta mudar o próprio papel: ERRO'
update advogados set papel = 'admin' where id = auth.uid();
\set ON_ERROR_STOP on

set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
\echo '--- Estagiária vê só o processo do prazo designado e o cliente dele:'
select numero_cnj from processos; select nome from clientes; select tipo, responsavel_nome from vw_prazos;
\set ON_ERROR_STOP off
\echo '--- Estagiária tenta cadastrar prazo: ERRO'
insert into prazos (processo_id, tipo, data_recebimento, dias, contagem) values ('bbbbbbbb-0000-0000-0000-000000000001','X','2026-11-13',5,'uteis');
\echo '--- Estagiária tenta editar o prazo direto: 0 linhas'
update prazos set dias = 10 where id = 'cccccccc-0000-0000-0000-000000000001';
\echo '--- Estagiária tenta cadastrar cliente: ERRO'
insert into clientes (tipo,nome) values ('PF','Teste');
\set ON_ERROR_STOP on
\echo '--- Estagiária dá cumprimento com observação:'
select cumprir_prazo('cccccccc-0000-0000-0000-000000000001', '2026-11-20', 'Protocolado no PJe. Aguardar intimação da parte autora.');
select acao, texto, autor_nome from vw_prazo_historico order by em;
select status, cumprido_por_nome, cumprimento_obs from vw_prazos;

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\echo '--- W cadastra suspensão de comarca (Salvador, só 1º grau) → vira sugestão para E2'
insert into suspensoes (abrangencia, tribunal, comarca, instancia, data_inicio, data_fim, tipo, motivo)
 values ('comarca','TJBA','Salvador','1g','2026-11-25','2026-11-25','feriado','Feriado municipal teste');
select count(*) as minhas_suspensoes_manuais from suspensoes where fonte <> 'regra';
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
\echo '--- X (E2) não vê a suspensão do E1, mas recebe a sugestão:'
select count(*) as suspensoes_manuais_visiveis from suspensoes where fonte <> 'regra';
select dados->>'motivo' motivo, dados->>'comarca' comarca, justificativa from sugestoes where tipo='suspensao';
\echo '--- X confirma a sugestão → passa a valer para o E2'
select confirmar_sugestao_suspensao((select id from sugestoes where tipo='suspensao')) is not null as criou;
select motivo, fonte from suspensoes where fonte <> 'regra';
\echo '--- Cálculo: mesmo número, E1 x E2 (ambos com a suspensão de 25/11 agora)'
insert into prazos (processo_id, tipo, data_recebimento, dias, contagem) values ('bbbbbbbb-0000-0000-0000-000000000009','Réplica','2026-11-13',15,'uteis');
select prazo_fatal from prazos;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\echo '--- listar escritórios (dono da plataforma):'
select nome, usuarios, processos from listar_escritorios();
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as nao_dono_ve from listar_escritorios();
