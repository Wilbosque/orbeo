// Orbeo · Função de administração de usuários e escritórios (Supabase Edge Function)
// Usuários: só o sócio administrador (papel "admin") do próprio escritório.
// Escritórios: só o dono da plataforma (tabela plataforma_donos). A chave de serviço
// fica no servidor do Supabase (variável SUPABASE_SERVICE_ROLE_KEY) e nunca vai para o navegador.
import { createClient } from 'npm:@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const resposta = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })
const falha = (mensagem: string, status = 400) => resposta({ erro: mensagem }, status)

function senhaTemporaria() {
  const alfabeto = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
  const bytes = crypto.getRandomValues(new Uint8Array(12))
  return Array.from(bytes, b => alfabeto[b % alfabeto.length]).join('')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return falha('Método não permitido.', 405)

  const url = Deno.env.get('SUPABASE_URL')!
  const servico = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

  // 1. Quem está chamando?
  const token = (req.headers.get('Authorization') || '').replace('Bearer ', '')
  const { data: { user }, error: errUser } = await servico.auth.getUser(token)
  if (errUser || !user) return falha('Sessão inválida. Entre de novo.', 401)
  const { data: eu } = await servico.from('advogados').select('id, papel, ativo, escritorio_id').eq('id', user.id).maybeSingle()
  const { data: dono } = await servico.from('plataforma_donos').select('usuario_id').eq('usuario_id', user.id).maybeSingle()

  let corpo: Record<string, any>
  try { corpo = await req.json() } catch { return falha('Pedido inválido.') }
  const { acao } = corpo

  // Cria o login e o perfil (usado para usuário novo e para o sócio de um escritório novo)
  async function criarUsuario(d: { email: string; nome: string; oab: string; uf: string; papel: string; visao_geral: boolean; escritorio_id: string }) {
    const senha = senhaTemporaria()
    const { data: criado, error } = await servico.auth.admin.createUser({ email: d.email, password: senha, email_confirm: true })
    if (error) throw new Error(/already/i.test(error.message) ? 'Já existe um usuário com este e-mail.' : error.message)
    const { error: errPerfil } = await servico.from('advogados').insert({
      id: criado.user.id, nome: d.nome, oab_numero: d.oab, oab_uf: d.uf, email: d.email, papel: d.papel, admin: d.papel === 'admin',
      visao_geral: d.visao_geral, escritorio_id: d.escritorio_id, ativo: true, trocar_senha: true,
    })
    if (errPerfil) {
      await servico.auth.admin.deleteUser(criado.user.id)
      throw new Error(/oab/i.test(errPerfil.message) ? 'Já existe um advogado com esta OAB.' : errPerfil.message)
    }
    return { id: criado.user.id, senha_temporaria: senha }
  }
  const papelValido = (p: unknown) => ['admin', 'advogado', 'estagiario'].includes(String(p))

  try {
    // ================= Escritórios (dono da plataforma) =================
    if (acao === 'escritorio_criar' || acao === 'escritorio_ativar') {
      if (!dono) return falha('Apenas o dono da plataforma pode fazer isso.', 403)
      if (acao === 'escritorio_criar') {
        const nome = String(corpo.nome || '').trim()
        const email = String(corpo.admin_email || '').trim().toLowerCase()
        const nomeAdm = String(corpo.admin_nome || '').trim()
        const oab = String(corpo.admin_oab_numero || '').replace(/[^0-9A-Za-z]/g, '').toUpperCase()
        const uf = String(corpo.admin_oab_uf || '').toUpperCase()
        if (!nome || !email || !nomeAdm || !oab || uf.length !== 2) return falha('Preencha o nome do escritório e os dados do sócio administrador.')
        const { data: esc, error } = await servico.from('escritorios').insert({ nome }).select('id').single()
        if (error) throw error
        try {
          const r = await criarUsuario({ email, nome: nomeAdm, oab, uf, papel: 'admin', visao_geral: true, escritorio_id: esc.id })
          return resposta({ escritorio_id: esc.id, ...r })
        } catch (e) { await servico.from('escritorios').delete().eq('id', esc.id); return falha((e as Error).message) }
      }
      const escId = String(corpo.escritorio_id || '')
      const ativo = Boolean(corpo.ativo)
      if (!ativo && escId === eu?.escritorio_id) return falha('Você não pode desativar o seu próprio escritório.')
      await servico.from('escritorios').update({ ativo }).eq('id', escId)
      const { data: membros } = await servico.from('advogados').select('id').eq('escritorio_id', escId)
      for (const m of membros || []) {
        await servico.auth.admin.updateUserById(m.id, { ban_duration: ativo ? 'none' : '876000h' })
        await servico.from('advogados').update({ ativo }).eq('id', m.id)
      }
      return resposta({ ok: true })
    }

    // ================= Usuários (sócio administrador do escritório) =================
    if (eu?.papel !== 'admin' || !eu?.ativo) return falha('Apenas o sócio administrador pode fazer isso.', 403)
    const meuEsc = eu.escritorio_id

    // ---------- Listar ----------
    if (acao === 'listar') {
      const { data: lista, error } = await servico.auth.admin.listUsers({ perPage: 1000 })
      if (error) throw error
      const { data: perfis } = await servico.from('advogados').select('*').eq('escritorio_id', meuEsc)
      const usuarios = lista.users.filter(u => perfis?.some(x => x.id === u.id)).map(u => {
        const p = perfis?.find(x => x.id === u.id)
        return {
          id: u.id, email: u.email, criado_em: u.created_at, ultimo_acesso: u.last_sign_in_at,
          nome: p?.nome ?? null, oab_numero: p?.oab_numero ?? null, oab_uf: p?.oab_uf ?? null,
          admin: p?.admin ?? false, papel: p?.papel ?? 'advogado', visao_geral: p?.visao_geral ?? false,
          ativo: p ? p.ativo : true, trocar_senha: p?.trocar_senha ?? false,
          sem_perfil: !p,
        }
      }).sort((a, b) => (a.nome || a.email || '').localeCompare(b.nome || b.email || ''))
      return resposta({ usuarios })
    }

    // ---------- Criar ----------
    if (acao === 'criar') {
      const email = String(corpo.email || '').trim().toLowerCase()
      const nome = String(corpo.nome || '').trim()
      const oab = String(corpo.oab_numero || '').replace(/[^0-9A-Za-z]/g, '').toUpperCase()
      const uf = String(corpo.oab_uf || '').toUpperCase()
      const papel = papelValido(corpo.papel) ? String(corpo.papel) : (corpo.admin ? 'admin' : 'advogado')
      if (!email || !nome || !oab || uf.length !== 2) return falha('Preencha e-mail, nome, OAB e UF.')
      try { return resposta(await criarUsuario({ email, nome, oab, uf, papel, visao_geral: Boolean(corpo.visao_geral), escritorio_id: meuEsc })) }
      catch (e) { return falha((e as Error).message) }
    }

    const alvo = String(corpo.id || '')
    if (!alvo) return falha('Usuário não informado.')
    const contarAdmins = async () => (await servico.from('advogados').select('id', { count: 'exact', head: true })
      .eq('escritorio_id', meuEsc).eq('papel', 'admin').eq('ativo', true)).count || 0
    const { data: perfilAlvo } = await servico.from('advogados').select('*').eq('id', alvo).maybeSingle()
    if (!perfilAlvo || perfilAlvo.escritorio_id !== meuEsc) return falha('Usuário não encontrado neste escritório.', 404)

    // ---------- Desativar / reativar ----------
    if (acao === 'desativar' || acao === 'reativar') {
      if (alvo === user.id) return falha('Você não pode desativar o seu próprio acesso.')
      if (acao === 'desativar' && perfilAlvo.papel === 'admin' && await contarAdmins() <= 1) return falha('É preciso manter pelo menos um sócio administrador ativo.')
      const { error } = await servico.auth.admin.updateUserById(alvo, { ban_duration: acao === 'desativar' ? '876000h' : 'none' })
      if (error) throw error
      if (perfilAlvo) await servico.from('advogados').update({ ativo: acao === 'reativar' }).eq('id', alvo)
      return resposta({ ok: true })
    }

    // ---------- Papel (admin, advogado, estagiário) e visão geral ----------
    if (acao === 'papel' || acao === 'admin') {
      const papel = acao === 'admin' ? (corpo.admin ? 'admin' : 'advogado') : String(corpo.papel)
      if (!papelValido(papel)) return falha('Papel inválido.')
      if (perfilAlvo.papel === 'admin' && papel !== 'admin' && await contarAdmins() <= 1) return falha('É preciso manter pelo menos um sócio administrador ativo.')
      await servico.from('advogados').update({ papel, admin: papel === 'admin' }).eq('id', alvo)
      return resposta({ ok: true })
    }
    if (acao === 'visao') {
      await servico.from('advogados').update({ visao_geral: Boolean(corpo.visao_geral) }).eq('id', alvo)
      return resposta({ ok: true })
    }

    // ---------- Redefinir senha ----------
    if (acao === 'redefinir_senha') {
      const senha = senhaTemporaria()
      const { error } = await servico.auth.admin.updateUserById(alvo, { password: senha })
      if (error) throw error
      if (perfilAlvo) await servico.from('advogados').update({ trocar_senha: true }).eq('id', alvo)
      return resposta({ senha_temporaria: senha })
    }

    // ---------- Excluir ----------
    if (acao === 'excluir') {
      if (alvo === user.id) return falha('Você não pode excluir o seu próprio usuário.')
      if (perfilAlvo.papel === 'admin' && await contarAdmins() <= 1) return falha('É preciso manter pelo menos um sócio administrador ativo.')
      const { data: ex } = await servico.rpc('exclusivos_do_advogado', { p: alvo })
      const { processos = 0, clientes = 0 } = (ex && ex[0]) || {}
      if (processos > 0 || clientes > 0) {
        return falha(`Não é possível excluir: há ${processos} processo(s) e ${clientes} cliente(s) que só este advogado enxerga. ` +
          'Por sigilo, o sistema não transfere esses dados. Desative o acesso ou peça para ele incluir outro advogado antes.', 409)
      }
      const { error } = await servico.auth.admin.deleteUser(alvo)
      if (error) throw error
      return resposta({ ok: true })
    }

    return falha('Ação desconhecida.')
  } catch (e) {
    return falha((e as Error).message || 'Erro inesperado.', 500)
  }
})
