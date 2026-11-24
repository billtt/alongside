# Alongside 开发说明

Alongside 是 macOS 13 及以上版本的桌面宠物。第一位角色达达是一只安静、爱躺着的英短蓝猫。主人选定的正脸、略收尖的嘴边、金色眼睛和偏低的卧姿，是校对新绘稿的依据。角色设计与历版绘稿的记录见 [达达的造型笔记](art/characters/dada/design-notes.md)。

## 构建与验证

在已安装 Xcode 命令行工具的 Mac 上运行以下命令。构建脚本生成同时支持 Apple Silicon 和 Intel 的应用，并在本机签名。对外公证需另行办理。

```sh
bash Tools/build.sh
dist/Alongside.app/Contents/MacOS/Alongside --check-petting
dist/Alongside.app/Contents/MacOS/Alongside --check-motion
dist/Alongside.app/Contents/MacOS/Alongside --check-attention
dist/Alongside.app/Contents/MacOS/Alongside --check-invitation
dist/Alongside.app/Contents/MacOS/Alongside --check
```

`--check-petting` 可离屏验证触摸区域、双击、长按、爱心和回头节奏。`--check-motion` 可离屏校验揣手、侧卧和坐卧转换的前后接地点、支撑爪、步幅以及两侧台沿的逐帧碰撞。`--check` 需要已登录的桌面会话。它读取真实显示器和 Dock，也用模拟地形检查 Dock 两端、不同角色尺寸以及狭窄屏幕。验证覆盖互动的起势和收势、朝向、后颈与鼠标的对齐、逐帧接地、换姿时的首尾衔接、上下台阶方向以及背睡回头后的静止高度。双击生成的应用可查看实际效果。菜单栏爪印和右击角色均可打开控制菜单。

## 动作与画面

- 0.1.18 的自然理毛从脸与前爪、胸、肩侧和后爪中选部位。一个本机训练的小网络读取本轮最近的部位记录，下一组可以继续洗同处或换地方。真实理毛时长模型在每组收势时决定能否继续。菜单“洗洗脸”会从润爪开始，展示全部四组，适合校稿。[训练数据、留出验证与复训](Tools/Research/Grooming/README.md)
- 正面趴姿下的安静注视可以带出半眨或眯眼，菜单“对达达慢眨眼”提供一次八秒的回应机会。半眨、眯眼与合眼的发生率及典型时长从 18 只猫的成对观察估计，播放期间保持卧姿和休息时钟。模型随应用打包，主人的个性档案独立保存。[原始记录与训练方法](Tools/Research/EyeResponses/README.md)
- 行走收步接坐姿时借用四脚承重与半坐绘稿。借用只作用于指定相邻帧。坐姿转向、侧卧转正面与背睡落稳分别校准全身高度、眼距和轮廓宽度。`--check-motion` 检查左右镜像、途中打断和这些相邻帧的形状变化。[收步和起身对照](docs/media/dada-transition-comparison.gif)
- 0.1.17 支持招手。在正面趴姿的脸旁悬停约半秒，沿同一侧慢慢移开一两个身长并停住。达达会结合招手方式、休息倾向、近期打扰、熟悉度和单独的招手偏好，决定是否跟来。起身、换脚和趴下共用原画的支撑爪标定，跟步全程留在同一块平台；可用空间不足时只抬眼。菜单“互动习惯”可教它更愿意跟来或留下。招手模型在 `Sources/Invitation.swift`，变速行走在 `Sources/ApproachGait.swift`。`--check-invitation` 在已登录桌面验证完整手势、不同停点和台沿；`Tools/InvitationReview.swift` 用正式绘制路径生成[招手预览](docs/media/dada-invitation.gif)。
- 0.1.16 启动后达达先趴下。指针从远处靠近清醒正面趴卧的达达时，它会选择继续休息或把视线和耳尖转向指针。轻触、注视和离开指针都有界限，短暂注意沿用原休息时钟。菜单“趴一会儿”可进入这一姿态，“互动习惯”可教它多看或多休息。完成温和的头背双击会慢慢增加熟悉度，两次计入至少相隔半小时。偏好、熟悉度和上次计入的时间记在本机，可在同一菜单清空。
- `Sources/RestBehavior.swift` 读取真实家猫观测训练的动作切换模型和卧姿持续概率。达达保留自己的长卧、睡眠时间与原有避让规则，清醒活动切换只在有绘稿的动作中采样。`Sources/Attention.swift` 读取独立的合成桌面互动模型，在靠近或轻触时运行。两份基础权重、训练数据出处和更新方式见[本地学习研究](docs/dada-local-learning.md)。`--check-attention` 在已登录的桌面会话内用隐藏窗口验证靠近、移开、休息时钟与触摸中断。`Tools/AttentionReview.swift` 通过正式控制器和绘制路径重放[互动预览](docs/media/dada-attention.gif)。

- `Resources/Pets/Dada/pet.json` 登记原画、绘制比例、锚点、互动接触位置与行为偏好。增加其他宠物时，独立保存其绘稿、性格参数和动作。当前启动入口加载达达。
- `Sources/Reaction.swift` 将相邻绘稿连接为可双向播放的序列。`Sources/Pet.swift` 让自动行为、菜单指令和鼠标互动从当前显示的那张画开始。正面趴姿转向背睡会先撑起胸口、四肢换步、再降低身体。转身体重随当帧的支撑爪移动，远侧支撑爪按台沿校准高度。被叫醒后保留 4–5.5 秒的注视，再收回原姿势。
- 无人打扰时，卧姿持续 10–18 分钟，睡姿持续 12–30 分钟。睡眠时胸背局部起伏，露出胡须的睡姿偶尔轻颤；接地线独立于呼吸。连续打扰会让达达起身，以日常步速走开。
- 清醒正面趴卧时有独立的胸背呼吸和随机眨眼。理毛沿当前趴姿接入，润湿前爪后可擦同侧脸颊，舔肩时回转头颈，舔后爪时先坐起、抬腿。关键绘稿和衔接帧位于 `Resources/Pets/Dada/Grooming/`。
- 理毛循环用透明单张绘稿表现下探、接触、颈肩回抽、抬爪或转腕，起身与放腿只在进出动作时播放。`--check-motion` 检查理毛接地、自主短组、完整展示与中断路径。`Tools/GroomingReview.swift` 可按正式渲染导出逐帧图与 30 fps 时间表。向 `Tools/GroomingComparison.py` 依次传入两版导出目录及 GIF 文件名，可生成[理毛前后对照](docs/media/dada-grooming-comparison.gif)。
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
