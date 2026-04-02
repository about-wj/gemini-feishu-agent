#!/bin/bash

# ==============================================================================
# Lark Agent 项目初始化脚本
# ==============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- [ 函数定义 ] ---

# 1. 检查基础命令
function check_base_commands() {
    echo -e "${YELLOW}--- [1/6] 检查基础工具 ---${NC}"
    local commands=("curl" "gcloud" "git")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误: 未找到 $cmd，请先安装。${NC}"
            exit 1
        fi
    done
    echo -e "${GREEN}基础工具检查通过。${NC}"
}

# 2. 检查 gcloud 登录状态
function check_gcloud_auth() {
    echo -e "${YELLOW}--- [2/6] 检查 Google Cloud 认证 ---${NC}"
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
        echo -e "${YELLOW}未检测到活跃的 gcloud 账号，请执行登录...${NC}"
        gcloud auth login
    else
        local account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
        echo -e "${GREEN}已登录账号: $account${NC}"
    fi
}

# 3. 安装/更新 uv
function install_uv() {
    echo -e "${YELLOW}--- [3/6] 检查 uv 安装 ---${NC}"
    if ! command -v uv &> /dev/null; then
        echo -e "未检测到 uv，正在安装..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # 尝试刷新路径，将 uv 的实际安装目录加入 PATH
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    # else
    #     echo -e "uv 已安装，正在尝试更新..."
    #     uv self update || true
    fi
    echo -e "${GREEN}uv 准备就绪: $(uv --version)${NC}"
}

# 4. 准备 Python 环境
function setup_python_env() {
    echo -e "${YELLOW}--- [4/6] 准备 Python 环境 ---${NC}"
    
    # 检查配置文件是否存在
    if [ ! -f "pyproject.toml" ]; then
        echo -e "${RED}错误: 未找到 pyproject.toml，请在项目根目录运行。${NC}"
        exit 1
    fi
    
    echo "正在检查并安装 Python 3.12 解释器..."
    # 下载一个稳定且兼容性好的版本
    uv python install 3.12
    
    echo "正在同步依赖并创建虚拟环境..."
    uv sync --python 3.12
    
    echo -e "${GREEN}Python 环境准备完成。${NC}"
}

# 5. 初始化配置文件 (.env)
function setup_env_file() {
    echo -e "${YELLOW}--- [5/6] 初始化配置文件 ---${NC}"
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            echo "正在从 .env.example 创建 .env..."
            cp .env.example .env
            echo -e "${YELLOW}警告: 请务必在 .env 中填写必要参数后重新执行脚本。${NC}"
            exit 1
        else
            echo -e "${RED}错误: 未找到 .env.example 模板。${NC}"
            exit 1
        fi
    else
        echo -e ".env 文件已存在，跳过。${NC}"
    fi
}

# 6. 检查并创建 GCS Bucket
function setup_gcs_bucket() {
    echo -e "${YELLOW}--- [6/6] 准备 Google Cloud Storage ---${NC}"
    
    # 加载环境变量
    source scripts/load_env.sh
    if [ -z "$STAGING_BUCKET" ]; then
        echo -e "${RED}错误: .env 中未定义 STAGING_BUCKET。${NC}"
        return 1
    fi

    # 提取 bucket 名称 (去掉 gs:// 前缀)
    local bucket_name=$(echo "$STAGING_BUCKET" | sed 's/gs:\/\///')

    echo "正在检查 Bucket: gs://$bucket_name ..."
    # 尝试读取 bucket 信息。如果存在则返回0，否则返回非0
    if ! gcloud storage buckets describe "gs://$bucket_name" --project="$PROJECT_ID" &> /dev/null; then
        echo "发现 Bucket 不存在或无法直接读取，正在尝试创建..."
        if [ -z "$PROJECT_ID" ]; then
             echo -e "${RED}错误: 创建 Bucket 需要 PROJECT_ID。请先填写 .env。${NC}"
             return 1
        fi
        
        # 默认使用部署区域，如果没有则使用 us-central1
        local location="${DEPLOY_LOCATION:-us-central1}"
        
        # 捕获创建输出，如果已经是自己拥有过的（409），则忽略错误
        local create_output
        create_output=$(gcloud storage buckets create "gs://$bucket_name" --project="$PROJECT_ID" --location="$location" --uniform-bucket-level-access 2>&1) || {
            if echo "$create_output" | grep -q "409.*already own it"; then
                echo -e "${GREEN}Bucket 已存在且为您所有。${NC}"
            else
                echo -e "${RED}Bucket 创建失败:${NC}\n$create_output"
                return 1
            fi
        }
        if ! echo "$create_output" | grep -q "409.*already own it"; then
            echo -e "${GREEN}Bucket gs://$bucket_name 创建成功。${NC}"
        fi
    else
        echo -e "${GREEN}Bucket 已存在。${NC}"
    fi
}

# --- [ 主流程 ] ---

function main() {
    echo -e "${GREEN}=========================================="
    echo "       Lark Agent 项目初始化程序"
    echo -e "==========================================${NC}"

    check_base_commands
    check_gcloud_auth
    install_uv
    setup_python_env
    setup_env_file
    setup_gcs_bucket

    echo -e "\n${GREEN}项目初始化成功！${NC}"
    echo -e "后续步骤："
    echo -e "1. 运行 ${YELLOW}uv run python -m lark_agent.main${NC} 本地调试"
    echo -e "2. 运行 ${YELLOW}bash deploy.sh${NC} 部署到云端"
}

# 执行主流程
main
