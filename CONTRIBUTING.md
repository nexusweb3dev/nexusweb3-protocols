# Contributing to NexusWeb3

Thank you for your interest in contributing to NexusWeb3! This document provides guidelines for contributing to the complete AI agent economy infrastructure on Base.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Contributing Workflow](#contributing-workflow)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Security Considerations](#security-considerations)
- [Areas for Contribution](#areas-for-contribution)
- [Protocol Categories](#protocol-categories)
- [Questions?](#questions)

## Code of Conduct

This project is MIT-0 licensed (public domain). We expect all contributors to:

- Be respectful and constructive in all interactions
- Prioritize security when handling code that manages real funds
- Follow responsible disclosure for any vulnerabilities discovered
- Help build infrastructure that empowers AI agents as economic actors

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (latest version)
- [Git](https://git-scm.com/downloads)
- Node.js (for integration tests)
- Access to Base mainnet RPC (for deployment verification)

### Repository Structure

```
nexusweb3-protocols/
├── src/           # 30+ protocol contracts (Solidity)
├── test/          # Comprehensive test suite (Foundry)
├── script/        # Deployment and utility scripts
├── deployments/   # Deployment records and addresses
├── integrations/  # Third-party integrations
└── reviews/       # Security audit reports
```

## Development Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/nexusweb3dev/nexusweb3-protocols.git
   cd nexusweb3-protocols
   ```

2. **Install dependencies:**
   ```bash
   forge install
   ```

3. **Set up environment:**
   ```bash
   cp .env.example .env
   # Edit .env with your RPC endpoints and private keys
   ```

4. **Run tests to verify setup:**
   ```bash
   forge test
   ```

## Contributing Workflow

1. **Fork and branch:**
   ```bash
   git checkout -b feature/your-feature-name
   # or
   git checkout -b fix/issue-description
   ```

2. **Make your changes:**
   - Write clear, documented code
   - Follow the coding standards below
   - Add tests for new functionality

3. **Test thoroughly:**
   ```bash
   # Run all tests
   forge test

   # Run with gas reporting
   forge test --gas-report

   # Run specific test file
   forge test --match-path test/AgentVault.t.sol
   ```

4. **Format your code:**
   ```bash
   forge fmt
   ```

5. **Commit with clear messages:**
   ```bash
   git commit -m "feat: add AgentVault withdrawal limits
   
   - Implements daily withdrawal caps per agent
   - Adds emergency pause functionality
   - Includes comprehensive test coverage"
   ```

6. **Push and create PR:**
   ```bash
   git push origin feature/your-feature-name
   ```

## Coding Standards

### Solidity

- **Version:** Use Solidity `^0.8.24` (as specified in `foundry.toml`)
- **Style:** Follow the [Foundry formatter configuration](foundry.toml)
- **Line length:** Maximum 120 characters
- **Comments:** Use NatSpec format for all public/external functions

```solidity
/// @notice Deposits funds into the agent's vault
/// @param amount The amount to deposit in wei
/// @return success Whether the deposit succeeded
/// @dev Emits a Deposit event on success
function deposit(uint256 amount) external returns (bool success) {
    // Implementation
}
```

### Naming Conventions

- Contracts: `PascalCase` (e.g., `AgentVault`, `AgentRegistry`)
- Functions: `camelCase` (e.g., `deposit`, `withdraw`)
- Constants: `UPPER_SNAKE_CASE` (e.g., `MAX_DEPOSIT`)
- Events: `PascalCase` with past tense (e.g., `DepositMade`, `AgentRegistered`)
- Errors: `PascalCase` with descriptive names (e.g., `InsufficientBalance`, `UnauthorizedOperator`)

### Code Organization

Order of elements in contracts:
1. Type declarations (enums, structs)
2. State variables
3. Events
4. Errors
5. Modifiers
6. Constructor
7. External functions
8. Public functions
9. Internal functions
10. Private functions

## Testing Requirements

All contributions must include comprehensive tests:

### Test Coverage

- **Minimum 90% line coverage** for new contracts
- **All public/external functions** must have tests
- **Edge cases** must be covered (zero values, max values, reverts)
- **Fuzz tests** where applicable (see `foundry.toml` config)

### Test Structure

```solidity
contract AgentVaultTest is Test {
    AgentVault vault;
    address agent;
    address operator;

    function setUp() public {
        // Deploy contracts and set up state
    }

    function test_Deposit() public {
        // Test normal operation
    }

    function test_Deposit_RevertWhen_ZeroAmount() public {
        // Test edge case / revert
    }

    function testFuzz_Deposit(uint256 amount) public {
        // Fuzz test with random inputs
    }
}
```

### Running Tests

```bash
# All tests
forge test

# With verbosity
forge test -vv

# With gas report
forge test --gas-report

# Specific test
forge test --match-test test_Deposit

# Fuzz tests only
forge test --match-contract Fuzz
```

## Security Considerations

This project handles real funds on Base mainnet. Security is paramount:

### Before Submitting

- [ ] Reentrancy protection checked (use `nonReentrant` where needed)
- [ ] Integer overflow/underflow handled (Solidity 0.8+ helps)
- [ ] Access controls implemented (owner, roles, or custom)
- [ ] Emergency pause functionality considered
- [ ] Events emitted for state changes
- [ ] No hardcoded secrets or private keys

### Security Review Process

1. All PRs undergo automated testing
2. New contracts require security review
3. Changes to financial logic require additional scrutiny
4. Consider requesting audit for significant changes

### Vulnerability Disclosure

If you discover a security vulnerability:

1. **DO NOT** open a public issue
2. Email security@nexusweb3.dev with details
3. Allow reasonable time for response before disclosure
4. Follow responsible disclosure practices

## Areas for Contribution

### High Priority

- **New protocol implementations** (see roadmap for planned protocols 31-40)
- **Integration adapters** for DeFi protocols (Aave, Compound, Uniswap, etc.)
- **Gas optimization** for high-frequency operations
- **Cross-chain bridges** to other L2s

### Medium Priority

- **Documentation improvements** (tutorials, examples, diagrams)
- **Developer tooling** (SDKs, CLI tools, monitoring)
- **Test coverage** expansion for edge cases
- **Frontend examples** for protocol interactions

### Good First Issues

- Fix typos in documentation
- Add missing NatSpec comments
- Improve error messages for better UX
- Add integration tests for existing protocols
- Create example scripts for common operations

## Protocol Categories

Our 30 protocols are organized into three layers:

### Financial Layer (Protocols 1-10)
AgentVault, AgentRegistry, AgentEscrow, AgentYield, AgentInsurance, AgentTreasury, AgentPayment, AgentSwap, AgentLending, AgentStaking

### Operational Layer (Protocols 11-20)
AgentMarket, AgentBounty, AgentMilestone, AgentReferral, AgentCollective, AgentGovernance, AgentOracle, AgentMessaging, AgentLicense, AgentAuditLog

### Safety Layer (Protocols 21-30)
AgentKillSwitch, AgentKYA, AgentInsights, AgentBridge, AgentLaunchpad, AgentAuction, AgentInsolvency, AgentRecovery, AgentDispute, AgentReputation

When contributing, specify which protocol(s) your changes affect.

## Questions?

- **Technical questions:** Open a Discussion on GitHub
- **Integration help:** Check the `/integrations` directory for examples
- **Security concerns:** Email security@nexusweb3.dev
- **General chat:** Join our community (link in README)

---

Thank you for helping build the infrastructure for autonomous AI agents! 🚀

*Remember: Every line of code here could be executed by an AI agent managing real economic value. Code carefully.*
