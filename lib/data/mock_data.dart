import '../models/role.dart';
import '../models/message.dart';
import '../models/memory.dart';

final now = DateTime.now().millisecondsSinceEpoch;
const day = 86400000;

final defaultRoles = <Role>[
  const Role(
    id: 'work',
    name: '职场助理',
    icon: '💼',
    description: '邮件、会议、任务、汇报',
    color: '#3B82F6',
    systemPrompt: '你是用户的职场助理，熟悉用户的工作关系和项目进展，回复简洁专业，直接给结论。',
  ),
  const Role(
    id: 'life',
    name: '生活助理',
    icon: '🌿',
    description: '餐饮、出行、购物、健康',
    color: '#22C55E',
    systemPrompt: '你是用户的生活助理，了解用户的生活偏好和习惯，回复轻松自然。',
  ),
  const Role(
    id: 'finance',
    name: '财务助理',
    icon: '💰',
    description: '收支、预算、账单提醒',
    color: '#F97316',
    systemPrompt: '你是用户的财务助理，帮助用户管理收支和预算，回复严谨准确。',
  ),
  const Role(
    id: 'health',
    name: '健康助理',
    icon: '❤️',
    description: '运动、饮食、睡眠',
    color: '#EF4444',
    systemPrompt: '你是用户的健康助理，关注用户的身体状况，回复有依据、不过度建议。',
  ),
];

final defaultMessages = <Message>[
  Message(
    id: 'm1',
    roleId: 'work',
    content: '@职场 帮我看下今天的会议，重点是什么',
    isUser: true,
    timestamp: now - day * 2 - 3600000,
  ),
  Message(
    id: 'm2',
    roleId: 'work',
    content: '今天14:00和张总的会，上次你们聊到Q3预算还有缺口，建议你准备一下方案B',
    isUser: false,
    timestamp: now - day * 2 - 3500000,
  ),
  Message(
    id: 'm3',
    roleId: 'work',
    content: '帮我起草一封邮件给张总，说明预算方案',
    isUser: true,
    timestamp: now - day * 2 - 3000000,
  ),
  Message(
    id: 'm4',
    roleId: 'work',
    content: '好的，我来起草。基于上次讨论，缺口约30万，以下是邮件草稿：\n\n张总您好，\n\n关于Q3预算缺口事宜，经过团队讨论，我们提出以下方案：\n\n方案A：优化现有资源配置，预计可节省15万\n方案B：申请追加预算，同时延后部分非核心项目\n\n建议我们在本周会议上详细讨论。\n\n此致',
    isUser: false,
    timestamp: now - day * 2 - 2900000,
  ),
  Message(
    id: 'm5',
    roleId: 'life',
    content: '附近有什么好吃的粤菜餐厅？',
    isUser: true,
    timestamp: now - day * 5,
  ),
  Message(
    id: 'm6',
    roleId: 'life',
    content: '推荐以下粤菜餐厅：\n\n1. 广州酒家（4.8分）- 距你1.2km\n2. 陶陶居（4.6分）- 距你2.0km\n3. 点都德（4.5分）- 距你0.8km\n\n根据你的记忆，你不吃香菜，我会帮你备注。',
    isUser: false,
    timestamp: now - day * 5 + 60000,
  ),
  Message(
    id: 'm7',
    roleId: 'finance',
    content: '帮我看看这个月的固定支出有哪些',
    isUser: true,
    timestamp: now - day * 7,
  ),
  Message(
    id: 'm8',
    roleId: 'finance',
    content: '本月固定支出汇总：\n\n🏠 房租：5,500元\n📱 手机话费：128元\n🚗 车贷：3,200元\n🏋️ 健身卡：299元\n\n合计：9,127元',
    isUser: false,
    timestamp: now - day * 7 + 60000,
  ),
];

final defaultMemories = <Memory>[
  Memory(
    id: 'mem1',
    type: 'semantic',
    content: '不吃香菜',
    timestamp: now - day * 30,
    tags: ['饮食'],
  ),
  Memory(
    id: 'mem2',
    type: 'semantic',
    content: '偏好简洁回复，直接给结论',
    timestamp: now - day * 20,
    tags: ['偏好'],
  ),
  Memory(
    id: 'mem3',
    type: 'semantic',
    content: '血压偏高，注意饮食',
    timestamp: now - day * 15,
    tags: ['健康'],
  ),
  Memory(
    id: 'mem4',
    type: 'episodic',
    content: '和张总讨论Q3预算，有缺口约30万',
    roleId: 'work',
    timestamp: now - day * 2,
    tags: ['职场', '预算'],
  ),
  Memory(
    id: 'mem5',
    type: 'episodic',
    content: '搜索了附近粤式餐厅',
    roleId: 'life',
    timestamp: now - day * 5,
    tags: ['生活', '餐饮'],
  ),
  Memory(
    id: 'mem6',
    type: 'episodic',
    content: '记录了本月固定支出',
    roleId: 'finance',
    timestamp: now - day * 7,
    tags: ['财务', '支出'],
  ),
  Memory(
    id: 'mem7',
    type: 'working',
    content: '正在准备Q3预算方案B',
    roleId: 'work',
    timestamp: now - day,
    tags: ['进行中'],
  ),
  Memory(
    id: 'mem8',
    type: 'working',
    content: '需要预约下周体检',
    roleId: 'health',
    timestamp: now - day * 3,
    tags: ['待办'],
  ),
];
