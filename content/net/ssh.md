---
title: "利用ssh隧道转发进行内网穿透"

date: 2021-01-05T13:23:51-05:00
draft: false

categories:
  - net
tags:
  - ssh
  - Tunnel

toc: true
---

## 需求

希望可以使用ipad pro 随时随地连接家中的电脑主机。
<!--more-->

```
  +---------+                 +----------+
  |         |                 |          |
  |  ipad:A |                 |PcAtHome:B|
  |         |                 |          |
  +---------+                 +----------+
       |                            |
       |                            |
       |                            |
       |      +--------------+      |
       +------+              +------+
              |     VPS:C    |
              |              |
              +--------------+
```
ipad和pc均可连接vps主机，互相无法直接连接，所以可以通过vps建立隧道转发进行连接，即A通过C连接B主机。

了解ssh的转发配置和原理，以实现该场景目标。

## ssh隧道转发

SSH有三种端口转发模式，本地端口转发(Local Port Forwarding)，远程端口转发(Remote Port Forwarding)以及动态端口转发(Dynamic Port Forwarding)。对于本地/远程端口转发，两者的方向相反；本地或远程的概念是相对与发起ssh连接的主机，在发起连接的主机上进行转发即本地转发，在被连接的机器上进行转发即远程转发。动态端口转发则为socks代理，可以用于上科学网。

### 本地端口转发

#### 场景拓扑

在A主机无法直接访问某个[远程接口]:[远程端口]组，而需要通过host-C主机才能进行访问的一些场合。

```
   curl   ssh          +      sshd      web
     |     |           |        |        |
     |     |           |        |        |
   +----------+        |      +------------+
   | |     |  |        |      | |        | |
   | |  A  +---------------->22-+ host-C | |
   | |     |  |        |      | |        | |
   +----------+        |      +------------+
     |     |           |        |        |
     +---> +           |        +------> +
         lo:2000       |                lo:80
                       +
```

#### 连接命令

```
ssh -L [本地接口]:[本地端口]:[远程接口]:[远程端口] user@host-C
```
在A中执行以下命令，建立本地转发：
```
ssh -L localhost:2000:localhost:80 user@host-C
```
那么通过A上执行
```
curl http://localhost:2000
```
将被通过ssh隧道转发访问host-C上面的80端口。

该条命令执行后，主机A新增端口2000 监听，监听进程为本地主机A与host-C连接的ssh进程：
```
see@17:03:32 ~  netstat -tlpn | grep 2000
(Not all processes could be identified, non-owned process info
 will not be shown, you would have to be root to see it all.)
tcp        0      0 127.0.0.1:2000          0.0.0.0:*               LISTEN      27104/ssh           
tcp6       0      0 ::1:2000                :::*                    LISTEN      27104/ssh 
```
如果使用命令:
```
ssh -L 3000:www.google.com:80 user@host-C
```
如果host-C可以访问外网，那么就可以使用A:3000访问外网。
```
curl http://localhost:3000
```
以上将访问到google。

### 远程端口转发

#### 场景拓扑

```
   +---------+                 +--------------+
   |         |                 |PcAtHome:B +--+->--sshd
   |  ipad:A |          ssh0---+-----+     |  |
   |   ssh1  |                 |     |---->+  |
   +----+----+                 +-----+--------+
        |            sshd            |    lo:22
        |              +             |
        |              |             ^
        |              |             |
        |      +-------+-------+     |
        |      |       |       |     |
        |      |       |       |     |
        +--->8989 +----+----->22--->-+
               |     VPS:C     |
               +---------------+
```

#### 连接命令

从PcAtHome:B发起ssh隧道连接到VPS:C。
```
ssh 
```

或者：

```
# -qTfNn 让ssh会话后台静默运行
ssh -qTfNn -R "*:8989:localhost:22" user@VPS:C
```

此时允许从VPS:C上通过localhost接口的8989端访问PcAtHome。

VPS:C主机上修改配置sshd_config：

```
GatewayPorts yes
```

允许ipad:A可以直接通过

```
ssh -p 8989 pcUser@VPS:C
```

直接连接PcAtHome。

ssh隧道建立后，vps主机上新增sshd进程监听在8989端口上，该进程与pc和vps间ssh通讯进程为同一进程：
```
root@instance-2 zhoujinze  netstat -nltp | grep sshd
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      31897/sshd          
tcp        0      0 0.0.0.0:8989            0.0.0.0:*               LISTEN      3243/sshd: zhoujinz 
tcp6       0      0 :::8989                 :::*                    LISTEN      3243/sshd: zhoujinz
```

### 动态端口转发

#### 场景拓扑

```
         chrome
         |
     msn |    ssh             sshd
      |  |     |                |
      |  |     |                |
   +-----------------+     +------------------+
   |  |  |     |     |     |    |             |
   |  |  |     +-------->-------+------------------>
   |  |  |     |     |     |                  |
   |  |  |     ^     |     |      VPS:C       |
   |  |  |     |     |     +------------------+
   |  |  |  +----+   |
   |  +---->|    |   |
   |     |  |7001|   |
   |     +->|    |   |
   |        +----+   |
   |   PcAtHome      |
   +---------------- +
```

### 连接命令

在本地主机A上执行命令：
```
ssh -D 7001 user@VPS:C
```
这里 SSH 是创建了一个 SOCKS 代理服务。
如场景拓扑中，chrome设置socks代理，即可通过vps访问网络。

## 实现

使用ssh远程端口转发可实现需求，提高使用体验，需要自动创建和稳定维持。

### 持久连接

持久连接参考[保持ssh连接]({{< ref "net/ssh2.md" >}})

### 自动创建

创建一个服务开机自动连接即可。


## 参考文献

- IBM developerWorks：[实战SSH端口转发](https://www.ibm.com/developerworks/cn/linux/l-cn-sshforward/)
- 阮一峰：[SSH原理与运用（二）：远程操作与端口转发](http://www.ruanyifeng.com/blog/2011/12/ssh_port_forwarding.html)
- [使用SSH反向隧道进行内网穿透](http://arondight.me/2016/02/17/%E4%BD%BF%E7%94%A8SSH%E5%8F%8D%E5%90%91%E9%9A%A7%E9%81%93%E8%BF%9B%E8%A1%8C%E5%86%85%E7%BD%91%E7%A9%BF%E9%80%8F/)
