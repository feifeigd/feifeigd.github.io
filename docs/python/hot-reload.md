# Python 热更新

## 为什么需要热更新

修改代码后不重启进程，变更即时生效。对开发效率和长连接服务（如 WebSocket、游戏服）尤其重要。

## asyncio 热更新的难点

- `asyncio.run()` 只能调用一次，不能重启
- 已有 Task 的当前协程帧不会自动切换新代码
- 全局持有旧函数引用的变量不会自动更新
- 类定义变化（新增字段/方法）不自动作用于已有实例

## 方案对比

| 方案 | 原理 | 适用场景 |
|------|------|----------|
| `--reload`（uvicorn 等） | 文件变化后重启整个进程 | 开发阶段，简单可靠 |
| `importlib.reload` | 重新导入模块，执行顶层代码 | 需要手动处理引用，适合小规模 |
| `jurigged` | `sys.settrace` 追踪函数，原地替换 `__code__` | 函数级热替换，自动更新所有引用 |
| 自建 watcher | `watchfiles` + 自定义 reload 逻辑 | 需要精确控制触发时机和范围 |

## importlib.reload 与 jurigged 对比

| 场景 | `importlib.reload` | `jurigged` |
|------|-------------------|------------|
| 函数体内部代码改动 | 需手动替换所有持有引用的变量 | 自动原地替换 `__code__`，所有引用自动生效 |
| `async def` 中 await 之后的代码 | 已进入事件循环不会感知 | 下次调用自动走新代码 |
| 已有 Task 中正在执行的代码 | 当前帧执行完后，持有旧引用则走旧代码，重新 import 则走新代码 | 当前帧执行完后，下次调用走**新代码**（`__code__` 原地替换） |
| 已赋给其他变量的函数引用 | **不会自动更新**，容易漏 | **自动更新** |
| 类新增方法 | 已有实例缺新方法 | 同左 |
| 实例新增字段 | 需要手动补齐 | 同左 |

推荐 `jurigged` 的原因：`importlib.reload` 只重新导入模块，但已赋给其他变量的旧函数引用不会自动更新，需要手动找所有引用位置重新赋值，容易遗漏。`jurigged` 通过原地替换 `__code__` 解决了这个问题。

## jurigged 基础使用

```bash
pip install jurigged
```

### 命令行模式

监听当前目录所有 `.py` 文件变化：

```bash
jurigged main.py
```

### API 模式

```python
import asyncio
import jurigged

async def handler():
    while True:
        await asyncio.sleep(2)
        print("hello")  # 保存后自动生效

async def main():
    jurigged.watch("handler.py")
    tasks = [asyncio.create_task(handler()) for _ in range(3)]
    await asyncio.gather(*tasks)

asyncio.run(main())
```

修改 `handler.py` 保存后，所有 Task 下次循环输出新内容。

> **不要用 `watch`**：`jurigged.watch()` 依赖 `sys.settrace`，这是进程级别的全局钩子，**所有 Python 字节码执行都会触发 trace 函数**，导致 CPU 密集场景慢 2-5 倍。即使只 watch 几个文件，trace 开销一样存在。
>
> 推荐做法：开发阶段用 `jurigged.reload()` 手动触发，或配合 `watchfiles` 按需 reload，**零运行时开销**。详见下文"手动热更新"。

## 监听多个文件 / 目录

```python
# 多个文件
jurigged.watch("server.py", "patch.py", "utils.py")

# 监听整个目录
jurigged.watch(".")
jurigged.watch("./src")
```

引用链中的模块（如 `from utils import helper`）需要单独加入 watch，否则不会被监听。

## 手动触发 reload

```python
jurigged.reload("handler.py")
jurigged.reload("patch.py")
```

## 手动热更新（不依赖 watch）

`jurigged.watch()` 依赖 `sys.settrace`，有性能开销。而 `jurigged.reload()` 不依赖 `sys.settrace`，只做 `__code__` 原地替换——**既保留了自动更新引用的优势，又没有性能开销**。适合手动按需触发或配合 `watchfiles` 使用。

### watchfiles + jurigged.reload

```python
import gc
import jurigged
import watchfiles

REGISTRY = {}

def register(cls, **fields):
    REGISTRY[cls] = fields

def patch_instances():
    for cls, fields in REGISTRY.items():
        for obj in gc.get_objects():
            if isinstance(obj, cls):
                for k, v in fields.items():
                    if k not in obj.__dict__:
                        obj.__dict__[k] = v

def reload_module(path: str):
    jurigged.reload(path)     # 原地替换 __code__，所有引用自动生效
    patch_instances()          # 补齐实例字段

import asyncio

async def watch_and_reload(paths: list[str]):
    async for changes in watchfiles.awatch(*paths):
        for _, path in changes:
            reload_module(path)
```

