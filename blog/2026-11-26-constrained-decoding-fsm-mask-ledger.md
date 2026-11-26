---
title: "约束解码的账本：128k 词表上每 token 的 mask 到底花在哪、状态数为什么随嵌套翻三倍、以及五个让合法 JSON 被拒的语义坑"
date: 2026-11-26T10:20:00+08:00
draft: false
tags: ["ai", "llm", "inference", "structured-output", "performance"]
categories: ["Tech"]
description: "结构化输出不是开关，是一台每 token 都要跑一次的字节级状态机。我把它手写了一遍：128k 词表上 naive 全表扫描每步 0.68~3.85 秒，token trie 压到 7.2~133 ms，但在自由字符串态仍要 2.7 秒——因为合法 token 占了 97.8%，剪枝等于没剪。裸 JSON 语法的可达状态数随嵌套深度每层约 3 倍（depth 6 已 4557 个，全表 bitmask 72.9 MB），这也是 xgrammar 只按栈顶节点缓存、把 1134/128k 个 token 留到运行时判定，才把 65.8 ms 压到 18 µs 的原因。后半部分是五个真踩过的语义坑：合并逗号态会接受尾逗号、EOS 不在接受态会逼出截断但可被 json.loads 的合法 JSON、additionalProperties 默认 true 会拒掉合法输入、数字与 Unicode 的边界、以及约束越紧推理越差（EMNLP 2024）。"
---

结构化输出（JSON mode、function calling、response_format）现在几乎是所有 LLM 服务的标配。用起来的感觉是"加个参数，输出就保证合法"，但把它当成一个免费的开关，是很容易付出代价的：这个开关在解码循环里插了一台**字节级状态机**，每生成一个 token 都要在词表上判一次"接上去还算合法吗"。

我把它从零手写了一遍（约 300 行纯 Python，带自检），然后拿真实的 128k 词表规模测了三种 mask 实现、状态数随深度的增长，以及五个只有实现过才会遇到的语义坑。数据在下面，结论先摆出来：

- mask 生成不是常数开销。naive 全词表扫描在 128k 规模上每步 **0.68~3.85 秒**（纯 Python）；token trie 把它压到 **7.2~133 ms**，但在"字符串内容"这种几乎全词表都合法的状态上仍然要 **2.68 秒**——剪枝等于没剪。
- mask 成本几乎完全由**合法 token 占比**决定，而不是由 grammar 复杂度决定。这直接解释了为什么生产实现要按"栈顶节点"预计算，而不是每步实时算。
- 裸 JSON 语法的可达状态数随嵌套深度**每层约 3 倍**：depth 3 是 150，depth 6 是 4557，depth 8 是 41169。depth 6 的全状态 bitmask 表就 **72.9 MB**，而且这还没算 schema 里的 pattern 和 enum。
- 语义坑比性能坑更容易出生产事故，而且多数坑的症状是"返回了一个能被 `json.loads` 解析、但语义已经被截断的对象"。

## 一、logits 和采样之间多了什么

标准采样：`logits[V] → softmax → sample`。约束解码在 softmax 前插一步，把非法 token 的 logit 置 −inf：

```python
def constrained_sample(logits, state, vocab, fsm):
    mask = fsm.allowed_mask(state)          # 每步都要算的东西
    logits = np.where(mask, logits, -np.inf)
    probs = softmax(logits)
    tok = sample(probs)
    return tok, fsm.advance(state, vocab[tok])
```

关键在于这一步只依赖"已生成的前缀"，跟 GPU 上的 forward 完全独立，所以可以并行、可以缓存。但也正是因为它每步都要做一次，**它的延迟会直接叠在 TPOT 上**。

算一笔 batch 账：8B 模型在 H100 上 batch=1 的 decode 一步大约 10~20 ms，CPU 有 10 ms 的余量；batch 开到 32，GPU 一步可能到 60 ms，但 CPU 要算 **32 个 mask**。如果每个 mask 花 1 ms，32 ms 还能藏进 GPU 时间里；花 3 ms 就是 96 ms，直接反超 GPU，服务变成 CPU-bound。这就是为什么大 batch 的服务上，"结构化输出一开吞吐掉一半"是真事。

