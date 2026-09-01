# Vertical Slice 技术规划

## 1. 技术目标

第一阶段技术目标不是搭建完整世界，而是用最小且可扩展的结构验证以下闭环：

`主城整备 → 单将远征 → 连续战斗 → Boss 战略削弱 → 成功/失败结算 → 永久成长 → 再次出征`

在引擎正式确认前，本规划使用引擎中立的模块名。若选择 Godot 4.x，定义数据可映射为 Resource/JSON，运行态使用纯逻辑类，界面使用场景与 Control；目录和类名在 M0 决策后再固化。

## 2. 分层与依赖方向

```text
UI / Presentation
        ↓ commands + view models
Application Controllers
  Combat | Expedition | Campaign
        ↓
Domain Logic + Runtime State
        ↓
Definitions / Balance Config / Save DTO
        ↓
Persistence + Content Loading + RNG + Logging
```

规则层不得依赖 UI；定义数据不得保存运行时引用；存档只保存稳定 ID 和必要状态，不保存场景节点或临时对象。

## 3. 定义数据

### CardDefinition

- `id`, `name`, `rarity`, `cost`, `tags`
- `owner_scope`: public/general-exclusive
- `copy_limit`, `exhaust`
- `conditions[]`
- `effects[]`
- `upgrade_branches[]`
- `presentation`: 文本、图标和动画提示 ID

### EffectDefinition

首批效果类型：

- DealDamage
- GainArmor
- ModifyMorale
- DrawCards
- GainActionPoint
- ModifyDefense
- ApplyStatus
- RepeatAttack
- ConsumeOwnMorale
- ConditionalEffect

每个效果只描述“做什么”；目标选择、数值、持续时间、叠加规则和失败提示必须显式配置。

### ConditionDefinition

首批条件：

- ArmyRatioAtLeast
- OwnMoraleAtLeast / EnemyMoraleAtMost
- ArmorAtLeast
- CardsPlayedThisTurnAtLeast
- AttackCardsPlayedThisTurnAtLeast
- EnemyMoraleLostThisTurnAtLeast
- EnemyDefenseAtMost
- HasStatus

条件统一返回 `passed` 与面向 UI 的失败原因，避免 UI 复刻逻辑。

### 其他定义

- GeneralDefinition / TalentDefinition
- ArmyTypeDefinition
- EnemyDefinition / EnemySkillDefinition / IntentDefinition
- ExpeditionDefinition / ExpeditionNodeDefinition
- TerritoryDefinition
- ResearchDefinition / CardUpgradeDefinition
- BalanceConfig

所有引用使用稳定字符串 ID，并在内容加载阶段做引用完整性校验。

## 4. 运行时状态

### CombatState

- 双方战斗快照：兵力、士气、攻击、防御、护甲、军队构成
- 抽牌堆、手牌、弃牌堆、耗尽区
- 当前行动力、回合计数、回合统计与状态效果
- 当前/下一敌方 Intent
- 可复现 RNG 状态和事件日志

状态机：

`Setup → PlayerTurnStart → PlayerAction → PlayerTurnEnd → EnemyIntentResolve → EnemyTurn → OutcomeCheck → 下一回合/Result`

撤退作为 PlayerAction 中的显式命令进入 `RetreatResolve`，不走普通失败路径。

### ExpeditionRunState

- 远征 ID、Seed、当前节点和已走节点
- 武将 ID 与出征快照
- 跨战剩余兵力/士气
- 未入库战利品
- 临时 Buff
- 已处理军事据点与 Boss 修正
- 运行状态：active/success/retreated/failed

### CampaignState

- `save_version`, campaign ID, 周期、主城阶段
- 主资源与特殊资源
- 军队库存
- GeneralInstance 列表：成长、伤势、死亡状态、专属卡
- 已解锁公共卡与唯一升级分支
- 领地与研究状态
- 当前未完成远征的恢复信息（如允许中途存档）

## 5. 控制器边界

### CombatController

接收不可变战斗输入，执行命令并产生领域事件。最终只返回 `CombatResult`，不能直接扣除长期军队库存或写 Campaign Save。

### ExpeditionController

把战斗结果写入远征运行态，执行节点事件、路线合法性、战利品袋和 Boss 修正。结束时生成 `ExpeditionSettlementRequest`。

### CampaignController

