// Audiências: rótulos, datas no fuso de Brasília e exportação .ics
export const TIPOS_AUD = {
  conciliacao: 'Conciliação', instrucao: 'Instrução e julgamento', una: 'Una', inicial: 'Inicial',
  julgamento: 'Sessão de julgamento', sustentacao_oral: 'Sustentação oral', outra: 'Outra',
}
export const MODALIDADES = { presencial: 'Presencial', virtual: 'Virtual', hibrida: 'Híbrida' }
export const STATUS_AUD = {
  agendada: 'Agendada', realizada: 'Realizada', redesignada: 'Redesignada', cancelada: 'Cancelada', nao_realizada: 'Não realizada',
}

const TZ = 'America/Sao_Paulo'
const partes = d => Object.fromEntries(new Intl.DateTimeFormat('en-CA', {
  timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false,
}).formatToParts(new Date(d)).map(p => [p.type, p.value]))

// "2026-11-20" + "14:30" (horário de Brasília) → ISO
export function montarISO(dia, hora) {
  if (!dia || !hora) return null
  return new Date(`${dia}T${hora}:00-03:00`).toISOString()
}
// ISO → { dia: "2026-11-20", hora: "14:30" } em Brasília
export function separarISO(iso) {
  if (!iso) return { dia: '', hora: '' }
  const p = partes(iso)
  return { dia: `${p.year}-${p.month}-${p.day}`, hora: `${p.hour === '24' ? '00' : p.hour}:${p.minute}` }
}
export const hojeSP = () => new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date())
export function diaSP(iso) { return separarISO(iso).dia }
export function diasAte(iso) {
  const a = new Date(hojeSP() + 'T12:00'), b = new Date(diaSP(iso) + 'T12:00')
  return Math.round((b - a) / 86400000)
}
export function rotuloQuando(iso) {
  const { hora } = separarISO(iso), n = diasAte(iso)
  if (n === 0) return `Hoje, ${hora}`
  if (n === 1) return `Amanhã, ${hora}`
  if (n === -1) return `Ontem, ${hora}`
  const d = new Date(iso).toLocaleDateString('pt-BR', { timeZone: TZ, weekday: 'short', day: '2-digit', month: '2-digit' })
  return `${d.replace('.', '')} · ${hora}`
}
export function rotuloDia(dia) {
  const n = Math.round((new Date(dia + 'T12:00') - new Date(hojeSP() + 'T12:00')) / 86400000)
  const txt = new Date(dia + 'T12:00').toLocaleDateString('pt-BR', { weekday: 'long', day: 'numeric', month: 'long' })
  return n === 0 ? `Hoje · ${txt}` : n === 1 ? `Amanhã · ${txt}` : txt.charAt(0).toUpperCase() + txt.slice(1)
}

export function gerarICSAudiencias(lista) {
  const esc = t => String(t || '').replace(/\\/g, '\\\\').replace(/;/g, '\;').replace(/,/g, '\\,').replace(/\n/g, '\\n')
  const utc = iso => new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '')
  const fim = iso => utc(new Date(new Date(iso).getTime() + 60 * 60000).toISOString())
  const ev = lista.map(a => [
    'BEGIN:VEVENT', `UID:${a.id}@orbeo-audiencias`, `DTSTAMP:${utc(new Date().toISOString())}`,
    `DTSTART:${utc(a.data_hora)}`, `DTEND:${fim(a.data_hora)}`,
    `SUMMARY:${esc(`Audiência de ${TIPOS_AUD[a.tipo] || a.tipo} · ${a.cliente}`)}`,
    `LOCATION:${esc(a.modalidade === 'virtual' ? (a.link || 'Virtual') : (a.local || ''))}`,
    `DESCRIPTION:${esc([`Processo ${a.numero_cnj}`, a.orgao_julgador, MODALIDADES[a.modalidade], a.link, a.observacoes].filter(Boolean).join('\n'))}`,
    'BEGIN:VALARM', 'TRIGGER:-P1D', 'ACTION:DISPLAY', 'DESCRIPTION:Audiência amanhã', 'END:VALARM',
    'BEGIN:VALARM', 'TRIGGER:-PT2H', 'ACTION:DISPLAY', 'DESCRIPTION:Audiência em 2 horas', 'END:VALARM',
    'END:VEVENT',
  ].join('\r\n'))
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Orbeo//PT-BR', 'X-WR-CALNAME:Audiências · Orbeo', ...ev, 'END:VCALENDAR'].join('\r\n')
}
