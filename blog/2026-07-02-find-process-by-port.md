# 一个快速查看端口占用进程的工具 sonar

## 安装
```shell
curl -sfL https://raw.githubusercontent.com/raskrebs/sonar/main/scripts/install.sh |bash
. ~/.bashrc
```

## 一条命令看清全貌
```shell
sonar list
```

## 带资源统计
```shell
sonar list --stats
```

## 自定义列
```shell
sonar list -c port,process,cpu,mem,uptime,state
```

## 端口详情
```shell
sonar info 80
```

## 按端口杀进程
```shell
sonar kill 80 # SIGTERM
sonar kill 80 -f # SIGKILL
```

## 查看日志
```shell
sonar logs 80
```

## 连接到服务
```shell
sonar attach 80
```

## 实时监控
```shell
# 每2秒刷新，显示变化
sonar watch 
# 实时资源监控
sonar watch --stats
# 更快的刷新间隔
sonar watch -i 500ms
# 端口上下线时发送桌面通知
sonar watch --notify 
```

## 依赖关系图
```shell
sonar graph
```

## 等待端口就绪
```shell
# 等待TCP连接可用
sonar wait 80
# 多个端口
sonar wait 80 6379
# 等待HTTP 200
sonar wait 80 --http
# 检查特定断点
sonar wait 80 --http=/health
# 超时
sonar wait 80 --timeout 30s
```

## 端口映射
```shell
# 把 6873 端口的服务映射到3002 端口。
sonar map 6873 3002
```

## 查找空闲端口
```shell
sonar next 
# 从 8000 开始
sonar next 8000
# 在范围搜索
sonar next 3000-3100
# 找 3 个连续空闲端口
sonar next -n 3
```

## 远程扫描
```shell
# 
sonar list  --host user@server
sonar watch  --host user@server
```

