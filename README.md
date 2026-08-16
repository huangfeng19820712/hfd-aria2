# hfd-aria2：用 Docker aria2 下载 Hugging Face 模型

把 Hugging Face 模型仓库通过本地的 Docker aria2 RPC 服务并行下载。适合在 NAS / 小主机上批量拉模型，绕过 HF 直连的限速并支持断点续传。

---

## 工作流程

```
hfd-aria2.sh（构建任务清单）
    ↓
.hfd/aria2c_urls.txt  ← URL + dir + out 格式
    ↓
hfd-aria2-rpc.sh（JSON-RPC 客户端）
    ↓
aria2.addUri
    ↓
Docker aria2 :6800（容器内 /downloads）
    ↓ volume 挂载
宿主机 /volume3/video/models/<repo>/...
    ↓
AriaNg（Web 监控，http://<nas-ip>:6880）
```

---

## 环境要求

- **Bash ≥ 4.0**（NAS 自带的 busybox ash 不支持部分语法）
- `jq`、`curl`
- **Docker aria2 容器**，端口 6800 暴露到宿主机
- 容器与宿主机之间**共享下载目录**（Docker `-v` 挂载）

---

## 安装

把两个脚本放在同一目录（NAS 上假设是 `/volume2/M/ai/models/`）：

```
/volume2/M/ai/models/
├── hfd-aria2.sh        # 主入口
├── hfd-aria2-rpc.sh    # RPC 桥接
└── hfd-aria2.env       # 你的配置（可选）
```

如果从 Windows 编辑过文件，先去掉 CRLF 行尾：

```bash
sed -i 's/\r$//' /volume2/M/ai/models/hfd-aria2.sh
sed -i 's/\r$//' /volume2/M/ai/models/hfd-aria2-rpc.sh
```

---

## 配置

### 方式一：环境变量文件（推荐）

在脚本同目录下创建 `hfd-aria2.env`：

```bash
cat > /volume2/M/ai/models/hfd-aria2.env << 'EOF'
export HF_ENDPOINT=https://hf-mirror.com
export HF_TOKEN=hf_你的token
export ARIA2_RPC=http://127.0.0.1:6800/jsonrpc
export ARIA2_SECRET=<你的aria2-rpc-secret>
EOF

chmod 600 /volume2/M/ai/models/hfd-aria2.env  # 含 token，建议收紧权限
```

脚本启动时会自动 `source` 这个文件，无需手动 export。

### 方式二：每次手动设置

```bash
export HF_ENDPOINT=https://hf-mirror.com
export HF_TOKEN=hf_xxx
export ARIA2_RPC=http://127.0.0.1:6800/jsonrpc
export ARIA2_SECRET=<你的aria2-rpc-secret>

bash hfd-aria2.sh <REPO_ID> ...
```

### 变量说明

| 变量 | 必填 | 说明 |
|---|---|---|
| `HF_ENDPOINT` | 否 | HF API 根地址。默认 `https://huggingface.co`；国内推荐 `https://hf-mirror.com`（需 token） |
| `HF_TOKEN` | 视情况 | HF 访问 token。私有/gated 模型必填；hf-mirror.com API 强制要；纯匿名下载可省 |
| `ARIA2_RPC` | 否 | aria2 JSON-RPC 地址。默认 `http://127.0.0.1:6800/jsonrpc` |
| `ARIA2_SECRET` | **必填** | aria2 RPC token，必须与 aria2.conf 里 `rpc-secret=` 一致 |
| `ARIA2_DIR_PREFIX` | 否 | 下载根目录前缀（容器内路径）。默认 `/downloads/models` |
| `HFD_DEBUG` | 否 | `1` 开启 DEBUG 输出（看每个文件被怎么处理） |
| `HFD_WAIT` | 否 | `1` 等所有下载任务完成后才退出（默认 `0`：addUri 完即退出，进度由 AriaNg 监控） |

### Docker aria2 配置要求

容器必须满足：

