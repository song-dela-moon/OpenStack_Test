#!/usr/bin/env bash
# =============================================================================
# prepare_compute_node.sh
# 신규 Compute Node 추가를 위한 사전 환경 및 패키지 설정 스크립트
#
# 실행 위치: 신규 Compute Node (fisa-cloud-dev-2)
# 실행 방법: bash prepare_compute_node.sh
# 소요 시간: 약 5분
#
# 전제조건:
#   - Ubuntu 22.04 LTS 설치 완료
#   - 인터넷 연결 가능 환경
#   - root 또는 sudo 권한
# =============================================================================

# =============================================================================
# 실행 방법: sudo bash prepare_compute_node.sh 2>&1 | tee prepare_compute_node.log
# =============================================================================
set -e
echo "[1/4] Installing and enabling host OVS service..."
sudo apt update && sudo apt install -y openvswitch-switch
sudo systemctl enable openvswitch-switch
echo "[2/4] Cleaning OVS runtime files..."
sudo systemctl stop openvswitch-switch 2>/dev/null || true
sudo rm -rf /run/openvswitch/*
sudo rm -rf /var/run/openvswitch/*
echo "[3/4] Starting OVS service and applying netplan..."
sudo systemctl start openvswitch-switch
sudo netplan apply
echo "[4/4] Configuring firewall and kernel modules..."
# Load br_netfilter for bridge filtering (required for Libvirt/OVS)
sudo modprobe br_netfilter
echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf
echo "---------------------------------------------------------"
echo "Compute node preparation complete."