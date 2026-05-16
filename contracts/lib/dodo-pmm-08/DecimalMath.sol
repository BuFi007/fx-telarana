/*

    Copyright 2020 DODO ZOO.
    SPDX-License-Identifier: Apache-2.0

*/
pragma solidity >=0.8.0;

// Vendored verbatim from
//   https://github.com/Abracadabra-money/abracadabra-money-contracts
//   commit 46ad8622cfe620b85473b829ca39e2bfb53f858c
//   path:   src/mimswap/libraries/DecimalMath.sol
// Only deviation from upstream: import path adapted to local directory layout
// (Abracadabra's `/mimswap/libraries/...` remapping → relative path).

import {Math} from "./Math.sol";

/**
 * @title DecimalMath
 * @author DODO Breeder
 *
 * @notice Functions for fixed point number with 18 decimals
 */
library DecimalMath {
    using Math for uint256;

    uint256 internal constant ONE = 10 ** 18;
    uint256 internal constant ONE2 = 10 ** 36;

    function mulFloor(uint256 target, uint256 d) internal pure returns (uint256) {
        return (target * d) / ONE;
    }

    function mulCeil(uint256 target, uint256 d) internal pure returns (uint256) {
        return (target * d).divCeil(ONE);
    }

    function divFloor(uint256 target, uint256 d) internal pure returns (uint256) {
        return (target * ONE) / d;
    }

    function divCeil(uint256 target, uint256 d) internal pure returns (uint256) {
        return (target * ONE).divCeil(d);
    }

    function reciprocalFloor(uint256 target) internal pure returns (uint256) {
        return ONE2 / target;
    }

    function reciprocalCeil(uint256 target) internal pure returns (uint256) {
        return ONE2.divCeil(target);
    }

    function powFloor(uint256 target, uint256 e) internal pure returns (uint256) {
        if (e == 0) {
            return 10 ** 18;
        } else if (e == 1) {
            return target;
        } else {
            uint p = powFloor(target, e / 2);
            p = (p * p) / ONE;
            if (e % 2 == 1) {
                p = (p * target) / ONE;
            }
            return p;
        }
    }
}
