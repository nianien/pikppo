"""
Speaker-to-Role 声线分配（两层映射）

数据流：
  speaker_to_role.json (剧级，按集分 key)  →  role_cast.json (剧级)
  spk_1 → "Ping_An"                         →  voice_type: "en_male_..."

  未标注的 speaker 按性别兜底：
  default_roles.male / female / unknown → 对应角色 → voice_type

提供两个核心函数：
- update_speaker_to_role(): Sub 阶段完成后自动填充 speaker 列表
- resolve_voice_assignments(): TTS 阶段解析 speaker → voice_type 映射
"""
import json
from pathlib import Path
from typing import Dict, List, Any, Optional

from pikppo.utils.logger import info


def update_speaker_to_role(
    speakers: List[str],
    file_path: str,
    episode_id: str,
) -> None:
    """
    更新 speaker_to_role.json 中某一集的 speaker 列表（只添加新 speaker，不覆盖已有赋值）。

    Args:
        speakers: 本集发现的 speaker 列表（如 ["spk_1", "spk_2"]）
        file_path: speaker_to_role.json 路径（剧级）
        episode_id: 集编号（如 "1"）
    """
    path = Path(file_path)

    # 读取已有文件或初始化空结构
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = {
            "schema": "speaker_to_role.v1.1",
            "episodes": {},
            "default_roles": {
                "male": "",
                "female": "",
                "unknown": "",
            },
        }

    episodes = data.setdefault("episodes", {})
    speaker_map = episodes.setdefault(episode_id, {})

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
        info(f"speaker_to_role[ep={episode_id}]: added {len(added)} new speakers: {added}")
    else:
        info(f"speaker_to_role[ep={episode_id}]: no new speakers")


def _load_role_cast(role_cast_path: str) -> Dict[str, str]:
    """
    加载 role_cast.json，返回 role_id → voice_type 映射。

    格式：{ "roles": { "Ping_An": "en_male_adam_mars_bigtts", ... } }
    """
    path = Path(role_cast_path)
    if not path.exists():
        return {}

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    roles = data.get("roles", {})
    if isinstance(roles, dict):
        return roles

    # 兼容旧数组格式 [{ "role_id": "...", "voice_type": "..." }, ...]
    result: Dict[str, str] = {}
    for entry in roles:
        role_id = entry.get("role_id")
        voice_type = entry.get("voice_type")
        if role_id and voice_type:
            result[role_id] = voice_type
    return result


def resolve_voice_assignments(
    file_path: str,
    role_cast_path: str,
    episode_id: str,
    speaker_genders: Optional[Dict[str, str]] = None,
) -> Dict[str, Dict[str, Any]]:
    """
    解析某一集的 speaker → voice_type 映射（两层映射 + 性别兜底）。

    链路:
      已标注: speaker → role_id → voice_type
      未标注: speaker → default_roles[gender] → voice_type

    Args:
        file_path: speaker_to_role.json 路径（剧级）
        role_cast_path: role_cast.json 路径
        episode_id: 集编号（如 "1"）
        speaker_genders: speaker → gender 映射（"male"/"female"/"unknown"）

    Returns:
        {
          "spk_1": {
            "voice_type": "en_male_adam_mars_bigtts",
            "role_id": "Ping_An",
          },
          ...
        }
    """
    path = Path(file_path)
    if not path.exists():
        return {}

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    speaker_map = data.get("episodes", {}).get(episode_id, {})
    # 兼容 v1 (default_role) 和 v1.1 (default_roles)
    default_roles = data.get("default_roles", {})
    if not default_roles:
        old_default = data.get("default_role", "")
        if old_default:
            default_roles = {"male": old_default, "female": old_default, "unknown": old_default}

    if not speaker_map:
        return {}

    genders = speaker_genders or {}
    role_cast = _load_role_cast(role_cast_path)

    result: Dict[str, Dict[str, Any]] = {}
    for speaker, role_id in speaker_map.items():
        # 未赋值的 speaker → 按性别取 default_roles
        if not role_id:
            gender = genders.get(speaker, "unknown")
            role_id = default_roles.get(gender, default_roles.get("unknown", ""))

        if not role_id:
            info(f"speaker_to_role: speaker '{speaker}' has no role assigned, skipping")
            continue

        voice_type = role_cast.get(role_id)
        if not voice_type:
            info(f"speaker_to_role: role '{role_id}' not found in role_cast.json for speaker '{speaker}'")
            continue

        result[speaker] = {
            "voice_type": voice_type,
            "role_id": role_id,
        }

    return result
