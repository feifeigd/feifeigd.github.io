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

如果不想用 `sys.settrace` 的开销，可以用 `watchfiles` 监听文件变化，手动触发 `importlib.reload` + 补齐字段：

```python
import gc
import importlib
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

def reload_module(path: str, root: str = "src"):
    """手动重载模块并补齐实例字段

    支持深层目录：src/services/user/handler.py → src.services.user.handler
    """
    # 去掉根路径前缀和 .py 后缀，转为模块名
    rel = Path(path).relative_to(root)
    mod_name = str(rel.with_suffix("")).replace("\\", "/").replace("/", ".")
    mod = importlib.import_module(mod_name)
    importlib.reload(mod)
    patch_instances()
    return mod

def reload_external(mod_name: str):
    """重载外部依赖库

    例如：reload_external("requests.adapters")
    """
    # 先确保顶级包可重载
    top = mod_name.split(".")[0]
    importlib.invalidate_caches()
    mod = importlib.import_module(mod_name)
    importlib.reload(mod)
    # 重新注入到已加载的父模块中
    parts = mod_name.split(".")
    for i in range(1, len(parts)):
        parent = ".".join(parts[:i])
        child = parts[i]
        parent_mod = importlib.import_module(parent)
        setattr(parent_mod, child, getattr(mod, child, None))
    return mod

# 在 asyncio 中监听文件变化
import asyncio

async def watch_and_reload(paths: list[str]):
    async for changes in watchfiles.awatch(*paths):
        for _, path in changes:
            reload_module(path)
```

### 按需热更新（手动触发，无 watch）

完全去掉文件监听，按需手动触发：

```python
import gc
import importlib
from pathlib import Path

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

    def reload_if_changed(self, path: str, root: str = "src"):
        if self.changed(path):
            rel = Path(path).relative_to(root)
            mod_name = str(rel.with_suffix("")).replace("\\", "/").replace("/", ".")
            mod = importlib.import_module(mod_name)
            importlib.reload(mod)
            patch_instances()
            return mod
        return None

# 在代码中加个入口，按需调用
if __name__ == "__main__":
    r = Reloader()
    input("按 Enter 热更新...")  # 阻塞等待
    r.reload_if_changed("src/handler.py")
```

### 深层目录与外部库的限制

| 问题 | 说明 |
|------|------|
| **深层目录** | `reload_module` 通过 `relative_to` 正确提取模块名，支持 `src/a/b/c.py` 变为 `a.b.c` |
| **外部依赖库** | `reload_external("requests.adapters")` 可重载，但**依赖链不会自动传播**：如果 `requests.adapters` 引用了 `urllib3` 中的类，改 `urllib3` 不会影响 `requests.adapters` 中已导入的引用。需要手动触发链上所有模块 |
| **`__init__.py` 中的引用** | 如果 `__init__.py` 做了 `from .sub import X`，重载子模块后父模块仍持有旧 `X`，需要 `reload_external` 重新 `setattr` |
| **C 扩展模块** | `.pyd` / `.so` 不可重载 |
| **循环依赖** | `importlib.reload` 对循环依赖处理不稳定，可能导致 `KeyError` |

### 解决依赖链问题的通用方法

```python
import sys
import importlib

def reload_with_deps(mod_name: str, depth: int = 3):
    """重载模块及其直接依赖模块（限定深度防循环）"""
    seen = set()

    def _reload(name: str, d: int):
        if name in seen or d <= 0:
            return
        seen.add(name)
        mod = sys.modules.get(name)
        if mod is None:
            return
        # 找出该模块直接 import 的子模块
        for child_name in dir(mod):
            child = getattr(mod, child_name)
            if hasattr(child, "__module__"):
                _reload(child.__module__, d - 1)
        importlib.reload(mod)

    _reload(mod_name, depth)
    patch_instances()
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