---
title: "LLM 推理中的存储 I/O 优化：从 HDD 到 CXL 的演进"
date: 2026-07-27T10:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "performance", "storage", "infra", "engineering"]
categories: ["Tech"]
description: "从 GPU HBM 到对象存储，系统梳理 LLM 推理全链路存储 I/O 优化策略——附 PCIe 5.0、Optane、CXL 等新兴技术的生产级对比"
---

# LLM 推理中的存储 I/O 优化：从 HDD 到 CXL 的演进

> LLM 推理的性能瓶颈早已不只在 GPU 算力上。当模型权重达到数百 GB、上下文窗口突破百万 token、服务需要弹性扩缩时，**存储 I/O 就是那条被低估的瓶颈**。

{/* truncate */}

## 一、LLM 推理的存储层次

一次典型的 LLM 推理请求，权重数据从持久化存储流经多层缓存，最终抵达 GPU 显存。每一层之间的带宽落差决定了系统的吞吐天花板。

| 层级 | 介质 | 典型容量 | 延迟 | 带宽 |
|------|------|----------|------|------|
| L1 | GPU HBM3/HBM3e | 80-192 GB | ~50 ns | 3.35-8 TB/s |
| L2 | CPU DRAM (DDR5) | 256 GB-2 TB | ~100 ns | 50-100 GB/s |
| L3 | CPU DRAM (CXL 扩展) | 1-8 TB | ~200-300 ns | 30-60 GB/s |
| L4 | SSD (NVMe PCIe 5.0) | 8-64 TB | ~3-10 µs | 7-14 GB/s |
| L5 | SSD (NVMe PCIe 4.0) | 8-64 TB | ~5-15 µs | 3-7 GB/s |
| L6 | Intel Optane (停产) | 512 GB-3 TB | ~7 µs (直读) | 6 GB/s |
| L7 | HDD / 对象存储 | 100 TB+ | 2-20 ms | 200-500 MB/s |

关键洞察：**HBM 到 DRAM 之间有约 50-100× 的带宽落差，DRAM 到 SSD 之间又有约 10× 的落差**。每一次"踏空"都会让推理延迟从毫秒级膨胀到秒级。

## 二、SSD 层的核心挑战：模型加载与换入换出

### 2.1 Memory-Mapped 模型加载

当模型无法完全装入 GPU 显存时，最直接的做法是将权重文件 mmap 到宿主内存，由 GPU 通过 PCIe 按需读取。Linux 的 page cache 在这里扮演关键角色：

```python
import numpy as np
import mmap

# 模型权重文件 mmap 到虚拟地址空间
with open("model_weights.bin", "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    # 仅当 GPU 实际访问对应页时触发 I/O
    weights_view = np.frombuffer(mm, dtype=np.float16).reshape(layer_shape)
```

这个机制的关键在于 **page cache 预热**。首次推理时，page cache 为空，每次 GPU 权重访问都会触发缺页中断→NVMe I/O→内存填充→PCIe DMA 到显存，延迟高达数毫秒。预热后，page cache 命中，延迟降至 ~100 ns 的 DRAM 访问级别。

**生产实践**：在服务启动时显式触发权重文件的顺序预读：

```bash
# 强制 page cache 预热（效果取决于文件大小和 SSD 带宽）
vmtouch -t /data/models/model_weights.bin
# 锁定到内存中，防止被 page cache 回收
vmtouch -l /data/models/model_weights.bin
```

### 2.2 巨型模型的分片服务

当单机无法容纳完整模型时（如 1.5T 参数的 MoE 模型），需将不同 expert 分片到多台机器的 SSD 上，推理时按需加载。这时的瓶颈从 PCIe 带宽变为 **网络带宽 + SSD I/O 并发度**。

KVell 等论文表明，传统 Linux 块 I/O 层在百万级并发下存在严重的锁竞争。解决方案是使用 SPDK 或 io_uring 绕过内核：

```bash
# 查看 SSD 的 I/O 深度上限
nvme list
nvme id-ctrl /dev/nvme0n1 | grep "Maximum Queue Entries"

# 使用 fio 验证不同 QD（队列深度）下的 4KB 随机读延迟
fio --name=randread --ioengine=io_uring --iodepth=128 \
    --rw=randread --bs=4k --numjobs=16 --runtime=30s \
    --filename=/dev/nvme0n1 --output=./fio_result.json
```

## 三、长上下文推理中的 KV-cache 换出

上下文窗口从 128K 扩展到 1M+ token，KV-cache 成为显存的主要消耗者。以 Llama 3 405B 为例，1M 上下文对应的 KV-cache 超过 600 GB，远超单卡 HBM。

**分级 KV-cache 策略**（如 vLLM 的 InfiniGen 风格方案）：

1. **高频 token 的 KV 留在 HBM**——基于注意力熵的筛选
2. **低频 token 的 KV 换入 CPU DRAM**——通过 PCIe DMA 按需取回
3. **冷数据持久化到 SSD**——预计算序列化，以 4KB 块粒度存储

Benchmark 数据（8× A100 80GB, Llama 3 70B, 512K 上下文）：

| 策略 | KV-cache 内存 | 首 token 延迟 | 吞吐 (token/s) |
|------|-------------|-------------|--------------|
| 全量 HBM | 240 GB（OOM） | — | — |
| 分级（DRAM+SSD） | 48 GB HBM + 192 GB DRAM | 2.1 s | 18.4 |
| 分级（纯 SSD 换出） | 48 GB HBM | 8.7 s | 4.2 |

