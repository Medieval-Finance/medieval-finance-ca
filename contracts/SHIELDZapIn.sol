// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IRouterV2.sol";

contract SHIELDZapIn is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // IMMUTABLE VARIABLES
    address public immutable SHIELD_TOKEN;
    address public immutable SCUSD_TOKEN;
    address public immutable SWAP_ROUTER;
    
    // EVENTS
    event ZapIn(address indexed user, address tokenIn, uint amountIn);

    constructor(
        address _SHIELD_TOKEN,
        address _SCUSD_TOKEN,
        address _SWAP_ROUTER
    ) Ownable(msg.sender) {
        SHIELD_TOKEN = _SHIELD_TOKEN;
        SCUSD_TOKEN = _SCUSD_TOKEN;
        SWAP_ROUTER = _SWAP_ROUTER;
    }

    // EXTERNAL FUNCTIONS
    function zapInToken(address _tokenIn, uint _tokenAmount) external nonReentrant {
        require(_tokenIn == SHIELD_TOKEN || _tokenIn == SCUSD_TOKEN, "Only SHIELD or SCUSD tokens accepted");

        // Transfer tokens from user
        IERC20(_tokenIn).transferFrom(msg.sender, address(this), _tokenAmount);
        
        // Get the optimal amounts for adding liquidity
        (uint amount0, uint swapAmount) = _getOptimalAmounts(_tokenIn, _tokenAmount);
        
        // Perform the swap if needed
        if (swapAmount > 0) {
            address _tokenOut = _tokenIn == SHIELD_TOKEN ? SCUSD_TOKEN : SHIELD_TOKEN;
            _swapExactTokensForTokens(swapAmount, _tokenIn, _tokenOut, address(this));
        }

        _addLiquidity();

        // Return any remaining tokens to user
        uint remainingSHIELDBalance = IERC20(SHIELD_TOKEN).balanceOf(address(this));
        if (remainingSHIELDBalance > 0) {
            if (_tokenIn == SCUSD_TOKEN) { // Convert SHIELD to SCUSD if sender sent SCUSD
                _swapExactTokensForTokens(remainingSHIELDBalance, SHIELD_TOKEN, SCUSD_TOKEN, msg.sender);
            }
            else { // Return any remaining tokens to user
                IERC20(SHIELD_TOKEN).safeTransfer(msg.sender, remainingSHIELDBalance);
            }
        }

        uint remainingSCUSDBalance = IERC20(SCUSD_TOKEN).balanceOf(address(this));
        if (remainingSCUSDBalance > 0) {
            if (_tokenIn == SHIELD_TOKEN) { // Convert SCUSD to SHIELD if sender sent SHIELD
                _swapExactTokensForTokens(remainingSCUSDBalance, SCUSD_TOKEN, SHIELD_TOKEN, msg.sender);
            }
            else { // Return any remaining tokens to user
                IERC20(SCUSD_TOKEN).safeTransfer(msg.sender, remainingSCUSDBalance);
            }
        }

        emit ZapIn(msg.sender, _tokenIn, _tokenAmount);
    }

    // INTERNAL FUNCTIONS
    function _addLiquidity() internal {
        // Add liquidity
        uint balance0 = IERC20(SHIELD_TOKEN).balanceOf(address(this));
        uint balance1 = IERC20(SCUSD_TOKEN).balanceOf(address(this));
        
        IERC20(SHIELD_TOKEN).approve(SWAP_ROUTER, balance0);
        IERC20(SCUSD_TOKEN).approve(SWAP_ROUTER, balance1);
        
        ( , , uint liquidity) = IRouterV2(SWAP_ROUTER).addLiquidity(
            SHIELD_TOKEN,
            SCUSD_TOKEN,
            true,
            balance0,
            balance1,
            0,
            0,
            msg.sender,
            block.timestamp
        );
    }

    function _getOptimalAmounts(address _tokenIn, uint _tokenAmount) internal view returns (uint amount0, uint swapAmount) {
        // Get token order from pair
        address token0 = SHIELD_TOKEN;
        address token1 = SCUSD_TOKEN;
        
        // For stable pools, calculate the optimal ratio
        uint out0 = _tokenIn == token0 ? _tokenAmount / 2 : 0;
        uint out1 = _tokenIn == token1 ? _tokenAmount / 2 : 0;
        
        // Get expected output for the swap
        if (_tokenIn == token0) {
            uint[] memory amounts = IRouterV2(SWAP_ROUTER).getAmountsOut(_tokenAmount / 2, _getRoutes(token0, token1));
            out1 = amounts[amounts.length - 1];
        } else {
            uint[] memory amounts = IRouterV2(SWAP_ROUTER).getAmountsOut(_tokenAmount / 2, _getRoutes(token1, token0));
            out0 = amounts[amounts.length - 1];
        }

        // Quote optimal amounts
        (uint amountA, uint amountB,) = IRouterV2(SWAP_ROUTER).quoteAddLiquidity(
            token0,
            token1,
            true,
            out0,
            out1
        );

        // Calculate optimal ratio with decimal adjustment
        // SHIELD is 1e18, SCUSD is 1e6
        if (_tokenIn == token0) {
            // If input is SHIELD
            uint ratio = (out0 * 1e18 / out1) * amountB / amountA;
            amount0 = _tokenAmount * 1e18 / (ratio + 1e18);
            swapAmount = _tokenAmount - amount0;
        } else {
            // If input is SCUSD
            uint ratio = (out0 * 1e6 / out1) * amountB / amountA;
            swapAmount = _tokenAmount * 1e6 / (ratio + 1e6);
            amount0 = _tokenAmount - swapAmount;
        }
    }

    function _getRoutes(address _tokenIn, address _tokenOut) internal pure returns (IRouterV2.Routes[] memory) {
        IRouterV2.Routes[] memory routes = new IRouterV2.Routes[](1);
        routes[0] = IRouterV2.Routes({
            from: _tokenIn,
            to: _tokenOut,
            stable: true
        });
        return routes;
    }

    function _swapExactTokensForTokens(uint _amountIn, address _tokenIn, address _tokenOut, address _to) internal {
        IERC20 tokenIn = IERC20(_tokenIn);
        tokenIn.approve(address(SWAP_ROUTER), _amountIn);

        IRouterV2.Routes[] memory routes = _getRoutes(_tokenIn, _tokenOut);

        IRouterV2(SWAP_ROUTER).swapExactTokensForTokens(
            _amountIn,
            0,
            routes,
            _to,
            block.timestamp
        );
    }

    // EMERGENCY FUNCTIONS
    function withdraw(address _token) external onlyOwner {
        if (_token == address(0)) {
            (bool success, ) = address(owner()).call{ value: address(this).balance }("");
        }
        IERC20 token = IERC20(_token);
        token.transfer(owner(), token.balanceOf(address(this)));
    }
}