## 二、把 JSON 编成字节级状态机

第一个决策是**按字节还是按字符**。必须按字节：

- token 的边界和字符边界不重合。BPE 词表里存在只含半个 UTF-8 汉字的 token（3 字节一个汉字，切在两个 token 之间很常见）。
- 按字符建 FSM，就要在推理时处理"这个 token 是半个字符"的拼接逻辑，等价于在状态机外面再挂一个缓冲，反而更慢更容易错。

所以 llama.cpp 的 GBNF、xgrammar 都是字节级的。我这份实现也是：状态 = 一个帧栈，每帧记录"我在什么结构里、期待什么"。

```python
def advance(stack, b, keyset=None):
    f = stack[-1]; k, d = f[0], f[1]
    if k == 'num':                       # 数字没有终止符, 靠"遇到非数字就收尾"推进
        if d == 'i':
            if is_digit(b): return stack
            if b == 0x2e: return stack[:-1] + (('num', '.'),)      # '.'
            c = complete_value(stack[:-1])                          # 值结束, 交还父帧
            return advance(c, b, keyset) if c else None
        ...
    if k == 'obj':
        if d == 'K0':                    # 刚开对象: 可以立刻 '}' 收空对象
            if b == 0x7d: return complete_value(stack[:-1])
            if b == 0x22: return stack + (('str', 'key', b''),)
            return None
        if d == 'K1':                    # 逗号之后: 必须来 key, 不许 '}'
            if b == 0x22: return stack + (('str', 'key', b''),)
            return None
    ...
```

注意 `K0` 和 `K1` 是两个状态。这不是洁癖——合并成一个，`{"a":1,}` 就会通过（下文踩坑第 1 条，我第一版就是这么错的）。

字符串帧还要带上前缀，因为 schema 约束的 key 集合、enum 值都要靠前缀判断：

```python
if k == 'str':
    mode, prefix = d, ex
    if b == 0x22:                                  # 收引号
        rest = stack[:-1]
        if mode == 'key': return rest[:-1] + (('obj', 'V'),)
        return complete_value(rest)
    newp = prefix + bytes([b])
    if keyset and mode == 'key':                   # schema 限定键名
        s = newp.decode('utf-8', 'ignore')
        if not any(kk.startswith(s) for kk in keyset): return None
    return stack[:-1] + (('str', mode, newp),)
```

## 三、三种 mask 实现的实测

环境：WSL、Python 3，合成词表 128000 条（从一个 698 KB 的语料里取 2~7 字节子串，平均 3.50 字节/token，覆盖全部 256 个单字节）。被约束的 schema 是一个 4 键对象（name/age/tags/score），带 keyset 限制。三种实现：

1. **naive**：对每个 token 逐字节走状态机；
2. **首字节索引**：先按首字节分组，只对"首字节合法"的分组做完整校验；
3. **token trie**：把词表建成字节前缀树，从当前状态出发只 DFS 走得通的分支。

| 状态 | naive | 首字节索引 | trie | 合法 token 数 |
|---|---|---|---|---|
| obj: 期待 key | 3251 ms | 3678 ms | 929.5 ms | 34161 |
| obj: 期待值 | 1302 ms | 237.5 ms | 92.3 ms | 4358 |
| obj: 逗号后期待 key | 681.6 ms | 103.1 ms | **7.2 ms** | 222 |
| string: 内容 | 3850 ms | 5581 ms | 2682.8 ms | 125126 |
| number: 数字位 | 1454 ms | 279.4 ms | 71.1 ms | 2869 |
| array: 期待值 | 1300 ms | 322.4 ms | 132.8 ms | 4515 |

三种实现的输出集合**完全一致**（脚本里做了逐项比对），差别只在成本。三个反直觉的读数：

