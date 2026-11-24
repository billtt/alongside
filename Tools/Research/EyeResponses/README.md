# 达达的眼神回应

训练使用 Humphrey、Stringer、Proops 和 McComb 发布的表 S1。18 只收容猫分别经历一段 60 秒的实验者表情中性和一段 60 秒的慢眨眼刺激。表中逐猫给出半眨、眯眼和完全闭眼的次数与累计时长。实验者在一分钟内可给出多次慢眨眼，缺少每次单独手势与回应之间的配对。[研究方法与表 S1，CC BY 4.0](https://pmc.ncbi.nlm.nih.gov/articles/PMC7761381/) · [作者公开的原表](https://mdpi-res.com/d_attachment/animals/animals-10-02256/article_deploy/animals-10-02256-s001.xlsx)

在项目根目录运行，训练只需要 Python 标准库。每次留出一整只猫的两段录像，用其余 17 只估计每种动作在两种情境下的每分钟发生率。按猫平均，每项计数的泊松负对数似然为 2.3561，忽略情境时为 2.4074，数值越低越好。时长取各只有过该动作的猫的每次平均时长，再跨猫取中位数。

```sh
mkdir -p local-work/eye-responses
curl -fL https://mdpi-res.com/d_attachment/animals/animals-10-02256/article_deploy/animals-10-02256-s001.xlsx -o local-work/eye-responses/table-s1.xlsx
python3 -B Tools/Research/EyeResponses/train.py local-work/eye-responses/table-s1.xlsx Resources/Pets/Dada/Attention/eye-events-v1.json
```

达达正面趴着时，菜单“对达达慢眨眼”显式送出一次社交信号。用相应情境的三种发生率，在八秒内采样第一个眼部动作，也可能继续休息。普通安静注视只在原有注意模型决定留意后，才在本次注视的剩余窗口用中性情境采样。这个指针对应关系、八秒窗口、恒定事件率假设和用于桌面播放的时长上限是应用设计。原表没有记录指针、触摸或单次回应延迟。整个过程在本机运行，实际互动不改写这些群体参数。
