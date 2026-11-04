// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Arbitrum's ArbSys precompile (0x64), which Elysium (an Orbit chain) has and forge's and anvil's EVMs
/// don't. Kleos's hooks ask it whether their caller is an L1 alias, so fork tests and local script runs put this
/// stand-in there. Only ever etched into a local EVM; on chain the real precompile answers.
contract MockArbSys {
    function wasMyCallersAddressAliased() external pure returns (bool) {
        return false;
    }

    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function arbChainID() external view returns (uint256) {
        return block.chainid;
    }

    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 32)
        }
    }
}
