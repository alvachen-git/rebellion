# Assets

视觉、音频与字体资产目录。M2 前先确认画面方向、目标分辨率和授权要求。

## Art Direction

- `art_direction/visual_style_reference_qinglu_scroll_cards_v0.1.png`：Vertical Slice 已确认的“青绿绘卷卡阵”视觉基准图。
- 具体锁定规则、资产范围与防漂移检查见 `docs/design/美术视觉风格规范_青绿绘卷卡阵_V0.1.md`。

## Fonts

- `fonts/source_han/SourceHanSansCN-VF.ttf`：思源黑体 CN Variable，界面正文与数值字体。
- `fonts/source_han/SourceHanSerifCN-VF.ttf`：思源宋体 CN Variable，标题与叙事强调字体。
- 两套字体均来自 Adobe 官方 Source Han 发布仓库；对应授权全文随资产保存在同一目录。
- 当前已完成 Godot 4.6.1 / macOS 导入与中文显示检查；Windows 导入仍属于 ART-002 的跨平台验收项。

## A0-A1 Presentation Assets

- `art/cards/`：6 张代表卡牌插画与 A2 占位回退图。
- `art/characters/`：赵烈、周靖、韩月与普通/精英/Boss 三个敌军层级代表图。
- `art/combatants/`：战斗场上的透明全身人物模板；当前登记义军步兵/弓兵/骑兵与官军步兵/弓兵/重甲六个低细节 2.5D 模板。义军不使用制式胸甲，以粗布、绳带、绑腿和零散错配皮护具形成阵营识别；旧版保留作迭代对照。
- `art/scenes/`：主城第一阶段与河源县战场代表背景。
- `data/presentation/visual_assets.json`：卡牌、武将、敌军、页面和图标的稳定 ID 表现层绑定清单。
- 本批 PNG 是 AI 构图与风格中间稿，已用于竖切验证，但在人工修绘、伪文字清理、授权与一致性签字之前不得标记为正式量产资产。
- 战场人物模板必须是带真实 Alpha 的 RGBA PNG；棋盘格、纯色底或场景底被烘进像素时视为失败资产，不得登记进表现目录。
