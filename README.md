# CPAMM V4

A high‑performance, permissionless automated market maker that builds directly on Uniswap V4’s concentrated liquidity primitives. By allowing LPs to deploy liquidity in custom price ranges, it delivers dramatically improved capital efficiency and tighter spreads, enabling full‑range market making without any centralized control or permissions. With on‑chain governance, flexible hooks, and seamless periphery integration, CPAMM_V4 offers a battle‑tested, composable foundation for next‑generation DeFi protocols.


## ⚠️ **Disclaimer**: 
This project is in active development. Functionality, structure, and APIs may change frequently and without notice. Use at your own risk.


## 🗂 Project Layout
```
CPAMM_V4/
├── contracts/
│ ├── src/
│ │ ├── core/
│ │ │ ├── CPAMM.sol
│ │ │ ├── UniswapV4Pair.sol
│ │ │ ├── ReserveTrackingHook.sol
│ │ │ └── CPAMMFactory.sol
│ │ ├── Interfaces/
│ │ │ ├── ICPAMMFactory.sol
│ │ │ ├── ICPAMMHook.sol
│ │ │ └── IPoolManager.sol
│ │ ├── lib/
│ │ │ ├── UniswapV4Utils.sol
│ │ │ └── CPAMMUtils.sol
│ │ └── periphery/
│ │ ├── Router.sol
│ │ ├── LiquidityProvider.sol
│ │ ├── Oracle.sol
│ │ └── Governance.sol
├── lib/ ← external dependencies (forge‐std, solmate, OZ, Uniswap v4, etc.)
├── scripts/
│ ├── deploy.s.sol ← deployment scripts
│ └── test.s.sol ← helper or integration tests
├── tests/ ← unit tests (Foundry)
│ ├── CPAMMTest.t.sol
│ ├── UniswapV4Pair.t.sol
│ └── …
├── foundry.toml ← Foundry config
└── LICENSE
```

## 🚀 Quickstart

1. **Install dependencies**  
   ```bash
   forge install```

2. **Compile**
```bash
forge build
```

3. **Run tests**
```bash
forge test --optimize
```

4. **Deploy**
Update scripts/deploy.s.sol with your desired RPC target & private key, then:
```bash
forge script scripts/deploy.s.sol --broadcast --rpc-url $RPC_URL
```

## 📖 Overview

   - CPAMM.sol:
    Core “Concentrated Permissionless AMM” logic for evenly distributed liquidity across the full tick range.

   - UniswapV4Pair.sol:
    ERC‑20 wrapper & per‑pool state management, hooking into the Uniswap V4 PoolManager.

   - ReserveTrackingHook.sol:
    Hook that records & exposes pool reserves to off‑chain systems and the periphery.

   - CPAMMFactory.sol:
    Deploys new pools, wires up hooks, and manages factory-level governance.

   - Periphery:

        Router.sol: single‑entry point for swaps & liquidity operations

        LiquidityProvider.sol: helper library for complex LP workflows

        Oracle.sol: on‑chain TWAP & snapshotting

        Governance.sol: permissioned voting & fee‑update proposals

   - lib/
    Shared utilities: tick/price math, pool‑key validation, liquidity math.


## 🔗 Useful Commands

  *  Forge

        forge fmt — format code

        forge clean — clear cache & artifacts

        forge test — run all tests

        forge coverage — measure test coverage


## 🤝 Contributing

  -  Fork the repo

  -  Create a feature branch

  -  Open a pull request

  -  Ensure all tests pass & code is formatted


## 📜 License

This project is licensed under the MIT License — see the LICENSE file for details.

