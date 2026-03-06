/** Pipeline Store: phase status, gate status, SSE run, log streaming */
import { create } from 'zustand'
import type { PhaseStatus, GateStatus, StageInfo, PipelineStatusResponse } from '../types/pipeline'
import { PHASE_NAMES } from '../types/pipeline'
import { fetchJson } from '../utils/api'

// ---- Action derivation ----

export type ActionKind = 'start' | 'resume' | 'pass_gate' | 'retry'

export interface WorkflowAction {
  label: string
  kind: ActionKind
  gateKey?: string     // for pass_gate
  fromPhase?: string   // for retry
}

function deriveAction(phases: PhaseStatus[], gates: GateStatus[]): WorkflowAction | null {
  if (phases.some(p => p.status === 'running')) return null

  // All done
  if (phases.every(p => p.status === 'succeeded' || p.status === 'skipped')
      && gates.every(g => g.status === 'passed')) return null

  // Gate awaiting → pass gate
  const awaitingGate = gates.find(g => g.status === 'awaiting')
  if (awaitingGate) return { label: '继续', kind: 'pass_gate', gateKey: awaitingGate.key }

  // Failed → retry from failed phase
  const failedPhase = phases.find(p => p.status === 'failed')
  if (failedPhase) return { label: '重试', kind: 'retry', fromPhase: failedPhase.name }

  // Some succeeded → resume
  if (phases.some(p => p.status === 'succeeded')) return { label: '继续', kind: 'resume' }

  // Nothing started
  return { label: '开始', kind: 'start' }
}

// ---- Store ----

interface PipelineState {
  phases: PhaseStatus[]
  gates: GateStatus[]
  stages: StageInfo[]
  isRunning: boolean
  logs: string[]
  runError: string | null
  currentAction: WorkflowAction | null

  // Actions
  loadStatus: (drama: string, ep: string) => Promise<void>
  _fetchStatus: (drama: string, ep: string) => Promise<void>
  _startPolling: () => void
  _stopPolling: () => void
  runPipeline: (drama: string, ep: string, fromPhase?: string) => Promise<void>
  passGate: (drama: string, ep: string, gateKey: string) => Promise<void>
  executeAction: (drama: string, ep: string) => Promise<void>
  _connectStream: (drama: string, ep: string) => Promise<void>
  cancelRun: () => void
  clearLogs: () => void
}

const defaultPhases: PhaseStatus[] = PHASE_NAMES.map(name => ({
  name,
  label: '',
  status: 'pending' as const,
  started_at: null,
  finished_at: null,
  skipped: false,
  metrics: {},
  error: null,
}))

const defaultGates: GateStatus[] = []
const defaultStages: StageInfo[] = [
  { key: 'extract',   label: '提取', phases: ['extract'],        status: 'pending' },
  { key: 'recognize', label: '识别', phases: ['asr', 'parse'], status: 'pending' },
  { key: 'translate', label: '翻译', phases: ['mt', 'align'],    status: 'pending' },
  { key: 'dub',       label: '配音', phases: ['tts', 'mix'],     status: 'pending' },
  { key: 'compose',   label: '合成', phases: ['burn'],           status: 'pending' },
]

// AbortController for current SSE connection
let _abortController: AbortController | null = null
// Track current drama/ep for re-fetching status
let _currentDrama = ''
let _currentEp = ''
// Polling timer for auto-refresh
let _pollTimer: ReturnType<typeof setInterval> | null = null

