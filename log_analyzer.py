#!/usr/bin/env python3
import re
import csv
import sys
import argparse
import requests
from collections import defaultdict

# --- 설정: 사용할 GeoAPI들 ---
GEO_APIS = [
    # (column_prefix, url_template)
    ("API1", "http://ip-api.com/json/{ip}?fields=status,country,city"),
    ("API2", "https://ipinfo.io/{ip}/json"),
    ("API3", "https://ipapi.co/{ip}/json"),
]
TIMEOUT = 1  # 초

def geolocate(ip):
    """세 가지 GeoAPI를 순서대로 호출하여 (country, city) 튜플 리스트 반환."""
    results = []
    for prefix, url in GEO_APIS:
        try:
            r = requests.get(url.format(ip=ip), timeout=TIMEOUT)
            data = r.json()
        except Exception:
            # 호출 실패 시 빈값
            results.append((None, None))
            continue

        # API별 응답 파싱
        # API1: ip-api.com → {'status':'success','country':'...', 'city':'...'}
        if url.startswith("http://ip-api.com") and data.get("status") == "success":
            results.append((data.get("country"), data.get("city")))
        # API2: ipinfo.io → {'country':'US','city':'Ashburn', ...}
        elif url.startswith("https://ipinfo.io"):
            results.append((data.get("country"), data.get("city")))
        # API3: ipapi.co → {'country_name':'United States','city':'Ashburn', ...}
        elif url.startswith("https://ipapi.co"):
            results.append((data.get("country_name"), data.get("city")))
        else:
            results.append((None, None))

    return results

def main():
    parser = argparse.ArgumentParser(description='UFW 로그 분석 + GeoIP 정보 포함 CSV 출력')
    parser.add_argument('logfile', help='분석할 UFW 로그 파일 경로')
    parser.add_argument('-n', '--top', type=int, default=20,
                        help='위치 조회할 상위 N개 IP (기본: 20)')
    args = parser.parse_args()

    # 로그 파싱용 정규식
    pattern = re.compile(r'SRC=(?P<src>\d+\.\d+\.\d+\.\d+).*DPT=(?P<dpt>\d+)')

    counts = defaultdict(int)
    ports  = defaultdict(set)

    with open(args.logfile, 'r') as f:
        for line in f:
            m = pattern.search(line)
            if not m:
                continue
            src = m.group('src')
            dpt = m.group('dpt')
            counts[src] += 1
            ports[src].add(dpt)

    # 시도 횟수 내림차순 정렬, 상위 N개 선택
    top_ips = sorted(counts.items(), key=lambda x: x[1], reverse=True)[:args.top]

    writer = csv.writer(sys.stdout, quoting=csv.QUOTE_MINIMAL)
    # 헤더: Source IP + 각 API별 Country/City 컬럼 + Attempts + Ports
    header = ["Source IP"]
    for prefix, _ in GEO_APIS:
        header += [f"{prefix}_Country", f"{prefix}_City"]
    header += ["Attempts", "Ports"]
    writer.writerow(header)

    for src, cnt in top_ips:
        geo_info = geolocate(src)
        # 결과 flatten: [(c1,city1), (c2,city2), (c3,city3)] → [c1, city1, c2, city2, ...]
        flat_geo = [item for pair in geo_info for item in pair]
        port_list = ",".join(sorted(ports[src], key=int))
        row = [src] + flat_geo + [cnt, port_list]
        writer.writerow(row)

if __name__ == '__main__':
    main()

