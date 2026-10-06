# Ticketing System（Discourse 工单系统插件）

一个自包含的 Discourse 工单（work order）插件：部门、优先级、指派、内部备注、附件、逐人已读追踪、员工收件箱，外加一个统计面板和两个后台任务。

不依赖任何其他插件，不改动现有的主题与帖子，不往 Discourse 的 `Topic`/`Post` 表里写任何东西——工单是五张独立的表。

---

## 安装

**仓库名是 `Ticketing-System`，插件目录必须是 `ticketing-system`。这一步不能省。**

```sh
cd /var/discourse/plugins
git clone https://github.com/CloudRail-BBS/Ticketing-System.git ticketing-system
```

在 `containers/app.yml` 里：

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/CloudRail-BBS/Ticketing-System.git ticketing-system
```

然后 `./launcher rebuild app`。

### 为什么必须显式指定目录名

Discourse 核心的样式表路由把名字约束成小写：

```ruby
# config/routes.rb
get "stylesheets/:name" => "stylesheets#show",
    constraints: { name: /[-a-z0-9_]+/, format: "css" }, format: true
```

而它拼出的 `<link>` 用的是**插件目录名**。目录叫 `Ticketing-System` 时，请求是 `/stylesheets/Ticketing-System_<digest>.css`，上面那条约束永远匹配不上，请求 404，控制器根本不会进入。

此时**其它一切都看起来正常**：编译成功、`stylesheet_cache` 表里有那条记录、`<link>` 也照常输出、别的插件样式都正常。唯一的症状是页面完全没有样式，外加控制台里一条关于 MIME type `text/html` 的报错。查起来非常费时间，所以请照抄上面那行 `git clone`。

（`git clone <url>` 不带目标目录时，目录名由仓库名推导，也就是 `Ticketing-System`。）

---

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Discourse | `3.2.0` 及以上（见 `plugin.rb` 的 `# required_version:`） |
| 数据库 | PostgreSQL（用到了 `DISTINCT ON` 与 `PERCENTILE_CONT`） |
| Ruby | 随 Discourse 一起提供，无额外 gem 依赖 |
| 前端 | 无构建步骤、无 npm 依赖；资源交给 Discourse 自己的流水线 |

安装后到 **管理 → 设置 → Plugins** 找到 `ticketing_system enabled`，默认已开启。若页面没出现，见下面的「排查」。

---

## 功能

**用户侧**

- `/tickets` — 我的工单列表，带未读数徽标、状态/优先级/部门筛选、四种排序
- `/tickets/new` — 新建工单，选部门、填标题与正文、加附件
- `/tickets/:id` — 工单详情：完整对话流、附件、时间线、操作栏
- 侧边栏「Community」区块与顶部导航栏都有入口（可用设置关掉）
- 工单被回复、被指派、状态变更、超时未响应、被自动关闭时会收到 Discourse 原生通知，出现在通知面板里

**员工侧**

- 收件箱作用域：`mine` / `all` / `unassigned` / `assigned_to_me` / `active`
- 改状态、改优先级、指派（支持 `me` / 用户名 / 用户 id / `none`）
- 内部备注——仅员工可见，不通知用户，不进对话流给用户看
- 未读是**逐人**的：一张工单被谁看过、什么时候看的，都在详情页的「已读」区块里列出来
- 时间线：谁在什么时候做了什么，逐条记录

**管理侧**

- `/tickets/admin` — 统计总览：总量、状态/优先级分布、部门分布、首次响应时长（均值与中位数）、准时/超时计数、近 30 天活动
- `/tickets/admin` 的「部门」页签 — 部门的增删改：名称、slug、描述、排序、启用开关、所属员工组、SLA 小时数、默认优先级

---

## 工单流程

```
open ──▶ in_progress ──▶ pending ──▶ resolved ──▶ closed
  ▲           │              │           │           │
  └───────────┴──────────────┴───────────┴───────────┘
                    用户或员工可重开
```

| 状态 | 含义 |
| --- | --- |
| `open` | 新工单，还没有员工回复 |
| `in_progress` | 员工已接手 |
| `pending` | 等用户补充信息，球在用户那边 |
| `resolved` | 已解决，等用户确认 |
| `closed` | 已关闭，用户不能直接回复（员工可以回复以重开） |

优先级：`low` / `normal` / `high` / `urgent`。

`open`、`in_progress`、`pending` 合称**活跃状态**，员工收件箱的默认范围、员工的未读徽标和「超时」判定都基于这三个。

> 发起人侧的未读**不**按活跃状态过滤：一张在他离开期间被解决的工单，恰恰是他需要看到徽标的那种情况。见下面「未读是逐人的」。

> `lib/ticketing_system/constants.rb` 里的整数是**存储契约**——它们会被写进数据库。加成员请追加新数字，永远不要重排或重编号。

---

## 未读是逐人的

未读**没有**存在任何一列上，它是推导出来的：

```
员工未读    ⇔  ticket.last_requester_message_at > marker.last_read_at
发起人未读  ⇔  ticket.last_staff_message_at     > marker.last_read_at
```

`marker` 是 `ticketing_system_read_markers` 里的一行 `(ticket_id, user_id, last_read_at)`。**行的缺失就是「从未打开过」**，所以 `last_read_at` 是 `NOT NULL` 的，不存在「未读行」这种东西。

