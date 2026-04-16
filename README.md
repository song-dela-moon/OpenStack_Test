# OpenStack 자동화 배포 및 실습 환경 구축
이 저장소는 **Kolla-Ansible** 을 활용하여 Ubuntu 22.04 LTS 환경에서 OpenStack 2024.2 (Dalmatian) 버전을 효율적으로 구축하고, Multi-tenant 실습 환경을 자동화하는 스크립트를 포함하고 있습니다.
<img width="2520" height="1113" alt="image" src="https://github.com/user-attachments/assets/a30f2f17-52ee-4666-8a89-934be7730e0c" />

## 🚀 주요 특징
- **자동화된 AIO 배포**: 한 번의 실행으로 Control Node 및 OpenStack 핵심 서비스 구축.
- **멀티 노드 확장성**: 새로운 Compute Node를 클러스터에 손쉽게 추가할 수 있는 가이드 및 스크립트 제공.
- **대용량 블록 스토리지**: LVM(Cinder) 기반의 대규모 스토리지(약 7TB+) 구성 지원.
- **실습 환경 자동화**: 팀별 프로젝트 생성, 자원 할당량(Quota) 설정, 네트워크 격리 및 인증 파일(OpenRC) 생성을 자동화.

## 📋 시스템 요구사항
### Control Node (All-in-One)
- **OS**: Ubuntu 22.04 LTS
- **RAM**: 최소 32GB (권장 64GB 이상)
- **CPU**: 최소 8 Core
- **Disk**: 100GB 이상 (Docker 이미지 및 이미지 저장소용)
### Compute Node (추가 노드)
- **RAM**: 최소 16GB
- **Disk**: Cinder 볼륨 구성을 위한 미사용 유휴 디스크(LVM VG용)

---

## 🛠 실행 순서
### 1단계: Control Node 배포 (All-in-One)
기본적인 OpenStack 컨트롤러 환경을 배포합니다.
```bash
bash kolla-ansible/01_deploy_aio.sh
```
### 2단계: 서비스 초기화
외부 네트워크 생성, 기본 이미지(Ubuntu) 등록 및 Flavor를 설정합니다.
```bash
bash kolla-ansible/02_init_openstack.sh
```
### 3단계: Compute 노드 추가 (선택 사항)
새로운 서버를 컴퓨트 노드로 클러스터에 통합합니다. (사전에 `prepare_compute_node.sh` 실행 필요)
```bash
bash kolla-ansible/03_add_compute.sh
```
### 4단계: 실습 팀(Team) 환경 구성
5개 팀을 위한 독립적인 프로젝트와 네트워크, 고사양 Quota를 배포합니다.
```bash
bash kolla-ansible/04_setup_teams.sh
```
---

## 📁 주요 스크립트 안내
- `01_deploy_aio.sh`: Kolla-Ansible 설치 및 AIO 배포 전체 자동화.
- `02_init_openstack.sh`: 네트워크/이미지/사양 등 초기 필수 인프라 설정.
- `03_add_compute.sh`: Multinode 인벤토리 생성 및 추가 컴퓨트 노드 배포.
- `04_setup_teams.sh`: 팀별 격리 환경(네트워크, 사용자, Quota) 구축 및 OpenRC 생성.
- `prepare_compute_node.sh`: 컴퓨트 노드용 OVS 및 커널 모듈 사전 설정.
- `cleanup_env.sh`: 꼬인 환경(Docker, OVS 찌꺼기 등)을 초기화하는 정리 스크립트.
