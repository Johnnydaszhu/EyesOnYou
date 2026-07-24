# SQLite 查询与降采样示例

以下 SQL 只是查询骨架。时间参数使用 UTC Unix milliseconds；应用层必须绑定参数，禁止拼接用户输入。

## 最近 60 秒 Top App

```sql
SELECT a.display_name, a.signing_id,
       SUM(b.bytes_down) AS down_bytes,
       SUM(b.bytes_up) AS up_bytes
FROM traffic_buckets b
JOIN apps a ON a.app_id = b.app_id
WHERE b.granularity_sec = 1
  AND b.bucket_start_ms >= :now_ms - 60000
GROUP BY b.app_id
ORDER BY down_bytes + up_bytes DESC
LIMIT 20;
```

## 指定 App 过去 24 小时曲线

```sql
SELECT bucket_start_ms,
       SUM(bytes_down) AS down_bytes,
       SUM(bytes_up) AS up_bytes
FROM traffic_buckets
WHERE app_id = :app_id
  AND granularity_sec = 60
  AND bucket_start_ms >= :now_ms - 86400000
GROUP BY bucket_start_ms
ORDER BY bucket_start_ms;
```

## 阻断最多的 App

```sql
SELECT a.display_name, a.signing_id, SUM(b.flows_blocked) AS blocked
FROM traffic_buckets b
JOIN apps a ON a.app_id = b.app_id
WHERE b.bucket_start_ms BETWEEN :from_ms AND :to_ms
GROUP BY b.app_id
HAVING blocked > 0
ORDER BY blocked DESC
LIMIT 50;
```

## 直连/代理分布

```sql
SELECT route_kind,
       SUM(bytes_down + bytes_up) AS bytes_total,
       SUM(flows_opened) AS flows
FROM traffic_buckets
WHERE bucket_start_ms BETWEEN :from_ms AND :to_ms
GROUP BY route_kind
ORDER BY bytes_total DESC;
```

## 1 秒桶降采样到 1 分钟

在单 transaction 中执行，并确保目标分钟完整结束：

```sql
INSERT INTO traffic_buckets (
    granularity_sec, bucket_start_ms, app_id, destination_id,
    transport, route_kind, verdict, bytes_up, bytes_down,
    flows_opened, flows_closed, flows_blocked, active_peak
)
SELECT 60,
       (bucket_start_ms / 60000) * 60000,
       app_id, destination_id, transport, route_kind, verdict,
       SUM(bytes_up), SUM(bytes_down), SUM(flows_opened),
       SUM(flows_closed), SUM(flows_blocked), MAX(active_peak)
FROM traffic_buckets
WHERE granularity_sec = 1
  AND bucket_start_ms >= :minute_start_ms
  AND bucket_start_ms < :minute_start_ms + 60000
GROUP BY app_id, destination_id, transport, route_kind, verdict
ON CONFLICT DO UPDATE SET
    bytes_up = excluded.bytes_up,
    bytes_down = excluded.bytes_down,
    flows_opened = excluded.flows_opened,
    flows_closed = excluded.flows_closed,
    flows_blocked = excluded.flows_blocked,
    active_peak = excluded.active_peak;
```

成功后再删除对应 1 秒桶。崩溃恢复时重复执行应保持幂等；因此这里覆盖目标聚合值，而不是再加一次。

## 查询计划要求

发布前对常用查询执行 `EXPLAIN QUERY PLAN`。任何时间范围页面都必须命中 `granularity_sec + bucket_start_ms` 或 `app_id + granularity_sec + bucket_start_ms` 索引；历史页禁止一次加载全部 raw flow。
