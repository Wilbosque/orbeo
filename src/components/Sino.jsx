import { useEffect, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import * as api from '#backend'
import Icone from './Icone.jsx'

const EVENTO = 'orbeo-notificacoes'
export const avisarMudancaNotificacoes = () => window.dispatchEvent(new Event(EVENTO))

/** Quantidade de notificações não lidas, atualizada ao navegar, ao voltar para o app e a cada 2 minutos */
export function useNaoLidas() {
  const [n, setN] = useState(0)
  const loc = useLocation()
  useEffect(() => {
    let vivo = true
    const ler = () => api.contarNaoLidas().then(x => vivo && setN(x)).catch(() => {})
    ler()
    const t = setInterval(ler, 120_000)
    const vis = () => document.visibilityState === 'visible' && ler()
    window.addEventListener(EVENTO, ler); document.addEventListener('visibilitychange', vis)
    return () => { vivo = false; clearInterval(t); window.removeEventListener(EVENTO, ler); document.removeEventListener('visibilitychange', vis) }
  }, [loc.pathname])
  return n
}

export const Contador = ({ n }) => n > 0 ? <span className="contador" aria-label={`${n} não lidas`}>{n > 99 ? '99+' : n}</span> : null

/** Sino para o topo das telas no celular */
export default function Sino() {
  const n = useNaoLidas()
  return (
    <Link to="/notificacoes" className="icone-btn sino-btn" aria-label={n ? `Notificações, ${n} não lidas` : 'Notificações'}>
      <Icone nome="sino" /><Contador n={n} />
    </Link>
  )
}
