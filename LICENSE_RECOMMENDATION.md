# 许可与开源来源建议

## 已选：MIT

本仓库采用 **[MIT License](./LICENSE)**，便于个人、公司与下游产品使用、修改和再分发（保留版权与许可声明即可）。

要求：

- 不复制 LuLu 等 GPL-3.0 实现代码；
- 可以阅读 Apple 文档、运行公开软件、研究通用架构思想；
- 对关键实现保留独立设计记录和测试；
- 第三方依赖建议建立 `THIRD_PARTY_NOTICES` 和许可证扫描。

## 历史备选（未采用）

- **Apache-2.0**：专利条款更明确，体积更大；项目已改为更简洁的 MIT。
- **GPL-3.0**：若直接在 GPL 代码上衍生更自然；与当前 MIT 目标不兼容。

## 建议依赖策略

核心路径尽量零第三方：

- Swift / Foundation / NetworkExtension / Network / Security；
- 系统 SQLite3；
- XCTest / Swift Testing；
- 协议解析自行实现小型有界状态机。

UI 辅助库可引入，但必须评估二进制体积、许可证、维护状态和 sandbox / system extension 兼容性。不要在 system extension 数据面引入大型通用网络框架，除非基准证明必要。