export const usePipelineStore = create<PipelineState>((set, get) => ({
  phases: defaultPhases,
  gates: defaultGates,
  stages: defaultStages,
  isRunning: false,
  logs: [],
  runError: null,
  currentAction: deriveAction(defaultPhases, defaultGates),

  loadStatus: async (drama, ep) => {
    _currentDrama = drama
    _currentEp = ep
    // Reset to all-pending to prevent stale action when switching episodes
    set({
      phases: defaultPhases,
      gates: defaultGates,
      stages: defaultStages,
      currentAction: deriveAction(defaultPhases, defaultGates),
    })
    await get()._fetchStatus(drama, ep)
    // Start polling
    get()._startPolling()
  },

  _fetchStatus: async (drama, ep) => {
    try {
      const data = await fetchJson<PipelineStatusResponse>(
        `/episodes/${encodeURIComponent(drama)}/${encodeURIComponent(ep)}/pipeline/status`,
      )
      const gates = data.gates ?? []
      const stages = data.stages ?? []
      set({
        phases: data.phases,
        gates,
        stages,
        currentAction: deriveAction(data.phases, gates),
      })
    } catch {
      // keep current state on fetch error
    }
  },

  _startPolling: () => {
    if (_pollTimer) clearInterval(_pollTimer)
    _pollTimer = setInterval(() => {
      if (_currentDrama && _currentEp) {
        get()._fetchStatus(_currentDrama, _currentEp)
      }
    }, 2000)
  },

  _stopPolling: () => {
    if (_pollTimer) {
      clearInterval(_pollTimer)
      _pollTimer = null
    }
  },

  runPipeline: async (drama, ep, fromPhase?) => {
    // Only abort SSE, do NOT send cancel (would race with the run request)
    if (_abortController) {
      _abortController.abort()
      _abortController = null
    }

    _currentDrama = drama
    _currentEp = ep

    set({ isRunning: true, logs: [], runError: null })

    const body: Record<string, string> = {}
    if (fromPhase) body.from_phase = fromPhase

    // Step 1: Submit pipeline tasks to DB
    try {
      const res = await fetch(
        `/api/episodes/${encodeURIComponent(drama)}/${encodeURIComponent(ep)}/pipeline/run`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        },
      )
      if (!res.ok) {
        const text = await res.text()
        set({ isRunning: false, runError: `API ${res.status}: ${text}` })
        return
      }
    } catch (err) {
      set({ runError: (err as Error).message, isRunning: false })
      return
    }

    // Step 2: Connect SSE stream
    await get()._connectStream(drama, ep)
  },

  passGate: async (drama, ep, gateKey) => {
    // Only abort SSE, do NOT cancel pipeline (would delete the gate task)
    if (_abortController) {
      _abortController.abort()
      _abortController = null
    }

    _currentDrama = drama
    _currentEp = ep
    set({ isRunning: true, logs: [], runError: null })

    // Step 1: Pass the gate (backend reactor creates next task)
    try {
      const res = await fetch(
        `/api/episodes/${encodeURIComponent(drama)}/${encodeURIComponent(ep)}/pipeline/gate/${encodeURIComponent(gateKey)}/pass`,
        { method: 'POST' },
      )
      if (!res.ok) {
        const text = await res.text()
        set({ isRunning: false, runError: `API ${res.status}: ${text}` })
        return
      }
    } catch (err) {
      set({ runError: (err as Error).message, isRunning: false })
      return
    }

    // Step 2: Connect SSE stream to watch progress (no submit needed, reactor already enqueued)
    await get()._connectStream(drama, ep)
  },

  executeAction: async (drama, ep) => {
    const action = get().currentAction
    if (!action) return
    switch (action.kind) {
      case 'pass_gate':
        if (action.gateKey) await get().passGate(drama, ep, action.gateKey)
        break
      case 'retry':
        await get().runPipeline(drama, ep, action.fromPhase)
        break
      case 'start':
      case 'resume':
        await get().runPipeline(drama, ep)
        break
    }
  },

  _connectStream: async (drama, ep) => {
    _abortController = new AbortController()
    const { signal } = _abortController

    try {
      const res = await fetch(
        `/api/episodes/${encodeURIComponent(drama)}/${encodeURIComponent(ep)}/pipeline/stream`,
        { signal },
      )

      if (!res.ok) {
        const text = await res.text()
        set({ isRunning: false, runError: `SSE ${res.status}: ${text}` })
        return
      }

      const reader = res.body?.getReader()
      if (!reader) {
        set({ isRunning: false, runError: 'No response stream' })
        return
      }

      const decoder = new TextDecoder()
      let buffer = ''

      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split('\n')
        buffer = lines.pop() ?? ''

        let currentEvent = ''
        for (const line of lines) {
          if (line.startsWith('event: ')) {
            currentEvent = line.slice(7)
          } else if (line.startsWith('data: ')) {
            const dataStr = line.slice(6)
            try {
              const data = JSON.parse(dataStr)

              if (currentEvent === 'error') {
                set({ runError: data.message, isRunning: false })
                await get().loadStatus(drama, ep)
                return
              }

              if (currentEvent === 'gate_awaiting') {
                await get().loadStatus(drama, ep)
                set({ isRunning: false })
                return
              }

              if (currentEvent.startsWith('pipeline_')) {
                const result = currentEvent.replace('pipeline_', '')
                if (result === 'failed') {
                  set({ runError: 'Pipeline failed' })
                }
                set({ isRunning: false })
                await get().loadStatus(drama, ep)
                return
              }

              // Task status events
              if (data.type) {
                get().loadStatus(drama, ep)
              }
            } catch {
              // Ignore malformed JSON
            }
            currentEvent = ''
          }
        }
      }

      set({ isRunning: false })
      await get().loadStatus(drama, ep)
    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        set(s => ({ logs: [...s.logs, 'Pipeline stopped'], isRunning: false }))
      } else {
        set({ runError: (err as Error).message, isRunning: false })
      }
      get().loadStatus(drama, ep)
    } finally {
      _abortController = null
    }
  },

  cancelRun: () => {
    if (_abortController) {
      _abortController.abort()
      _abortController = null
    }
    // Also tell backend to kill the process
    if (_currentDrama && _currentEp) {
      fetch(
        `/api/episodes/${encodeURIComponent(_currentDrama)}/${encodeURIComponent(_currentEp)}/pipeline/cancel`,
        { method: 'POST' },
      ).catch(() => {})
    }
    set({ isRunning: false })
  },

  clearLogs: () => set({ logs: [], runError: null }),
}))
