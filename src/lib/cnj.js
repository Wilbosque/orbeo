// Número único CNJ (Res. CNJ 65/2008): NNNNNNN-DD.AAAA.J.TR.OOOO

const UFS = ['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB',
             'PR','PE','PI','RJ','RN','RS','RO','RR','SC','SE','SP','TO']

export function soDigitos(v) { return (v || '').replace(/\D/g, '') }

export function formatarCNJ(v) {
  const d = soDigitos(v).slice(0, 20)
  const partes = [d.slice(0, 7), d.slice(7, 9), d.slice(9, 13), d.slice(13, 14), d.slice(14, 16), d.slice(16, 20)]
  let s = partes[0]
  if (d.length > 7) s += '-' + partes[1]
  if (d.length > 9) s += '.' + partes[2]
  if (d.length > 13) s += '.' + partes[3]
  if (d.length > 14) s += '.' + partes[4]
  if (d.length > 16) s += '.' + partes[5]
  return s
}

export function digitoCNJ(d20) {
  // d20 sem o DV: NNNNNNN AAAA J TR OOOO
  const n = d20.slice(0, 7), a = d20.slice(9, 13), j = d20.slice(13, 14), tr = d20.slice(14, 16), o = d20.slice(16, 20)
  const resto = BigInt(n + a + j + tr + o + '00') % 97n
  return String(98n - resto).padStart(2, '0')
}

export function validarCNJ(v) {
  const d = soDigitos(v)
  if (d.length !== 20) return { ok: false, motivo: 'O número CNJ tem 20 dígitos.' }
  if (digitoCNJ(d) !== d.slice(7, 9)) return { ok: false, motivo: 'Dígito verificador não confere. Confira o número.' }
  return { ok: true }
}

export function tribunalDoCNJ(v) {
  const d = soDigitos(v)
  if (d.length < 16) return null
  const j = d[13], tr = d.slice(14, 16), n = parseInt(tr, 10)
  switch (j) {
    case '1': return { sigla: 'STF', ramo: 'Supremo Tribunal Federal' }
    case '2': return { sigla: 'CNJ', ramo: 'Conselho Nacional de Justiça' }
    case '3': return { sigla: 'STJ', ramo: 'Superior Tribunal de Justiça' }
    case '4': return n === 90 ? { sigla: 'CJF', ramo: 'Justiça Federal' } : { sigla: `TRF${n}`, ramo: 'Justiça Federal' }
    case '5': return n === 0 ? { sigla: 'TST', ramo: 'Justiça do Trabalho' } : { sigla: `TRT${n}`, ramo: 'Justiça do Trabalho' }
    case '6': return n === 0 ? { sigla: 'TSE', ramo: 'Justiça Eleitoral' } : { sigla: `TRE-${UFS[n - 1] || tr}`, ramo: 'Justiça Eleitoral' }
    case '7': return { sigla: 'STM', ramo: 'Justiça Militar da União' }
    case '8': return { sigla: `TJ${UFS[n - 1] || tr}`, ramo: 'Justiça Estadual' }
    case '9': return { sigla: `TJM-${UFS[n - 1] || tr}`, ramo: 'Justiça Militar Estadual' }
    default: return null
  }
}

export function tipoAcaoSugerido(v) {
  const t = tribunalDoCNJ(v)
  if (!t) return ''
  return t.ramo === 'Justiça do Trabalho' ? 'Trabalhista' : ''
}
