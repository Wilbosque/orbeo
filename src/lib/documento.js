// CPF e CNPJ (inclui o CNPJ alfanumérico, em vigor desde julho de 2026)

export function limparDoc(v) { return (v || '').toUpperCase().replace(/[^0-9A-Z]/g, '') }

export function formatarDoc(v, tipo) {
  const d = limparDoc(v)
  if (tipo === 'PF') {
    const x = d.replace(/\D/g, '').slice(0, 11)
    return x.replace(/^(\d{3})(\d)/, '$1.$2').replace(/^(\d{3})\.(\d{3})(\d)/, '$1.$2.$3')
            .replace(/\.(\d{3})(\d{1,2})$/, '.$1-$2')
  }
  const x = d.slice(0, 14)
  let s = x.slice(0, 2)
  if (x.length > 2) s += '.' + x.slice(2, 5)
  if (x.length > 5) s += '.' + x.slice(5, 8)
  if (x.length > 8) s += '/' + x.slice(8, 12)
  if (x.length > 12) s += '-' + x.slice(12, 14)
  return s
}

export function validarCPF(v) {
  const c = (v || '').replace(/\D/g, '')
  if (c.length !== 11 || /^(\d)\1{10}$/.test(c)) return false
  const dv = (base, peso) => {
    let s = 0
    for (let i = 0; i < base.length; i++) s += parseInt(base[i], 10) * (peso - i)
    const r = (s * 10) % 11
    return r === 10 ? 0 : r
  }
  return dv(c.slice(0, 9), 10) === +c[9] && dv(c.slice(0, 10), 11) === +c[10]
}

export function validarCNPJ(v) {
  const c = limparDoc(v)
  if (c.length !== 14 || !/^[0-9A-Z]{12}\d{2}$/.test(c) || /^(.)\1{13}$/.test(c)) return false
  const val = ch => ch.charCodeAt(0) - 48
  const dv = (base) => {
    const pesos = base.length === 12 ? [5,4,3,2,9,8,7,6,5,4,3,2] : [6,5,4,3,2,9,8,7,6,5,4,3,2]
    const s = base.split('').reduce((acc, ch, i) => acc + val(ch) * pesos[i], 0)
    const r = s % 11
    return r < 2 ? 0 : 11 - r
  }
  const d1 = dv(c.slice(0, 12)), d2 = dv(c.slice(0, 12) + d1)
  return d1 === +c[12] && d2 === +c[13]
}

export function validarDoc(v, tipo) {
  if (!v) return true // opcional
  return tipo === 'PF' ? validarCPF(v) : validarCNPJ(v)
}
