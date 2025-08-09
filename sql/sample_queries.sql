-- ========================================
-- БАЗОВЫЕ ПРОВЕРКИ КЛАСТЕРА
-- ========================================

-- Проверка версии ClickHouse
SELECT version() AS clickhouse_version;

-- Список всех доступных кластеров
SHOW CLUSTERS;

-- Детальная информация о кластерах и их узлах
SELECT 
    cluster,
    groupArray(concat(host_name, ':', toString(port))) AS hosts,
    count() AS nodes_count
FROM system.clusters 
GROUP BY cluster 
ORDER BY cluster;

-- Проверка текущего хоста (на какой узел мы подключились)
SELECT hostName() AS current_host;

-- ========================================
-- СОЗДАНИЕ РЕПЛИЦИРУЕМЫХ ТАБЛИЦ
-- ========================================

-- Удаляем таблицы если они существуют (для повторного запуска)
DROP TABLE IF EXISTS user_scores ON CLUSTER c2sh2rep NO DELAY;
DROP TABLE IF EXISTS user_scores_rep ON CLUSTER c2sh2rep NO DELAY;

-- Создаем локальную реплицируемую таблицу на всех узлах кластера
-- Эта таблица будет физически хранить данные с репликацией
CREATE TABLE user_scores_rep ON CLUSTER c2sh2rep (
    user_id    UInt32,
    avg_score  Float32,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/shard_{shard_c2sh2rep}/{database}/{table}',  -- Уникальный путь в ZooKeeper
    '{replica_c2sh2rep}'                                       -- Имя реплики
)
ORDER BY (user_id)
SETTINGS index_granularity = 8192;

-- Создаем Distributed таблицу для прозрачного доступа ко всем шардам
-- Через эту таблицу мы будем работать с данными
CREATE TABLE user_scores ON CLUSTER c2sh2rep
AS user_scores_rep
ENGINE = Distributed(c2sh2rep, default, user_scores_rep, user_id);

-- ========================================
-- РАБОТА С ТЕСТОВЫМИ ДАННЫМИ
-- ========================================

-- Генерируем 10 000 000 тестовых записей
-- Данные автоматически распределятся по шардам
INSERT INTO user_scores
SELECT
    number % 10000000 + 1                                AS user_id,
    toFloat32(rand() % 50 + rand() % 50) / 10          AS avg_score,
    now() - (number * 86400 / 1000)                    AS created_at
FROM numbers(10000000);

-- Проверяем общее количество записей
SELECT count() AS total_records FROM user_scores;

-- Проверяем распределение по шардам
SELECT 
    shardNum() AS shard_id,
    count() AS rows_per_shard
FROM user_scores
GROUP BY shard_id
ORDER BY shard_id;

-- Количество строк и размер указанной таблицы по каждой реплике кластера
WITH
    'c2sh2rep'          AS cluster,  -- Имя кластера
    'default'           AS db,       -- Имя базы данных
    'user_scores_rep'   AS tbl       -- Имя таблицы
SELECT
  p.host,
  any(r.replica_name)                      AS replica_name,  -- Имя реплики из system.replicas
  sum(p.rows)                               AS total_rows,    -- Строки во всех активных партах
  formatReadableSize(sum(p.bytes_on_disk))  AS size           -- Размер в читаемом формате
FROM
(
  -- Информация о партах таблицы на каждой ноде
  SELECT hostName() AS host, rows, bytes_on_disk
  FROM clusterAllReplicas(cluster, 'system', 'parts')
  WHERE database = db
    AND table = tbl
    AND active
) AS p
ANY LEFT JOIN
(
  -- Имена реплик на каждой ноде
  SELECT hostName() AS host, replica_name
  FROM clusterAllReplicas(cluster, 'system', 'replicas')
  WHERE database = db
    AND table = tbl
) AS r USING host
GROUP BY p.host
ORDER BY p.host;

-- ========================================
-- МОНИТОРИНГ РЕПЛИКАЦИИ
-- ========================================

-- Состояние репликационных очередей
WITH
  'c2sh2rep' AS cluster,
  'default'  AS db
SELECT
  hostName() AS host,
  database,
  table,
  replica_name,
  total_replicas,
  active_replicas,
  is_leader,
  is_readonly
FROM clusterAllReplicas(cluster, 'system', 'replicas')
WHERE database = db
ORDER BY host, table;

-- Очередь репликации (показывает задачи на выполнение)
WITH
  'c2sh2rep' AS cluster,
  'default'  AS db
SELECT
  hostName() AS host,      -- какая нода
  database,
  table,
  replica_name,
  position,
  type,
  create_time,
  required_quorum,
  source_replica
FROM clusterAllReplicas(cluster, 'system', 'replication_queue')
WHERE database = db
ORDER BY create_time DESC
LIMIT 10;

-- Лог репликации (история выполненных операций)
WITH
  'c2sh2rep'        AS cluster,
  'default'         AS db,
  'user_scores_rep' AS tbl
SELECT
  hostName() AS host,      -- какая нода
  event_time,
  event_type,              -- NewPart / MergeParts / DownloadPart и т.д.
  part_name                -- имя парты (универсальное поле)
FROM clusterAllReplicas(cluster, 'system', 'part_log')
WHERE database = db
  AND table = tbl
  AND event_type IN ('NewPart','MergeParts','DownloadPart')
ORDER BY event_time DESC
LIMIT 30;

-- ========================================
-- АНАЛИТИЧЕСКИЕ ЗАПРОСЫ
-- ========================================

-- Простая агрегация по всем данным
SELECT 
    count() AS total_users,
    round(avg(avg_score), 2) AS average_score,
    min(avg_score) AS min_score,
    max(avg_score) AS max_score
FROM user_scores;

-- Распределение пользователей по диапазонам очков
SELECT 
    CASE 
        WHEN avg_score < 1.0 THEN '0.0 - 1.0'
        WHEN avg_score < 2.0 THEN '1.0 - 2.0'
        WHEN avg_score < 3.0 THEN '2.0 - 3.0'
        WHEN avg_score < 4.0 THEN '3.0 - 4.0'
        ELSE '4.0+'
    END AS score_range,
    count() AS users_count,
    round(count() * 100.0 / (SELECT count() FROM user_scores), 2) AS percentage
FROM user_scores
GROUP BY score_range
ORDER BY score_range;

-- Топ-10 пользователей по очкам
SELECT 
    user_id,
    avg_score,
    created_at
FROM user_scores 
ORDER BY avg_score DESC 
LIMIT 10;

-- ========================================
-- ОЧИСТКА (раскомментировать при необходимости)
-- ========================================

-- Удаление тестовых таблиц
-- DROP TABLE IF EXISTS user_scores ON CLUSTER c2sh2rep NO DELAY;
-- DROP TABLE IF EXISTS user_scores_rep ON CLUSTER c2sh2rep NO DELAY;