1. **RPC 端口暴露**：`-p 6800:6800`
2. **RPC 启用**：`--enable-rpc --rpc-listen-all=true`（或只 listen 宿主机 IP）
3. **以 root 跑**（避免权限问题）：`user: "0:0"` 或 `--user 0:0`
4. **目录挂载**：宿主机下载目录 ↔ 容器 `/downloads`，例：
   ```yaml
   volumes:
     - /volume3/video/models:/downloads
   ```

---

## 使用方法

### 单个文件

```bash
bash hfd-aria2.sh Comfy-Org/MiniMax-H3 \
  --include "vae/minimax_h3_audio_vae_fp32.safetensors" \
  -x 4 -j 4 \
  --local-dir /volume3/video/models/MiniMax-H3
```

- `-x 4`：每个文件 4 个连接
- `-j 4`：最多 4 个文件并行下载
- `--local-dir`：脚本监控的本地路径（必须跟 aria2 实际写入路径对齐）

### 多个文件（同一个 `--include` 后跟多个 pattern）

```bash
bash hfd-aria2.sh Comfy-Org/MiniMax-H3 \
  --include "vae/minimax_h3_video_vae_fp16.safetensors" \
             "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
  -x 4 -j 4 \
  --local-dir /volume3/video/models/MiniMax-H3
```

### 多个文件（多个 `--include` 标志）

```bash
bash hfd-aria2.sh Comfy-Org/MiniMax-H3 \
  --include "*.safetensors" \
  --include "vae/*.safetensors" \
  --include "text_encoders/*.safetensors" \
  -x 4 -j 4 \
  --local-dir /volume3/video/models/MiniMax-H3
```

两种写法效果一样，include 数组会累积。

### 整个仓库

```bash
bash hfd-aria2.sh Comfy-Org/MiniMax-H3 \
  --include "*" \
  -x 4 -j 4 \
  --local-dir /volume3/video/models/MiniMax-H3
```

⚠️ 注意：MiniMax-H3 这种几十 GB 的仓库要跑很久。

### 按类型 + 排除

```bash
bash hfd-aria2.sh Comfy-Org/MiniMax-H3 \
  --include "*.safetensors" "*.json" "*.md" \
  --exclude "*.bin" "*_temp.safetensors" \
  -x 4 -j 4 \
  --local-dir /volume3/video/models/MiniMax-H3
```

### Pattern 规则

脚本把 `*` 转成正则 `.*`，`.` 转成 `\.`：

| Pattern | 匹配 |
|---|---|
| `*` | 所有文件 |
| `*.safetensors` | 所有 .safetensors |
| `vae/*` | vae 目录下所有文件 |
| `minimax_h3_*.safetensors` | 前缀匹配 |
| `*_fp16.safetensors` | 后缀匹配 |
| `minimax_h3_audio_vae_fp32.safetensors` | 精确文件名 |

---

## 路径映射（最容易出错的地方）

aria2 容器内的路径 ↔ 宿主机路径映射关系：

```
容器内路径                              宿主机路径（取决于挂载）
  /downloads/models/MiniMax-H3/vae/    /volume3/video/models/MiniMax-H3/vae/
```

三件事必须对齐：

1. **Docker 挂载**：`/volume3/video/models:/downloads`（挂父目录，让 aria2 自己建子目录）
2. **aria2 `--dir`**：可不设（脚本用绝对 dir 字段覆盖），或在 aria2.conf 设 `--dir=/downloads`
3. **脚本 `--local-dir`**：`/volume3/video/models/MiniMax-H3`

如果挂载是 `/volume3/video/models:/downloads`、脚本写绝对路径 `dir=/downloads/models/MiniMax-H3/vae`，最终落点：
- 容器：`/downloads/models/MiniMax-H3/vae/xxx.safetensors`
- 宿主：`/volume3/video/models/models/MiniMax-H3/vae/xxx.safetensors`

⚠️ 注意 `models/` 出现了两次！如果不想这样，去掉 `ARIA2_DIR_PREFIX` 里的 `models/`：

```bash
export ARIA2_DIR_PREFIX=/downloads
```

---

## 断点续传

重跑同一命令即可。脚本会：