**其一，首字节索引在强约束状态下收益很大，在自由状态下是负收益。**"逗号后期待 key"只有 222 个 token 合法，从 681.6 ms 降到 103.1 ms；但"期待 key"（34161 个 token 都以引号开头）反而从 3251 ms 涨到 3678 ms，"字符串内容"更夸张：3850→5581 ms。原因很简单：分组本身要扫一遍全表，当几乎所有 token 都通过首字节检查时，你只是把一次遍历变成了两次。

**其二，trie 的剪枝率取决于合法占比，而不是取决于"你用了 trie"。** 注意上表最后一列的 trie 遍历节点数几乎等于合法 token 数加一——说明每个合法 token 都要走到叶子，剪枝只发生在最后一步。在"字符串内容"状态，97.8% 的 token 合法，trie 只能省掉 2%，于是 2.68 秒。**任何每步扫全词表的实现，在自由文本段都会被打爆**，语言换成 C++ 只是把秒换成毫秒，量级关系不变。

**其三，状态级缓存的性价比高到离谱。** 同一状态的 mask 算一次存下来，命中成本实测 **0.466 µs**（含 128k 规模的 dict 查找），比重新算快 4~6 个数量级。代价是内存：那个 34161 个 token 的 mask 用 int64 存是 33.4 KB，用 bitmask 是 16 KB。

这就把问题从"怎么算得快"变成了"怎么少算"。

## 四、状态数：真正的成本在内存和缓存命中率

我统计了裸 JSON 语法（不含任何 schema 约束）在规范化后的可达状态数，按嵌套深度截断：

| 最大嵌套深度 | 可达状态数 | 相对上一层 |
|---|---|---|
| 3 | 150 | — |
| 4 | 489 | 3.3x |
| 5 | 1506 | 3.1x |
| 6 | 4557 | 3.0x |
| 7 | 13710 | 3.0x |
| 8 | 41169 | 3.0x |

**每加一层嵌套，状态数乘 3**。原因很直白：一个值可以是对象、数组、字符串、数字、字面量，进入容器后还要区分"首元素态"和"逗号后态"，组合数就是这个倍数。

按 depth 6 的 4557 个状态算全表 bitmask：`4557 × 16 KB ≈ 72.9 MB`。这还是最朴素的 JSON 语法，没有 `pattern`、没有 `enum`、没有 `anyOf`。一个带 `^\d{4}-\d{2}-\d{2}$` 的日期字段，正则 DFA 就多出十来个状态；如果字段有 8 个，且每个都可能出现在两个分支里，状态数是乘法关系，很容易到十万级——按全表缓存就是 GB 级，根本装不下。

所以工业实现（xgrammar）的核心不是"更快的 C++ 循环"，而是三件事：

- **只按栈顶节点缓存**：`context-independent` 的 token（匹配过程不改变栈、或只改栈顶）可以根据栈顶节点预判，运行时直接查表；只有"跨越规则边界、需要看整条栈"的 token 才实时判定。
- **token 分类**：Llama-3.1 的 128k 词表上，`context-dependent` 的 token 只有 **1134 个（不到 1%）**，其余全部预计算。这才是数量级的来源。
- **grammar 变换**（rule inlining、context expansion）把这个比例再压下去，同时让 grammar 更容易被规则内联。

论文里的消融数据很能说明问题（每 token 延迟）：

| 优化 | 每 token 延迟 |
|---|---|
| PDA 基线 | 65.776 ms |
| + 节点合并 | 38.280 ms |
| + 自适应 token mask 缓存 | 0.154 ms |
| + 规则内联 | 0.035 ms |
| + 上下文扩展 | **0.018 ms** |

缓存一步就贡献了 248 倍。最终 18 µs/token，比 GPU 的 forward 小一个数量级，再和 GPU 执行 overlap，端到端开销接近零。这也解释了为什么它能报"JSON Schema 每 token 40 µs 以内，XML 和 Python DSL 在 200 µs 以内"。

**选型时的判断标准**：别只看 README 写没写 "supports JSON Schema"，问两个问题——有没有按状态缓存 mask？有没有把词表预分类？两个都没有的实现，在小模型上看起来能用，一上大 batch 就现原形。

## 五、五个语义坑

