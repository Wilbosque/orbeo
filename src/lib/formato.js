export const POLOS = { autor: 'Autor', reu: 'Réu' }
export const SITUACOES = { ativo: 'Ativo', suspenso: 'Suspenso', arquivado: 'Arquivado', encerrado: 'Encerrado' }
export const TIPOS_ACAO = ['Cível', 'Consumidor', 'Trabalhista', 'Outro']
export const UFS = ['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB',
                    'PR','PE','PI','RJ','RN','RS','RO','RR','SC','SE','SP','TO']

export function data(d) {
  if (!d) return ''
  const [a, m, dd] = String(d).slice(0, 10).split('-')
  return `${dd}/${m}/${a}`
}

export function moeda(v) {
  if (v === null || v === undefined || v === '') return ''
  return Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}

// "1.234,56" → 1234.56
export function lerMoeda(s) {
  if (s === null || s === undefined || s === '') return null
  const n = Number(String(s).replace(/[^\d,]/g, '').replace(',', '.'))
  return Number.isFinite(n) ? n : null
}

// digitação: só números → "1.234,56"
export function mascararMoeda(s) {
  const d = String(s || '').replace(/\D/g, '')
  if (!d) return ''
  const n = Number(d) / 100
  return n.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export function iniciais(nome) {
  return (nome || '?').split(/\s+/).filter(Boolean).slice(0, 2).map(p => p[0]).join('').toUpperCase()
}

export function normalizar(s) {
  return (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

export function mascararTelefone(v) {
  const d = String(v || '').replace(/\D/g, '').slice(0, 11)
  if (d.length <= 10) return d.replace(/^(\d{2})(\d)/, '($1) $2').replace(/(\d{4})(\d)/, '$1-$2')
  return d.replace(/^(\d{2})(\d)/, '($1) $2').replace(/(\d{5})(\d)/, '$1-$2')
}

/** Todas as OABs do advogado, a principal primeiro: "OAB 12345/BA · 6789/SE" */
export function oabsTexto(a) {
  const lista = [...(a?.advogado_oabs || [])].sort((x, y) => Number(y.principal) - Number(x.principal))
  if (!lista.length) return a?.oab_numero ? `OAB ${a.oab_numero}/${a.oab_uf}` : ''
  return 'OAB ' + lista.map(o => `${o.numero}/${o.uf}`).join(' · ')
}
/** Só a principal, com "+N" quando houver outras (para espaços curtos) */
export function oabCurta(a) {
  const n = (a?.advogado_oabs || []).length
  return a?.oab_numero ? `OAB ${a.oab_numero}/${a.oab_uf}${n > 1 ? ` +${n - 1}` : ''}` : ''
}
