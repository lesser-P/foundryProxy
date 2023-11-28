// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

/**
 * @title DSCEngine
 * @author ye
 *  该系统被设计得尽可能最小，并且让代币保持 1 代币 == 1 美元挂钩
 * The system is designed to be as minimal as possible,and have the tokens maintain a 1 token == $1 peg
 * It is simailar to DAI if DAI had no goernance ,no fee,and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized" At no point ,should the value of all collateral <= the $ backed value of all the DSC
 * 我们的 DSC 系统应该始终是“超抵押”的。在任何时候，所有抵押品的价值都不应该小于所有 DSC 的美元价值
 * @notice This contract is the core of the DSC System. It handle all the logic for mining and redemming DSC,as well as the depositing & widthdrawing of collateral
 * @notice 这个合约是 DSC 系统的核心。它处理所有的 DSC 挖矿和赎回逻辑，以及抵押品的存入和取出
 * @notice This contract is VERY loosely based on the MakerDAO DSS(DAI) system
 * @notice 这个合约是基于 MakerDAO DSS(DAI) 系统的
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "lib/forge-std/src/console.sol";

contract DSCEngine is ReentrancyGuard {
    error DSCEngine_NeedMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();
    error DSCEngine_MintFailed();

    // State Variables
    mapping(address token => address priceFeed) private s_priceFeed; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) //用户质押token数量
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100; //清算精度
    uint256 private constant LIQUIDATION_BONUS = 10; //this means a 10% bonus
    uint256 private constant Min_HEALTH_FACTOR = 2e18;
    //Event

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address token, uint256 indexed amount
    );

    DecentralizedStableCoin private i_dsc;

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine_NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        //USD iPrice Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        //For example ETH / USD , BTC / USD , MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddress[i];
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // 质押抵押品并铸造代币
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice followsCEI
     * @param tokenCollateralAddress The address of token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        payable
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralTokens.push(tokenCollateralAddress);
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
    {
        burnDsc(amountDscToBurn);
        redeemCollatoral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //赎回质押品
    function redeemCollatoral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        nonReentrant
        moreThanZero(amountCollateral)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // check if the collateral value>DSC
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_dsc.mint(msg.sender, amountDscToMint);
        if (!success) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    // If we do start nearing undercollateralization,we need some to liquidate positions

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        console.log("start", startingUserHealthFactor);
        // need to check health factor of the user
        if (startingUserHealthFactor >= Min_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover=$100
        // $100 DSC == ??? ETH
        // 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //And give them a 10% bouns
        //So we are giving the liquidator $110 of WETH for 100 DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        // 0.05 ETH * 0.1=0.005 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        console.log("end", endingUserHealthFactor);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 给定的美元金额购买的代币数量
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function _getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _healthFactor(address user) private view returns (uint256) {
        // total DXC minted
        //total collateral Value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // check health factor (do they have enough collateral ?)
        // revert if thry don't have enough collateral
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < Min_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor(userHealthFactor);
        }
    }

    function redeemCollateral(address tokenCollacteralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollacteralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[msg.sender] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(msg.sender);
    }

    function getAdditionalFeedPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeed[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getMinHealthFactor() public pure returns (uint256) {
        return Min_HEALTH_FACTOR;
    }
}
