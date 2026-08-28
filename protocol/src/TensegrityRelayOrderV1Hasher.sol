// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TensegrityRelayOrderV1Hasher
/// @notice Faithful Solidity implementation of Relay Settlement SDK Order v1
///         EIP-712 hashStruct semantics.
/// @dev This computes the struct hash only. There is deliberately no EIP-712
///      domain separator because Relay's SDK getOrderId() uses hashStruct().
library TensegrityRelayOrderV1Hasher {
    struct InputPayment {
        string chainId;
        bytes currency;
        uint256 amount;
        uint256 weight;
    }

    struct InputRefund {
        string chainId;
        bytes recipient;
        bytes currency;
        uint256 minimumAmount;
        uint32 deadline;
        bytes extraData;
    }

    struct Input {
        InputPayment payment;
        InputRefund[] refunds;
    }

    struct OutputPayment {
        bytes recipient;
        bytes currency;
        uint256 minimumAmount;
        uint256 expectedAmount;
    }

    struct Output {
        string chainId;
        OutputPayment[] payments;
        uint32 deadline;
        bytes[] calls;
        bytes extraData;
    }

    struct Fee {
        string recipientChainId;
        bytes recipient;
        string currencyChainId;
        bytes currency;
        uint256 amount;
    }

    struct Order {
        string version;
        string solverChainId;
        address solver;
        uint256 salt;
        Input[] inputs;
        Output output;
        Fee[] fees;
    }

    bytes32 internal constant INPUT_PAYMENT_TYPEHASH =
        keccak256(
            "InputPayment(string chainId,bytes currency,uint256 amount,uint256 weight)"
        );

    bytes32 internal constant INPUT_REFUND_TYPEHASH =
        keccak256(
            "InputRefund(string chainId,bytes recipient,bytes currency,uint256 minimumAmount,uint32 deadline,bytes extraData)"
        );

    bytes32 internal constant INPUT_TYPEHASH =
        keccak256(
            "Input(InputPayment payment,InputRefund[] refunds)InputPayment(string chainId,bytes currency,uint256 amount,uint256 weight)InputRefund(string chainId,bytes recipient,bytes currency,uint256 minimumAmount,uint32 deadline,bytes extraData)"
        );

    bytes32 internal constant OUTPUT_PAYMENT_TYPEHASH =
        keccak256(
            "OutputPayment(bytes recipient,bytes currency,uint256 minimumAmount,uint256 expectedAmount)"
        );

    bytes32 internal constant OUTPUT_TYPEHASH =
        keccak256(
            "Output(string chainId,OutputPayment[] payments,uint32 deadline,bytes[] calls,bytes extraData)OutputPayment(bytes recipient,bytes currency,uint256 minimumAmount,uint256 expectedAmount)"
        );

    bytes32 internal constant FEE_TYPEHASH =
        keccak256(
            "Fee(string recipientChainId,bytes recipient,string currencyChainId,bytes currency,uint256 amount)"
        );

    bytes32 internal constant ORDER_TYPEHASH =
        keccak256(
            "Order(string version,string solverChainId,address solver,uint256 salt,Input[] inputs,Output output,Fee[] fees)Fee(string recipientChainId,bytes recipient,string currencyChainId,bytes currency,uint256 amount)Input(InputPayment payment,InputRefund[] refunds)InputPayment(string chainId,bytes currency,uint256 amount,uint256 weight)InputRefund(string chainId,bytes recipient,bytes currency,uint256 minimumAmount,uint32 deadline,bytes extraData)Output(string chainId,OutputPayment[] payments,uint32 deadline,bytes[] calls,bytes extraData)OutputPayment(bytes recipient,bytes currency,uint256 minimumAmount,uint256 expectedAmount)"
        );

    function hash(Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                keccak256(bytes(order.version)),
                keccak256(bytes(order.solverChainId)),
                order.solver,
                order.salt,
                _hashInputs(order.inputs),
                _hashOutput(order.output),
                _hashFees(order.fees)
            )
        );
    }

    function _hashInputPayment(
        InputPayment calldata payment
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INPUT_PAYMENT_TYPEHASH,
                keccak256(bytes(payment.chainId)),
                keccak256(payment.currency),
                payment.amount,
                payment.weight
            )
        );
    }

    function _hashInputRefund(
        InputRefund calldata refund
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INPUT_REFUND_TYPEHASH,
                keccak256(bytes(refund.chainId)),
                keccak256(refund.recipient),
                keccak256(refund.currency),
                refund.minimumAmount,
                refund.deadline,
                keccak256(refund.extraData)
            )
        );
    }

    function _hashInput(
        Input calldata input
    ) private pure returns (bytes32) {
        bytes32[] memory refundHashes =
            new bytes32[](input.refunds.length);

        for (uint256 i; i < input.refunds.length; ++i) {
            refundHashes[i] =
                _hashInputRefund(input.refunds[i]);
        }

        return keccak256(
            abi.encode(
                INPUT_TYPEHASH,
                _hashInputPayment(input.payment),
                keccak256(abi.encodePacked(refundHashes))
            )
        );
    }

    function _hashInputs(
        Input[] calldata inputs
    ) private pure returns (bytes32) {
        bytes32[] memory hashes =
            new bytes32[](inputs.length);

        for (uint256 i; i < inputs.length; ++i) {
            hashes[i] =
                _hashInput(inputs[i]);
        }

        return keccak256(
            abi.encodePacked(hashes)
        );
    }

    function _hashOutputPayment(
        OutputPayment calldata payment
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                OUTPUT_PAYMENT_TYPEHASH,
                keccak256(payment.recipient),
                keccak256(payment.currency),
                payment.minimumAmount,
                payment.expectedAmount
            )
        );
    }

    function _hashBytesArray(
        bytes[] calldata values
    ) private pure returns (bytes32) {
        bytes32[] memory hashes =
            new bytes32[](values.length);

        for (uint256 i; i < values.length; ++i) {
            hashes[i] =
                keccak256(values[i]);
        }

        return keccak256(
            abi.encodePacked(hashes)
        );
    }

    function _hashOutput(
        Output calldata output
    ) private pure returns (bytes32) {
        bytes32[] memory paymentHashes =
            new bytes32[](output.payments.length);

        for (uint256 i; i < output.payments.length; ++i) {
            paymentHashes[i] =
                _hashOutputPayment(output.payments[i]);
        }

        return keccak256(
            abi.encode(
                OUTPUT_TYPEHASH,
                keccak256(bytes(output.chainId)),
                keccak256(abi.encodePacked(paymentHashes)),
                output.deadline,
                _hashBytesArray(output.calls),
                keccak256(output.extraData)
            )
        );
    }

    function _hashFee(
        Fee calldata fee
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FEE_TYPEHASH,
                keccak256(bytes(fee.recipientChainId)),
                keccak256(fee.recipient),
                keccak256(bytes(fee.currencyChainId)),
                keccak256(fee.currency),
                fee.amount
            )
        );
    }

    function _hashFees(
        Fee[] calldata fees
    ) private pure returns (bytes32) {
        bytes32[] memory hashes =
            new bytes32[](fees.length);

        for (uint256 i; i < fees.length; ++i) {
            hashes[i] =
                _hashFee(fees[i]);
        }

        return keccak256(
            abi.encodePacked(hashes)
        );
    }
}
