# ADR-0003：SQLite WAL 与单写者

## 状态

接受。

## 决策

- `telemetry.sqlite`：system extension 唯一写者，App 只读；
- `rules.sqlite`：App 唯一写者，Provider 读取编译后的 snapshot；
- WAL + NORMAL synchronous；
- 内存聚合后批量 UPSERT；
- 不采用 Core Data/SwiftData 作为数据面存储。

## 原因

SQLite 可控、体积小、无额外运行时；单写者避免 extension 与 App 之间复杂锁竞争。Core Data/SwiftData 在多进程、热路径和可预测 migration 方面不带来足够收益。
