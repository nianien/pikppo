# pikppo 数据架构 v3.2

状态:技术方案定稿(不含排期与合规)
取代 v2.x。范围:身份、存储、传输、合并四个解耦子系统的完整技术设计,覆盖三阶段演进(单机 MVP → 账号 + 零知识上云 → 多设备可选)。

v3.1 在 v3.0 基础上的差异(均为只加不改):
- §1 三集合表新增 Roles / Groups 入核心资产集
- §3.3 MemoryItems / SessionSummaries 增 `roleId` 列(支撑产品的"角色专属记忆+情节记忆"按角色归属);CustomRoles / Groups 数据表新增并补齐 S3–S5
- §3.3 kind=event 即"情节记忆",显式归入 MemoryItems(核心资产备份范围)
- §4 新增"提醒路由"小节:事件不带 roleId,提醒触发时端上小模型路由到 1–N 个角色私聊

v3.2 在 v3.1 基础上的差异(只加不改;v3.1 §4 路由协议反转):
- §3.3 `CalendarEvents` 增 `routedRoleId` 列(nullable);事件创建/修改时立即路由并缓存,OS 通知预调度才能在 App 被杀场景下投递到正确角色
- §4 提醒路由由"触发时多角色"改为"**创建时单角色** + 缓存 routedRoleId",路由结果落持久层(可与备份共迁移)
- §4 新增"系统通知预调度"小节:CalendarRepository._afterWriteHook 在写后调用 NotificationService.scheduleFor(event) 注册到 OS AlarmManager / UNUserNotificationCenter,App 被杀也能弹出
- §4 角色重命名/删除时由 Repository 触发 reschedule 未来事件(端上批处理)

---

## 0. 设计原则与脊柱

唯一贯穿原则:**身份 / 存储 / 传输 / 合并彻底解耦,每一期只加不改。**

为此,以下五样从 Phase 1 第一天起存在于数据中,称为**脊柱**。后续每一期的新能力都只挂在脊柱上,不触碰已有层:

| # | 脊柱 | 形态 | 它支撑的未来增量 |
|---|---|---|---|
| S1 | `schema_version` | 库级 PRAGMA user_version + 一切传输包 manifest 必带 | 任意旧包导入新版本(导入适配器),跨版本 handoff |
| S2 | 命名空间化的 opaque `user_id` | `accounts/<user_id>/` 目录 = 一个数据宇宙;Phase 1 为匿名本地 UUID | 账号提升(P2)、多账号隔离(P2)、按账号粒度搬家(P3)、分身(P3) |
| S3 | 行级 UUID 主键 | 客户端生成,禁止自增,全生命周期不变 | 双通道导入并集、跨设备全局身份 |
| S4 | `updatedAt` (UTC) | Repository 写路径统一盖戳 | 行级 LWW 合并 |
| S5 | `deleted` 墓碑 | 只软删不物理删,DAO 统一过滤 | 删除事实穿越备份/导入/同步 |

S3+S4+S5 合起来即每行一个 **LWW 寄存器**——这本身是合法的 state-based CRDT(LWW-Element-Set),意味着 Phase 3 若走同步路线,合并层在现有元数据上**纯增量**生长,无表迁移。

四个子系统的解耦边界:

- **身份**:user_id 是永恒锚;凭证(邮箱/Apple/Google/微信)是绑在锚上的可增删别名,永不做主键。
- **存储**:一个命名空间一个 SQLite,本地是该命名空间数据的唯一真相源;服务端(P2 起)只是它的零知识密文影子。
- **传输**:handoff 直传、导出文件、云备份共用同一**包格式**;通道可插拔,包不变。
- **合并**:导入即合并,规则只有一条(UUID upsert + 行级 LWW + 墓碑同权),与数据来自哪条通道无关。

---

## 1. 数据分类

