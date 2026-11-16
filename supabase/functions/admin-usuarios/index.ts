// Orbeo · Administração de usuários, escritórios e espaços (Supabase Edge Function)
//
// Sócio administrador (papel "admin" no escritório em uso): usuários do próprio escritório
//   listar · criar · papel · visao · desativar/reativar · redefinir_senha · previa_saida · remover
// Dono da plataforma (tabela plataforma_donos): escritórios e advogados entre escritórios
//   escritorio_criar · escritorio_ativar · autonomo_criar · membros_listar · incluir · previa_saida · remanejar
//   plataforma_listar · plataforma_ativar · plataforma_excluir (advogados autônomos)
//
// A chave de serviço fica só no servidor do Supabase (SUPABASE_SERVICE_ROLE_KEY).
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
const PAPEIS = ['admin', 'advogado', 'estagiario']
const limparOab = (v: unknown) => String(v || '').replace(/[^0-9A-Za-z]/g, '').toUpperCase()

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return falha('Método não permitido.', 405)

  const servico = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const token = (req.headers.get('Authorization') || '').replace('Bearer ', '')
  const { data: { user }, error: errUser } = await servico.auth.getUser(token)
  if (errUser || !user) return falha('Sessão inválida. Entre de novo.', 401)

  let corpo: Record<string, any>
  try { corpo = await req.json() } catch { return falha('Pedido inválido.') }
  const { acao } = corpo

  const { data: eu } = await servico.from('advogados').select('id, ativo, escritorio_id').eq('id', user.id).maybeSingle()
  const { data: dono } = await servico.from('plataforma_donos').select('usuario_id').eq('usuario_id', user.id).maybeSingle()
  const { data: meuVinculo } = eu
    ? await servico.from('escritorio_membros').select('papel, ativo').eq('advogado_id', user.id).eq('escritorio_id', eu.escritorio_id).maybeSingle()
    : { data: null }
  const meuEsc = eu?.escritorio_id as string | undefined
  const souSocio = Boolean(eu?.ativo && meuVinculo?.ativo && meuVinculo.papel === 'admin')

  // ---------- apoio ----------
  const rpc = async (nome: string, args: Record<string, unknown>) => {
    const { data, error } = await servico.rpc(nome, args)
    if (error) throw new Error(error.message)
    return data
  }
  const vinculos = async (adv: string) => (await servico.from('escritorio_membros').select('escritorio_id, papel, ativo').eq('advogado_id', adv)).data || []
  const contarSocios = async (esc: string) => (await servico.from('escritorio_membros').select('advogado_id', { count: 'exact', head: true })
    .eq('escritorio_id', esc).eq('papel', 'admin').eq('ativo', true)).count || 0
  async function definirEspaco(adv: string, esc: string) {
    const { data: m } = await servico.from('escritorio_membros').select('papel, visao_geral').eq('advogado_id', adv).eq('escritorio_id', esc).single()
    await servico.from('advogados').update({ escritorio_id: esc, papel: m.papel, admin: m.papel === 'admin', visao_geral: m.visao_geral }).eq('id', adv)
  }
  async function criarLogin(d: { email: string; nome: string; oab: string; uf: string; escritorio_id: string; papel: string; visao_geral: boolean }) {
    if (!d.email || !d.nome || !d.oab || d.uf.length !== 2) throw new Error('Preencha nome, e-mail, OAB e UF.')
    const senha = senhaTemporaria()
    const { data: criado, error } = await servico.auth.admin.createUser({ email: d.email, password: senha, email_confirm: true })
    if (error) throw new Error(/already/i.test(error.message) ? 'Já existe um usuário com este e-mail. Para colocá-lo em outro escritório, use "Incluir advogado existente".' : error.message)
    const { error: e1 } = await servico.from('advogados').insert({
      id: criado.user.id, nome: d.nome, oab_numero: d.oab, oab_uf: d.uf, email: d.email, escritorio_id: d.escritorio_id,
      papel: d.papel, admin: d.papel === 'admin', visao_geral: d.visao_geral, ativo: true, trocar_senha: true,
    })
    if (e1) { await servico.auth.admin.deleteUser(criado.user.id); throw new Error(/oab/i.test(e1.message) ? 'Já existe um advogado com esta OAB.' : e1.message) }
    const { error: e2 } = await servico.from('escritorio_membros').insert({ advogado_id: criado.user.id, escritorio_id: d.escritorio_id, papel: d.papel, visao_geral: d.visao_geral })
    if (e2) { await servico.auth.admin.deleteUser(criado.user.id); throw new Error(e2.message) }
    return { id: criado.user.id, senha_temporaria: senha }
  }
  // Saída de um escritório: copia o que o sócio autorizou, passa os exclusivos ao sucessor e apaga o vínculo
  async function sair(adv: string, esc: string, sucessor: string | null, levar: string[]) {
    if (levar.length) {
      const previa = await rpc('previa_saida', { p_adv: adv, p_escritorio: esc })
      const permitidos = new Set((previa.processos || []).map((p: any) => p.id))
      if (levar.some(id => !permitidos.has(id))) throw new Error('Só é possível levar processos em que o advogado está vinculado.')
      const autonomo = await rpc('garantir_autonomo', { p_adv: adv })
      for (const id of levar) await rpc('copiar_processo', { p_proc: id, p_destino: autonomo, p_adv: adv })
    }
    await rpc('executar_saida', { p_adv: adv, p_escritorio: esc, p_sucessor: sucessor || null })
  }

  try {
    // ================= Dono da plataforma =================
    if (['escritorio_criar', 'escritorio_ativar', 'autonomo_criar', 'membros_listar', 'incluir', 'remanejar', 'plataforma_listar', 'plataforma_ativar', 'plataforma_excluir'].includes(acao)
        || (acao === 'previa_saida' && corpo.escritorio_id && corpo.escritorio_id !== meuEsc)) {
      if (!dono) return falha('Apenas o dono da plataforma pode fazer isso.', 403)

      if (acao === 'escritorio_criar') {
        const nome = String(corpo.nome || '').trim()
        if (!nome) return falha('Informe o nome do escritório.')
        const { data: esc, error } = await servico.from('escritorios').insert({ nome }).select('id').single()
        if (error) throw error
        try {
          const r = await criarLogin({ email: String(corpo.admin_email || '').trim().toLowerCase(), nome: String(corpo.admin_nome || '').trim(),
            oab: limparOab(corpo.admin_oab_numero), uf: String(corpo.admin_oab_uf || '').toUpperCase(), escritorio_id: esc.id, papel: 'admin', visao_geral: true })
          return resposta({ escritorio_id: esc.id, ...r })
        } catch (e) { await servico.from('escritorios').delete().eq('id', esc.id); return falha((e as Error).message) }
      }

      if (acao === 'autonomo_criar') {
        const email = String(corpo.email || '').trim().toLowerCase()
        const nome = String(corpo.nome || '').trim()
        const { data: esc, error } = await servico.from('escritorios').insert({ nome: `${nome} (autônomo)`, tipo: 'autonomo' }).select('id').single()
        if (error) throw error
        try {
          const r = await criarLogin({ email, nome, oab: limparOab(corpo.oab_numero), uf: String(corpo.oab_uf || '').toUpperCase(), escritorio_id: esc.id, papel: 'admin', visao_geral: true })
          await servico.from('escritorios').update({ titular_id: r.id }).eq('id', esc.id)
          return resposta({ escritorio_id: esc.id, ...r })
        } catch (e) { await servico.from('escritorios').delete().eq('id', esc.id); return falha((e as Error).message) }
      }

      if (acao === 'escritorio_ativar') {
        const esc = String(corpo.escritorio_id || '')
        if (!corpo.ativo && esc === meuEsc) return falha('Você não pode desativar o escritório que está usando.')
        await servico.from('escritorios').update({ ativo: Boolean(corpo.ativo) }).eq('id', esc)
        return resposta({ ok: true })
      }

      if (acao === 'membros_listar') {
        const esc = String(corpo.escritorio_id || '')
        const { data } = await servico.from('escritorio_membros').select('papel, visao_geral, ativo, advogados(id, nome, email, oab_numero, oab_uf)').eq('escritorio_id', esc)
        const membros = (data || []).map((m: any) => ({ ...m.advogados, papel: m.papel, visao_geral: m.visao_geral, ativo: m.ativo }))
          .sort((a: any, b: any) => (a.nome || '').localeCompare(b.nome || ''))
        return resposta({ membros })
      }

      if (acao === 'incluir') {
        const email = String(corpo.email || '').trim().toLowerCase()
        const esc = String(corpo.escritorio_id || '')
        const papel = PAPEIS.includes(corpo.papel) ? corpo.papel : 'advogado'
        const { data: adv } = await servico.from('advogados').select('id').eq('email', email).maybeSingle()
        if (!adv) return falha('Não há advogado com este e-mail no Orbeo. Crie o usuário pelo escritório.')
        const { error } = await servico.from('escritorio_membros').upsert({ advogado_id: adv.id, escritorio_id: esc, papel, visao_geral: Boolean(corpo.visao_geral), ativo: true })
        if (error) throw error
        return resposta({ ok: true })
      }

      // Todos os advogados da plataforma, com os espaços de cada um
      if (acao === 'plataforma_listar') {
        const { data: lista, error } = await servico.auth.admin.listUsers({ perPage: 1000 })
        if (error) throw error
        const { data: advs } = await servico.from('advogados').select('id, nome, email, oab_numero, oab_uf, ativo')
        const { data: membros } = await servico.from('escritorio_membros').select('advogado_id, papel, ativo, escritorios(id, nome, tipo, ativo)')
        const { data: contagem } = await servico.from('processos').select('escritorio_id')
        const procs = new Map<string, number>()
        for (const p of contagem || []) procs.set(p.escritorio_id, (procs.get(p.escritorio_id) || 0) + 1)
        const usuarios = (advs || []).map((a: any) => {
          const u = lista.users.find(x => x.id === a.id)
          const espacos = (membros || []).filter((m: any) => m.advogado_id === a.id).map((m: any) => ({
            id: m.escritorios.id, nome: m.escritorios.nome, tipo: m.escritorios.tipo, papel: m.papel, ativo: m.ativo && m.escritorios.ativo,
            processos: procs.get(m.escritorios.id) || 0 }))
          return { ...a, ultimo_acesso: u?.last_sign_in_at || null, espacos, autonomo: !espacos.some((e: any) => e.tipo === 'escritorio') }
        }).sort((x: any, y: any) => (x.nome || '').localeCompare(y.nome || ''))
        return resposta({ usuarios })
      }

      if (acao === 'plataforma_ativar') {
        const alvo = String(corpo.id || '')
        if (alvo === user.id) return falha('Você não pode desativar o seu próprio acesso.')
        const ativo = Boolean(corpo.ativo)
        const { error } = await servico.auth.admin.updateUserById(alvo, { ban_duration: ativo ? 'none' : '876000h' })
        if (error) throw error
        await servico.from('advogados').update({ ativo }).eq('id', alvo)
        return resposta({ ok: true })
      }

      // Exclui do sistema um advogado sem escritório: o login e o espaço autônomo (com os processos dele)
      if (acao === 'plataforma_excluir') {
        const alvo = String(corpo.id || '')
        if (alvo === user.id) return falha('Você não pode excluir o seu próprio usuário.')
        const { data: vincs } = await servico.from('escritorio_membros').select('escritorios(id, tipo)').eq('advogado_id', alvo)
        if ((vincs || []).some((v: any) => v.escritorios?.tipo === 'escritorio')) {
          return falha('Este advogado ainda está em um escritório. Remova-o do escritório antes de excluir o login.')
        }
        const autonomos = (vincs || []).map((v: any) => v.escritorios?.id).filter(Boolean)
        const { data: titular } = await servico.from('escritorios').select('id').eq('titular_id', alvo)
        for (const t of titular || []) if (!autonomos.includes(t.id)) autonomos.push(t.id)
        const { error } = await servico.auth.admin.deleteUser(alvo)
        if (error) throw error
        for (const id of autonomos) await rpc('apagar_espaco', { p_escritorio: id })
        return resposta({ ok: true })
      }

      if (acao === 'previa_saida') {
        return resposta(await rpc('previa_saida', { p_adv: String(corpo.id), p_escritorio: String(corpo.escritorio_id) }))
      }

      if (acao === 'remanejar') {
        const adv = String(corpo.id || ''), de = String(corpo.de || ''), para = String(corpo.para || '')
        if (!adv || !de || !para || de === para) return falha('Informe o advogado, o escritório de origem e o de destino.')
        const papel = PAPEIS.includes(corpo.papel) ? corpo.papel : 'advogado'
        const { data: vinc } = await servico.from('escritorio_membros').select('papel').eq('advogado_id', adv).eq('escritorio_id', de).maybeSingle()
        if (!vinc) return falha('O advogado não está no escritório de origem.')
        if (vinc.papel === 'admin' && await contarSocios(de) <= 1) return falha('Ele é o único sócio administrador do escritório de origem. Defina outro sócio antes.')
        await servico.from('escritorio_membros').upsert({ advogado_id: adv, escritorio_id: para, papel, visao_geral: Boolean(corpo.visao_geral), ativo: true })
        await sair(adv, de, corpo.sucessor_id || null, Array.isArray(corpo.levar) ? corpo.levar : [])
        await definirEspaco(adv, para)
        return resposta({ ok: true })
      }
    }

    // ================= Sócio administrador do escritório em uso =================
    if (!souSocio || !meuEsc) return falha('Apenas o sócio administrador pode fazer isso.', 403)

    if (acao === 'listar') {
      const { data: lista, error } = await servico.auth.admin.listUsers({ perPage: 1000 })
      if (error) throw error
      const { data: membros } = await servico.from('escritorio_membros').select('advogado_id, papel, visao_geral, ativo').eq('escritorio_id', meuEsc)
      const ids = (membros || []).map((m: any) => m.advogado_id)
      const { data: perfis } = await servico.from('advogados').select('id, nome, oab_numero, oab_uf, trocar_senha').in('id', ids.length ? ids : ['00000000-0000-0000-0000-000000000000'])
      const usuarios = (membros || []).map((m: any) => {
        const p = perfis?.find((x: any) => x.id === m.advogado_id), u = lista.users.find(x => x.id === m.advogado_id)
        return { id: m.advogado_id, email: u?.email, criado_em: u?.created_at, ultimo_acesso: u?.last_sign_in_at,
          nome: p?.nome ?? null, oab_numero: p?.oab_numero ?? null, oab_uf: p?.oab_uf ?? null, trocar_senha: p?.trocar_senha ?? false,
          papel: m.papel, admin: m.papel === 'admin', visao_geral: m.visao_geral, ativo: m.ativo, sem_perfil: !p }
      }).sort((a: any, b: any) => (a.nome || a.email || '').localeCompare(b.nome || b.email || ''))
      return resposta({ usuarios })
    }

    if (acao === 'criar') {
      const papel = PAPEIS.includes(corpo.papel) ? corpo.papel : (corpo.admin ? 'admin' : 'advogado')
      try {
        return resposta(await criarLogin({ email: String(corpo.email || '').trim().toLowerCase(), nome: String(corpo.nome || '').trim(),
          oab: limparOab(corpo.oab_numero), uf: String(corpo.oab_uf || '').toUpperCase(), escritorio_id: meuEsc, papel, visao_geral: Boolean(corpo.visao_geral) }))
      } catch (e) { return falha((e as Error).message) }
    }

    const alvo = String(corpo.id || '')
    if (!alvo) return falha('Usuário não informado.')
    const { data: vinculoAlvo } = await servico.from('escritorio_membros').select('papel, ativo').eq('advogado_id', alvo).eq('escritorio_id', meuEsc).maybeSingle()
    if (!vinculoAlvo) return falha('Usuário não encontrado neste escritório.', 404)

    if (acao === 'papel' || acao === 'admin') {
      const papel = acao === 'admin' ? (corpo.admin ? 'admin' : 'advogado') : String(corpo.papel)
      if (!PAPEIS.includes(papel)) return falha('Papel inválido.')
      if (vinculoAlvo.papel === 'admin' && papel !== 'admin' && await contarSocios(meuEsc) <= 1) return falha('É preciso manter pelo menos um sócio administrador ativo.')
      await servico.from('escritorio_membros').update({ papel }).eq('advogado_id', alvo).eq('escritorio_id', meuEsc)
      return resposta({ ok: true })
    }
    if (acao === 'visao') {
      await servico.from('escritorio_membros').update({ visao_geral: Boolean(corpo.visao_geral) }).eq('advogado_id', alvo).eq('escritorio_id', meuEsc)
      return resposta({ ok: true })
    }

    if (acao === 'desativar' || acao === 'reativar') {
      if (alvo === user.id) return falha('Você não pode desativar o seu próprio acesso.')
      const ativo = acao === 'reativar'
      if (!ativo && vinculoAlvo.papel === 'admin' && await contarSocios(meuEsc) <= 1) return falha('É preciso manter pelo menos um sócio administrador ativo.')
      await servico.from('escritorio_membros').update({ ativo }).eq('advogado_id', alvo).eq('escritorio_id', meuEsc)
      // Login só é bloqueado se ele não tiver nenhum outro espaço ativo
      const outros = (await vinculos(alvo)).filter((v: any) => v.escritorio_id !== meuEsc && v.ativo)
      if (!outros.length) {
        await servico.auth.admin.updateUserById(alvo, { ban_duration: ativo ? 'none' : '876000h' })
        await servico.from('advogados').update({ ativo }).eq('id', alvo)
      }
      return resposta({ ok: true })
    }

    if (acao === 'redefinir_senha') {
      const outros = (await vinculos(alvo)).filter((v: any) => v.escritorio_id !== meuEsc)
      if (outros.length) return falha('Este advogado também usa o Orbeo em outro espaço. A senha dele só pode ser redefinida por ele mesmo ou pelo dono da plataforma.')
      const senha = senhaTemporaria()
      const { error } = await servico.auth.admin.updateUserById(alvo, { password: senha })
      if (error) throw error
      await servico.from('advogados').update({ trocar_senha: true }).eq('id', alvo)
      return resposta({ senha_temporaria: senha })
    }

    if (acao === 'previa_saida') {
      const previa = await rpc('previa_saida', { p_adv: alvo, p_escritorio: meuEsc })
      return resposta(previa)
    }

    // Remover do escritório (e, se for o caso, excluir o login ou mantê-lo como autônomo)
    if (acao === 'remover' || acao === 'excluir') {
      if (alvo === user.id) return falha('Você não pode remover o seu próprio usuário.')
      if (vinculoAlvo.papel === 'admin' && await contarSocios(meuEsc) <= 1) return falha('É preciso manter pelo menos um sócio administrador ativo.')
      const levar: string[] = Array.isArray(corpo.levar) ? corpo.levar : []
      const destino = acao === 'excluir' ? 'excluir_login' : String(corpo.destino || 'autonomo')
      const outros = (await vinculos(alvo)).filter((v: any) => v.escritorio_id !== meuEsc)
      if (destino === 'excluir_login' && (outros.length || levar.length)) {
        return falha(outros.length ? 'Este advogado tem outro espaço no Orbeo: o login não pode ser excluído, só a saída deste escritório.'
          : 'Para levar processos, o login precisa ser mantido como advogado autônomo.')
      }
      await sair(alvo, meuEsc, corpo.sucessor_id || null, levar)
      const restantes = (await vinculos(alvo)).filter((v: any) => v.ativo)
      if (!restantes.length) {
        if (destino === 'excluir_login') {
          const { error } = await servico.auth.admin.deleteUser(alvo)
          if (error) throw error
          return resposta({ ok: true, login: 'excluido' })
        }
        const autonomo = await rpc('garantir_autonomo', { p_adv: alvo })
        await definirEspaco(alvo, autonomo)
      }
      return resposta({ ok: true, login: 'mantido' })
    }

    return falha('Ação desconhecida.')
  } catch (e) {
    return falha((e as Error).message || 'Erro inesperado.', 500)
  }
})
