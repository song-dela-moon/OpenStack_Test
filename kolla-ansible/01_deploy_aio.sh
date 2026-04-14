#!/usr/bin/env bash
# =============================================================================
# 01_deploy_aio.sh
# Kolla-Ansible All-in-One OpenStack 2024.2 배포 스크립트
#
# 실행 위치: Control Node (172.21.33.67)
# 실행 방법: bash 01_deploy_aio.sh
# 소요 시간: 약 30~60분 (이미지 다운로드 포함)
#
# 전제조건:
#   - Ubuntu 22.04 LTS
#   - 최소 32GB RAM, 8 Core, 100GB Disk
#   - 인터넷 연결
#   - root 또는 sudo 권한
# =============================================================================

# =============================================================================
# 실행 방법: sudo bash 01_deploy_aio.sh 2>&1 | tee 01_deploy_aio.log
# =============================================================================

set -e

VENV_DIR="/opt/kolla-venv"
KOLLA_VERSION="2024.2"  # OpenStack Dalmatian (stable)
CONFIG_DIR="/etc/kolla"
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

log_info()    { echo -e "[\e[34mINFO\e[0m]  $1"; }
log_success() { echo -e "[\e[32mOK\e[0m]    $1"; }
log_warn()    { echo -e "[\e[33mWARN\e[0m]  $1"; }
log_error()   { echo -e "[\e[31mERROR\e[0m] $1"; exit 1; }

# --- Logging Information -----------------------------------------------------
log_info "Logging to 'deploy.log' and terminal simultaneously."
echo "-----------------------------------------------------------------------"

# ── 설정값 ────────────────────────────────────────────────────────────────────
NODE_IP="172.21.33.67"
NETWORK_IFACE="enp5s0f1"
KOLLA_VERSION="19.7.0"           # OpenStack 2024.2 (Dalmatian) - Latest stable
OPENSTACK_RELEASE="2024.2"
VENV_DIR="/opt/kolla-venv"
KOLLA_CONFIG_DIR="/etc/kolla"


# ── 1. OS 확인 ────────────────────────────────────────────────────────────────
log_info "OS 버전 확인..."
source /etc/os-release
if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "22.04" ]]; then
  log_error "Ubuntu 22.04 전용 스크립트입니다. (현재: ${PRETTY_NAME})"
fi
log_success "Ubuntu 22.04 확인"

# ── 1-1. 환경 정밀 청소 (Deep Purge) ──────────────────────────────────────────
log_info "기존 컨테이너 및 VIP 정밀 청소 중..."
# 1) VIP 강제 제거 (No route to host 에러 방지용)
sudo ip addr del 172.21.33.100/32 dev br-ex 2>/dev/null || true

# 2) 오픈스택 서비스 컨테이너 삭제 (네트워크 유지 위해 OVS는 제외)
SERVICES_TO_CLEAN="mariadb mariadb_clustercheck rabbitmq haproxy keepalived glance_api keystone nova_api nova_conductor nova_scheduler nova_libvirt nova_compute neutron_server neutron_openvswitch_agent placement_api"
for svc in $SERVICES_TO_CLEAN; do
    docker rm -f $svc 2>/dev/null || true
done

# 3) 핵심 데이터 볼륨 삭제
VOLUMES_TO_CLEAN="mariadb rabbitmq openvswitch_db"
for vol in $VOLUMES_TO_CLEAN; do
    docker volume rm $vol 2>/dev/null || true
done
log_success "Environment cleanup completed."

# ── 2. 시스템 패키지 설치 ─────────────────────────────────────────────────────
log_info "시스템 패키지 업데이트 및 설치..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  python3-dev python3-pip python3-venv python3-full \
  libffi-dev gcc libssl-dev \
  git curl wget vim net-tools

# -- 2-1. Resolve MariaDB/Database conflicts ---------------------------------
log_info "Checking for MariaDB conflicts..."
if netstat -tulpn 2>/dev/null | grep -q ":3306 "; then
    log_warn "  3306 포트 충돌 감지! 자동 정리를 시도합니다..."
    CONF_CONTS=$(docker ps -a --format "{{.ID}} {{.Ports}}" | grep ":3306->" | awk '{print $1}' || true)
    if [ -n "$CONF_CONTS" ]; then
        log_info "  기존 충돌 컨테이너 발견. 중지 및 제거 중..."
        docker stop $CONF_CONTS && docker rm $CONF_CONTS
    fi
    systemctl stop kolla-proxysql-container.service 2>/dev/null || true
    docker stop mariadb proxysql 2>/dev/null || true
    docker rm mariadb proxysql 2>/dev/null || true
    log_success "  포트 충돌 해결 완료"
