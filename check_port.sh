#!/bin/bash

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "### 🚀 심층 네트워크 진단 스크립트 (포트: 3000) ###\n"

# --- 1. 커널 IP 포워딩 확인 ---
echo -e "${YELLOW}--- 1. Kernel IP 포워딩 기능 확인 ---${NC}"
IP_FORWARD=$(sysctl net.ipv4.ip_forward)
echo "[정보] 현재 설정: ${BOLD}$IP_FORWARD${NC}"

if [[ "$IP_FORWARD" != "net.ipv4.ip_forward = 1" ]]; then
    echo -e "${RED}[문제!]${NC} IP 포워딩 기능이 비활성화되어 있습니다. Docker 포트 매핑이 동작할 수 없습니다."
    echo "   -> ${BOLD}임시 해결: sudo sysctl -w net.ipv4.ip_forward=1${NC}"
    echo "   -> ${BOLD}영구 해결: /etc/sysctl.conf 파일에 'net.ipv4.ip_forward = 1' 라인을 추가하거나 주석 해제하세요.${NC}"
    # 여기서 멈추는 게 의미 있으므로 exit
    exit 1
else
    echo -e "${GREEN}[정상]${NC} IP 포워딩 기능이 활성화되어 있습니다."
fi
echo ""

# --- 2. Grafana 컨테이너 IP 확인 및 직접 접속 테스트 ---
echo -e "${YELLOW}--- 2. 컨테이너 직접 접속 테스트 ---${NC}"
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' grafana)
if [ -z "$CONTAINER_IP" ]; then
    echo -e "${RED}[문제]${NC} 'grafana' 컨테이너의 IP 주소를 찾을 수 없습니다. 컨테이너가 실행 중인지 확인하세요."
    exit 1
fi
echo "[정보] Grafana 컨테이너의 내부 IP: ${BOLD}$CONTAINER_IP${NC}"

echo "[테스트] 호스트에서 컨테이너 내부 IP로 직접 접속을 시도합니다..."
if curl -s --connect-timeout 2 "http://$CONTAINER_IP:3000" > /dev/null; then
    echo -e "${GREEN}[정상]${NC} 호스트에서 컨테이너(${BOLD}$CONTAINER_IP:3000${NC})로 직접 접속이 가능합니다. 컨테이너 서비스 자체는 정상입니다."
else
    echo -e "${RED}[문제]${NC} 호스트에서도 컨테이너로 직접 접속할 수 없습니다. Grafana 컨테이너 내부의 문제일 수 있습니다."
    echo "   -> 확인 명령어: ${BOLD}docker logs grafana${NC}"
fi
echo ""

# --- 3. IPTABLES FORWARD 체인 정책 확인 ---
echo -e "${YELLOW}--- 3. IPTABLES FORWARD 체인 정책 확인 ---${NC}"
FORWARD_POLICY=$(sudo iptables -L FORWARD -v -n | grep "Chain FORWARD" | awk '{print $4}' | tr -d '()')
echo "[정보] FORWARD 체인의 기본 정책: ${BOLD}$FORWARD_POLICY${NC}"

if [[ "$FORWARD_POLICY" == "DROP" ]]; then
    echo -e "[정보] 기본 정책이 DROP이므로, Docker 관련 ACCEPT 규칙이 있는지 확인합니다."
    if sudo iptables -L FORWARD -n | grep -q "DOCKER-USER" && sudo iptables -L FORWARD -n | grep -q "DOCKER-ISOLATION-STAGE-1"; then
        echo -e "${GREEN}[정상]${NC} Docker가 생성한 FORWARD 허용 체인이 존재합니다."
    else
        echo -e "${RED}[문제 의심]${NC} FORWARD 체인 정책이 DROP인데 Docker 관련 허용 규칙이 보이지 않습니다. Docker 서비스 재시작이 필요할 수 있습니다."
        echo "   -> ${BOLD}sudo systemctl restart docker${NC}"
    fi
else
    echo -e "${GREEN}[정상]${NC} FORWARD 체인의 기본 정책이 ${BOLD}ACCEPT${NC}이므로 문제없습니다."
fi
echo ""

# --- 4. IPTABLES NAT 규칙 확인 ---
echo -e "${YELLOW}--- 4. IPTABLES NAT (포트포워딩) 규칙 확인 ---${NC}"
echo "[정보] 외부 IP(172.22.204.22/24) -> 컨테이너 IP(${CONTAINER_IP})로 DNAT 규칙이 있는지 확인합니다."
# 172.22.204.22 또는 172.22.204.24로 들어오는 3000번 포트 요청을 DNAT 하는 규칙이 있는지 확인
if sudo iptables -t nat -L DOCKER -v -n | grep "tcp dpt:3000" | grep -q "to-destination $CONTAINER_IP:3000"; then
    echo -e "${GREEN}[정상]${NC} 3000번 포트에 대한 DNAT 규칙이 올바르게 설정되어 있습니다."
else
    echo -e "${RED}[문제]${NC} 3000번 포트를 컨테이너 IP(${BOLD}$CONTAINER_IP${NC})로 전달하는 NAT 규칙을 찾을 수 없습니다."
    echo "   Docker Compose 설정의 'ports' 부분이 올바른지 확인하고, Docker를 재시작해보세요."
    echo "   -> ${BOLD}cd /home/ubuntu/prometheus/ && docker-compose down && docker-compose up -d${NC}"
fi
echo ""

# --- 5. 최종 결론 ---
echo -e "${YELLOW}--- 5. 최종 결론 ---${NC}"
echo "✅ 위 1~4번 항목이 ${GREEN}모두 [정상]${NC}으로 나온다면, 서버 내부 설정의 문제일 가능성은 거의 없습니다."
echo "이 경우, 문제는 99.9% ${BOLD}서버 외부의 네트워크 장비(보안 그룹, 물리 방화벽 등) 설정${NC} 때문입니다."
echo " "
echo "네트워크/인프라 담당자에게 다음과 같이 문의하세요:"
echo "------------------------------------------------------------------------------------------"
echo -e "  '외부에서 ${BOLD}172.22.204.22${NC} 또는 ${BOLD}172.22.204.24${NC} IP의 ${BOLD}TCP 3000번 포트${NC}로 들어오는"
echo -e "   인바운드 트래픽이 방화벽에서 허용되어 있는지 확인 부탁드립니다.'"
echo "------------------------------------------------------------------------------------------"
