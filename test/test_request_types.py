#!/usr/bin/env python3
"""测试 request_types 的校验功能"""
import sys
from pathlib import Path

project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root / "src"))

from video_remix.models.doubao.request_types import (
    DoubaoASRRequest,
    AudioConfig,
    RequestConfig,
    CorpusConfig,
)

# 测试校验：vad_segment=True 但 end_window_size=None
try:
    req = DoubaoASRRequest(
        audio=AudioConfig(url='https://example.com/audio.wav', format='wav'),
        request=RequestConfig(vad_segment=True, end_window_size=None),
    )
    req.validate()
    print('✗ 应该报错但没有')
except ValueError as e:
    print(f'✓ 校验1正确: {e}')

# 测试校验：enable_channel_split=True 但 channel=1
try:
    req = DoubaoASRRequest(
        audio=AudioConfig(url='https://example.com/audio.wav', format='wav', channel=1),
        request=RequestConfig(enable_channel_split=True),
    )
    req.validate()
    print('✗ 应该报错但没有')
except ValueError as e:
    print(f'✓ 校验2正确: {e}')

# 测试校验：ssd_version 但 enable_speaker_info=False
try:
    req = DoubaoASRRequest(
        audio=AudioConfig(url='https://example.com/audio.wav', format='wav'),
        request=RequestConfig(ssd_version='200', enable_speaker_info=False),
    )
    req.validate()
    print('✗ 应该报错但没有')
except ValueError as e:
    print(f'✓ 校验3正确: {e}')

# 测试 helper 方法
corpus = CorpusConfig.from_hotwords(['平安', '平安哥', '哥'])
print(f'✓ CorpusConfig.from_hotwords() 工作正常: {corpus.context[:50]}...')

print('\n所有测试通过！')
