// Apoio às suspensões de prazo: rótulos, cores, calendário e exportação .ics
import { UFS } from './formato.js'

export const TRIBUNAIS = [
  'STF', 'STJ', 'TST', 'TSE', 'STM',
  ...[1, 2, 3, 4, 5, 6].map(n => `TRF${n}`),
  ...Array.from({ length: 24 }, (_, i) => `TRT${i + 1}`),
  ...UFS.map(u => `TJ${u}`),
  ...UFS.map(u => `TRE-${u}`),
  'TJM-MG', 'TJM-RS', 'TJM-SP',
]

export const TIPOS = {
  feriado: { rotulo: 'Feriado', cor: '#24508f', fundo: '#e2eaf6' },
  recesso: { rotulo: 'Recesso', cor: '#5b3f8c', fundo: '#ece5f6' },
  ponto_facultativo: { rotulo: 'Ponto facultativo', cor: '#5b6573', fundo: '#eceae6' },
  indisponibilidade: { rotulo: 'Indisponibilidade de sistema', cor: '#8a5300', fundo: '#fbefd9' },
  ato: { rotulo: 'Suspensão por ato', cor: '#a8261b', fundo: '#f9e1de' },
}

export const ABRANGENCIAS = [['nacional', 'Nacional'], ['tribunal', 'Tribunal'], ['comarca', 'Comarca'], ['orgao', 'Vara']]
export const FONTES = { regra: 'Regra nacional', sugestao: 'Confirmada de sugestão', manual: 'Cadastro manual' }

export function rotuloAbrangencia(s) {
  if (s.abrangencia === 'nacional') return 'Nacional · todos os tribunais'
  if (s.abrangencia === 'tribunal') return s.tribunal
  if (s.abrangencia === 'comarca') return `${s.tribunal} · ${s.comarca}`
  return `${s.tribunal} · ${s.comarca} · ${s.orgao}`
}

const dm = d => { const [, m, dd] = d.split('-'); return `${dd}/${m}` }
const dma = d => { const [a, m, dd] = d.split('-'); return `${dd}/${m}/${a}` }
export function rotuloPeriodo(s) {
  const hora = s.hora_inicio ? ` a partir das ${String(s.hora_inicio).slice(0, 5)}` : ''
  if (!s.data_fim || s.data_fim === s.data_inicio) return `${dma(s.data_inicio)}${hora}`
  const mesmoAno = s.data_inicio.slice(0, 4) === s.data_fim.slice(0, 4)
  return `${mesmoAno ? dm(s.data_inicio) : dma(s.data_inicio)} a ${dma(s.data_fim)}${hora}`
}

export const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

// 6 semanas (42 dias) começando no domingo anterior ao dia 1
export function gradeDoMes(ano, mes) {
  const primeiro = new Date(ano, mes, 1)
  const inicio = new Date(ano, mes, 1 - primeiro.getDay())
  return Array.from({ length: 42 }, (_, i) => {
    const d = new Date(inicio.getFullYear(), inicio.getMonth(), inicio.getDate() + i)
    return { data: iso(d), dia: d.getDate(), doMes: d.getMonth() === mes, fimDeSemana: d.getDay() === 0 || d.getDay() === 6 }
  })
}

export const cobre = (s, data) => s.data_inicio <= data && (s.data_fim || s.data_inicio) >= data

// Filtro "meus tribunais": nacional + tribunais onde há processos ativos
export function relevante(s, emUso) {
  if (s.abrangencia === 'nacional') return true
  return emUso.some(t => t.tribunal === s.tribunal &&
    (!['comarca', 'orgao'].includes(s.abrangencia) || !t.comarca || t.comarca.toLowerCase() === (s.comarca || '').toLowerCase()))
}

export function gerarICS(lista, nome = 'Suspensões de prazo') {
  const esc = t => String(t || '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n')
  const ymd = d => d.replace(/-/g, '')
  const diaSeguinte = d => { const x = new Date(d + 'T12:00'); x.setDate(x.getDate() + 1); return ymd(iso(x)) }
  const agora = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '')
  const eventos = lista.map(s => [
    'BEGIN:VEVENT',
    `UID:${s.id}@sistema-processos`,
    `DTSTAMP:${agora}`,
    `DTSTART;VALUE=DATE:${ymd(s.data_inicio)}`,
    `DTEND;VALUE=DATE:${diaSeguinte(s.data_fim || s.data_inicio)}`,
    `SUMMARY:${esc(`[${s.abrangencia === 'nacional' ? 'Nacional' : rotuloAbrangencia(s)}] ${s.motivo}`)}`,
    `DESCRIPTION:${esc([TIPOS[s.tipo]?.rotulo, s.hora_inicio ? `A partir das ${String(s.hora_inicio).slice(0, 5)}` : '', s.numero_ato, s.link_ato].filter(Boolean).join('\n'))}`,
    'TRANSP:TRANSPARENT',
    'END:VEVENT',
  ].join('\r\n'))
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Sistema de Processos//PT-BR', 'CALSCALE:GREGORIAN',
    `X-WR-CALNAME:${esc(nome)}`, ...eventos, 'END:VCALENDAR'].join('\r\n')
}

export function baixarArquivo(conteudo, nome, tipo) {
  const url = URL.createObjectURL(new Blob([conteudo], { type: tipo }))
  const a = document.createElement('a'); a.href = url; a.download = nome
  document.body.appendChild(a); a.click(); a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