| 集合 | 内容 | 云备份(P2) | handoff/导出(P1) | 丢失后果 |
|---|---|---|---|---|
| **核心资产集** | 长期记忆 MemoryItems(含情节记忆 kind=event)、日历 CalendarEvents、自定义角色 CustomRoles、群组 Groups、用户设置 Settings | ✅ 零知识自动 | ✅ | P2 起可云恢复 |
| **本地数据集** | 短期记忆 SessionSummaries、聊天记录、媒体 | ❌ | ✅ | 接受丢失 |
| **派生数据** | 向量索引、FTS 索引、缓存 | ❌ | ❌ | 导入后端上重算 |

自定义角色入核心资产集的理由:用户填写画像 + AI 生成 system prompt + 用户编辑确认,是投入劳动的资产;丢机后只恢复了记忆却丢了角色,体验残缺。Groups 同理,且角色 id 跨包仍有效(S3 UUID),群组成员引用不会因恢复断裂。

体量:核心资产集常年个位数 MB;本地数据集含媒体可达 GB(只走直传);派生数据可重算,排除在一切传输之外。

**沉淀窗口规则**:短期记忆经沉淀器压缩进长期记忆。设备丢失的损失 = 未沉淀部分,故沉淀高频(会话结束即沉淀),P2 起沉淀完成触发备份(经变更检测与防抖,见 §7.4)。

**LLM 运行时数据流(范围声明)**:零知识保护的是**服务端静态存储**。运行时记忆仍注入 prompt 发往 LLM 推理端,该数据流不在零知识范围内;检索/RAG/embedding 全部端上执行,服务端永不接触明文记忆。

---

## 2. 身份模型

### 2.1 Phase 1:匿名本地身份

首次启动生成 `user_id = UUID v4`,纯本地,不上送任何服务端。它的唯一职责是命名一个命名空间:`accounts/<user_id>/`。单账号时期这个目录层看似冗余,它是 S2 脊柱——后续一切账号能力的挂载点。

### 2.2 Phase 2:身份提升(升级,非重构)

引入登录,第一凭证为**邮箱无密码**(magic link / 验证码)。服务端身份表:

```sql
CREATE TABLE users (
  user_id    TEXT PRIMARY KEY,       -- 与客户端同一 opaque UUID
  created_at INTEGER NOT NULL,
  status     TEXT NOT NULL           -- active | pending_delete
);
CREATE TABLE credentials (
  credential_id TEXT PRIMARY KEY,    -- 'email:a@b.c' | 'apple:sub_xx' | 'google:sub_yy' | 'wechat:openid_zz'
  user_id       TEXT NOT NULL REFERENCES users,
  provider      TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);
```

凭证可增删,user_id 不变。Phase 3 按市场叠加登录方式 = 往 credentials 插行,身份层零改动。

**提升与认领的机械规则**(三条,穷尽所有情形):

1. 本地匿名命名空间存在 + 服务端无此 user_id → **注册式提升**:本地匿名 user_id 原样注册为服务端 user_id,目录不动,凭证绑上。本地数据零迁移。
2. 本地匿名命名空间存在 + 登录到一个**已存在**的账号(重装后登旧账号,本地却已新生成匿名 id)→ **认领归并**:`accounts/<匿名id>/` rename 为 `accounts/<账号id>/`;若目标目录已存在(先云恢复后认领),对每张表执行 UUID upsert + LWW 合并(§8)。
3. 无本地匿名数据 + 登录已有账号 → 走恢复流程(§7.6)。

### 2.3 多账号

同设备多账号 = 多个命名空间并存,文件系统级硬隔离。业务表**不加 user_id 列**(设计纪律:杜绝跨账号 JOIN 的可能性)。切换账号 = 关库 → 开目标命名空间库 → 重建 provider 树。ReminderScheduler 例外:挂系统通知层,跨命名空间枚举调度。

---

## 3. 存储模型

### 3.1 布局

