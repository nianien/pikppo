/** Pinyin initial matching for Chinese character search */
import { pinyin } from 'pinyin-pro'

/**
 * Get first-letter initials for a text.
 * pinyin-pro returns multi-char initials like 'zh','ch','sh' —
 * we take only the first letter of each so "张三" → "zs" not "zhs".
 * Non-Chinese chars pass through as-is (lowercased).
 */
function getFirstLetters(text: string): string {
  return pinyin(text, { pattern: 'initial', toneType: 'none', type: 'array' })
    .map(s => s.charAt(0).toLowerCase())
    .join('')
}

/**
 * Match text against query, supporting:
 * 1. Direct substring match (case-insensitive)
 * 2. Pinyin first-letter match: "zs" matches "张三", "ls" matches "李四"
 */
export function matchPinyin(text: string, query: string): boolean {
  if (!query) return true
  const q = query.toLowerCase()
  // Direct substring match (Chinese chars etc.)
  if (text.toLowerCase().includes(q)) return true
  // Pinyin first-letter match — must be prefix (left-anchored)
  // e.g. "吴翠芳" → "wcf", query "w"/"wc"/"wcf" match, but "c"/"cf" don't
  const initials = getFirstLetters(text)
  return initials.startsWith(q)
}