### 为什么不是每张工单两个计数器

早期版本是 `tickets.staff_unread_count` / `requester_unread_count` 两个列。那回答的是「**有人**看过了吗」，而共享收件箱需要回答的是「**这个人**看过了吗」。用计数器时，第一个打开工单的员工会把整个团队的徽标一起清掉——也就是说，徽标恰好不再警告那些真正没看过的人。

### 为什么推导而不是存储

存一个布尔值意味着「来消息时置位、打开工单时清除」，而每一条写消息的路径、每一个打开工单的入口都是一次写错的机会。写错的症状是**一个永远清不掉的徽标**——看起来像缓存问题，其实不是。推导的话，两个事实来源不可能不一致。

### 两侧走同一套机制

发起人侧原本是计数器，现在也走读标记表。理由就是上面那条：两个事实来源总有一天会不一致。代价是发起人侧多一张表的一行，换来的是「未读」这件事在整个代码里只有一个答案。

`last_requester_message_at` / `last_staff_message_at` 是**关于消息**的事实，不是关于读取的，所以它们和读标记表不重复；它们的作用是把未读判定变成「一行已经在手上的记录里两个列比大小」，而不是扫一遍消息表。

### 内部备注不算「员工开口了」

写内部备注不动这两个时间戳。备注是员工的内部记账，发起人看不到它，把它算成「员工侧说话了」会给用户一个他永远不会看到内容的徽标。

### 读标记的写入是幂等的

`ReadMarker.mark_read!` 用 `insert_all` + `ON CONFLICT DO UPDATE`，而不是「查一次、没有就建」：

- **并发**：双击一张工单会发两个请求，「查一次、没有就建」会让两个请求都查不到、都去插入，第二个撞唯一索引报 500——把一次普通的双击变成一个错误页。
- **单调性**：冲突时取 `GREATEST(旧值, 新值)`。普通 upsert 会让先发出的旧请求在恰好后提交时把标记**往回移**，于是刚看过的消息又变成未读。

---

## 附件

新建工单和回复都支持附件，走 Discourse 自己的上传通道（`POST /uploads.json`），不是插件另起一套。

### 为什么不建 `ticketing_system_uploads` 表

核心已经拥有上传：它创建记录、按 SHA1 去重、知道文件存在哪里，还有最容易漏掉的一点——**它会为 `secure_uploads` 论坛重写 URL**。一个自己存 `upload_id` 列的插件白拿前三样，静默丢掉第四样。

所以关联用核心的 `UploadReference`（它本身就是一张多态关联表），载荷由核心的 `UploadSerializer` 生成：

```ruby
UploadSerializer#url
# => object.for_site_setting ? object.url
#                          : UrlHelper.cook_url(object.url, secure: SiteSetting.secure_uploads? && object.secure)
```

手搓一个哈希看起来完全正确——JSON 里字段齐全、数据库行也对——但在开了 secure uploads 的论坛上返回的是**原始存储路径**，浏览器取不到，附件 404。`lib/ticketing_system/attachments.rb` 里有完整说明。

### 附件不会被孤儿清理删掉

核心的 `clean_up_uploads` 任务会删掉没有任何引用指向的上传。它的排除列表里有一条是「通过 `UploadReference` 关联到非 `Post` 的东西的上传」，SQL 是 `LEFT JOIN upload_references ur ON ur.upload_id = uploads.id AND ur.target_type != 'Post'`。

也就是说，挂在 `TicketingSystem::Message` 上的附件**恰恰因为它的 target 不是 Post 而被排除在删除范围之外**。这个结论反直觉，但它是走 `UploadReference` 而不是自建列的又一个理由。

### 已知限制：secure uploads 论坛

在开启了 `secure_uploads` 的论坛上，工单附件会被判定为 secure（`ticketing_system_message` / `TicketingSystem::Message` 都不在 `UploadSecurity::PUBLIC_TYPES` / `PUBLIC_UPLOAD_REFERENCE_TYPES` 里，所以不算公开），于是经由 `/secure-uploads/` 提供。

但 `SecureUploadEndpointHelpers#check_secure_upload_permission` 只在**上传带 `access_control_post_id` 时**才做逐文件 ACL，而工单附件没有 post。剩下的一道检查是「必须已登录」。

所以在这类论坛上，附件由「已登录 + URL 里有一段猜不出的 SHA1」保护，但**没有**被限定到「能看见这张工单的人」，不像私信附件那样。要补上就得让核心的 guardian 认识工单，那是比这个插件该对核心上传路径做的更大的改动。这一点是**记录在案**的，不是被掩盖的——刻意没有调用 `UploadSecurity.register_custom_public_type`，因为把工单附件注册成公开类型会削弱隐私语义，方向正好相反。

### 服务端校验

客户端的选择器只是便利。id 是请求参数，什么都能是，所以 `Attachments.validate!` 会重新查一遍库：

- 附件功能是否开启；
- 数量是否超过上限；
- 每个 id 是否真的存在（`unknown_attachment`——不存在的 id 是报错，不是静默丢弃，否则用户会看到一条没带附件的回复且不知道为什么）；
- **上传者是否就是发帖人**（`attachment_not_owned`）——没有这一条，任何猜到别人 upload id 的人都能把那个文件钉在自己的消息上，然后通过自己控制的工单把它读回来；
- 扩展名是否在白名单内。

