// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    TensegrityRelayOrderV1Hasher
} from "../src/TensegrityRelayOrderV1Hasher.sol";

contract TensegrityRelayOrderV1HasherHarness {
    function hashOrder(
        TensegrityRelayOrderV1Hasher.Order calldata order
    ) external pure returns (bytes32) {
        return TensegrityRelayOrderV1Hasher.hash(order);
    }
}

contract TensegrityRelayOrderV1HasherTest {
    bytes32 internal constant RELAY_UPSTREAM_EXPECTED =
        0x67f44dc715059f196cd133e54e4bbe125773cb6d7053d24389fbda361f4c14d8;

    function _fixture()
        internal
        pure
        returns (TensegrityRelayOrderV1Hasher.Order memory order)
    {
        order.version = "v1";
        order.solverChainId = "base";
        order.solver =
            0xFD073A9ccB34F8a13c466Eb16DFf990D6178a5EF;
        order.salt =
            uint256(
                0x0ef19e8ac216cebd161d73425c0b1e1ae12f5a4d56fc54cddb4f9755c5e7b1b8
            );

        order.inputs =
            new TensegrityRelayOrderV1Hasher.Input[](1);

        order.inputs[0].payment =
            TensegrityRelayOrderV1Hasher.InputPayment({
                chainId: "base",
                currency: hex"0000000000000000000000000000000000000000",
                amount: 100000000000000,
                weight: 1
            });

        order.inputs[0].refunds =
            new TensegrityRelayOrderV1Hasher.InputRefund[](2);

        order.inputs[0].refunds[0] =
            TensegrityRelayOrderV1Hasher.InputRefund({
                chainId: "base",
                recipient: hex"8b5e4db198ffc7f69f8f11f6592f682717df1d92",
                currency: hex"0000000000000000000000000000000000000000",
                minimumAmount: 0,
                deadline: 1774878936,
                extraData: hex"000000000000000000000000b92fe925dc43a0ecde6c8b1a2709c170ec4fff4f"
            });

        order.inputs[0].refunds[1] =
            TensegrityRelayOrderV1Hasher.InputRefund({
                chainId: "solana",
                recipient: hex"5ca06a33d6036ec8bc1c7431dc53b8ebf26313227c7642fa4704c07d4567746c",
                currency: hex"c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61",
                minimumAmount: 0,
                deadline: 1774878936,
                extraData: hex""
            });

        order.output.chainId = "solana";

        order.output.payments =
            new TensegrityRelayOrderV1Hasher.OutputPayment[](1);

        order.output.payments[0] =
            TensegrityRelayOrderV1Hasher.OutputPayment({
                recipient: hex"5ca06a33d6036ec8bc1c7431dc53b8ebf26313227c7642fa4704c07d4567746c",
                currency: hex"c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61",
                minimumAmount: 187151,
                expectedAmount: 196567
            });

        order.output.calls = new bytes[](0);
        order.output.deadline = 1774878936;
        order.output.extraData = hex"";

        order.fees =
            new TensegrityRelayOrderV1Hasher.Fee[](0);
    }

    function _hash(
        TensegrityRelayOrderV1Hasher.Order memory order
    ) internal returns (bytes32) {
        TensegrityRelayOrderV1HasherHarness harness =
            new TensegrityRelayOrderV1HasherHarness();

        return harness.hashOrder(order);
    }

    function testRelayUpstreamSdkVector() public {
        TensegrityRelayOrderV1Hasher.Order memory order =
            _fixture();

        bytes32 actual =
            _hash(order);

        require(
            actual == RELAY_UPSTREAM_EXPECTED,
            "RELAY_UPSTREAM_VECTOR_MISMATCH"
        );
    }

    function testOutputMinimumMutationChangesHash() public {
        TensegrityRelayOrderV1Hasher.Order memory order =
            _fixture();

        bytes32 beforeHash =
            _hash(order);

        order.output.payments[0].minimumAmount =
            187152;

        bytes32 afterHash =
            _hash(order);

        require(
            beforeHash != afterHash,
            "OUTPUT_MINIMUM_NOT_BOUND"
        );
    }

    function testRefundRecipientMutationChangesHash() public {
        TensegrityRelayOrderV1Hasher.Order memory order =
            _fixture();

        bytes32 beforeHash =
            _hash(order);

        order.inputs[0].refunds[0].recipient =
            hex"8b5e4db198ffc7f69f8f11f6592f682717df1d93";

        bytes32 afterHash =
            _hash(order);

        require(
            beforeHash != afterHash,
            "REFUND_RECIPIENT_NOT_BOUND"
        );
    }

    function testDestinationCallMutationChangesHash() public {
        TensegrityRelayOrderV1Hasher.Order memory order =
            _fixture();

        bytes32 beforeHash =
            _hash(order);

        order.output.calls =
            new bytes[](1);

        order.output.calls[0] =
            hex"1234";

        bytes32 afterHash =
            _hash(order);

        require(
            beforeHash != afterHash,
            "DESTINATION_CALL_NOT_BOUND"
        );
    }
}
