# Alongside 开发说明

Alongside 是 macOS 13 及以上版本的桌面宠物。第一位角色达达是一只安静、爱躺着的英短蓝猫。主人选定的正脸、略收尖的嘴边、金色眼睛和偏低的卧姿，是校对新绘稿的依据。角色设计与历版绘稿的记录见 [达达的造型笔记](art/characters/dada/design-notes.md)。

## 构建与验证

在已安装 Xcode 命令行工具的 Mac 上运行以下命令。构建脚本生成同时支持 Apple Silicon 和 Intel 的应用，并在本机签名。对外公证需另行办理。

```sh
bash Tools/build.sh
dist/Alongside.app/Contents/MacOS/Alongside --check-petting
dist/Alongside.app/Contents/MacOS/Alongside --check-motion
dist/Alongside.app/Contents/MacOS/Alongside --check
```

`--check-petting` 可离屏验证触摸区域、双击、长按、爱心和回头节奏。`--check-motion` 可离屏校验揣手、侧卧和坐卧转换的前后接地点、支撑爪、步幅以及两侧台沿的逐帧碰撞。`--check` 需要已登录的桌面会话。它读取真实显示器和 Dock，也用模拟地形检查 Dock 两端、不同角色尺寸以及狭窄屏幕。验证覆盖互动的起势和收势、朝向、后颈与鼠标的对齐、逐帧接地、换姿时的首尾衔接、上下台阶方向以及背睡回头后的静止高度。双击生成的应用可查看实际效果。菜单栏爪印和右击角色均可打开控制菜单。

## 动作与画面

- `Resources/Pets/Dada/pet.json` 登记原画、绘制比例、锚点、互动接触位置与行为偏好。增加其他宠物时，独立保存其绘稿、性格参数和动作。当前启动入口加载达达。
- `Sources/Reaction.swift` 将相邻绘稿连接为可双向播放的序列。`Sources/Pet.swift` 让自动行为、菜单指令和鼠标互动从当前显示的那张画开始。正面趴姿转向背睡会先撑起胸口、四肢换步、再降低身体。转身体重随当帧的支撑爪移动，远侧支撑爪按台沿校准高度。被叫醒后保留 4–5.5 秒的注视，再收回原姿势。
- 无人打扰时，卧姿持续 10–18 分钟，睡姿持续 12–30 分钟。睡眠时胸背局部起伏，露出胡须的睡姿偶尔轻颤；接地线独立于呼吸。连续打扰会让达达起身，以日常步速走开。
- 校对大小时，在同一显示比例下比较眼距、肩宽和体态。保留站起来、身体转侧时自然产生的高度与轮廓差异。不同绘稿通过各自的等比尺寸与锚点对齐。轻点头背只留意一下。系统识别到双击后，达达在眯眼或侧卧闭眼时冒一颗爱心。背睡只回头看，正面和侧卧使用原画的眯眼表情。碰到腹部或爪子、长按或连续打扰时会避开。触摸区域随当前原画和朝向变化。
- `pet.json` 的 `levelView` 为每段动作指定平视校准。标定点依次给出横坐标、上半身的纵向位移比例和该处承重轮廓需消除的离地高度比例。静卧和蹲坐用 `restingContacts` 分别标出身体承重区和爪尾探出台沿的深度；起身时逐帧减小。行走靠支撑脚接地，腾空和悬提保留离地轮廓。
- `Sources/Artwork.swift` 使用透明原画的实体接地行绘制角色，同一坐标变换也用于点击和拖动。按住后向上拖到后颈高度才进入悬提姿势。设置中可调整至默认大小的 55%–200%。
- `Sources/Terrain.swift` 处理平台和安全落点。`Sources/DockMotion.swift` 分开处理上跳和下台阶。下台阶允许前爪先探到 Dock 以下，用留在台面上方的身体轮廓限制下降高度。上台先看台沿、蹬腿、前爪承重，再收后腿。左右镜像共用接触点，行走位移取自相邻两张原画中同一只支撑爪的位置差。
- `Sources/Dock.swift` 优先读取系统提供的 Dock 边界，必要时尝试窗口数据、已有权限下的辅助功能数据和布局估算。角色应用不会主动请求辅助功能或录屏权限。

README 保留双语纪念文字、简短介绍和一张循环动图。`docs/media/dada-looking-back.gif` 展示背睡、回头、再趴回原位，按程序的实际帧序播放。可分发的应用和压缩包位于本地 `dist/`。

## 骨骼实验（停用）

正式 App 使用逐帧 PNG。实验运行时保存在 `Tools/Rig/Runtime/`，分件和校准数据在 `Resources/Pets/Dada/Rig/`。以下命令可单独校对实验。

在项目根目录执行。Python 工具使用 Pillow、NumPy 和 SciPy。修改附件或关节映射后，从原生渲染的关键姿势校准跨视角对应关系，再测量下台阶轮廓并构建应用。

```sh
python3 -B Tools/Rig/bake.py
xcrun swiftc -O Tools/Rig/Runtime/{Artwork,Skeleton,Projection,Pet,Reaction,DockMotion}.swift Sources/{Dock,Terrain}.swift Tools/Rig/Review.swift -o /tmp/alongside-review
/tmp/alongside-review Resources/Pets/Dada local-work/rig-calibration/keys --keys
python3 -B Tools/Rig/registration.py local-work/rig-calibration/keys
/tmp/alongside-review Resources/Pets/Dada --bake-dock
/tmp/alongside-review Resources/Pets/Dada local-work/rig-calibration/native
python3 Tools/Rig/compare.py local-work/rig-calibration/native local-work/rig-calibration/dada-comparison.gif local-work/rig-calibration/dada-looking-back-rig.gif
```

`Tools/Rig/side.py` 定义侧面分件和四肢的逆向运动学，支撑脚按桌面行走速度锁定。
`registration.py` 从渲染结果配准视角，约束头部比例和网格形变。`views.py` 定义各投影视角的关节位置。预览左侧按旧版节奏取原画，右侧每秒采样 30 次骨骼，两个角色共用显示比例和地面。
