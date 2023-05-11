// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {IUniswapV2Pair} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import {UniswapV2Library} from './UniswapV2Library.sol';
import {RouterImmutables} from '../../../base/RouterImmutables.sol';
import {Payments} from '../../Payments.sol';
import {Permit2Payments} from '../../Permit2Payments.sol';
import {Constants} from '../../../libraries/Constants.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';

/// @title Router for Uniswap v2 Trades
abstract contract V2SwapRouter is RouterImmutables, Permit2Payments {
    error V2TooLittleReceived();
    error V2TooMuchRequested();
    error V2InvalidPath();

struct SwapData {
    address token0;
    uint256 finalPairIndex;
    uint256 penultimatePairIndex;
    address input;
    address output;
    uint256 reserve0;
    uint256 reserve1;
    uint256 reserveInput;
    uint256 reserveOutput;
    uint256 amountInput;
    uint256 amountOutput;
    uint256 amount0Out;
    uint256 amount1Out;
    address nextPair;
}

function _v2Swap(address[] calldata path, address recipient, address pair) private {
    unchecked {
        if (path.length < 2) revert V2InvalidPath();

        SwapData memory swapData;
        (swapData.token0,) = UniswapV2Library.sortTokens(path[0], path[1]);
        swapData.finalPairIndex = path.length - 1;
        swapData.penultimatePairIndex = swapData.finalPairIndex - 1;

        for (uint256 i; i < swapData.finalPairIndex; i++) {
            (swapData.input, swapData.output) = (path[i], path[i + 1]);
            (swapData.reserve0, swapData.reserve1,) = IUniswapV2Pair(pair).getReserves();
            (swapData.reserveInput, swapData.reserveOutput) = swapData.input == swapData.token0 ? 
                (swapData.reserve0, swapData.reserve1) : (swapData.reserve1, swapData.reserve0);
            swapData.amountInput = ERC20(swapData.input).balanceOf(pair) - swapData.reserveInput;
            swapData.amountOutput = UniswapV2Library.getAmountOut(
                swapData.amountInput, 
                swapData.reserveInput, 
                swapData.reserveOutput
            );
            (swapData.amount0Out, swapData.amount1Out) = swapData.input == swapData.token0 ? 
                (uint256(0), swapData.amountOutput) : (swapData.amountOutput, uint256(0));
            (swapData.nextPair, swapData.token0) = i < swapData.penultimatePairIndex ?
                UniswapV2Library.pairAndToken0For(
                    UNISWAP_V2_FACTORY, 
                    UNISWAP_V2_PAIR_INIT_CODE_HASH, 
                    swapData.output, 
                    path[i + 2]
                )
                : (recipient, address(0));
            IUniswapV2Pair(pair).swap(swapData.amount0Out, swapData.amount1Out, swapData.nextPair, new bytes(0));
            pair = swapData.nextPair;
        }
    }
}


    /// @notice Performs a Uniswap v2 exact input swap
    /// @param recipient The recipient of the output tokens
    /// @param amountIn The amount of input tokens for the trade
    /// @param amountOutMinimum The minimum desired amount of output tokens
    /// @param path The path of the trade as an array of token addresses
    /// @param payer The address that will be paying the input
    function v2SwapExactInput(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address[] calldata path,
        address payer
    ) internal {
        address firstPair =
            UniswapV2Library.pairFor(UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, path[0], path[1]);
        if (
            amountIn != Constants.ALREADY_PAID // amountIn of 0 to signal that the pair already has the tokens
        ) {
            payOrPermit2Transfer(path[0], payer, firstPair, amountIn);
        }

        ERC20 tokenOut = ERC20(path[path.length - 1]);
        uint256 balanceBefore = tokenOut.balanceOf(recipient);

        _v2Swap(path, recipient, firstPair);

        uint256 amountOut = tokenOut.balanceOf(recipient) - balanceBefore;
        if (amountOut < amountOutMinimum) revert V2TooLittleReceived();
    }

    /// @notice Performs a Uniswap v2 exact output swap
    /// @param recipient The recipient of the output tokens
    /// @param amountOut The amount of output tokens to receive for the trade
    /// @param amountInMaximum The maximum desired amount of input tokens
    /// @param path The path of the trade as an array of token addresses
    /// @param payer The address that will be paying the input
    function v2SwapExactOutput(
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        address[] calldata path,
        address payer
    ) internal {
        (uint256 amountIn, address firstPair) =
            UniswapV2Library.getAmountInMultihop(UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, amountOut, path);
        if (amountIn > amountInMaximum) revert V2TooMuchRequested();

        payOrPermit2Transfer(path[0], payer, firstPair, amountIn);
        _v2Swap(path, recipient, firstPair);
    }
}