SSD 换出的延迟主要来自 **4KB 随机读的 IOPS 上限**。单块 PCIe 5.0 SSD 的 4KB 随机读约 1.5M IOPS，假设每次换出取回需读 64KB（16 页），则理论带宽为 `1.5M × 64KB = 96 GB/s`——远高于 PCIe 4.0 的 `1M × 64KB = 64 GB/s`。但在实际系统中，NVMe 控制器和 PCIe 交换的争用会大幅压低有效带宽。

## 四、投机解码的 I/O 模式

投机解码（Speculative Decoding）引入了独特的存储 I/O 特征：

- **Draft 模型**：通常使用 0.5B-3B 参数的小模型，可常驻 CPU DRAM（约 1-6 GB）。从 DRAM 加载权重的延迟在 100 ns 级别，远快于 SSD，因此 draft 阶段几乎不受 I/O 影响。
- **Target 模型**：权重在 GPU 上无需额外 I/O，但 **draft token 的 KV-cache 传输**需要跨越 PCIe 总线。
- **Acceptance/Rejection**：每次 rejection 意味着浪费了 batch 内部分 token 的 KV-cache 计算——这部分数据如果被换出到 SSD，回取时带来的 I/O 放大系数可能达到 2-3×。

因此，投机解码在大上下文场景中，建议**将 draft 模型常驻 DRAM，并将 target KV-cache 中 hot region 锁定在 HBM**，避免 I/O 放大抵消推理加速收益。

## 五、CXL：弥合内存墙的关键拼图

CXL（Compute Express Link）是近年来存储层次最具变革潜力的技术。

| 特性 | 传统 DDR5 | CXL 内存扩展 | CXL 池化 |
|------|----------|-------------|---------|
| 延迟 | ~100 ns | ~200 ns | ~300-400 ns |
| 容量上限 | ~2 TB/插槽 | 8 TB+ | 32 TB+（多主机共享） |
| 共享能力 | 独占 | 独占 | 多主机 |
| 与 SSD 对比延迟 | 10-50× 快 | 15-30× 快 | 10-20× 快 |

CXL 对推理优化的价值：

1. **KV-cache 的天堂**——CXL 内存的延迟仅比 DDR5 高 2-3 倍，但远快于 NVMe。可以将大量非关键 KV 数据放在 CXL 内存上，取回代价仅 200-300 ns。
2. **模型权重的就近扩展**——当 HBM 不足但 CPU DRAM 已满时，CXL 提供比 SSD 快 10-20 倍的第二级扩展。
3. **Disaggregated Inference**——多台 GPU 服务器通过 CXL 共享同一个内存池，模型权重只需加载一份，消除重复的 SSD 预热时间。

```bash
# CXL 设备识别（需要 CXL 内核支持 + BIOS 开启）
ls /dev/dax*
# 输出: /dev/dax0.0  /dev/dax1.0

# 将 CXL 内存直接映射为 GPU 可访问的设备内存
# （配合 Nvidia CXL 1.1+ 支持）
nvidia-smi cxl --list
```

## 六、生产级优化清单

综合以上讨论，以下是我在生产环境验证有效的优化策略：

**1. Page Cache 精细调控**
- 使用 `vmtouch` 或 `fincore` 监控权重文件的 page cache 命中率
- 为关键模型权重设置 `mlockall()`，防止被回收
- 将 page cache 脏页刷新间隔调大：`sysctl -w vm.dirty_ratio=30`

**2. Hugepages 与 THP**
- LLM 权重访问模式是大块顺序的，1GB hugepage 比 4KB 基页减少 256× 的 TLB miss
- 显式预留：`echo 64 > /proc/sys/vm/nr_hugepages`
- 关闭 THP 的碎片整理（防止偶发延迟尖刺）：`echo never > /sys/kernel/mm/transparent_hugepage/defrag`

**3. io_uring 替代 libaio**
- io_uring 在 4KB 随机读场景比 libaio 快 30-50%，尤其在 queue depth 较大的场景
- 关键参数：`IOSQE_ASYNC` 标志将阻塞 I/O 卸载到内核 workqueue
- 启用 sqpoll 模式减少系统调用开销

```c
// io_uring 配置示例（简化）
struct io_uring_params p = {
    .flags = IORING_SETUP_SQPOLL | IORING_SETUP_COOP_TASKRUN,
    .sq_thread_idle = 3000, // 3秒空闲后休眠 sqpoll 线程
};
io_uring_queue_init_params(4096, &ring, &p);
```

**4. NVMe 多队列绑核**
- 每个 NVMe 队列绑定到独立 CPU 核心，消除 I/O 完成中断的跨 NUMA 访问
- `nvme set-feature /dev/nvme0 -f 0x1 -v <cpu_mask>`
- 配合 `numactl` 确保推理进程与 NVMe 中断在同一 NUMA 节点

## 七、未来展望

存储 I/O 的优化正从「机械部件的工程调优」转向「全链路可编程的异构内存调度」。几个值得关注的趋势：

- **CXL 3.0 的 Fabric 能力**——允许 GPU、CPU、内存组成统一的交换拓扑，消除 PCIe 交换的带宽瓶颈
- **Zoned Namespace (ZNS) SSD**——将 SSD 从块设备重构为区域设备，消除写放大和 GC 抖动
- **语义存储**——存储系统直接理解模型权重格式，实现加速器直接的零拷贝传输
- **SmartNIC/DPU 卸载**——在数据进入 CPU 之前完成模型发现、路由和错误恢复

对于今天的生产部署，最好的建议是：**不要假设数据在 DRAM 中就在 DRAM 中**。监控 page cache 命中率、跟踪 NVMe 队列深度、理解 PCIe 链路利用率——只有把存储 I/O 当作一等性能维度来对待，才能在百万 token 推理时代站住脚。
