// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IClawPactReputationRegistry {
    function recordAttestation(
        address target,
        string calldata category,
        int256 score,
        string calldata dataURI
    ) external;
}
