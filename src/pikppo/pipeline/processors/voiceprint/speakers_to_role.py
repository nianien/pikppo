"""
Speaker-to-Role 声线分配（两层映射）

数据流：
  speakers_to_role.json (剧集级)  →  role_to_voice.json (剧级)
  spk_1 → "Ping_An"              →  voice_type: "en_male_..."

提供两个核心函数：
- update_speakers_to_role(): Sub 阶段完成后自动填充 speaker 列表
- resolve_voice_assignments(): TTS 阶段解析 speaker → voice_type 映射
"""
import json
from pathlib import Path
from typing import Dict, List, Any, Optional

from pikppo.utils.logger import info


def update_speakers_to_role(
    speakers: List[str],
    file_path: str,
) -> None:
    """
    更新 speakers_to_role.json（只添加新 speaker，不覆盖已有赋值）。

    Args:
        speakers: 本集发现的 speaker 列表（如 ["spk_1", "spk_2"]）
        file_path: speakers_to_role.json 路径
    """
    path = Path(file_path)

    # 读取已有文件或初始化空结构
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = {
            "schema": "speaker_to_role.v1",
            "speakers": {},
            "default_role": "",
        }

    speaker_map = data.setdefault("speakers", {})

    # 只添加新 speaker（保留已有赋值）
    added = []
    for spk in speakers:
        if spk not in speaker_map:
            speaker_map[spk] = ""
            added.append(spk)

    # 原子写入
    tmp_path = path.with_suffix(".tmp")
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    tmp_path.replace(path)

    if added:
        info(f"speakers_to_role: added {len(added)} new speakers: {added}")
    else:
        info(f"speakers_to_role: no new speakers")


def _load_role_to_voice(role_to_voice_path: str) -> Dict[str, Dict[str, Any]]:
    """
    加载 role_to_voice.json，返回 role_id → entry 映射。
    """
    path = Path(role_to_voice_path)
    if not path.exists():
        return {}

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    result: Dict[str, Dict[str, Any]] = {}
    # 兼容 "voices" 和 "roles" 两种数组名
    entries = data.get("voices") or data.get("roles") or []
    for entry in entries:
        role_id = entry.get("role_id")
        if role_id:
            result[role_id] = entry
    return result


def resolve_voice_assignments(
    file_path: str,
    role_to_voice_path: str,
) -> Dict[str, Dict[str, Any]]:
    """
    解析 speaker → voice_type 映射（两层映射）。

    链路: speaker → role_id → voice_type

    Args:
        file_path: speakers_to_role.json 路径
        role_to_voice_path: role_to_voice.json 路径

    Returns:
        {
          "spk_1": {
            "voice_type": "en_male_campaign_jamal_moon_bigtts",
            "role_id": "Ping_An",
            "params": {},
          },
          ...
        }
    """
    path = Path(file_path)
    if not path.exists():
        return {}

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    speaker_map = data.get("speakers", {})
    default_role = data.get("default_role", "")

    if not speaker_map:
        return {}

    # 加载 role_to_voice 映射
    role_map = _load_role_to_voice(role_to_voice_path)

    result: Dict[str, Dict[str, Any]] = {}
    for speaker, role_id in speaker_map.items():
        # 未赋值的 speaker 使用 default_role
        effective_role = role_id if role_id else default_role
        if not effective_role:
            info(f"speakers_to_role: speaker '{speaker}' has no role assigned, skipping")
            continue

        # role_id → voice entry from role_to_voice.json
        role_entry = role_map.get(effective_role)
        if not role_entry:
            info(f"speakers_to_role: role '{effective_role}' not found in role_to_voice.json for speaker '{speaker}'")
            continue

        voice_type = role_entry.get("voice_type", "")
        if not voice_type:
            info(f"speakers_to_role: role '{effective_role}' has no voice_type in role_to_voice.json")
            continue

        result[speaker] = {
            "voice_type": voice_type,
            "role_id": effective_role,
            "params": role_entry.get("params", {}),
        }

    return result
