import { useEffect, useState, useCallback, useRef } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import type { Drama, Episode, PaginatedResponse } from '../types/asr-model'
import { fetchJson, putJson, uploadFile } from '../utils/api'
import { timeAgo } from '../utils/time-ago'
import { EpisodeTab } from '../components/EpisodeTab'
import { VoicePreview } from '../components/VoicePreview'
import { GlossaryPanel } from '../components/GlossaryPanel'

type Tab = 'episodes' | 'casting' | 'glossary'

const TABS: { key: Tab; label: string }[] = [
  { key: 'episodes', label: '剧集' },
  { key: 'casting', label: '角色管理' },
  { key: 'glossary', label: '术语表' },
]

export function DramaDetailPage() {
  const { dramaId } = useParams<{ dramaId: string }>()
  const navigate = useNavigate()
  const [drama, setDrama] = useState<Drama | null>(null)
  const [episodes, setEpisodes] = useState<Episode[]>([])
  const [loading, setLoading] = useState(true)
  const [tab, setTab] = useState<Tab>('episodes')

  // Synopsis editing
  const [editingSynopsis, setEditingSynopsis] = useState(false)
  const [synopsisText, setSynopsisText] = useState('')
  const [savingSynopsis, setSavingSynopsis] = useState(false)

  // Cover upload
  const coverInputRef = useRef<HTMLInputElement>(null)
  const [uploadingCover, setUploadingCover] = useState(false)
  const [synopsisExpanded, setSynopsisExpanded] = useState(false)

  const load = useCallback(async () => {
    try {
      const [dramasRes, allEpisodes] = await Promise.all([
        fetchJson<PaginatedResponse<Drama>>(`/dramas?search=&page_size=1000`),
        fetchJson<Episode[]>('/episodes'),
      ])
      const id = Number(dramaId)
      setDrama(dramasRes.items.find(d => d.id === id) ?? null)
      setEpisodes(allEpisodes.filter(e => e.drama_id === id))
    } finally {
      setLoading(false)
    }
  }, [dramaId])

  useEffect(() => { load() }, [load])

  const handleSaveSynopsis = async () => {
    if (!dramaId) return
    setSavingSynopsis(true)
    try {
      await putJson(`/dramas/${dramaId}`, { synopsis: synopsisText })
      setEditingSynopsis(false)
      await load()
    } finally {
      setSavingSynopsis(false)
    }
  }

  const handleCoverUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file || !dramaId) return
    setUploadingCover(true)
    try {
      await uploadFile(`/dramas/${dramaId}/cover`, file)
      await load()
    } finally {
      setUploadingCover(false)
      if (coverInputRef.current) coverInputRef.current.value = ''
    }
  }

  const cover = drama?.cover_image || null

  // Stats for header
  const doneCount = episodes.filter(e => e.status === 'succeeded' || e.dubbed_video).length
  const progress = episodes.length > 0 ? Math.round((doneCount / episodes.length) * 100) : 0

  if (loading) {
    return (
      <div className="min-h-full bg-[#0c0e14]">
        <div className="px-8 py-8">
          <div className="w-48 h-7 rounded bg-gray-800 animate-pulse mb-8" />
          <div className="space-y-3">
            {[1,2,3].map(i => <div key={i} className="h-16 rounded-xl bg-[#1a1d28] animate-pulse" />)}
          </div>
        </div>
      </div>
    )
  }

  if (!drama) {
    return (
      <div className="min-h-full bg-[#0c0e14] text-gray-100">
        <div className="px-8 py-16 text-center">
          <p className="text-gray-500">未找到该项目</p>
          <button onClick={() => navigate('/')} className="mt-4 text-sm text-gray-400 hover:text-gray-200 transition-colors">
            返回项目列表
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-full bg-[#0c0e14] text-gray-100">
      <div className="px-8 py-6">
        {/* Breadcrumb */}
        <div className="flex items-center gap-2 mb-6 text-sm">
          <button
            onClick={() => navigate('/')}
            className="text-gray-500 hover:text-gray-300 transition-colors"
          >
            项目
          </button>
          <span className="text-gray-700">/</span>
          <span className="font-medium truncate">{drama.name}</span>
        </div>

        {/* Project info card */}
        <div className="flex items-stretch gap-6 mb-6">
          {/* Cover — 竖版海报 2:3 比例 */}
          <button
            onClick={() => coverInputRef.current?.click()}
            disabled={uploadingCover}
            className="relative w-[140px] h-[210px] rounded-xl overflow-hidden shrink-0 group cursor-pointer"
          >
            {cover ? (
              <img
                src={cover}
                alt={drama.name}
                className="w-full h-full object-cover"
              />
            ) : (
              <div className="w-full h-full bg-gradient-to-br from-blue-600/40 via-violet-600/30 to-indigo-600/20 flex flex-col items-center justify-center gap-2">
                <span className="text-4xl font-bold text-white/80">{drama.name[0]}</span>
                <span className="text-[10px] text-white/40">点击上传封面</span>
              </div>
            )}
            <div className="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
              <span className="text-xs text-white/90 font-medium">
                {uploadingCover ? '上传中...' : cover ? '更换封面' : '上传封面'}
              </span>
            </div>
          </button>
          <input
            ref={coverInputRef}
            type="file"
            accept="image/jpeg,image/png,image/webp"
            onChange={handleCoverUpload}
            className="hidden"
          />

          <div className="flex-1 min-w-0 py-1 flex flex-col">
            {/* Title + edit button */}
            <div className="flex items-center gap-2 mb-2">
              <h1 className="text-2xl font-bold tracking-tight">{drama.name}</h1>
              {!editingSynopsis && (
                <button
                  onClick={() => { setSynopsisText(drama.synopsis ?? ''); setEditingSynopsis(true) }}
                  className="p-1.5 rounded-lg text-gray-600 hover:text-gray-300 hover:bg-white/[0.06] transition-colors shrink-0"
                  title="编辑简介"
                >
                  <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125M18 14v4.75A2.25 2.25 0 0 1 15.75 21H5.25A2.25 2.25 0 0 1 3 18.75V8.25A2.25 2.25 0 0 1 5.25 6H10" />
                  </svg>
                </button>
              )}
            </div>

            {/* Synopsis */}
            <div className="flex-1 min-h-0">
              {editingSynopsis ? (
                <div className="flex items-start gap-2">
                  <textarea
                    autoFocus
                    value={synopsisText}
                    onChange={e => setSynopsisText(e.target.value)}
                    onKeyDown={e => {
                      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSaveSynopsis() }
                      if (e.key === 'Escape') setEditingSynopsis(false)
                    }}
                    rows={4}
                    className="flex-1 px-3 py-2 text-sm rounded-lg bg-[#0a0b10] border border-white/10 outline-none focus:border-blue-500/60 focus:ring-1 focus:ring-blue-500/20 resize-none placeholder:text-gray-600"
                    placeholder="输入内容简介..."
                  />
                  <div className="flex flex-col gap-1.5 shrink-0">
                    <button
                      onClick={handleSaveSynopsis}
                      disabled={savingSynopsis}
                      className="h-8 px-3 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-500 disabled:opacity-40 transition-colors"
                    >
                      {savingSynopsis ? '...' : '保存'}
                    </button>
                    <button
                      onClick={() => setEditingSynopsis(false)}
                      className="h-8 px-2 text-xs rounded-lg text-gray-400 hover:text-gray-200 hover:bg-white/[0.04] transition-colors"
                    >
                      取消
                    </button>
                  </div>
                </div>
              ) : drama.synopsis ? (
                <div>
                  <p className={`text-sm text-gray-500 transition-colors ${synopsisExpanded ? '' : 'line-clamp-2'}`}>
                    {drama.synopsis}
                  </p>
                  <button
                    onClick={() => setSynopsisExpanded(!synopsisExpanded)}
                    className="mt-1 text-xs text-gray-600 hover:text-gray-400 transition-colors"
                  >
                    {synopsisExpanded ? '收起' : '展开'}
                  </button>
                </div>
              ) : (
                <button
                  onClick={() => { setSynopsisText(''); setEditingSynopsis(true) }}
                  className="text-sm text-gray-600 hover:text-gray-400 transition-colors"
                >
                  + 添加简介
                </button>
              )}
            </div>

            {/* Meta info */}
            <p className="text-xs text-gray-500 mt-auto pt-2">
              {episodes.length} 集
              {progress > 0 && ` \u00B7 ${progress}% 已完成`}
              {drama.updated_at && ` \u00B7 更新于 ${timeAgo(drama.updated_at)}`}
            </p>
          </div>
        </div>

        {/* Tab bar */}
        <div className="flex gap-1 mb-6 border-b border-white/[0.06]">
          {TABS.map(t => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`px-4 py-2 text-sm font-medium transition-colors relative ${
                tab === t.key
                  ? 'text-white'
                  : 'text-gray-500 hover:text-gray-300'
              }`}
            >
              {t.label}
              {tab === t.key && (
                <span className="absolute bottom-0 left-0 right-0 h-0.5 bg-blue-500 rounded-t" />
              )}
            </button>
          ))}
        </div>

        {/* Tab content */}
        {tab === 'episodes' && (
          <EpisodeTab drama={drama} episodes={episodes} onRefresh={load} />
        )}
        {tab === 'casting' && (
          <div className="h-[calc(100vh-260px)]">
            <VoicePreview embedded initialDrama={drama.name} />
          </div>
        )}
        {tab === 'glossary' && (
          <GlossaryPanel dramaId={drama.id} dramaName={drama.name} />
        )}
      </div>
    </div>
  )
}