```
<appSupport>/accounts/
  <user_id_A>/
    pikppo.db          ← drift/SQLite,该命名空间唯一真相源
    media/             ← 媒体文件(本地数据集)
    derived/           ← 向量/FTS 索引(派生,不传输)
  <user_id_B>/ …
```

### 3.2 本地静态加密

- iOS:依赖 Data Protection(NSFileProtectionComplete),零自管密钥。
- Android:SQLCipher,库密钥随机生成存 Keystore(StrongBox 优先)。
- **该密钥与传输/备份密钥体系(§6)完全无关**——它只保护"设备落盘",换设备即作废。由此一条硬规则:任何传输包(handoff/导出/云备份)中的快照必须**脱离本地落盘密钥**——Android 侧用 `sqlcipher_export` 重导出为以会话密钥/DEK 加密的包,禁止直接搬运 SQLCipher 文件(新机密钥不同,且会把 Keystore 绑定泄进包里)。

### 3.3 数据表

通用纪律 = 脊柱 S3/S4/S5。不加 `dirty` / `serverVersion`(快照式备份无需行级变更追踪;P3 若走同步,凭 S3–S5 升级,见 §9)。

```dart
// 日历 —— 核心资产集
// routedRoleId:事件创建/修改时由 ReminderRouter 决定的"归哪个角色"——cache
// 在事件上是为了 OS 通知预调度(App 被杀时 OS 唤起,无法跑路由器)。null 表示
// 尚未路由(刚迁移过来的老行)或路由失败,触发时退到默认角色。事件维度的单
// 角色归属,跨备份/迁移一并搬运。
class CalendarEvents extends Table {
  TextColumn get id => text()();                          // S3
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  DateTimeColumn get startTime => dateTime()();           // UTC
  DateTimeColumn get endTime => dateTime().nullable()();
  BoolColumn get allDay => boolean().withDefault(const Constant(false))();
  TextColumn get recurrenceRule => text().nullable()();
  IntColumn get reminderMinutes => integer().nullable()();
  TextColumn get routedRoleId => text().nullable()();     // v3.2 新增
  DateTimeColumn get updatedAt => dateTime()();           // S4
  BoolColumn get deleted => boolean().withDefault(const Constant(false))(); // S5
  @override Set<Column> get primaryKey => {id};
}

// 长期记忆 —— 核心资产集
// roleId 语义:null = 用户画像(全角色共享);non-null = 角色专属。
// kind=event 即产品语境下的"情节记忆"(具体事件),按 roleId 归属当时对话的
// 角色,中期保留、走加密备份;由遗忘策略(importance + lastAccessedAt)在
// MemoryItems 源头降级清理,而非在备份层过滤。
class MemoryItems extends Table {
  TextColumn get id => text()();                          // S3
  TextColumn get kind => text()();                        // identity|preference|relation|fact|event
  TextColumn get content => text()();
  TextColumn get roleId => text().nullable()();           // null=用户画像; non-null=角色专属
  TextColumn get sourceSessionId => text().nullable()();
  RealColumn get importance => real().withDefault(const Constant(0.5))();
  DateTimeColumn get lastAccessedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();           // S4
  BoolColumn get deleted => boolean().withDefault(const Constant(false))(); // S5
  @override Set<Column> get primaryKey => {id};
}

// 短期记忆 —— 本地数据集
// roleId 与 MemoryItems 同语义。consolidated=true 表示已被沉淀器提取进
// MemoryItems(对应 kind 由沉淀器决定:稳定事实→identity/preference/...,
// 具体事件→event)。
class SessionSummaries extends Table {
  TextColumn get id => text()();                          // S3
  TextColumn get sessionId => text()();
  TextColumn get summary => text()();
  TextColumn get roleId => text().nullable()();           // null=画像汇总; non-null=角色私聊
  BoolColumn get consolidated => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();           // S4
  BoolColumn get deleted => boolean().withDefault(const Constant(false))(); // S5
  @override Set<Column> get primaryKey => {id};
}

// 自定义角色 —— 核心资产集
// 预置角色由代码常量提供,不入库;本表仅用户自创角色。
class CustomRoles extends Table {
  TextColumn get id => text()();                          // S3 - UUID
  TextColumn get name => text()();
  TextColumn get icon => text()();                        // emoji
  TextColumn get description => text()();
  TextColumn get color => text()();                       // hex
  TextColumn get systemPrompt => text()();
  DateTimeColumn get updatedAt => dateTime()();           // S4
  BoolColumn get deleted => boolean().withDefault(const Constant(false))(); // S5
  @override Set<Column> get primaryKey => {id};
}

// 群组 —— 核心资产集
// roleIdsJson 是字符串化的 UUID 数组;预置/自定义角色一视同仁。
class Groups extends Table {
  TextColumn get id => text()();                          // S3
  TextColumn get name => text()();
  TextColumn get roleIdsJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();           // S4
  BoolColumn get deleted => boolean().withDefault(const Constant(false))(); // S5
  @override Set<Column> get primaryKey => {id};
}

// 设置 —— 核心资产集(键值,值为 JSON)
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get valueJson => text()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  @override Set<Column> get primaryKey => {key};          // 自然键,LWW 同样适用
}
```

