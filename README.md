# Orbeo · gestão de processos, publicações e prazos

App para celular e computador. Banco e login no Supabase; site no GitHub Pages.
A pasta `marca/` tem o símbolo da Orbeo em vetor (SVG), nas versões clara, escura e ícone de app.

## 1. Supabase (uma vez)

1. Crie um projeto novo em supabase.com, região **South America (São Paulo)**.
2. **SQL Editor → New query**: cole todo o arquivo `supabase/01_schema.sql` e clique em **Run**.
3. **Authentication → Sign In / Providers → Email**: desligue **Allow new users to sign up**.
   Assim ninguém cria conta sozinho; só quem você cadastrar.
4. **Authentication → Users → Add user → Create new user**: crie **só o seu** login
   (e-mail e senha, marcando *Auto Confirm User*). Os demais você cria depois, pelo próprio sistema.
5. **Project Settings → API**: copie a **Project URL** e a chave **anon public**.

## 1.1 Tornar-se administrador (uma vez)

Depois de entrar no sistema pela primeira vez e preencher nome e OAB, rode no **SQL Editor**
(troque pelo seu e-mail):

    update public.advogados set admin = true where email = 'seu-email@exemplo.com';

A partir daí, o menu **Usuários** aparece para você.

## 1.2 Publicar a função de administração (criar/excluir usuários pelo sistema)

Criar e excluir logins exige uma chave secreta que nunca pode ir para o navegador. Por isso essa
parte roda numa função no servidor do Supabase:

1. Supabase → **Edge Functions → Deploy a new function → Via Editor**.
2. Nome da função: `admin-usuarios` (exatamente assim).
3. Apague o exemplo e cole todo o conteúdo de `supabase/functions/admin-usuarios/index.ts`.
4. Clique em **Deploy**. Não é preciso configurar chave: o Supabase já fornece as variáveis.

Pelo sistema, o administrador pode: criar usuário (gera senha provisória, e o advogado é obrigado a
criar a própria senha no primeiro acesso), gerar nova senha provisória, tornar/retirar administrador,
desativar/reativar o acesso e excluir. Por sigilo, só é possível excluir quem não tem processos ou
clientes exclusivos; nesse caso, desative o acesso.

## 1.3 Consulta ao DataJud (andamentos)

1. **Banco:** se você já tinha rodado o `01_schema.sql` antes, rode agora só
   `supabase/migracoes/01_fase2_datajud.sql`. (Projeto novo: o `01_schema.sql` já inclui tudo.)
2. **Função:** Edge Functions → Deploy a new function → Via Editor → nome `datajud-sync` →
   cole `supabase/functions/datajud-sync/index.ts` → Deploy. Depois, na função, desligue
   **Enforce JWT verification** e salve (a própria função confere quem chama).
3. **Agendamento diário:** no SQL Editor, rode `supabase/02_agendamentos.sql`.
   Ele liga a consulta automática de madrugada (03h–06h, em lotes, abaixo do limite do CNJ).

A chave pública do DataJud já vem no código. Se o CNJ trocar a chave, cadastre a nova em
Edge Functions → Secrets com o nome `DATAJUD_API_KEY` (a chave vigente fica na wiki do DataJud).

## 1.4 Audiências

Rode `supabase/migracoes/02_audiencias.sql` no SQL Editor (projeto novo: já está no `01_schema.sql`).
Se a função `datajud-sync` já estiver publicada, atualize o código dela com a versão nova
(ela passou a sugerir audiências quando o DataJud registra "audiência designada").

## 1.5 Prazos com cálculo automático

Rode `supabase/migracoes/03_prazos.sql` no SQL Editor (projeto novo: já está no `01_schema.sql`).
O prazo fatal é calculado pelo banco (dias úteis ou corridos, feriados, suspensões, art. 224 do CPC)
e recalculado sozinho quando uma suspensão é cadastrada, alterada ou excluída.

## 1.6 Ritos (Juizados e Trabalhista)

Rode `supabase/migracoes/04_ritos_juizados.sql` (depois da 03). Cada processo ganha um rito
(identificado automaticamente pela classe, vara e tribunal) que define os tipos de prazo:
Juizados (contestação até a audiência, recurso inominado 10 dias, preparo em 48h...),
Trabalhista (recurso ordinário 8 dias...) e Comum (CPC).

## 1.7 Modelo de contagem do sistema anterior

Rode `supabase/migracoes/05_modelo_anterior.sql` (depois da 04). Ela:
- inclui Carnaval (segunda e terça) e Corpus Christi como dias sem prazo, todo ano;
- cria a **instância** no processo e na suspensão (1º grau/Juizados x 2º grau/Turmas Recursais);
- impede data de elaboração depois do prazo fatal;
- recalcula os prazos abertos com essas regras.

## 1.8 DJEN (publicações pelo número do processo)

Rode `supabase/migracoes/06_djen.sql` (depois da 05) e publique de novo a função `datajud-sync`
(cole o `index.ts` novo por cima e clique em Deploy). O botão "Atualizar agora" passa a consultar
o DataJud e o DJEN. A busca é só pelo número de cada processo cadastrado: nenhuma OAB fica fixa.
A aba **Buscar processos** procura publicações pelo nome de uma parte (cliente ou não) para achar
processos que ainda não estão no Orbeo; cada resultado tem o botão "Cadastrar processo".

## 1.9 Notificações no celular

Rode `supabase/migracoes/07_notificacoes.sql` (depois da 06) e publique de novo a função `datajud-sync`.
As chaves de envio são geradas sozinhas pela função na primeira vez (nada para configurar).
Cada advogado ativa em **Ajustes → Notificações**, em cada aparelho. No iPhone: iOS 16.4 ou mais novo,
Orbeo salvo na Tela de Início pelo Safari e aberto pelo ícone. Os avisos automáticos dependem do
`02_agendamentos.sql` (agendamento `orbeo-avisos`, a cada 15 minutos das 6h às 22h45).

## 1.10 Mais de uma OAB por advogado

Rode `supabase/migracoes/08_varias_oabs.sql` (depois da 07). Cada advogado inclui as inscrições
suplementares em Ajustes → Meus dados e OAB; o administrador também pode incluir pela tela Usuários.

## 2. Configurar o app

Abra `src/config.js` e cole a URL e a chave anon nos lugares indicados.

## 3. GitHub Pages

1. Crie um repositório novo (ex.: `sistema-processos`) e envie **todos** os arquivos desta pasta,
   inclusive a pasta oculta `.github`.
2. No repositório: **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. Cada envio para a branch `main` publica o site sozinho (aba **Actions** mostra o andamento).
4. Volte ao Supabase em **Authentication → URL Configuration** e coloque o endereço do site
   (ex.: `https://SEU-USUARIO.github.io/sistema-processos/`) em **Site URL**.
   É para onde aponta o link de "Esqueci minha senha".

## 4. Primeiro acesso

Cada advogado entra com o e-mail e a senha criados no passo 1.4 e informa nome e OAB.
A OAB passa a ser monitorada no DJEN quando a busca automática for ligada (fase 2).

No celular, abra o site e use **Adicionar à tela inicial**: ele abre como aplicativo.

## Sigilo

Cada advogado só vê os processos em que está incluído. A regra está no banco (RLS),
não na tela: mesmo com acesso direto à API, o Supabase recusa o que não é do advogado.

## Para quem for mexer no código

    npm install
    npm run dev        # usa o Supabase de src/config.js
    npm run dev:mock   # dados fictícios, sem Supabase (login com qualquer e-mail;
                       # e-mail começando com "colega" entra como a colega)
