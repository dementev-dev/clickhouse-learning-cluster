-- Версия ClickHouse
SELECT version();

-- Созданные в системе кластера
SHOW clusters;

-- Список активных репликаций
SELECT * FROM system.zookeeper WHERE path = '/clickhouse/task_queue/replicas/';
