#!/usr/bin/env bash
# =============================================================================
# 03_add_compute.sh
# 추가 Compute Node 클러스터 통합 및 배포 스크립트
#
# 실행 위치: Control Node
# 실행 방법: bash 03_add_compute.sh
# 소요 시간: 약 20~30분
#
# 전제조건:
#   - 01_deploy_aio.sh 수행 완료
#   - 신규 노드에 prepare_compute_node.sh 수행 완료
#   - Control -> Compute 방향 SSH 키 복제(ssh-copy-id) 완료
# =============================================================================

# =============================================================================
# 실행 방법: sudo bash 03_add_compute.sh 2>&1 | tee 03_add_compute.log
# =============================================================================

# 모든 출력을 터미널과 로그 파일(03_add_compute.log)에 동시에 기록
LOG_FILE="03_add_compute.log"
exec > >(tee -i "$LOG_FILE") 2>&1

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]  $*"; }
log_error()   { echo -e "${RED}[ERROR] $*"; exit 1; }

# ── 환경 변수 설정 ─────────────────────────────────────────────────────────────
CONTROL_IP="172.21.33.67"
COMPUTE_IP="172.21.33.69"
VIP_IP="172.21.33.100"
USER_NAME="user"
VENV_DIR="/opt/kolla-venv"
KOLLA_CONFIG_DIR="/etc/kolla"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. 권한 사전 조정 ─────────────────────────────────────────────────────────
log_info "Kolla 설정 파일 권한 조정 중..."
sudo chmod 644 "${KOLLA_CONFIG_DIR}/passwords.yml" || true
sudo chmod 644 "${KOLLA_CONFIG_DIR}/globals.yml" || true
log_success "권한 조정 완료"

# ── 2. 가상환경 활성화 및 필수 패키지 설치 ──────────────────────────────────
log_info "가상환경 활성화 및 의존성 설치 중..."
source "$VENV_DIR/bin/activate"
pip install -q -U pip
pip install -q docker
kolla-ansible install-deps
log_success "의존성 설치 완료"

# ── 3. SSH 연결 확인 ─────────────────────────────────────────────────────────
log_info "Compute 노드 (${COMPUTE_IP}) SSH 연결 확인..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${USER_NAME}@${COMPUTE_IP}" "echo OK" &>/dev/null; then
  log_error "SSH 접속 실패! 'ssh-copy-id ${USER_NAME}@${COMPUTE_IP}'를 먼저 실행하세요."
fi
log_success "SSH 접속 확인 완료"

# ── 4. 상세 Multinode 인벤토리 생성 (모든 프록시 그룹 포함) ──────────────────
log_info "상세 multinode 인벤토리 생성 중 (프록시 누락 완벽 차단)..."
cat > "${SCRIPT_DIR}/multinode" << EOF
[control]
${CONTROL_IP}  ansible_user=${USER_NAME} ansible_become=true ansible_python_interpreter=${VENV_DIR}/bin/python

[network]
${CONTROL_IP}  ansible_user=${USER_NAME} ansible_become=true ansible_python_interpreter=${VENV_DIR}/bin/python

[compute]
${COMPUTE_IP}  ansible_user=${USER_NAME} ansible_become=true

[monitoring]
${CONTROL_IP}  ansible_user=${USER_NAME} ansible_become=true ansible_python_interpreter=${VENV_DIR}/bin/python

[storage]
${CONTROL_IP}  ansible_user=${USER_NAME} ansible_become=true ansible_python_interpreter=${VENV_DIR}/bin/python

[deployment]
localhost  ansible_connection=local ansible_python_interpreter=${VENV_DIR}/bin/python

# --- Kolla 모든 필수 세부 그룹 매핑 ---
[mariadb:children]
control
[rabbitmq:children]
control
[keystone:children]
control

[glance:children]
control
[glance-api:children]
glance

[nova:children]
control
[nova-api:children]
nova
[nova-conductor:children]
nova
[nova-scheduler:children]
nova
[nova-novncproxy:children]
nova
[nova-spicehtml5proxy:children]
nova
[nova-serialproxy:children]
nova

[placement:children]
control
[placement-api:children]
placement

# --- Neutron All Subgroups ---
[neutron:children]
control
[neutron-server:children]
neutron
[neutron-agents:children]
neutron
[neutron-dhcp-agent:children]
neutron-agents
[neutron-l3-agent:children]
neutron-agents
[neutron-metadata-agent:children]
neutron-agents
[neutron-ovn-metadata-agent:children]
neutron-agents
[neutron-bgp-dragent:children]
neutron-agents
[neutron-infoblox-ipam-agent:children]
neutron-agents
[neutron-metering-agent:children]
neutron-agents
[ironic-neutron-agent:children]
neutron-agents
[neutron-openvswitch-agent:children]
neutron-agents
[neutron-linuxbridge-agent:children]
neutron-agents
[neutron-sriov-agent:children]
neutron-agents
[neutron-mlnx-agent:children]
neutron-agents
[neutron-eswitchd:children]
neutron-agents
[neutron-ovn-agent:children]
neutron-agents

[cinder:children]
control
[cinder-api:children]
cinder
[cinder-scheduler:children]
cinder
[cinder-volume:children]
compute
[cinder-backup:children]
cinder

[memcached:children]
control
[horizon:children]
control
[heat:children]
control
[heat-api:children]
heat
[heat-api-cfn:children]
heat
[heat-engine:children]
heat

[loadbalancer:children]
control
[haproxy:children]
loadbalancer
EOF
log_success "상세 인벤토리 생성 완료"

# ── 5. globals.yml 업데이트 (HAProxy & OVS 호스트 모드) ───────────────────────
log_info "globals.yml 설정 업데이트 중..."
sudo sed -i "s/^kolla_internal_vip_address:.*/kolla_internal_vip_address: \"${VIP_IP}\"/" "${KOLLA_CONFIG_DIR}/globals.yml"
sudo sed -i "s/^enable_haproxy:.*/enable_haproxy: \"yes\"/" "${KOLLA_CONFIG_DIR}/globals.yml"

if grep -q "enable_openvswitch" "${KOLLA_CONFIG_DIR}/globals.yml"; then
    sudo sed -i 's/^#*enable_openvswitch:.*/enable_openvswitch: "no"/' "${KOLLA_CONFIG_DIR}/globals.yml"
else
    echo 'enable_openvswitch: "no"' | sudo tee -a "${KOLLA_CONFIG_DIR}/globals.yml"
fi

# ── 6. Compute 노드 배포 ──────────────────────────────────────────────────
log_info "Compute 노드 배포 시작..."

log_info "Step [1/2]: bootstrap-servers 실행..."
kolla-ansible bootstrap-servers -i "${SCRIPT_DIR}/multinode" --limit compute

log_info "Step [2/2]: deploy 실행 (Control과 Compute 연동 작업을 수행합니다)..."
kolla-ansible deploy -i "${SCRIPT_DIR}/multinode" --limit control,compute

log_success "Compute node deployment complete. Log: $LOG_FILE"

# ── 7. 결과 확인 ─────────────────────────────────────────────────────────────
source "$HOME/admin-openrc.sh"
echo "--- Compute Service List ---"
openstack compute service list
echo "--- Hypervisor List ---"
openstack hypervisor list