聊天/会话表沿用现有结构,补齐 S3–S5。向量嵌入存 `derived/`,从不进任何包。

备份范围 = 核心资产集整表(含墓碑)。`kind`/`importance` 不做备份过滤——低价值记忆由遗忘策略在源头(MemoryItems)剔除,备份语义保持"长期记忆 = 备份范围"。

**记忆按角色加载的查询纪律**:对话时拼 system prompt,加载 `MemoryItems WHERE deleted=false AND (roleId IS NULL OR roleId = :currentRoleId)`——用户画像(roleId=null)与当前角色专属(roleId=currentRoleId)并集,且情节记忆(kind=event)受同条件覆盖。其他角色的专属/情节记忆与当前对话无关,DAO 层不暴露跨角色读路径。

---

## 4. 数据访问层

每域一个 Repository 作为**唯一写入口**:统一盖戳 updatedAt(UTC)、软删置墓碑、编排副作用(reminder 重排、沉淀触发、`_afterWriteHook`)。drift 原始写方法不导出。

```
UI(强类型 Dart 调用)──┐
                      ├──> Repository ──> drift
LLM LocalTool(JSON薄壳)┘         │
                                 └─ _afterWriteHook:
                                    P1 = 空;P2 = 核心资产表写后 requestBackup(防抖)
```

LLM 工具层:日历四工具(`calendar_list/create/update/delete_event`)+ 记忆工具(`memory_search/save/forget`),全部是 Repository 之上的 JSON 翻译壳,无业务逻辑。工具不感知备份/同步的存在(调用方无感知原则);写路径副作用 UI 与 LLM 完全一致。

**时间戳单调护栏**:写入时若 `now <= 该行现有 updatedAt`,取 `existing + 1ms`(LWW 的正确性依赖单调)。

### 提醒路由(端上,单角色归属)

事件类提醒(日历、未来的邮件/IM 集成等)统一以**聊天消息**形态呈现 + **系统通知**双轨触达(锁屏/通知中心由 OS 负责呈现样式)。一条事件归属**单一角色**——避免锁屏刷屏,且让事件归属语义清晰(一条事件 = 一个角色私聊里的一条记录)。

```
事件创建/修改(Repository.create/update)
  → Router(event.title, event.description, candidates=非删除角色清单+各自描述)
  → 单一 roleId(端上规则 prefilter + LLM 兜底,§技术方案 §6.5)
  → 写回 CalendarEvents.routedRoleId
  → NotificationService.scheduleFor(event, roleId)
        registers a local OS-level alarm (AlarmManager / UNUserNotificationCenter)
        以 roleId 维度分组(group key = roleId),同角色多条提醒堆叠
路由失败/超时 → routedRoleId = null;触发时退到默认角色(预置职场助理)
事件被删 → NotificationService.cancelFor(event.id)
角色被删/重命名 → Repository.rerouteFutureEvents(roleId):遍历未来事件、对涉及该角色的重路由 + reschedule
```

