// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {Script} from "../lib/forge-std/src/Script.sol";
import {console} from "../lib/forge-std/src/console.sol";
import {ERC20Mock} from "../lib/openzeppelin-contracts//contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

contract HelperConfig is Script {
    struct NetWorkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    NetWorkConfig public activeNetWorkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;

    uint256 public DEFAULT_ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetWorkConfig = _getSepoliaConfig();
        } else {
            activeNetWorkConfig = _getOrCreateAnvilConfig();
        }
    }

    function _getSepoliaConfig() internal view returns (NetWorkConfig memory sepoliaNetworkConfig) {
        sepoliaNetworkConfig = NetWorkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    //部署两个DataFeed 合约 和两个token
    function _getOrCreateAnvilConfig() internal returns (NetWorkConfig memory anvilNetworkConfig) {
        if (activeNetWorkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetWorkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            ETH_USD_PRICE
        );
        ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", msg.sender, 1000e8);

        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            BTC_USD_PRICE
        );
        ERC20Mock wbtcMock = new ERC20Mock("WBTC", "WBTC", msg.sender, 1000e8);
        vm.stopBroadcast();
        anvilNetworkConfig = NetWorkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            deployerKey: vm.envUint("LOCAL_PRIVATE_KEY")
        });
    }

    function run() external {
        vm.startBroadcast();
        console.log("Hello, world!");
        vm.stopBroadcast();
    }
}
