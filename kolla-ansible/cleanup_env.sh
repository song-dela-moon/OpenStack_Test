#!/usr/bin/env bash
# =============================================================================
# cleanup_env.sh
# 오픈스택 및 컨테이너 환경 완전 초기화 스크립트
#
# 실행 위치: 모든 노드 (개별 실행)
# 실행 방법: bash cleanup_env.sh
# 소요 시간: 약 5분
#
# 전제조건:
#   - root 또는 sudo 권한
# =============================================================================

# =============================================================================
# 실행 방법: sudo bash cleanup_env.sh 2>&1 | tee cleanup_env.log
# =============================================================================

set -e

echo "[INFO] Starting environment cleanup..."

# 1. Docker 컨테이너 및 볼륨 삭제
if command -v docker &>/dev/null; then
    echo "[INFO] Removing Docker containers and volumes..."
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
fi

# 2. OVS 내부 브리지 청소 (br-ex는 관리망이므로 제외하고 br-int 등을 삭제)
if command -v ovs-vsctl &>/dev/null; then
    echo "[INFO] Removing OVS internal bridges..."
    # br-ex는 사용자께서 수동으로 잡으셨으므로 건드리지 않습니다.
    ovs-vsctl del-br br-int 2>/dev/null || true
    ovs-vsctl del-br br-tun 2>/dev/null || true
fi

# 3. Sunbeam / Calico / LXD 찌꺼기 제거
echo "[INFO] Cleaning up network residue (Calico/LXD)..."
# Calico 관련 가상 인터페이스 삭제
ip link show | grep "cali" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}' | xargs -I {} ip link delete {} 2>/dev/null || true
ip link delete vxlan.calico 2>/dev/null || true
# LXD 브리지 삭제
ip link set lxdbr0 down 2>/dev/null || true
ip link delete lxdbr0 2>/dev/null || true

# 4. LVM (Cinder) 초기화
if command -v vgdisplay &>/dev/null; then
    echo "[INFO] Cleaning up Cinder LVM volume group..."
    vgremove -y cinder-volumes 2>/dev/null || true
    # PV 삭제 (스크립트의 디스크 경로 참고)
    pvremove -y /dev/nvme0n1p2 /dev/sdb 2>/dev/null || true
fi

# 5. 설정 및 가상환경 초기화
echo "[INFO] Removing configuration directories..."
rm -rf /etc/kolla
rm -rf /opt/kolla-venv
# ~/.ansible 폴더도 청소하여 컬렉션 충돌 방지
rm -rf ~/.ansible

echo "[OK] Environment cleanup complete."
