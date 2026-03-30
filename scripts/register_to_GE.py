import os
import sys
import json
import subprocess
from pathlib import Path
import requests
import dotenv

# ==========================================
# 1. 路径与环境变量加载
# ==========================================
# 获取当前脚本所在目录和根目录
script_dir = Path(__file__).resolve().parent
root_dir = script_dir.parent

# 加载 .env 和 .deploy_env 文件 (相当于 source load_env.sh)
dotenv.load_dotenv(root_dir / ".env")
dotenv.load_dotenv(root_dir / ".deploy_env")

# 读取环境变量并设置默认值
ge_app_location = os.getenv("GE_APP_LOCATION", "global")
agent_display_name = os.getenv("AGENT_DISPLAY_NAME", "Lark Document Agent")
agent_description = os.getenv("AGENT_DESCRIPTION", "Lark Document Agent")

# 必填项提取
project_id = os.getenv("PROJECT_ID")
lark_auth_id = os.getenv("LARK_AUTH_ID")
lark_client_id = os.getenv("LARK_CLIENT_ID")
lark_client_secret = os.getenv("LARK_CLIENT_SECRET")
lark_authorization_uri = os.getenv("LARK_AUTHORIZATION_URI")
lark_token_uri = os.getenv("LARK_TOKEN_URI")
vertex_reasoning_engine_name = os.getenv("VERTEX_REASONING_ENGINE_NAME")
ge_app_id = os.getenv("GE_APP_ID")

# 检查必要参数
required_vars = {
    "PROJECT_ID": project_id,
    "LARK_AUTH_ID": lark_auth_id,
    "LARK_CLIENT_ID": lark_client_id,
    "VERTEX_REASONING_ENGINE_NAME": vertex_reasoning_engine_name,
    "GE_APP_ID": ge_app_id,
    "GE_APP_LOCATION": ge_app_location
}

missing_vars = [k for k, v in required_vars.items() if not v]
if missing_vars:
    print(f"错误: 缺少必要参数 {missing_vars}。请确保 .env 和 .deploy_env 已正确配置。")
    sys.exit(1)

# ==========================================
# 2. 获取 Google Cloud 基础信息 (gcloud)
# ==========================================
def run_gcloud_command(cmd: str) -> str:
    """运行 gcloud 命令并返回字符串结果"""
    try:
        result = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT)
        return result.strip()
    except subprocess.CalledProcessError as e:
        print(f"执行 gcloud 命令失败: {e.output}")
        sys.exit(1)

print("正在获取 GCP Project Number 和 Access Token...")
project_number = run_gcloud_command(f"gcloud projects describe {project_id} --format='value(projectNumber)'")
access_token = run_gcloud_command("gcloud auth print-access-token")

# 全局 HTTP Headers
headers = {
    "Authorization": f"Bearer {access_token}",
    "Content-Type": "application/json",
    "X-Goog-User-Project": project_id
}

# ==========================================
# 3. 创建 OAuth 授权资源
# ==========================================
print(f"\n1. 正在创建 OAuth 授权资源: {lark_auth_id} ...")
auth_url = (
    f"https://{ge_app_location}-discoveryengine.googleapis.com/v1alpha/"
    f"projects/{project_id}/locations/{ge_app_location}/authorizations?authorizationId={lark_auth_id}"
)

auth_payload = {
    "name": f"projects/{project_number}/locations/{ge_app_location}/authorizations/{lark_auth_id}",
    "serverSideOauth2": {
        "clientId": lark_client_id,
        "clientSecret": lark_client_secret,
        "authorizationUri": lark_authorization_uri,
        "tokenUri": lark_token_uri
    }
}

auth_response = requests.post(auth_url, headers=headers, json=auth_payload)
if auth_response.status_code not in [200, 201, 409]: # 409 可能是已经存在
    print(f"创建 OAuth 授权资源异常 ({auth_response.status_code}): {auth_response.text}")

# ==========================================
# 4. 将 Agent 注册到 Gemini Enterprise
# ==========================================
print(f"\n2. 正在将 Agent 注册到 Gemini Enterprise ...")
agent_url = (
    f"https://{ge_app_location}-discoveryengine.googleapis.com/v1alpha/"
    f"projects/{project_id}/locations/{ge_app_location}/collections/default_collection/"
    f"engines/{ge_app_id}/assistants/default_assistant/agents"
)

agent_payload = {
    "displayName": agent_display_name,
    "description": agent_description,
    "adkAgentDefinition": {
        "provisionedReasoningEngine": {
            "reasoningEngine": vertex_reasoning_engine_name
        }
    },
    "authorizationConfig": {
        "toolAuthorizations": [
            f"projects/{project_number}/locations/{ge_app_location}/authorizations/{lark_auth_id}"
        ]
    }
}

agent_response = requests.post(agent_url, headers=headers, json=agent_payload)
print(f"\n响应结果: {json.dumps(agent_response.json(), indent=2, ensure_ascii=False)}")

# ==========================================
# 5. 提取资源名并回写到 .deploy_env
# ==========================================
response_data = agent_response.json()
agent_name = response_data.get("name")

if agent_name and "agents/" in agent_name:
    print(f"\n✅ 注册成功！Agent 资源名: {agent_name}")
    
    # 将结果写回 .deploy_env 文件
    deploy_env_path = root_dir / ".deploy_env"
    dotenv.set_key(str(deploy_env_path), "GE_AGENT_RESOURCE_NAME", agent_name, quote_mode="always")
    print(f"已同步 GE_AGENT_RESOURCE_NAME 到 {deploy_env_path}")
else:
    print("\n⚠️ 警告: 未能从响应中识别出 Agent 资源名，请检查上面的报错输出。")
