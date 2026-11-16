// Cálculo do prazo fatal no navegador, para a PRÉVIA no formulário.
// O valor oficial é calculado pelo banco (função calcular_prazo), com as mesmas regras.

export const RITOS = {
  comum: 'Comum (CPC)', juizado_civel: 'Juizado Especial Cível', juizado_fazenda: 'Juizado da Fazenda Pública',
  juizado_federal: 'Juizado Especial Federal', trabalhista: 'Trabalhista (CLT)',
}
export const REGRA_RITO = {
  comum: 'CPC: dias úteis (art. 219), excluído o dia do começo (art. 224).',
  juizado_civel: 'Juizado: dias úteis (Lei 9.099, art. 12-A), contados da intimação ou ciência, e não da juntada (FONAJE, Enunciado 13).',
  juizado_fazenda: 'Juizado da Fazenda: dias úteis (Lei 9.099, art. 12-A, aplicada subsidiariamente). Sem prazo em dobro para a Fazenda (Lei 12.153, art. 7º).',
  juizado_federal: 'Juizado Federal: dias úteis (Lei 9.099, art. 12-A, aplicada subsidiariamente). Sem prazo em dobro para entes públicos (Lei 10.259, art. 9º).',
  trabalhista: 'CLT: dias úteis, excluído o dia do começo (art. 775).',
}
// Lista de tipos aprovada no sistema anterior, agrupada. Os dias ficam EM BRANCO: o advogado informa.
// "tipico" só sugere (botão "usar"), por rito. Limite: 15 dias; Mandado de Segurança e "Outro": 120.
const J = ['juizado_civel', 'juizado_fazenda', 'juizado_federal']
const T = ['trabalhista']
const C = ['comum']
export const GRUPOS = ['Peças iniciais', 'Defesa', 'Manifestações', 'Recursos', 'Execução', 'Incidentes', 'Outros']
export const TIPOS = [
  { grupo: 'Peças iniciais', tipo: 'Petição inicial', tipico: {} },
  { grupo: 'Peças iniciais', tipo: 'Emenda à inicial', tipico: { comum: 15, juizado: 15, trabalhista: 15 } },
  { grupo: 'Peças iniciais', tipo: 'Mandado de segurança', max: 120, contagem: 'corridos', tipico: { comum: 120 }, nota: 'Prazo decadencial de 120 dias corridos da ciência do ato (Lei 12.016, art. 23).' },
  { grupo: 'Defesa', tipo: 'Contestação (até a audiência)', audiencia: true, ritos: [...J, ...T] },
  { grupo: 'Defesa', tipo: 'Contestação', tipico: { comum: 15, juizado: 15 } },
  { grupo: 'Defesa', tipo: 'Reconvenção', ritos: C, tipico: { comum: 15 } },
  { grupo: 'Defesa', tipo: 'Réplica', tipico: { comum: 15, juizado: 5, trabalhista: 5 } },
  { grupo: 'Defesa', tipo: 'Impugnação à justiça gratuita', tipico: { comum: 15 } },
  { grupo: 'Manifestações', tipo: 'Manifestação', tipico: { comum: 5, juizado: 5, trabalhista: 5 } },
  { grupo: 'Manifestações', tipo: 'Especificação de provas', tipico: { comum: 5, juizado: 5 } },
  { grupo: 'Manifestações', tipo: 'Manifestação sobre laudo pericial', tipico: { comum: 15, trabalhista: 5 } },
  { grupo: 'Manifestações', tipo: 'Alegações finais / memoriais', tipico: { comum: 15, trabalhista: 5 } },
  { grupo: 'Manifestações', tipo: 'Cumprimento de diligência / juntada', tipico: { comum: 5, juizado: 5, trabalhista: 5 } },
  { grupo: 'Recursos', tipo: 'Embargos de declaração', tipico: { comum: 5, juizado: 5, trabalhista: 5 } },
  { grupo: 'Recursos', tipo: 'Recurso inominado', ritos: J, tipico: { juizado: 10 } },
  { grupo: 'Recursos', tipo: 'Contrarrazões ao recurso inominado', ritos: J, tipico: { juizado: 10 } },
  { grupo: 'Recursos', tipo: 'Preparo do recurso inominado (48h)', ritos: J, dias: 2, origem: 'ato', contagem: 'corridos' },
  { grupo: 'Recursos', tipo: 'Apelação', ritos: C, tipico: { comum: 15 } },
  { grupo: 'Recursos', tipo: 'Contrarrazões à apelação', ritos: C, tipico: { comum: 15 } },
  { grupo: 'Recursos', tipo: 'Recurso ordinário', ritos: T, tipico: { trabalhista: 8 } },
  { grupo: 'Recursos', tipo: 'Contrarrazões ao recurso ordinário', ritos: T, tipico: { trabalhista: 8 } },
  { grupo: 'Recursos', tipo: 'Recurso de revista', ritos: T, tipico: { trabalhista: 8 } },
  { grupo: 'Recursos', tipo: 'Agravo de petição', ritos: T, tipico: { trabalhista: 8 } },
  { grupo: 'Recursos', tipo: 'Agravo de instrumento', ritos: [...C, ...T], tipico: { comum: 15, trabalhista: 8 } },
  { grupo: 'Recursos', tipo: 'Agravo interno', tipico: { comum: 15, juizado: 15, trabalhista: 8 } },
  { grupo: 'Recursos', tipo: 'Recurso especial', ritos: C, tipico: { comum: 15 } },
  { grupo: 'Recursos', tipo: 'Recurso extraordinário', tipico: { comum: 15, juizado: 15, trabalhista: 15 } },
  { grupo: 'Recursos', tipo: 'Contrarrazões (outros recursos)', tipico: { comum: 15, juizado: 15, trabalhista: 8 } },
  { grupo: 'Execução', tipo: 'Pagamento voluntário / cumprimento da sentença', tipico: { comum: 15, juizado: 15, trabalhista: 2 } },
  { grupo: 'Execução', tipo: 'Impugnação ao cumprimento de sentença', ritos: [...C, ...J], tipico: { comum: 15, juizado: 15 } },
  { grupo: 'Execução', tipo: 'Embargos à execução', tipico: { comum: 15, juizado: 15, trabalhista: 5 } },
  { grupo: 'Execução', tipo: 'Impugnação aos cálculos', tipico: { comum: 15, trabalhista: 8 } },
  { grupo: 'Incidentes', tipo: 'Exceção / arguição de incompetência', tipico: { comum: 15, trabalhista: 5 } },
  { grupo: 'Incidentes', tipo: 'Incidente de desconsideração da personalidade jurídica', tipico: { comum: 15, juizado: 15, trabalhista: 15 } },
  { grupo: 'Incidentes', tipo: 'Impugnação ao valor da causa', tipico: { comum: 15 } },
  { grupo: 'Outros', tipo: 'Outro', max: 120, tipico: {} },
]
export const LIMITE_DIAS = 15
export const limiteDoTipo = t => t?.max || LIMITE_DIAS
const chaveRito = r => (J.includes(r) ? 'juizado' : r === 'trabalhista' ? 'trabalhista' : 'comum')
export const tipicoDoTipo = (t, rito) => t?.tipico?.[chaveRito(rito)] ?? null
export const tiposDoRito = rito => TIPOS.filter(t => !t.ritos || t.ritos.includes(rito))
// Compatibilidade
export const CATALOGO = Object.fromEntries(Object.keys(RITOS).map(r => [r, tiposDoRito(r)]))
export const TIPOS_PRAZO = TIPOS.map(c => [c.tipo, null])

