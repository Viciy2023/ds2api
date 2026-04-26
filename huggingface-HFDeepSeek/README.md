---
title: DS2API HFDeep
emoji: 🚀
colorFrom: blue
colorTo: indigo
sdk: docker
app_port: 7860
---

# DS2API for Hugging Face Docker Spaces

这个目录包含了一套可用于 **DS2API** 的 Hugging Face Docker Space 部署包。

## 这个部署包会做什么

- 在 Hugging Face **Docker Space** 上以 `7860` 端口启动 DS2API
- **在 Docker 构建阶段预装官方 GitHub 最新 Release 构建产物**：`https://github.com/CJackHwang/ds2api/releases`
- 支持 `DS2API_CONFIG_JSON`，方便你把配置放进 **HF Secrets**
- 以 HF 挂载的 `/data` 作为唯一持久化路径
- 默认开启 `DS2API_ENV_WRITEBACK=1`，首次引导后自动切到文件持久化模式

## Hugging Face 重要说明

Hugging Face 会从**仓库根目录**的 `README.md` 读取 Docker Space 元数据，并且要求可部署的 `Dockerfile` 也位于**仓库根目录**。

因此，这个目录更适合作为一份**部署包源目录**。当你真正创建 HF Space 仓库时，请把这些文件复制到 HF Space 仓库根目录：

- `README.md`
- `Dockerfile`
- `start.sh`
- 可选再带上 `.env.example` 供你自己参考

## HF 必填 Secrets

至少要在 Hugging Face **Secrets** 或 **Variables** 中设置以下内容：

- `DS2API_ADMIN_KEY`
- `DS2API_JWT_SECRET`
- `DS2API_CONFIG_JSON`

推荐同时设置以下运行参数：

- `PORT=7860`
- `LOG_LEVEL=INFO`
- `DS2API_AUTO_BUILD_WEBUI=false`
- `DS2API_RELEASE_TAG=latest`
- `DS2API_CONFIG_PATH=/data/config.json`
- `DS2API_ENV_WRITEBACK=1`

## 配置策略

### 推荐方式：环境变量注入配置

使用 `DS2API_CONFIG_JSON`，把完整 `config.json` 以以下任意一种形式放入 HF Secrets：

- 原始 JSON
- Base64 编码后的 JSON

这是最适合 HF 的方式，因为 DS2API 原生支持 env-backed config（环境变量配置）。

### 推荐方式：挂载 `/data` 文件持久化

如果你的 Space 已经挂载持久化存储到 `/data`，建议保留：

```text
DS2API_CONFIG_PATH=/data/config.json
DS2API_ENV_WRITEBACK=1
```

启动脚本会在第一次启动时，如果 `/data/config.json` 不存在，就把 `DS2API_CONFIG_JSON` 写入该文件。

之后 DS2API 会在管理台保存时直接写回 `DS2API_CONFIG_PATH`，因为 HF 已经把持久化存储挂载到 `/data`，所以重启后仍会保留。

## Release 构建产物逻辑

Dockerfile 会在构建阶段先解析 GitHub 的最新 release tag，再下载对应的 Linux release 压缩包，命名格式如下：

```text
ds2api_<tag>_linux_amd64.tar.gz
ds2api_<tag>_linux_arm64.tar.gz
```

这和仓库当前的 release 工作流命名完全一致。

官方压缩包至少应包含：

- `ds2api`
- `config.example.json`
- `.env.example`
- `static/admin`

说明：

- `static/admin` 仍然是 HF 镜像启动管理端所必需的静态资源目录
- `sha3_wasm_bg*.wasm` 仅对旧版 release 兼容保留；从 `v3.2.0` 开始，上游已切换为原生 Go PoW，实现上不再要求 release 包必须携带该文件

当前方案不再在 `start.sh` 中动态下载或源码构建，运行时直接启动 Docker 镜像中已经准备好的 `ds2api` 二进制。

## 部署步骤

1. 创建一个新的 Hugging Face **Docker Space**。
2. 把这些文件复制到 **HF Space 仓库根目录**。
3. 参考 `.env.example` 填写你的 Secrets / Variables。
4. 推送代码。
5. 访问以下路径检查是否正常：
   - `/healthz`
   - `/readyz`
   - `/admin`

## 建议的首次测试

部署完成后，建议验证：

1. `https://<your-space>.hf.space/healthz`
2. `https://<your-space>.hf.space/readyz`
3. `https://<your-space>.hf.space/admin`

如果 `/healthz` 正常但 `/admin` 打不开，通常说明安装回退过程有问题，或者静态资源没有准备好。

## 持久化说明

当前部署方案只依赖 HF Space 已挂载的 `/data` 持久化目录：

- `config.json` 推荐路径：

```text
DS2API_CONFIG_PATH=/data/config.json
```

- 首次启动可通过 `DS2API_CONFIG_JSON` 引导生成配置文件
- 后续管理台改动会写回 `/data/config.json`
- 只要 HF Space 的挂载存储仍然存在，重启后配置不会丢失

## 说明

- HF 更适合作为 **演示 / 轻量使用** 的部署目标。
- DS2API 本质上仍然是一个长期运行的 Go 服务，并且包含流式 API；如果你追求更稳定的生产部署，传统容器平台仍然更合适。