---

## 设置

全部 25 项都在 **管理 → 设置 → Plugins** 分类下（`config/settings.yml` 的顶层键是 `plugins:`）。

### 开关与入口

| 设置 | 默认 | 说明 |
| --- | --- | --- |
| `ticketing_system_enabled` | `true` | 插件总开关 |
| `ticketing_system_staff_groups` | `staff` | 谁算员工。管理员始终算员工，所以留空也有可用的员工权限 |
| `ticketing_system_show_nav_link` | `true` | 侧边栏与顶部导航栏的入口 |
| `ticketing_system_unread_badge` | `true` | 侧边栏入口上的未读数徽标 |

### 用户能做什么

| 设置 | 默认 |
| --- | --- |
| `ticketing_system_allow_requester_priority` | `true` |
| `ticketing_system_allow_requester_close` | `true` |
| `ticketing_system_allow_requester_reopen` | `true` |
| `ticketing_system_allow_internal_notes` | `true` |
| `ticketing_system_default_priority` | `normal` |

### 长度与限额

| 设置 | 默认 | 范围 |
| --- | --- | --- |
| `ticketing_system_title_min_length` | `4` | 1–50 |
| `ticketing_system_title_max_length` | `120` | 10–255 |
| `ticketing_system_body_max_length` | `20000` | 1000–100000 |
| `ticketing_system_max_open_per_user` | `10` | 1–200 |
| `ticketing_system_create_per_hour` | `5` | 1–100（每人每小时，0 关闭） |
| `ticketing_system_reply_per_hour` | `30` | 1–500（每人每小时，0 关闭） |
| `ticketing_system_list_page_size` | `20` | 5–100 |

### 附件

| 设置 | 默认 | 范围 | 说明 |
| --- | --- | --- | --- |
| `ticketing_system_max_attachments` | `5` | 0–20 | 单条消息的附件上限。**0 表示关闭附件功能**（前端不渲染选择器，服务端拒绝带 `upload_ids` 的请求） |
| `ticketing_system_allowed_upload_extensions` | 空 | 列表 | 允许的扩展名，空表示不限制。大小写与开头的点都会被归一化掉 |

上限在服务端还会再夹一次 `Attachments::MAX_ATTACHMENTS_CEILING`（20），所以管理后台里填错一个数字不会变成一次无上限的写入。

### SLA 与通知

| 设置 | 默认 |
| --- | --- |
| `ticketing_system_first_response_hours` | `24` |
| `ticketing_system_resolution_hours` | `72` |
| `ticketing_system_overdue_reminders` | `true` |
| `ticketing_system_auto_close_days` | `7` |
| `ticketing_system_notify_staff` | `true` |
| `ticketing_system_notify_requester` | `true` |
| `ticketing_system_notify_assignee` | `true` |

SLA 截止时间仍然是**读取时**由 `created_at` 推导出来的，没有把截止时间写进库，所以统计面板和详情页永远算的是同一件事，也不存在一个需要随设置变更回填的列。后台任务只是**扫描**这些推导出来的截止时间（见下面的「后台任务」）。

部门可以在自己的记录上覆盖 SLA 小时数与默认优先级；为空时回落到上面两个全局设置。

`ticketing_system_auto_close_days` 为 0 表示不自动关闭。

---

## 权限

| 动作 | 谁可以 |
| --- | --- |
| 看自己的工单 | 登录用户 |
| 看全部工单、员工收件箱作用域 | 员工 |
| 回复工单 | 工单发起人、员工 |
| 写内部备注 | 员工 |
| 改状态 | 员工；发起人受 `allow_requester_close` / `allow_requester_reopen` 约束 |
| 改优先级 | 员工；发起人受 `allow_requester_priority` 约束 |
| 指派 | 员工 |
| 改部门 | 员工（发起人仅在工单仍未分配时） |
| 加附件 | 回复工单的人；且只能加**自己上传的**文件 |
| 看「谁已读」 | 员工（发起人看不到，服务端下发空数组） |
| 部门的增 / 改 / 删 | **仅管理员** |

前端渲染哪些按钮和权限判断共用 `lib/ticketing_system/permissions.rb`，但**服务端会重新判断一遍**。界面是便利，不是管控。

---

## HTTP API