export const INSTANCIAS = { '1g': '1º grau / Juizados', '2g': '2º grau / Turmas Recursais' }
export const INSTANCIAS_SUSP = { todas: 'Todas as instâncias', '1g': 'Só 1º grau / Juizados', '2g': 'Só 2º grau / Turmas Recursais' }
export const inferirInstancia = orgao => (/(turma recursal|c[âa]mara|tribunal pleno|se[çc][ãa]o c[íi]vel|desembargador|gabinete)/i.test(orgao || '') ? '2g' : '1g')

export function inferirRito(tribunal, classe, orgao) {
  const t = (tribunal || '').toUpperCase(), txt = `${classe || ''} ${orgao || ''}`
  if (t.startsWith('TRT') || t === 'TST') return 'trabalhista'
  if (/(juizado|turma recursal|\bJEC|\bSJE)/i.test(txt)) return /fazenda/i.test(txt) ? 'juizado_fazenda' : t.startsWith('TRF') ? 'juizado_federal' : 'juizado_civel'
  return 'comum'
}

const SUSPENDE = ['recesso', 'ato', 'indisponibilidade']
const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
const mais = (s, n) => { const d = new Date(s + 'T12:00'); d.setDate(d.getDate() + n); return iso(d) }
const fimDeSemana = s => { const w = new Date(s + 'T12:00').getDay(); return w === 0 || w === 6 }

function vale(s, proc) {
  if (s.instancia && s.instancia !== 'todas' && s.instancia !== (proc.instancia || '1g')) return false
  if (s.abrangencia === 'nacional') return true
  if (s.tribunal !== proc.tribunal) return false
  if (s.abrangencia === 'tribunal') return true
  const mesmaComarca = (proc.comarca || '').toLowerCase() === (s.comarca || '').toLowerCase()
  if (s.abrangencia === 'comarca') return mesmaComarca
  return mesmaComarca && (proc.orgao_julgador || '').toLowerCase().includes((s.orgao || '').toLowerCase())
}