### 按需触发（无 watch，无 sys.settrace）

```python
from pathlib import Path
import jurigged

class Reloader:
    def __init__(self):
        self._snapshots: dict[str, float] = {}

    def changed(self, path: str) -> bool:
        mtime = Path(path).stat().st_mtime
        if path not in self._snapshots:
            self._snapshots[path] = mtime
            return True
        if mtime > self._snapshots[path]:
            self._snapshots[path] = mtime
            return True
        return False

    def reload_if_changed(self, path: str):
        if self.changed(path):
            jurigged.reload(path)
            patch_instances()
            return True
        return False

# 入口：按 Enter 触发
if __name__ == "__main__":
    r = Reloader()
    input("按 Enter 热更新...")
    r.reload_if_changed("src/handler.py")
```

### 深层目录与外部依赖库

`jurigged.reload` 接收文件路径，支持深层目录：

```python
jurigged.reload("src/services/user/handler.py")   # 深层目录
jurigged.reload("C:/path/to/site-packages/requests/adapters.py")  # 外部库
```

但外部库的限制与 `importlib.reload` 一样：**依赖链不会自动传播**。改了 `urllib3`，`requests` 中已导入的旧引用不会自动更新。需要手动触发链上所有模块：

```python
# 同时重载有依赖关系的模块
jurigged.reload("urllib3/connection.py")
jurigged.reload("requests/adapters.py")  # 依赖 urllib3
```

### 触发方式

| 方式 | 实现 |
|------|------|
| 终端按 Enter | `input()` 阻塞等待 |
| HTTP 端点 | Flask/FastAPI 加个 `/reload` 路由 |
| 信号 | `signal.signal(signal.SIGUSR1, handler)` |
| 快捷键 | `keyboard` 库监听热键 |
| 定时检查 | asyncio loop 定时轮询文件 mtime（无 watch 库依赖） |

## 动态增加实例字段

热更新框架只能替换函数代码，不能自动为已有实例补齐新增的字段。整合两种互补方案：**基类 `__getattr__` 兜底 + callback 统一补齐**。

### 文件结构

```
project/
├── hotpatch.py      # 不参与 watch 的稳定文件（补齐 + 注册）
├── base.py           # 基类，不参与 watch 或只读不改
├── main.py           # 入口，watch 业务文件
├── user.py           # 业务文件，被 watch
└── order.py          # 业务文件，被 watch
```

### hotpatch.py（稳定，不被 watch）

```python
import gc
import copy

DEFAULTS = {}

def register(cls, **fields):
    DEFAULTS[cls] = fields

def patch_all():
    for cls, fields in DEFAULTS.items():
        for obj in gc.get_objects():
            if isinstance(obj, cls):
                for k, v in fields.items():
                    if k not in obj.__dict__:
                        obj.__dict__[k] = v
```

### base.py（稳定，不被 watch）

```python
class HotReloadBase:
    _defaults: dict = {}

    def __getattr__(self, name):
        if name in self._defaults:
            val = self._defaults[name]
            if isinstance(val, (list, dict, set)):
                val = copy.deepcopy(val)
            object.__setattr__(self, name, val)
            return val
        raise AttributeError(name)
```

### user.py（被 watch）

```python
from base import HotReloadBase

class User(HotReloadBase):
    _defaults = {"score": 0, "items": []}

    def __init__(self, name: str):
        self.name = name

    def level_up(self):
        self.score += 10  # 即使热更新前没有 score，__getattr__ 兜底
```

### order.py（被 watch，不继承基类）

```python
class Order:
    def __init__(self, oid: str, amount: float):
        self.oid = oid
        self.amount = amount

    def apply_discount(self, rate: float):
        self.amount *= rate
```

### main.py（入口）

```python
import asyncio
import jurigged
from hotpatch import register, patch_all
from order import Order

register(Order, amount_discount=lambda: 0.0)

async def main():
    # watch 业务文件，回调用稳定模块中的 patch_all
    jurigged.watch("user.py", "order.py", callback=patch_all)
    # ...

asyncio.run(main())
```

### 运作方式

| 场景 | 处理 |
|------|------|
| 继承 `HotReloadBase` 的类新增字段 | 在 `_defaults` 加一行，旧实例通过 `__getattr__` 即用即补 |
| 不继承基类的类（第三方库/已有类）新增字段 | 用 `register(cls, field=default)` 注册，callback 统一补齐 |
| 可变类型（list/dict）的默认值 | `__getattr__` 中 `deepcopy`，callback 直接赋值 |
| callback 加了新 `register` | 因为 `hotpatch.py` 不被 watch，第一次保存就生效 |
| 修改 `__getattr__` 本身的逻辑 | 不建议改；如必须改，需重启或等第二次保存生效 |