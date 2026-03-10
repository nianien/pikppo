import { useEffect, useState, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { VoicePreview } from '../components/VoicePreview'
import type { Drama } from '../types/asr-model'
import { fetchJson } from '../utils/api'

export function CastingPage() {
  const { dramaId } = useParams<{ dramaId: string }>()
  const navigate = useNavigate()
  const [dramas, setDramas] = useState<Drama[]>([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    try {
      const data = await fetchJson<{ items: Drama[] }>('/dramas')
      setDramas(data.items ?? [])
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { load() }, [load])

  if (loading) {
    return (
      <div className="h-full bg-[#0c0e14] flex items-center justify-center">
        <div className="w-32 h-4 rounded bg-gray-800 animate-pulse" />
      </div>
    )
  }

  const id = dramaId ? Number(dramaId) : NaN
  const currentDrama = Number.isNaN(id) ? dramas[0] : dramas.find(d => d.id === id)
  const dramaNames = dramas.map(d => d.name)

  return (
    <div className="h-full flex flex-col bg-gray-900 text-gray-100">
      <VoicePreview
        onBack={() => dramaId ? navigate(`/drama/${dramaId}`) : navigate('/')}
        dramas={dramaNames}
        initialDrama={currentDrama?.name ?? ''}
      />
    </div>
  )
}
