// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

// Compile-only shim so Foundry produces artifacts for vm.deployCode in
// AvalancheBasketSmokeTest without importing 0.8.19 sources into 0.8.26 tests.
import {Morpho} from "morpho-blue/Morpho.sol";
import {IrmMock} from "morpho-blue/mocks/IrmMock.sol";

contract MorphoArtifacts {
    Morpho internal morpho;
    IrmMock internal irm;
}