1. 比对本地文件大小 vs manifest 中记录的大小
2. 删除错误大小的不完整文件（无 `.aria2` 控制文件的）
3. 跳过已下载完成的文件
4. 仅 addUri 真正缺失的文件

中途 `Ctrl+C` 中断后重新执行即可继续。

---

## 运行模式（提交后是否等待）

`HFD_WAIT` 控制脚本在 addUri 完所有任务后是否等待下载完成。

| 值 | 行为 |
|---|---|
| `0`（默认）| addUri 完所有任务 → 立刻 exit 0，aria2 在后台继续下载。用 AriaNg 监控进度。 |
| `1` | 等所有任务 `complete` 才退出。带进度监控（轮询 `aria2.getGlobalStat`）。适合脚本化串联。 |

**三种设置方式（按优先级）：**

```bash
# 方式 1：命令行临时设置（最高优先级）
HFD_WAIT=1 bash hfd-aria2.sh ...

# 方式 2：当前 shell 已 export
export HFD_WAIT=1
bash hfd-aria2.sh ...

# 方式 3：写在 hfd-aria2.env 里（脚本自动 source，最方便）
echo "export HFD_WAIT=1" >> /volume2/M/ai/models/hfd-aria2.env
```

**典型用法：**

```bash
# 场景 A：日常使用，提交就走人，AriaNg 看进度
bash hfd-aria2.sh Comfy-Org/MiniMax-H3 --include "*.safetensors" -x 4 -j 4 \
  --local-dir /volume3/video/models/MiniMax-H3

# 场景 B：脚本串联，下完再做下一步（HFD_WAIT=1 + &&）
HFD_WAIT=1 bash hfd-aria2.sh ... && echo "全部完成，触发后续"

# 场景 C：下完自动关机
HFD_WAIT=1 bash hfd-aria2.sh ... && shutdown -h now

# 场景 D：crontab 定时下载，不用等
0 2 * * * bash /volume2/M/ai/models/hfd-aria2.sh ... --include "*"
```

**DEBUG 与 WAIT 可叠加：**

```bash
# DEBUG + 等下载完（看完整流程）
HFD_DEBUG=1 HFD_WAIT=1 bash hfd-aria2.sh ...

# DEBUG + 立刻退出（看 addUri 部分）
HFD_DEBUG=1 bash hfd-aria2.sh ...
```

---

## 调试

```bash
# 开启 DEBUG 看每个文件被怎么处理
export HFD_DEBUG=1
bash hfd-aria2.sh Comfy-Org/MiniMax-H3 \
  --include "vae/*.safetensors" \
  -x 4 -j 4 \
  --local-dir /volume3/video/models/MiniMax-H3
```

DEBUG 输出类似：

```
[DEBUG] FILES_LIST=.hfd/aria2c_urls.txt
[DEBUG] cwd=/volume3/video/models/MiniMax-H3
[DEBUG] first 5 lines of file:
https://hf-mirror.com/.../xxx.safetensors
 dir=/downloads/models/MiniMax-H3/vae
 out=xxx.safetensors

[DEBUG] read LINE=[https://hf-mirror.com/...]
[DEBUG] matched URL, URL=https://hf-mirror.com/...
[DEBUG] read LINE=[ dir=/downloads/models/MiniMax-H3/vae]
[DEBUG] matched dir, DIR=/downloads/models/MiniMax-H3/vae
[DEBUG] read LINE=[ out=xxx.safetensors]
[DEBUG] matched out, OUT=xxx.safetensors
[DEBUG] OPTIONS={"dir":"/downloads/models/MiniMax-H3/vae","out":"xxx.safetensors",...}
[INFO] Added: xxx.safetensors
[INFO] GID:   xxxxx
```

调试完 `unset HFD_DEBUG` 关闭。

---

## 故障排查

### `curl: (3) Illegal characters found in URL`

环境变量文件有 CRLF 行尾（Windows 编辑过），导致 URL 后面带了 `\r`：

```bash
sed -i 's/\r$//' /volume2/M/ai/models/hfd-aria2.env
```

### `Failed to make the directory ... Permission denied` (ERROR 18)

