import type { Cue } from '../types/asr-model'

export function deriveSpeakers(cues: Cue[]): number[] {
  const seen = new Set<number>()
  const result: number[] = []
  for (const cue of cues) {
    if (!seen.has(cue.speaker)) {
      seen.add(cue.speaker)
      result.push(cue.speaker)
    }
  }
  return result
}