性能可以调，语义错了会静默丢数据。下面五个都是我写这份实现时真踩到的。

### 1. 逗号后的状态不能和首态合并

我第一版的 `obj` 只有 `K` 一个"期待 key"状态，`[` 之后也只有 `V` 一个"期待值"状态。18 条自测用例挂了 7 条，其中一条是 `{"a":1,}` 被接受。

JSON 语法里，`{}` 是合法的空对象，`{"a":1,}` 不是。两个状态必须分开：`K0`（刚开括号，允许 `}`）和 `K1`（逗号之后，必须来 key）。数组同理 `V0` / `V1`。

这条的普适教训：**约束解码的测试集必须有负例**，而且负例要覆盖"接近合法"的变形。只测正例的实现，能通过 100% 的正常请求，然后在某个上游 SDK 传了尾逗号时崩掉——注意，是**你的 grammar 允许了非法输入**，下游解析器才会崩。

### 2. EOS 只在接受态合法，数字还有个隐式收尾的例外

状态机跑完必须判断"这里能不能停"。如果 `{"a":1` 这种状态不允许 EOS，模型会被逼着继续生成——但 grammar 可能允许它先输出一个 `}` 收尾，再输出 `{` 开新对象，于是你拿到 `{"a":1}{"b":2}` 或者一长串空白，直到 `max_tokens`。

更隐蔽的是数字：JSON 的数字**没有终止符**，`-0.0e10` 结尾是合法 JSON，但状态机停在"指数位"这个中间态。如果 EOS 判断只看"是否处于接受态"，这个输入会被判非法。我的自检里 `-0.0e10` 就是这么挂的。正确做法是在 EOS 时对未闭合的数字做一次隐式收尾：

```python
def accepts(data, keyset=None):
    st = (('root', 'V'),)
    for b in data:
        st = advance(st, b, keyset)
        if st is None: return False
    if st[-1] == ('root', 'DONE'): return True
    if st[-1][0] == 'num' and st[-1][1] in ('0', 'i', 'f', 'ed'):
        return complete_value(st[:-1]) == (('root', 'DONE'),)   # 数字隐式收尾
    return False
```

线上症状：一小部分请求（我见过的是千分之几量级）在 `finish_reason=length` 下返回一个**语法完整但语义被截断**的对象。它能被 `json.loads` 解析，schema 校验也可能通过（因为字段都在），然后下游拿它去做业务判断。这是最难查的一类问题——监控里既没有解析错误，也没有 5xx。

### 3. `additionalProperties` 默认是 true

JSON Schema 里，`additionalProperties` 默认 **true**：你只声明了 `name` 和 `age`，模型输出 `{"name":"x","age":1,"note":"ok"}` 是**完全合法**的。如果 grammar 只拿 `properties` 的 key 集合建 FSM（就像我在基准里传了 `keyset`），这个合法输入会被 grammar 拒掉，模型只能一遍遍重试或者被逼着选错。

反过来，如果 schema 显式写了 `additionalProperties: false`，grammar 就必须严格限制 key 集合。这两者必须一致，而多数"schema 转 grammar"的库在这里默认取严的那一边。

工程建议：**服务端 grammar 用宽松 JSON 语法 + 事后做 schema 校验**，只对真正影响解析的字段（枚举、固定格式）收紧。把全部 schema 语义压进 grammar，收益很小，风险是"合法输入被拒"和"grammar 编译失败"两条。

### 4. 数字和 Unicode 的边界

- `1e400` 在 IEEE float 下是 `inf`，`json.loads` 不报错，但下游存 float32 列就炸；超过 2^53 的整数在 JS/Python 的 float 路径上静默丢精度，超过 int64 直接溢出。
- RFC 8259 明确禁止前导零、`.5`、`1.`、`+1`。我的自检里这几条都是负例——但很多"JSON 模式"的实现接受它们，因为底层复用了宽松解析器。
- 字符串里的 `\ud800` 是**未配对的代理项**，按规范是非法 JSON，但 Python 的 `json.loads` 接受它（产生一个 lone surrogate），某些 Rust/Go 的严格解码器会拒绝。同一份输出，两边行为不同。
- 键的规范化：`"café"` 用 NFC 和 NFD 两种编码在字面上不同、在视觉上相同，如果上游做了 NFKC 归一化，两个键会撞在一起。再加上 `{"a":1,"a":2}` 这种重复键——Python 取最后一个，很多解析器取第一个，grammar 一律放行。

