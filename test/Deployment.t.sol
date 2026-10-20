// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// @dev Models the launch factory without environment values, secrets, network access or broadcasts.
contract DeploymentFactory {
    function deploy(bytes32 salt) external returns (NightshiftVault) {
        return new NightshiftVault{salt: salt}();
    }
}

contract DeploymentTest is Test {
    function test_factoryDeploymentEmptyChainFixedOwnerAndPredictableAddress() public {
        DeploymentFactory factory = new DeploymentFactory();
        bytes32 salt = keccak256("deployment rehearsal");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), salt, keccak256(type(NightshiftVault).creationCode)
                        )
                    )
                )
            )
        );
        NightshiftVault vault = factory.deploy(salt);
        assertEq(address(vault), predicted);
        assertEq(vault.owner(), 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5);
        assertTrue(vault.owner() != address(factory));
        assertTrue(vault.owner() != address(this));
        assertEq(address(vault).balance, 0);
        assertLe(type(NightshiftVault).creationCode.length, 49_152);
        _checkRuntime(address(vault).code);
        DepositForwarder forwarder = new DepositForwarder(address(vault), keccak256("account"));
        _checkRuntime(address(forwarder).code);
    }

    function test_forwarderCreate2PredictionIncludesVaultAccountAndCreationCode() public {
        NightshiftVault vault = new NightshiftVault();
        bytes32 id = keccak256("counterfactual");
        bytes32 initHash =
            keccak256(abi.encodePacked(type(DepositForwarder).creationCode, abi.encode(address(vault), id)));
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(vault), id, initHash)))));
        assertEq(vault.depositAddress(id), expected);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
