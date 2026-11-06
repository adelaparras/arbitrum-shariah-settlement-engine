# AAOIFI Shariah-Compliant Settlement Engine Specification

## Supported Financial Primitives
- **Murabaha (Cost-Plus Sale)**: Deferred payment contract with explicit cost disclosure and zero Riba (interest).
- **Musharakah (Partnership)**: Equity sharing contract with dynamic profit-and-loss ratio allocation.
- **Takaful (Mutual Guarantee)**: Co-operative liquidity pool for supply chain risk mitigation.

## L2 Arbitrum Gas Optimization
- Packed `uint128` state variables.
- Assembly-optimized custom errors replacing string revert messages.