fi

if docker volume ls -q | grep -q "^mariadb$"; then
    log_warn "  기존 'mariadb' 볼륨 존재. 비밀번호 변경 시 Access Denied가 발생할 수 있습니다."
fi

if command -v apparmor_parser &>/dev/null; then
    log_info "  AppArmor 설정 확인 중... (컨테이너 권한 문제 방지)"
    apt-get remove -y -qq apparmor-profiles 2>/dev/null || true
    apparmor_parser -R /etc/apparmor.d/usr.sbin.mariadbd 2>/dev/null || true
fi

# 이전에 잘못 설치된 우분투 기본 패키지나 충돌 데몬(docker, libvirt 등) 삭제
apt-get remove -y -qq docker.io docker-compose-v2 containerd runc libvirt-daemon-system libvirt-clients libvirt-daemon 2>/dev/null || true
apt-get autoremove -y -qq
rm -rf /var/run/libvirt/ || true
log_success "시스템 패키지 준비 완료"

# ── 3. 디스크 설정 ───────────────────────────────────────────────────────────
# nvme0n1p1 (100GB) -> /var/lib/docker
# nvme0n1p2 + sdb -> cinder-volumes VG (총 ~3.5TB)
log_info "디스크 파티셔닝 및 LVM 설정 시작..."
apt-get install -y -qq lvm2 xfsprogs parted

NVME_DISK="/dev/nvme0n1"
NVME_P1="${NVME_DISK}p1"
NVME_P2="${NVME_DISK}p2"
CINDER_DISK="/dev/sdb"

if ! lsblk "$NVME_P1" &>/dev/null; then
    log_info "  nvme0n1 파티셔닝 중 (p1: 100GB, p2: 나머지)..."
    parted -s "$NVME_DISK" mklabel gpt
    parted -s "$NVME_DISK" mkpart primary xfs 0% 100GiB
    parted -s "$NVME_DISK" mkpart primary 100GiB 100%
    partprobe "$NVME_DISK"
    sleep 2
fi

if ! grep -q "$NVME_P1" /proc/mounts 2>/dev/null; then
    log_info "  $NVME_P1 -> /var/lib/docker 마운트 중..."
    mkfs.xfs -f "$NVME_P1" || true
    mkdir -p /var/lib/docker
    mount "$NVME_P1" /var/lib/docker
    UUID=$(blkid -s UUID -o value "$NVME_P1")
    grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /var/lib/docker xfs defaults 0 2" >> /etc/fstab
fi

if ! vgs cinder-volumes &>/dev/null; then
    log_info "  Cinder LVM 볼륨 그룹(cinder-volumes) 생성 중..."
    pvcreate -f "$NVME_P2" "$CINDER_DISK" || true
    vgcreate cinder-volumes "$NVME_P2" "$CINDER_DISK"
fi

log_success "디스크 및 스토리지 설정 완료"


# ── 4. Python 가상환경 + kolla-ansible 설치 ───────────────────────────────────
log_info "Python 가상환경 생성 및 kolla-ansible 설치..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

pip install -q --upgrade pip
pip install -q "ansible-core>=2.16,<2.18"
pip install -q "kolla-ansible==${KOLLA_VERSION}"
pip install -q "docker>=7.1.0"
pip install -q "dbus-python"       # prechecks dbus-python 에러 해결용
pip install -q "PyYAML"            # 구성 파싱 의존성

# ── 4-1. Ansible Galaxy 의존성 설치 ──────────────────────────────────────────
log_info "Ansible Galaxy 컬렉션 설치 (install-deps)..."
kolla-ansible install-deps || log_warn "일부 컬렉션 설치 실패 (무시 가능)"
log_success "컬렉션 설치 완료"


# pip 설치 경로 확인
KOLLA_BIN=$(which kolla-ansible)
log_info "kolla-ansible 경로: $KOLLA_BIN"

# ── 5. kolla 설정 디렉토리 초기화 ────────────────────────────────────────────
log_info "kolla 설정 디렉토리 초기화..."
mkdir -p "$KOLLA_CONFIG_DIR"

# ── 6. 설정 파일 복사 및 비밀번호 생성 ─────────────────────────────────────────
log_info "기본 설정 파일 복사 및 비밀번호 생성..."

