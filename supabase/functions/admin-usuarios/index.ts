// Orbeo · Função de administração de usuários (Supabase Edge Function)
// Só responde a quem está logado E é administrador ativo. A chave de serviço
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
  const { data: eu } = await servico.from('advogados').select('id, admin, ativo').eq('id', user.id).maybeSingle()
  if (!eu?.admin || !eu?.ativo) return falha('Apenas o administrador pode fazer isso.', 403)

  let corpo: Record<string, any>
  try { corpo = await req.json() } catch { return falha('Pedido inválido.') }
  const { acao } = corpo

  try {
    // ---------- Listar ----------
    if (acao === 'listar') {
      const { data: lista, error } = await servico.auth.admin.listUsers({ perPage: 1000 })
      if (error) throw error
      const { data: perfis } = await servico.from('advogados').select('*')
      const usuarios = lista.users.map(u => {
        const p = perfis?.find(x => x.id === u.id)
        return {
          id: u.id, email: u.email, criado_em: u.created_at, ultimo_acesso: u.last_sign_in_at,
          nome: p?.nome ?? null, oab_numero: p?.oab_numero ?? null, oab_uf: p?.oab_uf ?? null,
          admin: p?.admin ?? false, ativo: p ? p.ativo : true, trocar_senha: p?.trocar_senha ?? false,
          sem_perfil: !p,
        }
      }).sort((a, b) => (a.nome || a.email || '').localeCompare(b.nome || b.email || ''))
      return resposta({ usuarios })
    }

    // ---------- Criar ----------
    if (acao === 'criar') {
      const email = String(corpo.email || '').trim().toLowerCase()
      const nome = String(corpo.nome || '').trim()
      const oab = String(corpo.oab_numero || '').replace(/\D/g, '')
      const uf = String(corpo.oab_uf || '').toUpperCase()
      if (!email || !nome || !oab || uf.length !== 2) return falha('Preencha e-mail, nome, OAB e UF.')
      const senha = senhaTemporaria()
      const { data: criado, error } = await servico.auth.admin.createUser({ email, password: senha, email_confirm: true })
      if (error) return falha(/already/i.test(error.message) ? 'Já existe um usuário com este e-mail.' : error.message)
      const { error: errPerfil } = await servico.from('advogados').insert({
        id: criado.user.id, nome, oab_numero: oab, oab_uf: uf, email, admin: Boolean(corpo.admin), ativo: true, trocar_senha: true,
      })
      if (errPerfil) {
        await servico.auth.admin.deleteUser(criado.user.id)
        return falha(/oab/.test(errPerfil.message) ? 'Já existe um advogado com esta OAB.' : errPerfil.message)
      }
      await servico.from('monitoramentos').insert({ advogado_id: criado.user.id, tipo: 'oab', valor: oab, uf })
      return resposta({ id: criado.user.id, senha_temporaria: senha })
    }

    const alvo = String(corpo.id || '')
    if (!alvo) return falha('Usuário não informado.')
    const contarAdmins = async () => (await servico.from('advogados').select('id', { count: 'exact', head: true }).eq('admin', true).eq('ativo', true)).count || 0
    const { data: perfilAlvo } = await servico.from('advogados').select('*').eq('id', alvo).maybeSingle()

    // ---------- Desativar / reativar ----------
    if (acao === 'desativar' || acao === 'reativar') {
      if (alvo === user.id) return falha('Você não pode desativar o seu próprio acesso.')
      if (acao === 'desativar' && perfilAlvo?.admin && await contarAdmins() <= 1) return falha('É preciso manter pelo menos um administrador ativo.')
      const { error } = await servico.auth.admin.updateUserById(alvo, { ban_duration: acao === 'desativar' ? '876000h' : 'none' })
      if (error) throw error
      if (perfilAlvo) await servico.from('advogados').update({ ativo: acao === 'reativar' }).eq('id', alvo)
      return resposta({ ok: true })
    }

    // ---------- Tornar / retirar admin ----------
    if (acao === 'admin') {
      if (!perfilAlvo) return falha('Este usuário ainda não concluiu o cadastro.')
      if (!corpo.admin && perfilAlvo.admin && await contarAdmins() <= 1) return falha('É preciso manter pelo menos um administrador ativo.')
      await servico.from('advogados').update({ admin: Boolean(corpo.admin) }).eq('id', alvo)
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
      if (perfilAlvo?.admin && await contarAdmins() <= 1) return falha('É preciso manter pelo menos um administrador ativo.')
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
