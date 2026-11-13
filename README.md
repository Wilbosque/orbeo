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
