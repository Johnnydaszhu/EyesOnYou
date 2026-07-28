# Open-source proxy references

Projects reviewed for per-app direct / proxy routing on macOS:

| Project | License / status | Useful reference | Decision |
|---|---|---|---|
| [ProxyBridge](https://github.com/InterceptSuite/ProxyBridge) | MIT, active | `NETransparentProxyProvider`, bundle-ID rules, TCP and UDP proxying | Best reference for the future all-protocol system-extension path |
| [rama](https://github.com/plabayo/rama) | MIT or Apache-2.0, active | Modern system-extension packaging and lifecycle examples | Use lifecycle patterns only; EyesOnYou does not adopt its TLS interception examples |
| [SimpleTunnel](https://github.com/networkextension/SimpleTunnel) | Apple sample, inactive | Historical Network Extension structure | Reference only; APIs and project setup are dated |
| [NEKit](https://github.com/zhuhaow/NEKit) | BSD-3-Clause, archived | Historical proxy rule model | Do not build new work on an archived dependency |
| [Specht](https://github.com/zhuhaow/Specht) | GPL-3.0, archived | Older macOS rule UI | Do not import into this MIT repository |

The current host-app enforcement path covers HTTP and HTTPS traffic that follows the
macOS system proxy. A future transparent Network Extension is still required for raw
TCP, UDP, QUIC, and apps that ignore the system proxy. Until that path is complete,
unsupported forced-proxy traffic must fail rather than silently escape direct.
