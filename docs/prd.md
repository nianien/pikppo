```
你是一个资深Flutter工程师。请帮我开发一个名为「Private Butler」的私人AI助理App原型。

## 技术栈
- Flutter + Dart
- shared_preferences（本地存储）
- go_router（导航）
- UI组件：Flutter Material 3 原生组件
- dio（HTTP客户端，用于调用本地模型API）
- flutter_riverpod（状态管理）

## 产品背景
这是一个私人AI助理App，核心理念是：
- 个人记忆本地存储，切换模型上下文不丢失
- 多角色体系（职场/生活/财务等），通过@符号切换
- 统一对话框作为唯一入口
- 支持本地模型接入（Ollama / LM Studio），数据不出本地

## 数据结构（Dart类型）

class Role {
  final String id;
  final String name;
  final String icon;
  final String description;
  final String color;
  final String systemPrompt;
}

class Message {
  final String id;
  final String roleId;
  final String content;
  final bool isUser;
  final int timestamp;
}

class Memory {
  final String id;
  final String type; // 'semantic' | 'episodic' | 'working'
  final String content;
  final String? roleId;
  final int timestamp;
  final List<String> tags;
}

class AppState {
  final List<Role> roles;
  final List<Message> messages;
  final List<Memory> memories;
  final String currentRoleId;
  final String currentModel;
  final String serviceType; // 'ollama' | 'lmstudio'
  final String serviceHost;
}

## 需要实现的页面和功能

### 1. 主对话页（HomeScreen）
- 顶部：App名称「Butler」+ 当前角色标签 + 模型切换按钮
- 中间：消息流列表
  - 用户消息（右对齐，深色气泡）
  - AI消息（左对齐，浅色气泡，带角色头像和角色名称）
  - AI思考中状态：气泡内显示「...」动画
- 底部：输入框
  - 占位符文字：「输入或 @ 切换角色…」
  - 发送按钮
  - 输入@时弹出角色选择浮层

### 2. @角色切换浮层
- 输入@后从底部弹出（showModalBottomSheet）
- 展示所有角色列表：职场、生活、财务、健康、自定义
- 每个角色有图标、名称、一句话描述
- 点击选中角色，浮层关闭，输入框前缀显示@角色名

### 3. 角色管理页（RolesScreen）
- 展示所有角色卡片
- 每个卡片：角色图标、名称、描述、最近对话时间
- 点击进入该角色的专属对话历史
- 底部「+新建角色」按钮

### 3.1 新建角色页（CreateRoleScreen）
- 基本信息：
  - 角色名称（文本输入框）
  - 角色图标（emoji选择器，预设20个常用emoji供选择）
  - 角色颜色（色块选择器，预设8个颜色）
  - 角色描述（一句话，文本输入框）

- 角色画像（用于生成Prompt的关键信息）：
  - 专注领域（多选标签）：
    预设选项：工作汇报 / 邮件撰写 / 会议记录 / 财务分析 /
    健康管理 / 旅行规划 / 学习辅导 / 育儿咨询 / 法律常识 / 自定义输入
  - 回复风格（单选）：
    简洁直接 / 详细周全 / 轻松幽默 / 严谨专业
  - 回复语言（单选）：
    中文 / 英文 / 中英混合
  - 特别说明（选填，自由文本）：
    如「不要给我列清单，直接说结论」「回复控制在100字以内」

- 底部「生成角色Prompt」按钮
  - 点击后调用本地模型，根据以上信息自动生成 systemPrompt
  - 生成中显示 loading 状态
  - 生成完成后在页面下方展示生成结果（可编辑的文本框）
  - 用户可以直接编辑修改生成的 Prompt
  - 确认后点击「保存角色」完成创建

- 生成Prompt时发送给模型的指令：
  「请根据以下信息，为一个AI助理角色生成一段简洁的系统提示词（system prompt），
  要求：用第一人称，明确角色定位，体现回复风格，100-150字以内，中文。

  角色名称：{name}
  专注领域：{fields}
  回复风格：{style}
  回复语言：{language}
  特别说明：{notes}」

### 4. 记忆面板页（MemoryScreen）
- 顶部：三个Tab「语义记忆」「情节记忆」「工作记忆」
- 语义记忆：以标签形式展示，如「不吃香菜」「偏好简洁回复」
- 情节记忆：时间线列表，每条有时间、角色标签、内容摘要
- 右上角「+手动添加」按钮
- 每条记忆可左滑删除（Dismissible组件）

### 5. 设置页（SettingsScreen）
- 本地模型配置：
  - 服务类型选择：Ollama / LM Studio（单选RadioButton）
  - 服务地址输入框，默认值：
    - Ollama：http://localhost:11434
    - LM Studio：http://localhost:1234
  - 「检测连接」按钮，点击后请求服务端获取可用模型列表
  - 可用模型下拉列表（从服务端动态拉取，非硬编码）
  - 当前选中模型显示
- 个人信息：姓名、偏好语言
- 数据管理：导出记忆、清除全部记忆

### 6. 底部导航栏（NavigationBar · Material 3）
- 对话（首页）
- 角色
- 记忆
- 设置

## Mock数据
请预置以下mock数据让原型看起来真实：

角色：
- 职场助理（蓝色，💼）：「邮件、会议、任务、汇报」
  systemPrompt：「你是用户的职场助理，熟悉用户的工作关系和项目进展，回复简洁专业，直接给结论。」
- 生活助理（绿色，🌿）：「餐饮、出行、购物、健康」
  systemPrompt：「你是用户的生活助理，了解用户的生活偏好和习惯，回复轻松自然。」
- 财务助理（橙色，💰）：「收支、预算、账单提醒」
  systemPrompt：「你是用户的财务助理，帮助用户管理收支和预算，回复严谨准确。」
- 健康助理（红色，❤️）：「运动、饮食、睡眠」
  systemPrompt：「你是用户的健康助理，关注用户的身体状况，回复有依据、不过度建议。」

对话历史（职场助理）：
- 用户：「@职场 帮我看下今天的会议，重点是什么」
- AI：「今天14:00和张总的会，上次你们聊到Q3预算还有缺口，建议你准备一下方案B」
- 用户：「帮我起草一封邮件给张总，说明预算方案」
- AI：「好的，我来起草。基于上次讨论，缺口约30万……」

语义记忆：
- 「不吃香菜」（饮食）
- 「偏好简洁回复，直接给结论」（偏好）
- 「血压偏高，注意饮食」（健康）

情节记忆：
- 「2天前 · 职场：和张总讨论Q3预算，有缺口约30万」
- 「5天前 · 生活：搜索了附近粤式餐厅」
- 「1周前 · 财务：记录了本月固定支出」

## 本地模型API对接

### Ollama
- 获取模型列表：GET http://{host}/api/tags
- 发送对话：POST http://{host}/api/chat
  请求体：
  {
    "model": "{modelName}",
    "messages": [...],
    "stream": false
  }
  响应取：response.message.content

### LM Studio
- 获取模型列表：GET http://{host}/v1/models
- 发送对话：POST http://{host}/v1/chat/completions
  请求体（OpenAI兼容格式）：
  {
    "model": "{modelName}",
    "messages": [...],
    "stream": false
  }
  响应取：choices[0].message.content

### 统一接口封装
封装 ModelService 抽象类，屏蔽两者差异：

abstract class ModelService {
  Future<List<String>> fetchModels();
  Future<String> chat(List<Map<String, String>> messages);
}

class OllamaService implements ModelService { ... }
class LMStudioService implements ModelService { ... }

根据用户设置，通过 Riverpod Provider 注入对应实例。

### 对话消息构建
每次发送前，按以下顺序构建messages数组：
1. system：role.systemPrompt + 相关记忆拼接
   格式：「{systemPrompt}\n\n以下是关于用户的已知信息：\n{相关语义记忆和近期情节记忆}」
2. history：当前角色的历史消息（最近10条）
3. user：当前输入内容

### 错误处理
- 连接失败：SnackBar 显示「无法连接到本地模型服务，请检查服务是否启动」
- 请求超时：30秒，超时后 AI 气泡显示「请求超时，请重试」
- 响应异常：AI 气泡显示「请求失败，请重试」

## 额外功能：划词问询
- 消息气泡内文字使用 SelectableText 组件
- 通过 contextMenuBuilder 参数注入自定义菜单项「问Butler」
- 点击「问Butler」后自动构建并发送：「请解释一下：{选中文字}」
- 当前角色不变，直接在当前对话中追问，无需用户二次确认

## 交互细节要求
- 对话页发送消息后自动滚动到最新消息（ScrollController）
- 发送消息后输入框清空并保持焦点
- 输入@时键盘不收起，浮层从底部弹出
- 切换角色后消息流只展示该角色的历史记录
- 记忆条目左滑出现红色删除按钮（Dismissible）
- 模型切换后顶部 SnackBar 提示「已切换至 {modelName}」
- AI回复期间发送按钮变为loading状态，禁止重复发送

## 项目结构
lib/
├── main.dart
├── models/
│   ├── role.dart
│   ├── message.dart
│   ├── memory.dart
│   └── app_state.dart
├── screens/
│   ├── home_screen.dart
│   ├── roles_screen.dart
│   ├── create_role_screen.dart
│   ├── memory_screen.dart
│   └── settings_screen.dart
├── widgets/
│   ├── message_bubble.dart
│   ├── role_chip.dart
│   ├── role_selector_sheet.dart
│   ├── memory_tag.dart
│   ├── emoji_picker.dart
│   └── color_picker.dart
├── services/
│   ├── model_service.dart
│   ├── ollama_service.dart
│   └── lmstudio_service.dart
├── providers/
│   ├── app_state_provider.dart
│   ├── model_service_provider.dart
│   └── memory_provider.dart
└── data/
    └── mock_data.dart

## 注意事项
- 重点是交互逻辑正确，视觉风格遵循 Material 3 即可
- 代码结构清晰，方便后续迭代
- 所有文案使用中文
- 请一次性输出完整的所有文件代码，不要省略
- 必须包含完整的 pubspec.yaml，列出所有依赖包及版本号
```