这些不属于 grammar 的职责，属于**入口校验**的职责。grammar 只保证"能被解析"，不保证"能被正确消费"。

### 5. 约束越紧，推理越差

这条不是实现问题，是模型问题。EMNLP 2024 Industry 的 *Let Me Speak Freely?* 系统测过：约束解码（JSON mode）会显著降低模型的推理能力，**约束越紧退化越明显**；但分类类任务的准确率反而会上升。也就是说，你在"格式"上换来的确定性，代价可能落在"内容正确性"上。

可用的缓解手段，按侵入性从低到高：

1. **reasoning 段不约束**：让模型先自由写分析，只对最后一个 segment（结论对象）上约束。多数 API 的 `response_format` 支持不了这个，需要自建或在 prompt 层做两段式。
2. **两段式调用**：第一次自由生成，第二次用 tool call 把结果"抄"进结构化字段。多一次请求，但在难题上通常净收益为正。
3. **降级路径**：grammar 失败或解析失败时退回自由生成 + 重试解析，并且**按 schema 版本统计降级率**。没有这条，你会误以为结构化输出"一直都能用"。

## 六、上线要盯的六个指标

结构化输出出问题时，症状往往不是报错，而是"数据看起来正常但偶尔不对"。这六个指标能提前暴露：

```python
# 伪代码, 直接挂到推理服务的 per-request 埋点上
M = {
  "grammar_mask_us":      histogram(),   # 每步 mask 生成耗时, 看 p99 不是均值
  "mask_cache_hit":       counter(),     # 状态缓存命中/未命中
  "mask_cache_bytes":     gauge(),       # 缓存内存, 有上限才安全
  "finish_reason_length": counter(),     # 撞 max_tokens 的比例, 正常应接近 0
  "grammar_fallback":     counter(),     # grammar 失败/超时后降级的比例
  "schema_compile_ms":    histogram(),   # schema 编译耗时, 长尾常来自 pattern
}
```

其中 `finish_reason_length` 是性价比最高的一条：它的正常值应该接近 0，一旦冒头就意味着"模型被 grammar 逼着生成停不下来"，对应的正是 EOS 接受态那个坑。`mask_cache_bytes` 也要有上限——状态数按嵌套深度每层乘 3，一个复杂 schema 加上 `anyOf` 很容易把缓存撑爆，然后你看到的是延迟抖动而不是内存告警。

## 七、收尾清单

- mask 的成本由**合法 token 占比**决定。自由文本段接近 100% 合法，任何"每步扫全词表"的实现都会崩，语言换成 C++ 只是把秒换成毫秒。
- 状态数随嵌套每层约 3 倍，别指望全表缓存。按栈顶节点缓存 + 词表预分类，是唯一的数量级解法（实测 65.8 ms 到 0.018 ms）。
- 状态机里"首元素态"和"逗号后态"必须分开；测试集必须有负例，尤其是接近合法的变形。
- EOS 只在接受态合法，但数字要允许隐式收尾。否则你会拿到能被 `json.loads` 解析的截断对象。
- schema 语义别全压进 grammar：`additionalProperties` 默认 true，用声明的 properties 建 FSM 会拒掉合法输入。
- 数字和 Unicode 的边界属于入口校验，不属于 grammar。
- 约束越紧推理越差（EMNLP 2024），reasoning 段能不加约束就不加。

我这份实现和基准脚本是纯 Python、无第三方依赖的，约 300 行，18 条自检用例（含 7 条负例）。跑一遍最直观的感受是：写状态机不难，把"什么算合法"这件事想清楚才难——这四个坑里有三个是"我的 grammar 接受/拒绝了不该接受/该接受的东西"，没有一个性能和它有关。
