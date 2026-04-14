#!/usr/bin/env bash
# =============================================================================
# 04_setup_teams.sh
# 실습용 다중 테넌트(팀별) 환경 자동 구성 스크립트
#
# 실행 위치: Control Node
# 실행 방법: bash 04_setup_teams.sh
# 소요 시간: 약 5분
#
# 전제조건:
#   - 01/02번 스크립트(배포 및 초기화) 완료
#   - admin-openrc.sh 파일 존재
# =============================================================================

# =============================================================================
# 실행 방법: sudo bash 04_setup_teams.sh 2>&1 | tee 04_setup_teams.log
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── 1. 설정값 (5개 팀 고사양 체제) ───────────────────────────────────────────
NUM_TEAMS=5
INSTANCES_PER_TEAM=20
VCPU_PER_TEAM=20
RAM_PER_TEAM=40960     # 40GB (MB 단위)
DISK_PER_TEAM=1024     # 1TB (GB 단위)
FIP_PER_TEAM=10
EXT_NETWORK="external-net"
USER_PASSWORD_PREFIX="FisaOpenStack" # 비밀번호: FisaOpenStack01! 형태

# ─── 2. OpenStack 인증 확인 ───────────────────────────────────────────────────
log_info "OpenStack 인증 설정(admin-openrc.sh) 로드 중..."
if [[ -f ~/admin-openrc.sh ]]; then
    source ~/admin-openrc.sh
else
    log_error "본인 홈 디렉토리에 admin-openrc.sh 파일이 필요합니다."
fi

# 인증 테스트
openstack token issue &>/dev/null || log_error "OpenStack 인증에 실패했습니다. admin-openrc.sh를 확인하세요."
log_success "OpenStack 인증 성공"

# member 역할 존재 확인
if ! openstack role show member &>/dev/null; then
    log_info "member 역할을 생성합니다..."
    openstack role create member
fi

# ─── 3. 팀별 환경 구성 루프 ──────────────────────────────────────────────────
TEAM_OPENRC_DIR="${HOME}/team-openrc"
mkdir -p "$TEAM_OPENRC_DIR"

log_info "새로운 5개 팀 환경 구성을 시작합니다..."

for i in $(seq -f "%02g" 1 $NUM_TEAMS); do
    PROJECT_NAME="team${i}"
    USER_NAME="user${i}"
    USER_PASS="${USER_PASSWORD_PREFIX}${i}!"
    NET_NAME="net-${i}"
    SUBNET_NAME="subnet-${i}"
    ROUTER_NAME="router-${i}"
    CIDR="10.10.${i#0}.0/24" # 10.10.1.0/24, 10.10.2.0/24 ...

    echo "-----------------------------------------------------------------------"
    log_info "팀 ${i} (${PROJECT_NAME}) 환경 구성 시작..."

    # 3-1. 프로젝트 생성
    if ! openstack project show "$PROJECT_NAME" &>/dev/null; then
        openstack project create --description "Team ${i} Project" --enable "$PROJECT_NAME"
        log_success "  프로젝트 '${PROJECT_NAME}' 생성 완료"
    else
        log_warn "  프로젝트 '${PROJECT_NAME}' 이미 존재함"
    fi

    # 3-2. 사용자 생성 및 역할 부여
    if ! openstack user show "$USER_NAME" &>/dev/null; then
        openstack user create --project "$PROJECT_NAME" --password "$USER_PASS" --enable "$USER_NAME"
        log_success "  사용자 '${USER_NAME}' 생성 완료"
    else
        log_warn "  사용자 '${USER_NAME}' 이미 존재함"
    fi
    openstack role add --project "$PROJECT_NAME" --user "$USER_NAME" member
    log_success "  '${USER_NAME}'에게 '${PROJECT_NAME}'의 member 역할 부여"

    # 3-3. Quota 설정
    log_info "  Quota 설정 중 (vCPU: ${VCPU_PER_TEAM}, RAM: ${RAM_PER_TEAM}MB, Disk: ${DISK_PER_TEAM}GB)..."
    openstack quota set --instances "$INSTANCES_PER_TEAM" \
                        --cores "$VCPU_PER_TEAM" \
                        --ram "$RAM_PER_TEAM" \
                        --gigabytes "$DISK_PER_TEAM" \
                        --volumes 10 \
                        --floating-ips "$FIP_PER_TEAM" \
                        --secgroups 10 \
                        --secgroup-rules 100 \
                        "$PROJECT_NAME"

    # 3-4. 프라이빗 네트워크 및 서브넷 구성
    if ! openstack network show "$NET_NAME" &>/dev/null; then
        openstack network create --project "$PROJECT_NAME" "$NET_NAME"
        openstack subnet create --project "$PROJECT_NAME" --network "$NET_NAME" \
                                --subnet-range "$CIDR" --dns-nameserver 8.8.8.8 "$SUBNET_NAME"
        log_success "  네트워크 '${NET_NAME}' 및 서브넷 '${CIDR}' 생성 완료"
    fi

    # 3-5. 라우터 및 외부망 연결
    if ! openstack router show "$ROUTER_NAME" &>/dev/null; then
        openstack router create --project "$PROJECT_NAME" "$ROUTER_NAME"
        openstack router set --external-gateway "$EXT_NETWORK" "$ROUTER_NAME"
        openstack router add subnet "$ROUTER_NAME" "$SUBNET_NAME"
        log_success "  라우터 '${ROUTER_NAME}' 생성 및 외부망 연결 완료"
    fi

    # 3-6. 프로젝트 기본 보안 그룹 규칙 추가 (SSH, ICMP)
    # 해당 프로젝트의 default 보안 그룹 ID 찾기
    SG_ID=$(openstack security group list --project "$PROJECT_NAME" -f value -c ID -c Name | grep "default" | awk '{print $1}' | head -1)
    if [[ -n "$SG_ID" ]]; then
        openstack security group rule create --proto icmp --ingress "$SG_ID" 2>/dev/null || true
        openstack security group rule create --proto tcp --dst-port 22 --ingress "$SG_ID" 2>/dev/null || true
        log_success "  기본 보안 그룹 규칙 추가 (ICMP, SSH)"
    fi

    # 3-7. 개별 OpenRC 파일 생성
    OPENRC_PATH="${TEAM_OPENRC_DIR}/${USER_NAME}-openrc.sh"
    # OS_AUTH_URL 추출
    AUTH_URL=$(openstack endpoint list --service keystone --interface public -f value -c URL | head -1)

    cat <<EOF > "$OPENRC_PATH"
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=${PROJECT_NAME}
export OS_USERNAME=${USER_NAME}
export OS_PASSWORD=${USER_PASS}
export OS_AUTH_URL=${AUTH_URL}
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
    chmod 600 "$OPENRC_PATH"
    log_success "  인증 파일 생성: ${OPENRC_PATH}"
done

echo "-----------------------------------------------------------------------"
log_success "Team environment setup complete."
log_info "OpenRC files generated in ${TEAM_OPENRC_DIR}."
log_info "Password pattern: ${USER_PASSWORD_PREFIX}01~05!"
