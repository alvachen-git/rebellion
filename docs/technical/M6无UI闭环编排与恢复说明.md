# M6-01A 无 UI Vertical Slice 闭环编排与恢复说明

> M6-03A 已用 Save V4、共用15～25张公共基础牌组和军议堂替代本文件第3、4节的每武将固定20张长期牌组。M6-01A 的历史实现与验收数据保留用于追溯；当前规则见《M6军议堂与共用基础牌组说明》与 D-020。

## 1. 交付边界

本批建立应用层闭环：`新档 → 主城 → 出征整备 → 远征节点 → 战斗检查点 → 待最终结算 → 主城 → 补兵/研究/改牌组 → 再次出征就绪`。只交付可测试的领域与应用接口，不制作主城、地图或结算 UI，不改变 M3 卡牌、敌人和 Boss 平衡，也不新增第二个远征。

河源县成功后只调用 `expedition_readiness()` 证明新长期状态可再次整备；不会重跑同一任务。

## 2. 权威流程状态

`GameFlowCoordinator` 持有 SaveEnvelope、CampaignController、ExpeditionRunState、内容注册表和存档服务。流程阶段不单独保存，而从权威状态推导：

- Campaign 为 `game_over`：`game_over`；
- 无 Expedition：`main_city`；
- 有不可变待战请求：`combat_checkpoint`；
- Expedition 为 `active`：`expedition_map`；
- Expedition 为 `awaiting_settlement`、`retreated` 或 `failed`：`settlement_pending`。

主城补兵、研究、Loadout 修改和出征入口均由协调器执行阶段门禁。主城操作不触发自动存档，可写三个手动槽，或随下一战斗检查点进入自动档。

## 3. Save V3 与长期 Loadout

新档使用 Save V3 和 `content_version=0.6.0-m6-flow`。CampaignState 增加：

- `general_loadouts`：武将到20张长期牌组的映射；
- `loadout_system`：稳定 action ID 与审计流水。

Loadout 固定20张，校验公共卡解锁、专属卡归属与解锁、卡牌复制上限，以及武将存活状态。`set_loadout()` 对同一 action ID 幂等。

V2→V3 只补空字段并保留原 `content_version`，不授予卡牌。旧档缺牌组时，整备返回 `requires_legacy_loadout_recovery=true`；只有显式 `recover_legacy_loadouts()` 才授予当前15张原型起始公共卡并导入赵烈、周靖、韩月模板，操作进入审计流水且可重放。

新档原型资源、军队库存、三名武将、不可出征玩家占位和15张公共卡全部来自 `prototype_campaign_bootstrap.json`。玩家占位保持零属性、无天赋、无专属卡的【待设计】边界。

## 4. 出征冻结与成长换算

`DeploymentAssembler` 校验当前无远征、战役有效、武将健康可出征、兵种数量为非负整数、总兵力为正且不超库存/上限，以及长期 Loadout 合法。

未指定兵种数量时，按武将原始兵种比例和当前带兵上限使用最大余数法分配，保证整数和精确等于上限。出征冻结：

- 武将战斗快照；
- 精确兵种数量和归一化构成；
- 20张 Loadout；
- 当前永久升级分支；
- 已解析的升级卡覆盖定义。

`prototype_deployment_rules.json` 把相对初始属性的增量换算为战斗值：每1武勇增加1攻击；每1统率增加0.5防御和25带兵上限；政务不影响战斗；士气沿用静态定义。全部是【原型暂定】。

CombatRequest 的 `card_overrides` 优先于共享 ContentRegistry；CombatController 会完整校验覆盖定义。CombatResult 带 `battle_id`，M6 节点事务拒绝缺失、过期或串战结果。

## 5. 河源县节点解析与原子事务

`ExpeditionEncounterResolver` 以远征 Seed、稳定节点 ID 和固定盐派生战斗 Seed，并从 `prototype_heyuan_encounters.json` 解析路线敌人、精英、财富战、据点和 Boss。相同 Seed 与节点会得到相同敌人、战斗 Seed 和效果。

配置集中保存普通/据点/精英/财富/Boss 奖励、官道攻击 Buff、村野士气 Buff、路线战利品、15%兵力与20士气补给，以及 `boss_profile_revealed` 情报标记。节点解析生成稳定 `resolution_id`。

ExpeditionRunState 保存解析 ID、流水、情报、已结算 battle ID 和待解析检查点。节点完成、战利品、Buff、情报、据点削弱与路线开放在一个协调器事务中提交；重复 resolution 或 battle 不重复发奖。

## 6. 保存、恢复与两阶段最终结算

自动存档时点为：

- `new_campaign`；
- `combat_checkpoint_created`；
- `expedition_node_settled`；
- `expedition_terminal_checkpoint`；
- `expedition_final_settled`。

战斗回合内不保存。战斗恢复总是使用已保存的不可变 CombatRequest，从战斗开头重建。

Expedition restore 以 `expedition_id + seed` 从当前内容重新生成地图，校验已访问/完成/揭示/当前/可达节点、路线连通性、状态与待战 battle ID；存档中的 `visible_nodes` 只作旧 DTO 兼容，不作为恢复依据。

终止战斗分两阶段：

1. `submit_combat_result()` 推进 Expedition 到终态并保存 `settlement_pending`；
2. `finalize_expedition()` 提交 Campaign settlement，原子消费军队/武将/势力效果，清除 Expedition 并保存主城状态。

协调器在每个自动保存事务前保留深拷贝。保存失败时从上一 Envelope 重建 Campaign 和 Expedition；节点、奖励、战斗请求、长期结算和流程阶段全部回滚。最终保存失败会继续停在 `settlement_pending`，允许重试。

## 7. 自动化证据

`tests/run_m6_flow_tests.gd` 覆盖 Save V3、V2显式 Loadout 恢复、新档初始化、三武将默认整备、玩家占位/死亡/重伤/库存/上限、Loadout 长度/锁定/归属/复制/幂等、属性成长、升级卡真实战斗覆盖、确定性节点、情报/奖励/据点、地图/战斗/终态恢复、可见节点重建、解析流水校验、串战拒绝、保存失败回滚、两阶段最终化、分类兵损、撤退/士气失败/永久死亡/Game Over、回城补兵/研究/改牌组/手动保存，以及再次出征就绪，共139项断言。

M6 专项为139通过、0失败；包含本批在内的19组串行回归为1647通过、0失败。每组均执行严格错误标记扫描，除脚本精确白名单中的 Godot 4.6.1 macOS CA 证书噪声外，没有解析错误、无效调用、未处理异常或测试失败。