全部挂在 `/tickets/api` 下（`config/routes.rb` 的 `scope "/api"`），返回 JSON，走 Discourse 自己的 `check_xhr` 与 CSRF 校验。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/tickets/api/meta` | 部门列表、状态与优先级词表（已翻译）、可用作用域、当前用户能力、未读数 |
| `GET` | `/tickets/api/stats` | 统计面板的数据，仅员工 |
| `GET` | `/tickets/api/tickets` | 列表。参数：`scope` `status` `priority` `department` `assignee` `search` `sort` `page` |
| `POST` | `/tickets/api/tickets` | 新建工单。可选 `upload_ids` |
| `GET` | `/tickets/api/tickets/:id` | 详情（含对话流、附件、时间线、「谁已读」） |
| `POST` | `/tickets/api/tickets/:id/messages` | 回复或写内部备注。可选 `upload_ids` |
| `POST` | `/tickets/api/tickets/:id/actions` | 状态变更，用 `operation` 区分 |
| `GET` | `/tickets/api/departments` | 部门列表 |
| `POST` | `/tickets/api/departments` | 新建部门（管理员） |
| `PUT` | `/tickets/api/departments/:id` | 修改部门（管理员） |
| `DELETE` | `/tickets/api/departments/:id` | 删除部门（管理员，有工单时拒绝） |

`upload_ids` 是**逗号分隔**的上传 id（`"12,34"`），也可以传成数组——`Attachments.normalize_ids` 两种都收。文件本身先走核心的 `POST /uploads.json` 上传（`upload_type=ticketing_system_message`），拿到 id 再随消息提交。前端用逗号拼接而不是数组，是因为数组在 jQuery 序列化后的形状依赖 `traditional` 开关，一旦形状变了 Rails 只会保留最后一个值，附件会静默少一个。

`GET /tickets/api/tickets/:id` 会**顺带**给当前用户写一条读标记——打开详情页就是「已读」这个动作，没有单独的「标记已读」接口。

`POST /tickets/api/tickets/:id/actions` 的 `operation` 取 `status` / `priority` / `assign` / `department`：

```jsonc
{ "operation": "status",     "status": "resolved" }
{ "operation": "priority",   "priority": "urgent" }
{ "operation": "assign",     "assignee": "me" }        // 也接受用户名、用户 id、null、"none"
{ "operation": "department", "department_id": 3 }
```

判别字段是 `operation` 而**不是** `action`——Rails 在 params 里为路由保留了 `action` 和 `controller`，读它拿到的是控制器方法名，不是调用方的意图。

页面外壳（`/tickets`、`/tickets/new`、`/tickets/:id`、`/tickets/admin`）是服务端渲染的，放在 `<noscript>` 里，只为了让直接访问、刷新和爬虫拿到真实 HTML 而不是 404。带 JS 的访客看不到它。

---

## 通知

插件注册了自己的通知类型：

```ruby
Notification.types[:ticketing_system] = 5000
```

**5000 是存储契约，一旦产生过通知就不要再改。** 不复用 `Notification.types[:custom]`（14）是因为那个类型是所有插件共用的，谁最后注册渲染器谁赢，彼此的通知会串台。

会发通知的事件：

| 事件 | 收件人 | 开关 |
| --- | --- | --- |
| `new_ticket` | 部门员工组（或全局员工组）+ 指派者 | `notify_staff` |
| `requester_reply` | 同上 | `notify_staff` |
| `staff_reply` | 发起人 | `notify_requester` |
| `assigned` | 被指派者（自己指派给自己不发） | `notify_assignee` |
| `status_changed` | 发起人，且仅当改为 `resolved` / `closed` | `notify_requester` |
| `sla_breached` | 部门员工组（或全局员工组） | `overdue_reminders` + `notify_staff` |
| `auto_closed` | 发起人 | `notify_requester` |

内部备注**不产生任何通知**：用户看不见它，通知了就是 bug；而员工刚写完的备注再通知全体员工，会让共享收件箱的徽标失去意义。

`status_changed` 只在改为 `resolved` / `closed` 时发。每一次内部流转（`open` → `in_progress`）都发一条，只会把人训练成忽略这些通知。

`sla_breached` 只发给员工，不发给发起人：一张「你还没收到回复」的工单，用户没有任何可做的动作，而告诉他「你的工单被无视了」是一种客服反模式。能改变行为的提醒是发给员工的那一条。

`sla_breached` 和 `auto_closed` 由定时任务写入，**没有发言人**，所以通知条目的发言人标签是空的。这两条（以及按 `breach` 分流的 `sla_breached_first_response` / `sla_breached_resolution`）因此写成**完整句子**而不是短语——没有主语的短语（「超出了时限」）读起来是残句。

通知里 `topic_id` 是空的，这是刻意的。核心的三处相关逻辑都容忍这一点（`belongs_to_required_by_default = false`、`scope :visible` 的 `LEFT JOIN` 放行空 topic、`NotificationEmailer` 用 `respond_to?` 兜底所以不会尝试发信），`lib/ticketing_system/notifier.rb` 里有逐条说明。

---

## 后台任务

两个 Sidekiq 定时任务，都只是**薄封装**：逻辑在 `lib/ticketing_system/` 里，任务类只负责调用。

| 任务类 | 频率 | 逻辑 | 做什么 |
| --- | --- | --- | --- |
| `Jobs::TicketingSystemSlaSweep` | 每 15 分钟 | `lib/ticketing_system/sla_sweeper.rb` | 找出已超过首次响应或解决时限、且还没提醒过的工单，给员工发一次 `sla_breached` 通知 |
| `Jobs::TicketingSystemAutoClose` | 每天 | `lib/ticketing_system/auto_closer.rb` | 把 `resolved` 超过 `ticketing_system_auto_close_days` 天的工单改成 `closed` |

### 为什么逻辑在 `lib/` 而不在任务类里

任务类在 `Jobs::` 命名空间下、由 Sidekiq 调用，在测试和 Rails console 里不方便直接跑。把逻辑放进一个普通的类（`SlaSweeper.call` / `AutoCloser.call`），就能在 console 里手工触发一次、观察结果，而不必等 15 分钟。

### 插件里的 `app/jobs/scheduled` 必须显式 eager load

Discourse 的 `Jobs::Scheduled` 是通过 `MiniScheduler` 收集的，而 MiniScheduler 只认**已经加载过的**常量。生产环境里 `app/jobs/scheduled` 不在自动加载路径上，于是任务会静默地不存在——没有报错，只是永远不跑。

`lib/ticketing_system/engine.rb` 里的写法来自核心官方的 `discourse-data-explorer`：

```ruby
scheduled_job_dir = "#{config.root}/app/jobs/scheduled"
config.to_prepare { Rails.autoloaders.main.eager_load_dir(scheduled_job_dir) }
```

### 幂等：`sla_notified_at`

每 15 分钟扫一次，但一张超时的工单只能提醒**一次**。做法是先 claim 再通知：

```ruby
claimed = Ticket.where(id: ticket.id, sla_notified_at: nil)
                .update_all(sla_notified_at: now, updated_at: now)