验证结算请求并一次性提交长期变化。成功、撤退、兵力归零、士气溃败必须有不同且可测试的结算策略。

## 6. 存档与版本策略

- 存档根节点必须包含 `save_version`, `content_version`, `created_at`, `updated_at`。
- 使用显式 DTO 序列化，不直接序列化场景树/节点/任意对象。
- 引用内容时保存稳定 ID；载入时校验缺失 ID 并给出可读错误。
- 每次保存先写临时文件、校验成功后再替换正式文件，并保留一个最近备份。
- 每个旧版本通过顺序迁移函数升级，例如 `v1 → v2 → v3`，不在载入代码中堆叠零散兼容分支。
- 不可逆卡牌升级、永久死亡和 Game Over 必须通过事务式结算，避免写入一半后中断。
- 是否使用铁人自动存档由设计决策决定，但底层需要支持明确的保存时点策略。

## 7. 测试策略

### M1 规则测试

- 伤害顺序：攻击、条件增伤、防御、护甲、兵力。
- 防御递减边界、护甲清空时点、士气 0 和兵力 0 的优先级。
- 抽牌洗牌、弃牌、耗尽、费用不足与无效目标。
- 兵种门槛在开战时锁定。
- 返行动力、0 费、重复攻击和条件组合的单回合上限。
- Intent 可见、AI 不读取未来手牌、同 Seed 结果一致。
- 主动撤退、玩家死亡和武将重伤分支。

### M3 内容契约测试

- 所有定义 ID 唯一，引用有效，文本/费用/效果完整。
- 每张牌至少有一条可用性测试和一条核心效果测试。
- 三名武将各有一条证明天赋身份的固定 Seed 战斗。
- Boss 三种据点削弱分别生效，且不会互相串状态。

### M4～M6 集成测试

- 路线不可回头；成功前战利品不进入 Campaign。
- 撤退丢弃战利品但保留既有损失。
- 连续战斗正确继承兵力/士气，清除单战护甲。
- 成功结算、领地收入、研究升级、补兵与再次出征闭环。
- Save/Load 在战斗前、节点间和结算后保持一致（具体保存点待决策）。

## 8. 调试与平衡工具

- 指定武将、牌组、兵种构成、敌人和 Seed 直接开战。
- 结构化战斗日志：抽牌、付费、条件、伤害管线、状态和 Intent。
- 统计回合数、兵力损失、士气损失、护甲利用率、无效手牌比例。
- 批量运行同一 Build 对敌人组合的胜率与损耗分布。
- 记录内容版本和 Seed，确保平衡结论可复现。

## 9. 首要技术风险

1. 卡牌效果系统过度通用会提前变成脚本语言；首批只覆盖 19 张牌所需能力，特殊机制用受控扩展点。
2. Combat 直接修改 Campaign 会让撤退、死亡和读档难以测试；必须通过结果对象与结算事务隔离。
3. 卡牌预计伤害与真实结算分叉会迅速破坏信任；两者必须调用同一规则评估器。
4. 永久死亡与读档策略不明确会削弱整个风险设计；应在 M1 前锁定保存哲学。
5. 19 张卡牌只有名称没有完整数据，不能由程序员自行补齐并当作锁定设计。
6. 地图、卡牌、AI 和 UI 同时开工会掩盖核心是否好玩；先用 Headless 内核和固定 Seed 证明三种 Build。
7. 单个固定 Seed 只能证明身份回合和确定性，不能证明敌人数值平衡；普通/精英回合数与胜率必须留到 M3-05 批量统计。
8. 战前军令入口只负责创建可试玩 CombatRequest，不得提前承担远征整备、Campaign 修改或存档职责。
9. Boss 阶段技能与求援可能在同一玩家回合连续入队；必须使用可测试的先进先出队列，禁止后入阶段技能静默覆盖已有援军，或反之。
10. 三项战略削弱若直接修改共享 Boss 定义，会污染后续战斗与组合测试；必须只修改每次 CombatRequest 创建的深拷贝，并分别验证单项与组合输入。

## 10. 建议技术选择

在未确认前不创建引擎工程。若以桌面端、2D UI/卡牌表现和快速数据迭代为首发目标，建议优先选择 Godot 4.x：纯逻辑测试、Resource/JSON 数据、Control UI 和轻量构建与本项目匹配。最终选择仍需结合目标平台、团队熟悉度和发布渠道确认。
