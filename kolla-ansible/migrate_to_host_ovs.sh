#!/usr/bin/env bash
# =============================================================================
# migrate_to_host_ovs.sh
# 컨테이너 기반 OVS를 호스트 기반 OVS로 마이그레이션하는 스크립트
#
# 실행 위치: 모든 노드 (개별 실행)
# 실행 방법: bash migrate_to_host_ovs.sh
# 소요 시간: 약 2분
#
# 전제조건:
#   - OpenStack 배포 완료 상태
#   - root 또는 sudo 권한
# =============================================================================

# =============================================================================
# 실행 방법: sudo bash migrate_to_host_ovs.sh 2>&1 | tee migrate_to_host_ovs.log
# =============================================================================
set -e
echo "[1/4] Stopping OVS containers and services..."
docker stop openvswitch_vswitchd openvswitch_db 2>/dev/null || true
docker rm openvswitch_vswitchd openvswitch_db 2>/dev/null || true
sudo systemctl stop openvswitch-switch 2>/dev/null || true
echo "[2/4] Cleaning up OVS runtime files (PIDs, sockets)..."
# Required for host service to start cleanly.
sudo rm -rf /run/openvswitch/*
sudo rm -rf /var/run/openvswitch/*
echo "[3/4] Starting host OVS service..."
sudo systemctl start openvswitch-switch
sudo systemctl enable openvswitch-switch
echo "[4/4] Restoring network and applying configurations..."
# globals.yml에 enable_openvswitch: "no" 추가/수정
if grep -q "enable_openvswitch" /etc/kolla/globals.yml; then
    sudo sed -i 's/^#*enable_openvswitch:.*/enable_openvswitch: "no"/' /etc/kolla/globals.yml
else
    echo 'enable_openvswitch: "no"' | sudo tee -a /etc/kolla/globals.yml
fi
sudo netplan apply
docker restart neutron_openvswitch_agent
echo "Migration complete. Check status with 'systemctl status openvswitch-switch'."