return false if claimed.zero?
```

条件 UPDATE 是原子的，所以两个并发跑的任务实例也只有一个能拿到它。代价是「claim 成功但通知失败」会丢掉那一次提醒（进程崩溃、通知写入报错）。这个方向是刻意选的：**丢一次提醒**远好于**每 15 分钟重复提醒**——后者会让人关掉整个功能。

### 自动关闭不动 `last_activity_at`

关掉一张工单是**清理**，不是「有动态」。改 `last_activity_at` 会让它在按最近动态排序的列表里跳到最前面，把一张没人管的旧工单推到正在处理的工单上面。

---

## 目录结构

```
plugin.rb                          元数据、require_relative 清单、资源注册、通知类型
config/
  routes.rb                        JSON API + 页面外壳 + engine 挂载
  settings.yml                     25 项设置
  locales/{client,server}.{en,zh_CN}.yml
db/migrate/                        5 张表：departments / tickets / messages / events / read_markers
                                   6 个迁移；`..._000007` 只用来把 f98e1bf 之前建的库补齐
lib/ticketing_system/              **不自动加载，必须 require_relative**
  constants.rb                     状态、优先级、事件种类、作用域、排序
  errors.rb                        领域异常，各自带 HTTP 状态码
  permissions.rb                   唯一的权限判断来源，服务端与前端共用
  engine.rb                        Rails::Engine（含 app/jobs/scheduled 的 eager load）
  ticket_query.rb                  列表的筛选/排序/分页
  ticket_creator.rb                新建工单（含附件关联与读标记）
  message_creator.rb               回复与内部备注（含附件关联与读标记）
  ticket_updater.rb                状态/优先级/指派/部门变更
  attachments.rb                   附件策略：上限、白名单、归属校验、序列化
  sla_sweeper.rb                   SLA 超时扫描（被定时任务调用）
  auto_closer.rb                   resolved 超期归档（被定时任务调用）
  statistics.rb                    统计面板的查询
  notifier.rb                      Discourse 通知
  rate_limiter.rb                  包装核心的 RateLimiter
  serialization.rb                 AMS 基类
  ticket_serialization.rb          工单的状态/优先级标签与未读判定
  version.rb                       版本号
app/                               **由 Zeitwerk 自动加载，禁止 require_relative**
  models/ticketing_system/         5 个模型（ticket / message / event / department / read_marker）
  controllers/ticketing_system/    8 个控制器
  serializers/ticketing_system/    5 个序列化器
  jobs/scheduled/                  2 个定时任务（由 engine 显式 eager load）
  views/ticketing_system/pages/    无 JS 时的服务端外壳
assets/
  javascripts/discourse/
    ticketing-system-route-map.js  Ember 路由表（必须导出「函数」）
    routes/                        index / new / show / admin
    templates/                     对应的 .gjs 路由模板
    components/                    10 个组件（列表、详情、编辑器、附件选择器、管理面板…）
    services/                      把 currentUser 上的能力包成 service
    initializers/                  导航入口 + 通知渲染器注册
    lib/                           API 路径、格式化、通知渲染器工厂、附件上传状态机
  stylesheets/                     用户侧 + 管理侧