为什么"创建时路由"而非"触发时路由":OS 调度器(iOS UNUserNotificationCenter / Android AlarmManager)在 App 被杀时仍能弹出通知,但**无法跑路由代码**——若到触发时才决定归哪个角色,被杀场景下要么投不出去,要么默认角色全占。把决策提前到写入时、用持久层 cache(routedRoleId),是 OS 通知机制下的工业标准做法(微信/钉钉本质同构)。

零知识相容性:Router 在端上跑,事件内容与角色清单不出设备;NotificationService 也是端上 OS API,服务端永不参与"该不该提醒、提醒给谁"的判断。**注**:加密备份带走 `routedRoleId`,换机恢复后未来事件的归属保留;新机首次启动需要 NotificationService.reschedule 全量未来事件,把 cache 重新注册到本机 OS 调度器(OS alarm 不跨设备迁移)。

---

## 5. 传输:统一包格式与三条通道

### 5.1 包格式(唯一,三通道共用)

```
package/
  manifest.json {
    package_format: 1,
    schema_version: <S1>,
    user_id: <S2>,
    scope: "core_assets" | "full_namespace",
    tables: [...], media_included: bool,
    created_at, source_device_id,
    content_sha256                 // 明文 tar 的哈希,导入端解密后校验
  }
  snapshot.db      // 临时 SQLite:scope 内各表 ATTACH→INSERT SELECT(含墓碑),已脱离本地落盘密钥
  media/…          // 仅 full_namespace 且含媒体时
→ tar → AES-256-GCM(通道密钥) → 通道
```

快照制作:drift checkpoint(WAL 合并)→ 建临时库 INSERT SELECT(**禁止直接拷在用的 db 文件**)→ 制包期间 `pauseBackgroundWrites()`。

### 5.2 通道一:handoff 直传(P1)

换机一次性 hand-off,搬运 `full_namespace`(可多命名空间逐个搬):

```
1. 旧机:选命名空间 → 制包 → 生成一次性会话密钥 + 局域网监听端点 → 展示 QR(含端点 + 密钥指纹)
2. 新机:扫码 → ECDH 建立加密信道(QR 中指纹防中间人)→ 流式接收
3. 新机:解密 → 校验 content_sha256 → 按 §8 导入 → 重建派生索引
4. 校验与导入全部成功后,新机回执 → 旧机才提示"可退役本机/抹除该命名空间"
   (顺序硬规则:确认完整在先,退役提示在后——防"搬一半抹旧机")
```

跨平台:包是文件级格式,iOS ↔ Android 无差别。

### 5.3 通道二:导出文件(P1)

同一包格式落成单文件(密钥由用户口令派生,argon2id),用户自存网盘/U 盘。它是 P1 时期(以及任何不信任云的用户)对"丢机全灭"的唯一对冲;导入 = 选文件 + 输口令 → §8。**handoff 包与导出文件是同一格式的两种通道封装,实现共享 90% 代码。**

### 5.4 通道三:零知识云备份(P2,见 §7)

scope=core_assets 的包,通道密钥 = DEK(§6)。

---

## 6. 密钥体系(P2):零知识信封

```
DEK  : 随机 256-bit,加密备份包。本地 Keychain/Keystore 持有。
KEK  : 由用户恢复短语(recovery phrase,BIP39 风格 12 词)经 argon2id 派生。
服务端: 只存 wrapped_dek = AES-GCM(KEK, DEK) 与密文 blob —— 两者它都解不开。
```

