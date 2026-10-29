#!/bin/bash
# exporter 계정 생성 · 갱신 (templates/account-job.yaml 이 실행). 재실행 안전 — 실행마다 비밀번호 · 제한 · 권한을 다시 넣는다.
# 환경 변수: MASTER_HOST · MASTER_PORT · MASTER_USER · MASTER_PASSWORD · EXPORTER_USER · EXPORTER_PASSWORD (Secret),
#           MAX_USER_CONNECTIONS · CA_FILE (ConfigMap). 비밀번호는 명령 인자(ps 에 보임)가 아니라 옵션 파일 · stdin 으로 넘긴다
set -euo pipefail
umask 077

cat > /work/master.cnf <<CNF
[client]
host=${MASTER_HOST}
port=${MASTER_PORT}
user=${MASTER_USER}
password=${MASTER_PASSWORD}
ssl-ca=${CA_FILE}
ssl-verify-server-cert
CNF

# 'exporter'@'%' — 파드는 워커 노드 IP 로 나가므로(Calico natOutgoing) 호스트를 고정할 수 없다. 접속은 SG M11 이 워커로 제한.
# 권한: PROCESS(processlist · InnoDB 상태) · REPLICATION CLIENT(MariaDB 의 BINLOG MONITOR 별칭, binlog 상태) ·
# REPLICA MONITOR(SHOW SLAVE STATUS, exporter slave_status 수집기) · performance_schema 읽기 (온프레미스 db_stack 과 같은 권한).
# RDS master 는 세 권한 모두 GRANT OPTION 이 있다 (2026-10-29 확인). performance_schema 는 db.t4g.micro 라 꺼져 있지만
# 나중에 켤 때 권한을 다시 줄 필요가 없게 미리 준다
mariadb --defaults-extra-file=/work/master.cnf <<SQL
CREATE USER IF NOT EXISTS '${EXPORTER_USER}'@'%' IDENTIFIED BY '${EXPORTER_PASSWORD}';
ALTER USER '${EXPORTER_USER}'@'%' IDENTIFIED BY '${EXPORTER_PASSWORD}' REQUIRE SSL WITH MAX_USER_CONNECTIONS ${MAX_USER_CONNECTIONS};
GRANT PROCESS, REPLICATION CLIENT, REPLICA MONITOR ON *.* TO '${EXPORTER_USER}'@'%';
GRANT SELECT ON performance_schema.* TO '${EXPORTER_USER}'@'%';
SQL

# 알람 임계값 · 커넥션 풀 크기 근거 (Terraform 90 db_connections_threshold)
mariadb --defaults-extra-file=/work/master.cnf --table <<SQL
SELECT @@max_connections AS max_connections, @@performance_schema AS performance_schema,
       @@log_output AS log_output, @@log_slow_query AS log_slow_query, @@log_slow_query_time AS log_slow_query_time;
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected', 'Max_used_connections');
-- SHOW GRANTS 는 비밀번호 해시를 출력하므로 쓰지 않는다
SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE = "'${EXPORTER_USER}'@'%'";
SQL
echo "exporter 계정 준비 완료"
