# 从真实家猫观察学习动作顺序

这个离线实验回答一个限定的问题。已知一段行为刚刚结束，给出紧邻的前一次行为、刚结束的行为和它持续的秒数，预测接下来的动作。五个可选类别为卧、坐、站、行走或小跑、自我理毛。独立的经验模型根据姿势和已过时长逐秒估计切换概率，二者合起来能模拟一段连续行为。Alongside 本身不依赖这些研究工具。

## 数据与复现

Michelle Smit 于 2023 年公布 12 只群养家猫的逐秒人工标注。这里只需下载 817,024 字节的标注文件。数据采用 CC BY 4.0，本实验将原始标签归为五类并估计模型参数。原研究在第一天工作人员活动、喂食的 09:00–14:00 时段标注，论文报告约 46 小时 20 分钟，显式的人类接触和睡眠标签在本公开表中均为零。[原始数据 v2](https://doi.org/10.6084/m9.figshare.23605842.v2) · [研究方法](https://pmc.ncbi.nlm.nih.gov/articles/PMC10458840/) · [使用许可](https://creativecommons.org/licenses/by/4.0/)

在项目根目录执行。数据、虚拟环境及估计出的参数存放在本地研究目录。训练需 NumPy、SciPy、pandas 与 pyreadr，推断只需 NumPy。

```sh
mkdir -p local-work/observed-behavior
python3 -m venv local-work/observed-behavior/venv
source local-work/observed-behavior/venv/bin/activate
python -m pip install numpy scipy pandas pyreadr==0.5.9
curl -fL https://ndownloader.figshare.com/files/41409933 -o local-work/observed-behavior/anno_data.RDATA
python Tools/Research/ObservedBehavior/behavior.py train local-work/observed-behavior/anno_data.RDATA --output local-work/observed-behavior/base.json
python Tools/Research/ObservedBehavior/behavior.py next local-work/observed-behavior/base.json --previous lie --current groom --seconds 15
python Tools/Research/ObservedBehavior/behavior.py rollout local-work/observed-behavior/base.json --seconds 120 --seed 67
```

0.1.16 的桌面版本只需神经权重和退出概率表。可在项目根目录运行下列命令从训练结果导出；数据来源、署名和许可链接会保存在模型中。互动偏好另存在 macOS 的应用设置里。

```sh
python3 Tools/Research/ObservedBehavior/behavior.py export-app local-work/observed-behavior/base.json Resources/Pets/Dada/Behavior/transitions-v1.json
```

训练入口会核对作者公布的 MD5，先对 12 只猫分别留出验证，再从全部数据估计并保存参数。推断示例给定“趴卧之后理毛 15 秒，且现在结束理毛”，全量小网络输出继续卧下约 72%、坐约 21%、站约 5%、移动约 2%。这些数值是候选结果的相对概率。

## 方法与结果

程序按猫和时间排序。每秒须只有一个已知且纳入实验的标签。时间跳跃、离开镜头、其他行为、空标签、多重标签都切断序列。每段连续观察的第一个动作起始时刻未知，末尾动作的下一步未知，两者都无法作为待预测的中间动作。公开表共 167,927 行，38,395 行带有离开镜头标记。筛选得到 115,838 秒和 1,582 段可用连续观察，其中有 1,349 次具备完整输入与目标的切换。每只猫贡献 22–233 次。

表格为逐只猫留出，先算每只猫的指标再取等权平均。所有方法都已知发生切换，均排除当前类别。负对数似然采用自然对数，越低表示给真实下一步的概率越高。

| 方法 | 输入 | 负对数似然 | 首选命中 |
| --- | --- | ---: | ---: |
| 后继类别频率 | 整体频率，排除当前动作 | 1.250 | 51.84% |
| 一阶转移表 | 当前动作 | 0.604 | 82.66% |
| 分层计数表 | 前一次和当前动作、持续时长分箱 | 0.496 | 84.88% |
| 小神经网络 | 前一次和当前动作、连续的对数时长 | 0.465 | 84.82% |

小网络有 11 个输入、8 个 tanh 隐藏单元、5 个输出，共 141 个权重和偏置，在 CPU 上用 L-BFGS 优化。分层计数表先估计当前动作的后继分布，再逐层加入前一次动作和持续时间，用四个先验样本平滑每一层。时长分箱的边界为 2、8、32 秒。`next --method timed_counts` 可直接使用该计数基线。相同线索下，两种方法的首选动作命中率几乎一样。对 82.28% 的入选切换，后继动作恰好回到前一次动作，典型模式有坐、理毛、再坐。

这些入选的完整动作段中位时长为 6 秒，纳入条件偏向较短且邻近行为可见的片段。长卧、夜间睡眠、触摸反应和长期个性需要其他观察。即使留出了一只猫，这些动物也共享两间群养圈舍和护理时间，迁移到家庭环境仍需重新验证。

## 120 秒离线模拟

从运动转为坐的时刻设为零。每过一秒，先由退出概率决定是否切换，发生切换时由神经网络采样下一动作。种子 67 生成“坐 12 秒、理毛 39 秒、坐 15 秒、理毛 6 秒、坐 2 秒、理毛 33 秒、坐 3 秒、理毛 10 秒”。最后的 10 秒在模拟终点截断，达达可能继续理毛。这一回合反复交替的两种动作也暴露出短时模型缺少长期状态。

退出模型按姿势及已过秒数分箱，边界为 2、8、32、128、512 秒。每段连续观察的首个动作起点未知，予以排除。对于后面的动作，只要下一秒可见且仍属于五种行为，就可记录一次继续或切换。末尾动作在观测终止前的所有已知继续秒都提供信息，最后一秒的去向记为未知。每个时长分箱用该姿势的总体退出率和平滑系数 4 估计。共获得 69,993 个有明确结果的秒间隔。逐只猫留出，对“下一秒是否切换”的二元负对数似然按猫等权平均，仅看姿势得 0.0921，增加持续时长得 0.0868。退出指标的单位是每个可见秒间隔，上表的指标单位是每次已知切换。

进入其他行为（例如进食）也会结束训练片段。因而这里估计的是五类可见行为之间的退出机会，完整日常生活中的时长分布需要覆盖更多状态、连续时段和家庭场景。