- 短语在账号开启云备份时生成并强制完成抄写确认(随机抽 2 词回填校验);可选引导用户把短语存入其个人 iCloud Keychain / 密码管理器(产品对"短语丢失率"的主要调节阀)。
- **丢机 + 丢短语 = 核心资产永久不可恢复**。这是零知识的固有属性,作为架构事实记录。
- 短语轮换:设备在手(Keychain 有 DEK)时可随时换新短语重包 DEK,旧短语作废;blob 无需重加密(DEK 未变)。
- **单向门声明**:零知识 ⇒ 服务端永远不能成为有数据的执行方。离线主动提醒计算、服务端定时 agent、Web 端读记忆等"服务端替用户做事"的能力被架构性放弃;一切智能在端上。此为与"零知识 vs at-rest"同一决定的另一面,接受之。

---

## 7. 零知识云备份协议(P2)

### 7.1 服务端存储

```sql
CREATE TABLE backups (
  user_id        TEXT NOT NULL,
  backup_version INTEGER NOT NULL,     -- 服务端单调取号
  blob           BLOB NOT NULL,        -- 密文,服务端不可解
  blob_sha256    TEXT NOT NULL,        -- 密文哈希,传输完整性
  schema_version INTEGER NOT NULL,
  device_id      TEXT NOT NULL,        -- 审计
  created_at     INTEGER NOT NULL,
  PRIMARY KEY (user_id, backup_version)
);
CREATE TABLE user_keys (
  user_id     TEXT PRIMARY KEY,
  wrapped_dek BLOB NOT NULL            -- E(KEK, DEK),KEK 永不在服务端
);
```

服务端无明文业务表、无 LLM 工具、无解密能力——哑 blob 仓库。

### 7.2 端点

```
PUT  /backup/{user_id}        If-Match: <上次 version>(首次 If-None-Match: *)
GET  /backup/{user_id}/latest
GET  /backup/{user_id}/{version}        ← 历史版本恢复(UI 高级选项)
GET  /keys/{user_id}                    ← 返回 wrapped_dek(登录态)
PUT  /keys/{user_id}                    ← 上送/轮换 wrapped_dek
POST /devices/{user_id}/takeover        ← 见 7.5
```

### 7.3 backup_ready 状态机(按 user_id 键控)

```
登录成功 → Keychain 无 DEK?生成 → 服务端无 wrapped_dek?引导短语流程并上送
        → 全部就绪置 backup_ready;任一步失败:放行进入应用 + 持续告警 + 后台重试
未 ready:写操作照常,_afterWriteHook 不触发备份。
```

(不阻塞登录;ready 是备份的闸,不是使用的闸。)

### 7.4 触发与成本闸门

- 触发源:沉淀完成 / 核心资产表写后,统一进 5 分钟防抖;每日定时兜底。
- **变更检测**:核心资产表维护单调变更计数器,与上次成功备份的计数对比,无变化不制包不上传(沉淀经常零新增)。
- 网络策略:Wi-Fi 即时;蜂窝默认延迟至兜底(用户可开关)。
- 保留策略(防坏数据覆盖好备份):最近 3 份 + ≥12h/≥24h/≥72h/≥7d 各最近 1 份。

### 7.5 单活跃设备的执法与冲突路径

D「同一账号同一时刻一台活跃设备」由协议而非声明保证:

- 新设备完成恢复(§7.6)即调用 `takeover`:服务端吊销该 user_id 其他设备的备份凭证并下发通知;旧设备转入**已被接管**态——本地数据可读、可导出(§5.3),`_afterWriteHook` 永久关闭,UI 明示。
- `PUT /backup` 收到 412(If-Match 失配,意味着另一设备已推进版本):客户端**停止备份 + 显著告警 + 引导用户处置(导出本机数据 / 放弃)**。绝不自动覆盖任何一侧——快照备份是整体替换,自动化处置必丢一侧数据。

### 7.6 新设备恢复

