# airi-nanobot
这是airi与nanobot的集成，赛博mm不只是提供情绪价值，也能帮你完成各项任务。
- [airi项目](https://github.com/moeru-ai/airi)
- [nanobot项目](https://github.com/HKUDS/nanobot)

## airi单独使用效果与接入nanobot效果对比

<table>
  <tr>
    <td align="center"><b>Airi 单独使用</b></td>
    <td align="center"><b>Airi + nanobot</b></td>
  </tr>
  <tr>
    <td><img src="examples/airi.gif" width="400" alt="Airi standalone"></td>
    <td><img src="examples/airi-nanobot.gif" width="400" alt="Airi with nanobot"></td>
  </tr>
</table>

## 架构

```
┌─────────┐     ┌──────────────┐     ┌─────────────────┐
│  Airi   │────▶│  CORS Proxy  │────▶│  nanobot API    │
│ (浏览器) │     │  :18900      │     │  :8900          │
└─────────┘     └──────────────┘     └─────────────────┘
                                           │
                                           ▼
                                    ┌─────────────────┐
                                    │  nanobot Gateway│
                                    │  :18790 (health)│
                                    │  :8765  (ws)    │
                                    └─────────────────┘
```
## 文件介绍
- setup.sh — 一键部署脚本，clone仓库、配置nanobot、启动Docker服务、启动CORS代理、安装Airi依赖、注入配置、打开浏览器。
- cors-proxy.py — CORS 代理 + 消息合并，把Airi的请求转发给nanobot API并自动添加跨域头。
- nanobot_config.py — nanobot配置工具，只改Docker必需的 4 个字段（host × 3 + apiKey），其他由nanobot 默认值和onboard wizard管理。
- nanobot-setup.html — 浏览器自动配置页（模板），写入Airi的localStorage后跳转到Airi主页，省去手填provider配置。

## 快速开始
```
git clone https://github.com/KANG99/airi-nanobot.git
cd airi-nanobot

./setup.sh
```
