#!/usr/bin/env bash
# =============================================================================
# 02_init_openstack.sh
# 오픈스택 초기 인프라 설정 (외부망, 이미지, Flavor 생성)
#
# 실행 위치: Control Node
# 실행 방법: bash 02_init_openstack.sh
# 소요 시간: 약 5~10분
#
# 전제조건:
#   - 01_deploy_aio.sh 수행 완료
#   - 인터넷 연결 가능 환경
#   - admin-openrc.sh 파일 존재
# =============================================================================

# =============================================================================
# 실행 방법: sudo bash 02_init_openstack.sh 2>&1 | tee 02_init_openstack.log
# =============================================================================

set -e

# ── 설정값 (필수 확인) ────────────────────────────────────────────────────────
NODE_IP="172.21.33.67"
EXTERNAL_NETWORK_CIDR="172.21.33.0/24"
EXTERNAL_GATEWAY="172.21.33.254"
FLOATING_IP_START="172.21.33.200"
FLOATING_IP_END="172.21.33.250"

log_info()    { echo -e "[\e[34mINFO\e[0m]  $1"; }
log_success() { echo -e "[\e[32mOK\e[0m]    $1"; }
log_warn()    { echo -e "[\e[33mWARN\e[0m]  $1"; }
log_error()   { echo -e "[\e[31mERROR\e[0m] $1"; exit 1; }

# ── 1. 인증 환경변수 로드 ──────────────────────────────────────────────────────
log_info "인증 설정(admin-openrc.sh)을 찾는 중..."
OPENRC_FILES=("$HOME/admin-openrc.sh" "./admin-openrc.sh" "/etc/kolla/admin-openrc.sh")
SOURCE_FILE=""

for f in "${OPENRC_FILES[@]}"; do
    if [ -f "$f" ]; then
        SOURCE_FILE="$f"
        break
    fi
done

if [ -z "$SOURCE_FILE" ]; then
    log_error "admin-openrc.sh 파일을 찾을 수 없습니다. 01번 배포가 완료되었는지 확인하세요."
fi

source "$SOURCE_FILE"
log_success "인증 로드 완료 ($SOURCE_FILE)"

# OpenStack CLI 가상환경 연동
if [ -d "/opt/kolla-venv" ]; then
    source /opt/kolla-venv/bin/activate
fi

# ── 2. 외부 Provider 네트워크 생성 ───────────────────────────────────────────
# VM들이 실제 외부 인터넷(172.21.33.xxx)으로 나가는 통로입니다.
log_info "외부 네트워크(external-net) 생성 중..."
openstack network create --share --external --provider-physical-network physnet1 --provider-network-type flat external-net 2>/dev/null || true
openstack subnet create --network external-net --allocation-pool "start=${FLOATING_IP_START},end=${FLOATING_IP_END}" \
    --dns-nameserver 8.8.8.8 --gateway "$EXTERNAL_GATEWAY" --subnet-range "$EXTERNAL_NETWORK_CIDR" --no-dhcp \
    external-subnet 2>/dev/null || true
log_success "외부망 생성 완료 (FIP 범위: ${FLOATING_IP_START} ~ ${FLOATING_IP_END})"

# ── 3. Flavor(사양) 생성 ──────────────────────────────────────────────────────
log_info "VM 기본 사양(Flavor) 생성 중..."
openstack flavor create --ram 1024 --vcpus 1 --disk 10 m1.small 2>/dev/null || true
openstack flavor create --ram 2048 --vcpus 2 --disk 20 m1.medium 2>/dev/null || true
openstack flavor create --ram 4096 --vcpus 4 --disk 40 m1.large 2>/dev/null || true
log_success "Flavor 생성 완료"

# ── 4. 이미지 등록 (Ubuntu 22.04) ───────────────────────────────────────────
log_info "Cloud 이미지 등록 중..."

IMAGE_NAME="Ubuntu-22.04"
IMAGE_DIR="./images"
IMAGE_PATH="${IMAGE_DIR}/ubuntu-22.04.qcow2"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

mkdir -p "$IMAGE_DIR"

if openstack image show "$IMAGE_NAME" &>/dev/null; then
    log_success "이미 등록된 이미지입니다: $IMAGE_NAME"
else
    # 1) 기존 파일이 너무 작거나 유효하지 않으면 삭제 (실패한 다운로드 방지)
    if [ -f "$IMAGE_PATH" ]; then
        FILE_SIZE=$(stat -c%s "$IMAGE_PATH")
        if [ "$FILE_SIZE" -lt 100000000 ]; then  # 100MB 미만이면 비정상으로 간주
            log_warn "기존 파일이 너무 작아서( $(du -sh $IMAGE_PATH | awk '{print $1}') ) 삭제 후 다시 다운로드합니다."
            rm -f "$IMAGE_PATH"
        fi
    fi

    # 2) 다운로드
    if [ ! -f "$IMAGE_PATH" ]; then
        log_info "$IMAGE_NAME 이미지 다운로드 시작 (현재 경로: $IMAGE_PATH)..."
        if ! wget --continue "$IMAGE_URL" -O "$IMAGE_PATH"; then
            log_error "다운로드 실패! 인터넷 연결이나 용량을 확인하세요."
        fi
    fi

    # 3) 파일 진단 출력
    log_info "다운로드 결과 확인:"
    ls -lh "$IMAGE_PATH"
    file "$IMAGE_PATH"

    # 4) OpenStack 등록
    log_info "OpenStack에 이미지 등록 시도 중..."
    if openstack image create --container-format bare --disk-format qcow2 --file "$IMAGE_PATH" --public "$IMAGE_NAME"; then
        log_success "$IMAGE_NAME 이미지 등록 성공!"
    else
        log_error "OpenStack 등록 중 오류가 발생했습니다. (파일 경로: $(realpath $IMAGE_PATH))"
    fi
fi

# ── 5. 보안 그룹 (관리자용 기본 허용) ──────────────────────────────────────────
# 사용자들(팀원)은 나중에 계정으로 로그인해서 직접 추가하면 됩니다.
# 여기서는 Admin 계정의 default 보안 그룹에 최소한의 문(SSH, Ping)만 열어둡니다.
log_info "관리자용 기본 보안 그룹(SSH, ICMP) 규칙 추가..."
ADMIN_ID=$(openstack project show admin -f value -c id)
SG_ID=$(openstack security group list --project "$ADMIN_ID" -f value -c ID | head -1)
openstack security group rule create --proto icmp "$SG_ID" 2>/dev/null || true
openstack security group rule create --proto tcp --dst-port 22 "$SG_ID" 2>/dev/null || true
log_success "보안 규칙 추가 완료"

log_success "OpenStack initialization complete."