```
1. 登录(无密码邮箱)→ 新设备恢复属高敏:二次确认(向凭证邮箱发确认)
2. GET wrapped_dek → 用户输恢复短语 → argon2id 派生 KEK → 解包 DEK → 入 Keychain
3. GET blob(latest 或用户选历史版本)→ 验密文 sha256 → DEK 解密 → 验明文 content_sha256
4. 导入(§8;目标命名空间通常为空,直落)
5. takeover(§7.5);后台重建派生索引;UI 明示短期记忆/聊天不在恢复范围
6. 审计记录 + 全凭证渠道通知"账号已在新设备恢复"
```

---

## 8. 合并模型(与通道解耦,全系统唯一一份导入器)

任何包(handoff / 导出文件 / 云 blob)的导入都走同一管线:

```
解密 → 校验 → schema 适配 → 落库 → 派生重建 → (P2)触发新备份
```

**schema 适配**:按 manifest.schema_version 查**导入适配器表**——每个历史版本一段"旧列→新列"的 SELECT 映射。注意这与 drift onUpgrade 是两套并行的迁移:onUpgrade 升级本机活库,导入适配器翻译外来快照(ATTACH 的库不会触发 drift 迁移器)。schema 每次变更必须同时落两份。`schema_version` 高于本机 → 拒绝,提示升级 App。

**落库规则(全部场景穷尽)**:

| 目标命名空间状态 | 规则 |
|---|---|
| 空 | 直落 |
| 非空(双通道相遇、认领归并等) | 逐表 UUID upsert:同 id 比 updatedAt,新者胜;墓碑同权参与(墓碑较新则删除胜);Settings 表以 key 为自然键同规则 |

S3+S4+S5 保证任意来源、任意先后的两包并集收敛一致——合并不关心数据走过哪条通道。

---

## 9. Phase 3:多设备(可选,二选一)

仅当真实需求出现时启动。决策是产品判断,两条路线的工程预埋均已就绪:

**路线 A · 持续同步**:S3–S5 已构成行级 LWW-Element-Set(state-based CRDT),合并层零迁移;增量化需补两件事——行级变更标记(dirty 列回归,加列即可)与变更流传输。传输可插拔:近场(局域网,复用 handoff 信道)打头阵,自有常开 E2E 中转节点(只见密文)做第二档。合并模型与传输解耦,先近场后中转是配置而非重构。

**路线 B · 分身**:per-device 人格分域,no-sync 作为特性——每台设备一个独立命名空间,天然契合多角色设计;工程成本为零(多命名空间机制 P2 已有),仅产品概念包装。

两条路线均不触碰身份层(凭证按市场叠加,绑同一 user_id)与存储层。

---

## 10. 不做清单

| 不做 | 理由 |
|---|---|
| 服务端可解密的任何密钥托管 | 零知识单向门,事后不可补 |
| 服务端检索 / RAG / 主动计算 | §6 单向门的另一面,智能全在端 |
| 聊天记录云备份 | 本地数据集定位;与零知识下的体量/成本不成比 |
| dirty/serverVersion(现阶段) | 快照备份无需;P3 路线 A 时加列回归 |
| oplog / 时光回溯 | 历史版本恢复(§7.2)已覆盖主要诉求 |
| CRDT 字段级合并 / OT | 行级 LWW 在单写者+偶发双通道场景下充分 |
| 跨账号聚合视图 | 命名空间硬隔离纪律 |
| 向量/FTS 索引入包 | 派生数据,重算即可 |

---

## 11. 只加不改的验收不变式

1. P2 上线:P1 的表 schema、Repository、LocalTool、handoff/导出实现**零改动**;新增 = 身份提升逻辑、密钥体系、云通道、`_afterWriteHook` 实现体。
2. P3 路线 A:仅加 dirty 列 + 变更流模块;路线 B:零代码。
3. 任意阶段新增登录方式 = credentials 插行。
4. 任意两包以任意顺序导入同一命名空间,终态一致(合并收敛性)。
5. 短语轮换不重加密 blob;通道增删不改包格式。
   违反任一条,回溯为脊柱设计缺陷而非追加补丁。