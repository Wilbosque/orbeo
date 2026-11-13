// Logo Orbeo (vetor recriado a partir da marca). variante: "claro" (anel azul-marinho) ou "escuro" (anel branco)
const ANEL = 'M 853.1 322.9 A 390 390 0 1 1 702.3 171.6'

export function Simbolo({ escuro, ...props }) {
  return (
    <svg viewBox="0 0 1024 1024" aria-hidden="true" {...props}>
      <path d={ANEL} fill="none" stroke={escuro ? '#ffffff' : '#0f172a'} strokeWidth="80" />
      <circle cx="512" cy="512" r="206" fill="#6c5bff" />
      <circle cx="880" cy="143" r="72" fill="#6c5bff" />
    </svg>
  )
}

export default function Logo({ variante = 'claro', className = '', style }) {
  const escuro = variante === 'escuro'
  return (
    <span className={`logo ${escuro ? 'escuro' : ''} ${className}`} style={style} aria-label="Orbeo" role="img">
      <Simbolo escuro={escuro} />
      <span aria-hidden="true">Orbeo</span>
    </span>
  )
}