aria2 容器以 `nobody` 运行，写不进挂载目录。修法：

```yaml
services:
  aria2:
    user: "0:0"     # ← 加这行
```

或者宿主机目录 `chmod 777`。

### `Download aborted.` (ERROR 16) + 文件名是 hash

`out` 字段被脚本发成空字符串，aria2 用 URL 哈希当文件名兜底。检查：

1. `cat .hfd/aria2c_urls.txt` 应该有 `out=真实文件名`
2. `grep DIR=... hfd-aria2-rpc.sh` 应是 `${LINE#*dir=} OUT="${LINE#*out=}"`（带 `*`）
3. 必要时 `export HFD_DEBUG=1` 看 `DIR=` 和 `OUT=` 是否有值

### `Listed 0 files`

`--include` pattern 没匹配到任何文件。检查：

- HF 文件路径是相对仓库根的（`vae/xxx.safetensors`），**不要带前导 `/`**
- `*` 通配符写对位置：`vae/*` 匹配 `vae/` 下所有，`*` 匹配所有

### 进度条一直 0B/s

- aria2 队列里有历史残留任务：`docker restart <容器>`
- 文件路径不对（容器内路径写不进）：重新检查挂载 + `--local-dir`

### `aria2 is not installed`

hfd-aria2.sh 已经移除了对本地 `aria2c` 的依赖。如果还报这个，说明脚本没更新：

```bash
grep -n 'check_command' hfd-aria2.sh
# 期望看到 "check_command wget" 而不是 "check_command aria2c"
```

---

## 命令行参数完整列表

```
用法: hfd-aria2.sh <REPO_ID> [选项]

必填:
  REPO_ID                         HF 仓库 ID，格式 "org/repo"

选项:
  --include PATTERN [PATTERN...]  包含的文件路径 pattern（glob）
  --exclude PATTERN [PATTERN...]  排除的文件路径 pattern（glob）
  --hf_username NAME              HF 用户名（gated 仓库需要）
  --hf_token TOKEN                HF token（命令行传入，覆盖 env）
  --tool aria2c|wget              下载工具（默认 aria2c，RPC 模式自动用 aria2c）
  -x N                            每文件连接数 1-10（默认 4）
  -j N                            并发下载数 1-10（默认 5）
  --dataset                       下载 dataset 而非 model
  --local-dir PATH                本地保存路径
  --revision REV                  Git revision（默认 main）

示例:
  hfd-aria2.sh MiniMaxAI/MiniMax-H3 --include *.json *.md
  hfd-aria2.sh Comfy-Org/MiniMax-H3 --include "*.safetensors" -x 4 -j 4
  hfd-aria2.sh user/private-repo --hf_username me --hf_token hf_xxx
```

---

## AriaNg 监控

aria2 自带 AriaNg Web UI（默认 `http://<nas-ip>:6880`），可看：

- 实时下载进度 / 速度
- 已添加任务列表
- 全局设置（split、max-concurrent-downloads 等）

中途临时增加并发：`设置 → 全局 → 最大并发下载数`。

---

## 常见组合速查

| 场景 | 命令片段 |
|---|---|
| 下单个文件 | `--include "path/to/file.ext"` |
| 下整个子目录 | `--include "dirname/*"` |
| 下所有 .safetensors | `--include "*.safetensors"` |
| 下模型+配置 | `--include "*.safetensors" "*.json" "*.md"` |
| 排除大文件 | `--include "*" --exclude "*.bin"` |
| 断点续传 | 重跑同一命令 |
| 提交就退出 | 默认行为，AriaNg 看进度 |
| 等下完才返回 | `HFD_WAIT=1 bash hfd-aria2.sh ...` |
| 调试 | `HFD_DEBUG=1 bash hfd-aria2.sh ...` |
| 换镜像 | `export HF_ENDPOINT=https://hf-mirror.com` |
| 换 aria2 端口 | `export ARIA2_RPC=http://host:port/jsonrpc` |
| 不带 models/ 中间层 | `export ARIA2_DIR_PREFIX=/downloads` |