scripts/                           提交前跑的闸门，见下
```

### `lib/` 与 `app/` 的区别不是风格问题

- `lib/` **不**在 Zeitwerk 的管辖范围内，所以 `plugin.rb` 必须逐条 `require_relative`。
- `app/` **在** Zeitwerk 的管辖范围内，所以**绝对不要** `require_relative` 它下面的任何文件。

原因是时序：插件激活发生在 `config/application.rb` 的**函数体里**，早于 `Rails.application.initialize!` 建立自动加载器。此时去加载一个继承自 `ApplicationController` / `ApplicationSerializer` / `ActiveRecord::Base` 的文件，会抛 `NameError: uninitialized constant`，被 `Plugin.initialization_guard` 捕获，打印 "You are unable to start Discourse due to errors in the plugin at …" 然后 `exit 1`。同一个 `exit 1` 还会让紧随其后的 `rake db:migrate` 步骤失败——一个事件，两个症状。

---

## 管理页为什么在 `/tickets/admin` 而不是 `/admin/plugins`

Discourse 的惯例是把插件管理界面挂在 `/admin/plugins` 下。这个插件没有这么做，是有意的：

1. `/admin/plugins` 下的页面属于**管理后台 bundle**，而管理后台只在 `/admin` 路由下加载。这个插件的用户侧页面在 `/tickets`，两个 bundle 之间共享样式和组件需要额外的注册，收益不抵复杂度。
2. 挂到 `/admin/plugins/<name>` 需要提供 `templates/admin/plugins/show/*.gjs` 去覆盖核心的 admin 插件展示模板，而这条路径是否会被核心解析**无法在没有真实实例的情况下确证**。Ember 路由表里用对象形式挂到已有节点时，如果目标节点不在路由树中，路由会被**静默丢弃**——没有日志、没有报错，只有 404。
3. 这个插件的管理页是插件自己前端路由表上的一条普通路由，用的是已经端到端验证过的**函数形式** `export default function () { this.route(...) }`。

代价是：`/admin/plugins` 里那个「设置」链接指向的是 Discourse 标准的插件设置页，而不是这个统计面板。统计面板的入口在侧边栏的工单链接旁边（员工可见）。

顺带一提，`config/routes.rb` 里 `get "/admin"` **必须**写在 `get "/:id"` 前面：Ember 路由没有正则约束，`show` 的 `:id` 会把字面量 `"admin"` 吞掉，Rails 侧同理。漏掉这一行时，应用内导航到 `/tickets/admin` 正常，直接刷新 404——最难查的一种分裂。

---

## 未实现

以下功能**刻意没有做**，写在这里以免被当成 bug：

**邮件通知。** 通知只出现在站内通知面板里。核心的 `NotificationEmailer` 对未知通知类型是 `respond_to?` 兜底、静默跳过，所以插件通知**不会**触发邮件，也不会报错。要发信得注册 `email_notification_filters` 并自己写模板。

**secure uploads 论坛上的逐工单附件权限。** 附件受「已登录 + 不可猜的 URL」保护，但没有被限定到能看见这张工单的人。要补上就得让核心的 guardian 认识工单。见上面「附件」一节的「已知限制」。

**工单合并、标签、自定义字段、SLA 升级策略。** 都不在 v1 范围内。

---

## 开发

插件本身没有构建步骤，也不需要 `npm install`。但有一道**提交前必须跑**的闸门：

```sh
sh scripts/selftest.sh
```

四个阶段，任一失败立即停止：

| 阶段 | 内容 |
| --- | --- |
| 1/4 | `scripts/check-templates.py` — `.gjs` 模板的作用域，以及剥掉模板后的 JS 语法 |
| 2/4 | `scripts/validate.py` — 16 项跨文件静态一致性检查 |
| 3/4 | `scripts/check-ruby.rb` — 44 个 `.rb` 的语法、`.erb` 的可编译性，以及 Ruby 解析器的警告 |
| 4/4 | `scripts/selftest.py` — 变异自测：向代码注入 17 处缺陷，确认前三个校验器确实报错，然后恢复文件 |

也可以用 `npm run lint`（等价）、`npm run validate`、`npm run templates`、`npm run ruby`、`npm run mutation` 单独跑某一项。

没有 Ruby 的机器上阶段 3 会跳过并打印一行说明；其余三个阶段照跑。

### 为什么需要这套东西

这个插件里几乎每一种错误的**表现都是沉默的**：

| 错误 | 症状 |
| --- | --- |
| 少一个 i18n 键 | 界面上出现 `[en.ticketing_system.foo]` |
| 少一个 `site_setting` | 第一次真正读它时才抛 `NoMethodError` |
| API 路径拼错 | 一个 404 页面，不是一个异常 |
| 状态枚举加了成员忘了文案 | 下拉框里多一个原始键名 |
| 事件种类加了成员忘了文案 | 时间线上安静地显示成 `auto_closed` 这种机器名——`EventSerializer#kind_label` 带 `default: kind`，退化得比原始键名还隐蔽 |
| 某个语种少一个键 | 只有那个语种的用户看得见 |
| `errors.add` 的键没有条目 | 报错信息变成 `translation missing: …` |
| `.gjs` 里用了未 import 的辅助函数 | **整个插件 bundle** 被换成一行 `throw new Error("… not in scope …")`，所有组件失效 |
| 哈希里同一个键写了两遍 | 前者被静默覆盖（真实案例：`status: 400, status: "bogus"` 让 HTTP 状态码变成了 `"bogus"`，500 而不是 400） |
| 已发布的迁移被原地改写 | 改动只对之后安装的库生效，已有库拿不到新列，代码一读就是 Postgres `undefined column`——报错指向查询，不指向「列没建」（真实案例，见 `..._000002` 顶部的注释） |
| 把控制器的 `params` 当成 Hash 用 | 不是 404、不是 400，而是**那个端点** 500：`ActionController::Parameters` 没有 `with_indifferent_access` 这类 Hash 方法，报错发生在参数规整阶段，比任何查询都早（真实案例：`/tickets/api/tickets` 500 而 `/tickets/api/meta` 200） |
| 方法在不同分支上返回不同类型 | **定时任务每天都失败，而它看起来是健康的**：一个从不运行的任务，和一个运行了但没找到该关闭的工单的任务，是同一种安静。真实案例：`AutoCloser#call` 前两条分支写 `return 0`、最后一行是 `.each { … }`，于是功能关闭时返回 Integer、开启时返回 Array，调用方的 `closed.positive?` 抛 `undefined method 'positive?' for an instance of Array` —— 自动关闭一次都没跑成，唯一的证据是 `/logs` 里一行没人会翻的 `Job exception` |
| 图标名不在核心精灵里 | `d-icon` 不报错、不警告，只是画出一块空白——侧边栏那行看着像「忘了配图标」，通知条目空一块（真实案例：`ticket`，见 `scripts/discourse-icons.txt`） |

没有一条会写日志，没有一条会让测试变红。所以这些检查必须在这里、在提交之前跑一遍。

`scripts/validate.py` 的 16 项检查：YAML 可解析与客户端 `js:` 包装、两个语种的键集对齐（含叶子类型）、前端 `i18n()` 调用、服务端 `I18n.t` / `Errors::*` / `errors.add`、`Errors::*` 类名、`Errors::*` 插值参数与文案占位符、`site_settings` 与文案双向、`site_settings` 与 Ruby 用法双向、枚举与文案（`STATUSES` / `PRIORITIES` 查两个语种的**客户端**文案，`EVENT_KINDS` 只查**服务端**文案——它的标签由 `EventSerializer` 在服务端查，去客户端文案里找只会报假错）、`plugin.rb` 元数据、前端 API 路径与 `config/routes.rb`、前端相对导入可达性、已提交的迁移未被修改（比工作区与 `HEAD` 的差异，所以改动一旦单独提交就自动变绿）、图标名能真的渲染出来（`scripts/discourse-icons.txt` 是 `SvgSprite::SVG_ICONS` 的快照，再加上本插件 `register_svg_icon` 贡献的名字）、控制器参数没被当成 Hash 用（`params.with_indifferent_access` 这类 Hash 专属方法在 `ActionController::Parameters` 上并不存在，命中的端点会 500——清单刻意只收确定不存在的名字，会误报的闸门比没有闸门更糟）、方法返回类型稳定（一个方法既 `return <数字>` 又以 `.each` / `.map` 之类迭代器收尾时，它在不同分支上返回的是不同类型——`Array#each` 返回的是被遍历的集合本身，于是调用方写的 `结果.positive?` 会在**其中一条分支上**炸，而且这类失败发生在定时任务里，没人会去翻）。

### 几条容易踩的约定

- **前端不要 import 核心 UI 组件，也不要用模板辅助函数。** `.gjs` 里 import 一个不存在的模块、或者用没导入的 `(eq a b)` / `{{not x}}`，Discourse 的 js_compiler 会把整个插件 bundle 替换成一行 `throw`。这个插件用内联 SVG 图标集和原生 `<select>` / `<button>`，所有比较与取反都在 JS getter 里算好。
- **`plugin.rb` 里不要出现剥离后为纯 `#` 的行。** `Plugin::Metadata#parse_line` 对这样的行算出 `attribute = nil` 然后调 `nil.strip`，抛 `NoMethodError` 中止整个启动，回溯指向核心且不报插件名。空行是安全的，所以段落之间用空行，不要用 `#` 分隔线。
- **Ember 路由表必须导出「函数」**（`export default function () { this.route(...) }`）。对象形式 `{ resource: "x", map() {} }` 是「挂到已有节点」，插件自有顶层路由名不在树中，会被静默丢弃。
- **`register_asset` 不要带 `:admin`。** `:admin` 会把样式放进只在 `/admin` 路由加载的 bundle，而这个插件的管理页在 `/tickets/admin`。
- **客户端 locale 文件必须在 `js:` 下。** 服务端 `I18n.t` 和客户端 `i18n()` 是两个 I18n 实例，同一个键两边都要写一遍。
- **上传文件时 `processData: false` / `contentType: false` 不能省。** jQuery 不会因为 `data` 是 `FormData` 就自动改用 multipart——它照常走 `jQuery.param()`，而 `FormData` 没有任何可枚举的自有属性，结果是**一个空请求体**，服务端报「没有文件」。CSRF 反过来不用自己设：核心的全局 `$.ajaxPrefilter` 会给所有非 crossDomain 请求注入 `X-CSRF-Token`。
- **插件里的 `app/jobs/scheduled` 必须显式 eager load**，否则任务静默地不存在（见「后台任务」）。
- **迁移只增不改。** 迁移一旦提交就不能再动——Rails 把它记在 `schema_migrations` 里，**永远不会重跑**，所以改动只对「之后才安装的库」生效，对已经跑过它的库完全无效。两边于是永久分叉，而分叉的后果取决于每个库是在哪一天装的。要改结构就新加一个迁移（`..._000007` 就是为此存在的，`..._000002` 顶部的注释记录了它被原地改过的那一次）。闸门里有一条检查专门盯这个：工作区出现「已提交的迁移被修改」就报错，把这次修改单独提交之后检查自动变绿。

### 排查

**只有 `/tickets/api/tickets` 500，`/tickets/api/meta` 正常。** 这不是 schema 问题——缺列会让两个端点一起挂（见下一条）。这条症状的判别力在于：两个端点共享鉴权、共享 `Permissions`、共享序列化基类，唯一多出来的东西是「列表会构造 `TicketQuery`」。所以去看 `TicketQuery`，尤其是它的构造器：它拿到的是控制器的 `params`，而 `ActionController::Parameters` **不是 Hash**。真实案例是构造器里的 `(params || {}).with_indifferent_access` —— `Parameters` 只把 `keys` / `empty?` / `include?` 这几个读取器委托给内部包着的 `HashWithIndifferentAccess`，其余一律落到 `Object`，所以这一行在**任何查询之前**就抛 `NoMethodError`，症状和 schema、查询、序列化全都无关。改法是先 `params.to_unsafe_h` 再规整（见 `lib/ticketing_system/ticket_query.rb` 的 `normalize_params`）。闸门里有一条检查专门盯这个。

**工单页 500，日志里是 Postgres 的 `undefined column`（`/tickets/api/tickets` 和 `/tickets/api/meta` 一起挂）。** 代码读的列在库里不存在，几乎总是「拉了新代码但没跑迁移」。Discourse 只在 `./launcher rebuild app` 时跑插件迁移，`restart` 不会。进容器确认：

```bash
./launcher enter app
sudo -u discourse bundle exec rake db:migrate:status | grep ticketing_system
```

六个迁移都应该在，且 `ticketing_system_tickets` 上应该有 `last_requester_message_at` / `last_staff_message_at` / `sla_notified_at` 三个列。缺任何一个就是迁移没跑完。

**侧边栏条目只有文字没有图标，或通知条目空一块。** 图标名没被打包进核心的精灵。Discourse 下发的是 FontAwesome 的子集：`SvgSprite.bundle` 只取 `SvgSprite.all_icons` 里的名字（= `SvgSprite::SVG_ICONS` + 站点设置 / 主题 / 插件贡献）。FontAwesome 源文件里有、但清单里没有的名字，渲染出来就是一块空白，**不报错、不警告**。要么换成清单里的名字，要么在 `plugin.rb` 里 `register_svg_icon "名字"`。跑 `sh scripts/py.sh scripts/validate.py --verbose` 会直接指出是哪个名字。

**插件页面 404 / 没有样式。** 先确认目录名是 `ticketing-system`（全小写），再确认 `plugin.rb` 的 `# name:` 与 `PLUGIN_NAME` 和目录名三者一致。

**设置改了没反应。** 默认值只在没有任何存储值的时候生效。一旦在管理后台点过开关，存下来的值就赢了，改 `settings.yml` 里的 `default` 不再有任何作用。到 `/admin/site_settings/category/plugins` 看实际值。

**界面全是方括号键名，但错误提示是正常中文。** 说明 `client.*.yml` 少了 `js:` 那一层——服务端查询照常工作，客户端查询全部落空。

**整个插件都失效，控制台有一行 `throw new Error(... not in scope ...)`。** 某个 `.gjs` 用了未 import 的名字。跑 `sh scripts/py.sh scripts/check-templates.py --verbose` 定位。

**附件传上去了，但点开是 404，而 JSON 里字段看着都对。** 说明返回的是原始存储路径，而不是 `UploadSerializer#url` 重写后的 `/secure-uploads/…`。检查是不是有人手搓了上传的哈希（`lib/ticketing_system/attachments.rb` 说明了为什么不能这么做）。这个症状只在开了 `secure_uploads` 的论坛上出现。

**通知里少了一条超时提醒。** 定时任务只在 `ticketing_system_overdue_reminders` 与 `ticketing_system_notify_staff` 都打开时发通知；另外 `sla_notified_at` 一旦写上就不会再提醒第二次（这是幂等设计，不是 bug）。要重测，先把那张工单的 `sla_notified_at` 置空。

**`/logs` 里出现 `Job exception: undefined method 'positive?' for an instance of Array`。** 定时任务拿到的东西类型不对。真实案例：`AutoCloser#call` 的前两条分支写 `return 0`，最后一行原本是 `.each { |ticket| close(ticket, now) }` —— 而 `Array#each` 返回的是**被遍历的集合本身**，不是遍历的结果。于是这个方法在功能关闭时返回 Integer、开启时返回 Array，任务里的 `closed.positive?` 只在开启时炸。因为设置是开着的，早退分支从不触发，所以这个任务**每天**都失败，自动关闭一次都没跑成。改法是让每一条分支返回同一种类型（现在是 `candidates.count { |ticket| close(ticket, now) }`，并且 `close` 明确返回 `true`/`false`，而不是让 `Notifier` 的返回值决定计数）。排查时看那个 lib 方法**每一条** `return` 分别是什么类型，而不是只看最后一行。这类失败是安静的：一个从不运行的任务，和一个运行了但没找到该关闭的工单的任务，在日志里长得一模一样。闸门里有一条检查盯这个。

**「已读」区块一直是空的。** 它只对员工渲染，而且服务端会**排除发起人本人**——这个列表要回答的是「团队里有没有人看到过」。员工自己打开工单会写入自己的读标记，所以另一位员工应该马上能看到。

---

## 许可

MIT，见 [LICENSE](LICENSE)。