export function situacaoDoDia(dia, suspensoes, proc) {
  const doDia = suspensoes.filter(s => dia >= s.data_inicio && dia <= (s.data_fim || s.data_inicio) && vale(s, proc))
  if (doDia.some(s => !s.hora_inicio && SUSPENDE.includes(s.tipo))) return { sit: 'suspenso', s: doDia }
  if (doDia.some(s => !s.hora_inicio)) return { sit: 'nao_util', s: doDia }
  if (doDia.length) return { sit: 'parcial', s: doDia }
  return { sit: null, s: [] }
}
const util = (d, sus, proc) => !fimDeSemana(d) && ['ok', 'parcial', null].includes(situacaoDoDia(d, sus, proc).sit)
function proximoUtil(d, sus, proc) { let x = mais(d, 1); while (!util(x, sus, proc)) x = mais(x, 1); return x }

/**
 * @returns {{ inicio, fatal, publicacao, considerados: [{dia, motivo}] } | null}
 */
export function calcularPrazo({ data, origem = 'intimacao', dias, contagem = 'uteis' }, suspensoes, proc) {
  if (!data || !dias || dias < 1) return null
  const considerados = new Map()
  if (origem === 'ato') {
    let d = mais(data, Number(dias))
    while (!util(d, suspensoes, proc) || situacaoDoDia(d, suspensoes, proc).sit === 'parcial') {
      const r = situacaoDoDia(d, suspensoes, proc); if (r.s.length) considerados.set(d, r.s.map(x => x.motivo).join('; '))
      d = mais(d, 1)
    }
    return { inicio: data, fatal: d, publicacao: null, considerados: [...considerados].map(([dia, motivo]) => ({ dia, motivo })) }
  }
  const anotar = d => { const r = situacaoDoDia(d, suspensoes, proc); if (r.s.length) considerados.set(d, r.s.map(x => x.motivo).join('; ')) }
  let base = data, publicacao = null
  if (origem === 'disponibilizacao') { base = publicacao = proximoUtil(base, suspensoes, proc) }
  const inicio = proximoUtil(base, suspensoes, proc)
  let d = inicio, n = 1, guarda = 0
  while (n < dias) {
    d = mais(d, 1); if (++guarda > 2000) return null
    if (contagem === 'uteis') { if (util(d, suspensoes, proc)) n++; else if (!fimDeSemana(d)) anotar(d) }
    else { const r = situacaoDoDia(d, suspensoes, proc); if (r.sit !== 'suspenso') n++; else anotar(d) }
  }
  while (!util(d, suspensoes, proc) || situacaoDoDia(d, suspensoes, proc).sit === 'parcial') {
    if (!fimDeSemana(d)) anotar(d)
    d = mais(d, 1)
  }
  return { inicio, fatal: d, publicacao, considerados: [...considerados].map(([dia, motivo]) => ({ dia, motivo })) }
}

export const diaSemana = s => new Date(s + 'T12:00').toLocaleDateString('pt-BR', { weekday: 'short' }).replace('.', '')

// Lê "no prazo de 15 (quinze) dias", "prazo de cinco dias", "em 48 horas" no texto da publicação.
// Só SUGERE: o advogado confere e confirma.
const EXTENSO = { um: 1, uma: 1, dois: 2, duas: 2, tres: 3, quatro: 4, cinco: 5, seis: 6, sete: 7, oito: 8, nove: 9, dez: 10,
  onze: 11, doze: 12, treze: 13, quatorze: 14, catorze: 14, quinze: 15, vinte: 20, trinta: 30, quarenta: 40, sessenta: 60, noventa: 90 }
export function prazoNoTexto(texto) {
  const t = (texto || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
  const m = t.match(/prazo\s+(?:comum\s+|sucessivo\s+|legal\s+)?de\s+(\d{1,3}|[a-z]+)\s*(?:\([a-z\s]+\)\s*)?(dias?|horas?)(\s+uteis|\s+corridos)?/)
    || t.match(/\b(?:em|no)\s+(\d{1,3}|[a-z]+)\s*(?:\([a-z\s]+\)\s*)?(dias?|horas?)(\s+uteis|\s+corridos)?/)
  if (!m) return null
  const n = /^\d+$/.test(m[1]) ? Number(m[1]) : EXTENSO[m[1]]
  if (!n) return null
  if (m[2].startsWith('hora')) return { horas: n, trecho: m[0] }
  return { dias: n, contagem: m[3]?.includes('corridos') ? 'corridos' : 'uteis', trecho: m[0] }
}