# globals.yml 복사 (이 스크립트와 같은 디렉토리의 globals.yml 우선 사용)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/globals.yml" ]; then
  cp "${SCRIPT_DIR}/globals.yml" "${KOLLA_CONFIG_DIR}/globals.yml"
  log_success "  globals.yml 복사 완료"
else
  cp "$VENV_DIR/share/kolla-ansible/etc_examples/kolla/globals.yml" "$KOLLA_CONFIG_DIR/globals.yml"
fi

# passwords.yml 템플릿 복사 후 비밀번호 생성
cp "$VENV_DIR/share/kolla-ansible/etc_examples/kolla/passwords.yml" "$KOLLA_CONFIG_DIR/passwords.yml"
kolla-genpwd
log_success "  passwords.yml 생성 완료 (비밀번호 랜덤화 완료)"

# ── 6-1. Nova KVM 가속 확인 및 fallback ─────────────────────────────────────
log_info "KVM 하드웨어 가속 확인 중..."
if ! grep -Eoc "vmx|svm" /proc/cpuinfo > /dev/null; then
  log_warn "  KVM 가속이 지원되지 않거나 BIOS에서 비활성화됨. QEMU 모드로 전환합니다."
  sed -i 's/nova_compute_virt_type: "kvm"/nova_compute_virt_type: "qemu"/' "$KOLLA_CONFIG_DIR/globals.yml"
else
  log_success "  KVM 가속 지원 확인됨"
fi

# ── 7. all-in-one inventory 설정 ────────────────────────────────────────────
log_info "all-in-one inventory 설정..."
# 가상환경 내 기본 AIO 인벤토리 경로 확인
AIO_INVENTORY="$VENV_DIR/share/kolla-ansible/ansible/inventory/all-in-one"

if [ ! -f "$AIO_INVENTORY" ]; then
  # 직접 생성 (파일이 없을 경우 대비)
  cat > /tmp/kolla-aio-inventory << 'EOF'
[control]
localhost       ansible_connection=local

[network]
localhost       ansible_connection=local

[compute]
localhost       ansible_connection=local

[monitoring]
localhost       ansible_connection=local

[storage]
localhost       ansible_connection=local

[deployment]
localhost       ansible_connection=local
EOF
  AIO_INVENTORY="/tmp/kolla-aio-inventory"
fi
log_success "  inventory 준비 완료: ${AIO_INVENTORY}"



# admin 비밀번호 확인 (나중에 Dashboard 로그인용)
ADMIN_PASS=$(grep "^keystone_admin_password" "$KOLLA_CONFIG_DIR/passwords.yml" | awk '{print $2}')
log_info "Admin 비밀번호 (나중에 사용): ${ADMIN_PASS}"
echo "ADMIN_PASSWORD=${ADMIN_PASS}" > "$SCRIPT_DIR/.admin_password"

# ── 8. 서버 부트스트랩 ────────────────────────────────────────────────────────
log_info "kolla bootstrap-servers 실행 (Docker 설정 확인)..."
kolla-ansible bootstrap-servers -i "$AIO_INVENTORY" \
  --ask-become-pass 2>/dev/null || \
kolla-ansible bootstrap-servers -i "$AIO_INVENTORY"
log_success "bootstrap-servers 완료"

# ── 9. 사전 점검 ──────────────────────────────────────────────────────────────
log_info "kolla prechecks 실행..."
kolla-ansible prechecks -i "$AIO_INVENTORY"
log_success "prechecks 통과"

# ── 10. OpenStack 배포 (핵심 단계: 20~50분 소요) ─────────────────────────────
kolla-ansible deploy -i "$AIO_INVENTORY"
log_success "OpenStack deployment finished."

# ── 11. admin-openrc 생성 ─────────────────────────────────────────────────────
log_info "admin-openrc.sh 생성..."
kolla-ansible post-deploy -i "$AIO_INVENTORY"
cp /etc/kolla/admin-openrc.sh "$HOME/admin-openrc.sh"
log_success "~/admin-openrc.sh 생성 완료"

# ── 완료 메시지 ───────────────────────────────────────────────────────────────
echo "-----------------------------------------------------------------------"
log_info "OpenStack ${OPENSTACK_RELEASE} Deployment Summary"
log_info "Horizon Dashboard: http://${NODE_IP}"
log_info "Admin Password:    ${ADMIN_PASS}"
log_info "CLI Access:        source ~/admin-openrc.sh"
echo "-----------------------------------------------------------------------"
log_info "Next Step: bash 02_init_openstack.sh"
