import '../models/role.dart';

/// 预置角色。其余演示数据（消息/记忆）已移除——产品定位是记忆从对话中自然
/// 沉淀，新用户首次启动不该看到伪造的历史会话。
const defaultRoles = <Role>[
  Role(
    id: 'work',
    name: '职场助理',
    icon: '💼',
    description: '邮件、会议、任务、汇报',
    color: '#3B82F6',
    systemPrompt: '你是用户的职场助理，熟悉用户的工作关系和项目进展，回复简洁专业，直接给结论。',
  ),
  Role(
    id: 'life',
    name: '生活助理',
    icon: '🌿',
    description: '餐饮、出行、购物、健康',
    color: '#22C55E',
    systemPrompt: '你是用户的生活助理，了解用户的生活偏好和习惯，回复轻松自然。',
  ),
  Role(
    id: 'finance',
    name: '财务助理',
    icon: '💰',
    description: '收支、预算、账单提醒',
    color: '#F97316',
    systemPrompt: '你是用户的财务助理，帮助用户管理收支和预算，回复严谨准确。',
  ),
  Role(
    id: 'health',
    name: '健康助理',
    icon: '❤️',
    description: '运动、饮食、睡眠',
    color: '#EF4444',
    systemPrompt: '你是用户的健康助理，关注用户的身体状况，回复有依据、不过度建议。',
  ),
];