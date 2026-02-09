"""
字典加载器（Dictionary Loader）

职责：
- 统一加载 dub/dict/ 目录下的所有字典文件
- 实现优先级：names.json（最高）→ slang.json → 其他
- 提供轻量校验接口（glossary violation check）
"""
import json
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from pikppo.utils.logger import info, warning


class DictLoader:
    """字典加载器（统一管理所有字典）"""
    
    def __init__(self, dict_dir: Path):
        """
        初始化字典加载器。
        
        Args:
            dict_dir: dub/dict 目录路径
        """
        self.dict_dir = dict_dir
        self.names: Dict[str, str] = {}  # {中文名: 英文名}
        self.slang: Dict[str, str] = {}  # {中文术语: 英文翻译}
        self._load_all()
    
    def _load_all(self):
        """加载所有字典文件（按优先级顺序）"""
        # 1. 加载 names.json（最高优先级）
        names_path = self.dict_dir / "names.json"
        if names_path.exists():
            try:
                with open(names_path, "r", encoding="utf-8") as f:
                    self.names = json.load(f)
                info(f"Loaded names dictionary: {len(self.names)} entries from {names_path}")
            except Exception as e:
                warning(f"Failed to load names.json from {names_path}: {e}")
        else:
            info(f"Names dictionary not found: {names_path}, using empty dict")
        
        # 2. 加载 slang.json（次高优先级）
        slang_path = self.dict_dir / "slang.json"
        if slang_path.exists():
            try:
                with open(slang_path, "r", encoding="utf-8") as f:
                    self.slang = json.load(f)
                info(f"Loaded slang dictionary: {len(self.slang)} entries from {slang_path}")
            except Exception as e:
                warning(f"Failed to load slang.json from {slang_path}: {e}")
        else:
            info(f"Slang dictionary not found: {slang_path}, using empty dict")
    
    def resolve_name(self, src_name: str) -> Optional[str]:
        """
        解析人名（从 names.json）。

        Args:
            src_name: 中文人名

        Returns:
            英文名或 None（如果不存在）
        """
        entry = self.names.get(src_name)
        if entry is None:
            return None
        if isinstance(entry, dict):
            return entry.get("target")
        return str(entry)
    
    def has_name(self, src_name: str) -> bool:
        """检查人名是否在字典中"""
        return src_name in self.names
    
    def add_name(self, src_name: str, target: str) -> bool:
        """
        添加人名到字典（first-write-wins）。
        
        Args:
            src_name: 中文人名
            target: 英文名
        
        Returns:
            True 表示添加成功，False 表示已存在（不覆盖）
        """
        if src_name in self.names:
            return False  # 已存在，不覆盖
        
        self.names[src_name] = target
        return True
    
    def save_names(self):
        """保存 names.json"""
        names_path = self.dict_dir / "names.json"
        names_path.parent.mkdir(parents=True, exist_ok=True)
        with open(names_path, "w", encoding="utf-8") as f:
            json.dump(self.names, f, indent=2, ensure_ascii=False)
        info(f"Saved names dictionary: {len(self.names)} entries to {names_path}")
    
    def get_slang_glossary_text(self) -> str:
        """
        获取 slang 词表文本（用于 prompt，作为"必须遵守的术语表"）。
        
        Returns:
            格式化的词表字符串（用于 System Prompt）
        """
        if not self.slang:
            return ""
        
        lines = []
        for zh_term, en_translation in sorted(self.slang.items()):
            lines.append(f"{zh_term} -> {en_translation}")
        
        return "\n".join(lines)
    
    def check_glossary_violation(self, src_text: str, out_text: str) -> List[str]:
        """
        检查 glossary 违反情况（轻量校验）。
        
        Args:
            src_text: 源文本（中文）
            out_text: 输出文本（英文）
        
        Returns:
            违反的术语列表（空列表表示无违反）
        
        规则：如果源文本包含 glossary key，但输出文本不包含对应 value，则视为违反。
        """
        violations = []
        out_lower = out_text.lower()
        
        for zh_term, en_translation in self.slang.items():
            if zh_term in src_text:
                # 源文本包含术语，检查输出是否包含对应翻译
                en_lower = en_translation.lower()
                # 检查是否包含（允许部分匹配，如 "three of a kind" 包含 "three"）
                if en_lower not in out_lower:
                    violations.append(f"{zh_term} -> {en_translation}")
        
        return violations
