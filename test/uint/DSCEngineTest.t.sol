// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {MockFailedTransfer} from "test/mocks/MockFailedTransfer.sol";
import {MockFailedMintDSC} from "test/mocks/MockFailedMintDSC.sol";
import {MockMoreDebtDSC} from "test/mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployDSC;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 amountToMint = 100 ether;

    uint256 public collateralToCover = 20 ether;
    address public liquiditor = makeAddr("liquiditor");

    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address token, uint256 indexed amount
    );

    function setUp() external {
        deployDSC = new DeployDSC();
        (dsc, dsce, helperConfig) = deployDSC.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetWorkConfig();

        if (block.chainid == 31337) {
            vm.deal(USER, STARTING_USER_BALANCE);
        }

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////
    //Price Test      //
    ////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 exceptedUsd = 30e21;
        uint256 actualUsd = dsce._getUsdValue(weth, ethAmount);
        assertEq(exceptedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() external {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;

        // 给的美元能换多少个weth
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    //////////////////////////
    //Contructor Tests      //
    //////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceeFeeds() external {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////////////////
    //depositCollateral      Test //
    ////////////////////////////////
    function testRevertsIfCollateralZero() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        vm.startPrank(USER);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        //质押总数
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, 0);
        console.log("Log...", collateralValueInUsd);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    //////////////////////////////////////////
    //depositCollateralAndMintDsc      Test //
    //////////////////////////////////////////

    // function testRevertsIfMintedDscBreaksHealthFactor() public {
    //     (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
    //     amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

    //     uint256 expectedHealthFactor = dsce.
    // }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    //////////////////////
    //mintDsc      Test //
    //////////////////////

    function testRevertsIfMintFails() public {
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    // function testRevertsIfMintAmountBreaksHealthFactor()public depositedCollateral{
    //     (,int256 price,,,)=MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
    //     amountToMint=(AMOUNT_COLLATERAL*(uint256(price)*dsce.getAdditionalFeedPrecision()))/dsce.getPrecision();
    //     vm.startPrank(USER);
    //     uint256 expectedHealthFactor=dsce
    // }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(amountToMint, userBalance);
    }

    //////////////////////////
    //burnDsc      Test     //
    //////////////////////////
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(userBalance, 0);
    }

    function testRevertsIfTransferFails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses,priceFeedAddresses,address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        mockDsce.redeemCollatoral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        dsce.redeemCollatoral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // redeemCollateralForDsc Tests   //
    ////////////////////////////////////
    function testMustRedeemMoreThanZero() public {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Test  //
    ////////////////////////
    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedhealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        assertEq(healthFactor, expectedhealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatePrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatePrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        assert(userHealthFactor == 0.9 ether);
    }

    ////////////////////////
    // Liquidation Tests  //
    ////////////////////////

    function testMustImproveHealthFactorOnLiquidation() public {
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses,priceFeedAddresses,address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquiditor, collateralToCover);

        vm.startPrank(liquiditor);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);

        int256 ethUsdUpdatePrice = 18e8;
        console.log("log", mockDsce.getHealthFactor(USER));
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatePrice);
        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorNotImproved.selector);

        mockDsce.liquidate(weth, USER, debtToCover);

        vm.stopPrank();
    }

    function testCanLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquiditor, collateralToCover);

        vm.startPrank(liquiditor);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOk.selector);
        dsce.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    // modifier liquidated() {
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    //     vm.stopPrank();
    //     int256 ethUsdUpdatedPrice = 18e8;
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    //     uint256 userHealthFactor = dsce.getHealthFactor(USER);
    //     ERC20Mock(weth).mint(liquiditor, collateralToCover);

    //     vm.startPrank(liquiditor);
    //     ERC20Mock(weth).approve(address(dsce), collateralToCover);
    //     dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    //     dsc.approve(address(dsce), amountToMint);
    //     dsce.liquidate(weth, USER, amountToMint);
    //     vm.stopPrank();
    //     _;
    // }

    // function testLiquiditationPayoutIsCorrect() public liquidated {
    //     uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquiditor);
    //     uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
    //         + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());
    //     uint256 hardCodedExpected = 6111111111111111110;
    //     assertEq(liquidatorWethBalance, hardCodedExpected);
    //     assertEq(liquidatorWethBalance, expectedWeth);
    // }

    ////////////////////////////////
    // View & Pure Function Tests //
    ////////////////////////////////

    function testgetCollateralTokenPriceFeed() public {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        address[] memory collateralTokens = dsce.getCollateralTokens();
        console.log("addr", collateralTokens[0]);
        vm.stopPrank();

        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, 2e18);
    }
}
