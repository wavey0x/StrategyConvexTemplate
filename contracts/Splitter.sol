// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/curve.sol";

interface IGauge {
    struct VotedSlope {
        uint slope;
        uint power;
        uint end;
    }
    struct Point {
        uint bias;
        uint slope;
    }
    function vote_user_slopes(address, address) external view returns (VotedSlope memory);
    function last_user_vote(address, address) external view returns (uint);
    function points_weight(address, uint256) external view returns (Point memory);
    function checkpoint_gauge(address) external;
    function time_total() external view returns (uint);
}

interface IStrategy {
    function estimatedTotalAssets() external view returns (uint);
    function rewardsContract() external view returns (address);
}

interface IRewards {
    function getReward(address, bool) external;
}

interface IYveCRV {
    function deposit(uint) external;
}

contract Splitter {
    event Split(uint yearnAmount, uint keep, uint templeAmount, uint period);
    event PeriodUpdated(uint period, uint globalSlope, uint userSlope);
    event YearnUpdated(address recipient, uint keepCRV);
    event TempleUpdated(address recipient);
    event ShareUpdated(uint share);
    event PendingShareUpdated(address setter, uint share);
    event Sweep(address sweeper, address token, uint amount);

    struct Yearn{
        address recipient;
        address voter;
        address admin;
        uint share;
        uint keepCRV;
    }
    struct Period{
        uint period;
        uint globalSlope;
        uint userSlope;
    }

    uint internal constant precision = 10_000;
    uint internal constant WEEK = 7 days;
    IERC20 internal constant crv = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IYveCRV internal constant yvecrv = IYveCRV(0xc5bDdf9843308380375a611c18B50Fb9341f502A);
    IERC20 public constant liquidityPool = IERC20(0xdaDfD00A2bBEb1abc4936b1644a3033e1B653228);
    IERC20 internal constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant cvx = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IGauge public constant gaugeController = IGauge(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB);
    address public constant gauge = 0x8f162742a7BCDb87EB52d83c687E43356055a68B;
    mapping(address => uint) pendingShare; 
    
    Yearn public yearn;
    Period public period;
    address public strategy;
    address public templeRecipient = 0xE97CB3a6A0fb5DA228976F3F2B8c37B6984e7915;

    // use Curve to sell our CVX and CRV rewards to WETH
    ICurveFi internal constant crveth =
        ICurveFi(0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511); // use curve's new CRV-ETH crypto pool to sell our CRV
    ICurveFi internal constant cvxeth =
        ICurveFi(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4); // use curve's new CVX-ETH crypto pool to sell our CVX

    
    constructor() public {
        crv.approve(address(yvecrv), type(uint).max);
        yearn = Yearn(
            address(0x93A62dA5a14C80f265DAbC077fCEE437B1a0Efde), // recipient
            address(0xF147b8125d2ef93FB6965Db97D6746952a133934), // voter
            address(0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52), // admin
            8_000, // share of profit (initial terms of deal)
            5_000 // Yearn's discretionary % of CRV to lock as veCRV on each split
        );
    }

    function split() external {
        address _strategy = strategy;
        if(_strategy == address(0)) return;
        require(
            msg.sender == yearn.admin || 
            msg.sender == templeRecipient || 
            msg.sender == strategy,
            "!authorized"
        );
        (uint crvBal, uint cvxBal) = _pullTokens();
        if (cvxBal > 0) {
            _sellCvx();
            _buyCRV();
        }
        uint crvBalance = crv.balanceOf(_strategy);
        if(crvBalance > 0) {
            _split(crvBalance);
        }
        else {
            emit Split(0, 0, 0, period.period);
            return;
        }
    }

    function _pullTokens() internal returns (uint crvBal, uint cvxBal) {
        address _strategy = strategy;
        IRewards(IStrategy(_strategy).rewardsContract()).getReward(_strategy, true);
        crvBal = crv.balanceOf(_strategy);
        if( crvBal > 0) crv.transferFrom(_strategy, address(this), crvBal);
        cvxBal = cvx.balanceOf(_strategy);
        if (cvxBal > 0) cvx.transferFrom(_strategy, address(this), cvxBal);
    }

    // Sells our CRV and CVX on Curve, then WETH -> stables together on UniV3
    function _sellCvx() internal {
        uint256 _amount = cvx.balanceOf(address(this));
        if (_amount > 0) {
            // don't want to swap dust or we might revert
            cvxeth.exchange(1, 0, _amount, 0, false);
        }
    }

    function _buyCRV() internal {
        uint256 _wethBalance = weth.balanceOf(address(this));
        if (_wethBalance > 0) {
            // don't want to swap dust or we might revert
            crveth.exchange(0, 1, _wethBalance, 0, false);
        }
    }

    // @notice split all 
    function _split(uint crvBalance) internal {
        if (block.timestamp / WEEK * WEEK > period.period) _updatePeriod();
        (uint yRatio, uint tRatio) = _computeSplitRatios();
        if (yRatio == 0) {
            crv.transfer(templeRecipient, crvBalance);
            emit Split(0, 0, crvBalance, period.period);
            return;
        }
        uint yearnAmount = crvBalance * yRatio / precision;
        uint templeAmount = crvBalance * tRatio / precision;
        uint keep = yearnAmount * yearn.keepCRV / precision;
        if (keep > 0) {
            yvecrv.deposit(keep);
            IERC20(address(yvecrv)).transfer(yearn.recipient, keep);
        }
        if(yearnAmount > 0) crv.transfer(yearn.recipient, yearnAmount - keep);
        if(templeAmount > 0) crv.transfer(templeRecipient, templeAmount);
        emit Split(yearnAmount, keep, templeAmount, period.period);
    }

    // @dev updates all period data to present week
    function _updatePeriod() internal {
        uint _period = block.timestamp / WEEK * WEEK;
        period.period = _period;
        gaugeController.checkpoint_gauge(gauge);
        uint _userSlope = gaugeController.vote_user_slopes(yearn.voter, gauge).slope;
        uint _globalSlope = gaugeController.points_weight(gauge, _period).slope;
        period.userSlope = _userSlope;
        period.globalSlope = _globalSlope;
        emit PeriodUpdated(_period, _userSlope, _globalSlope);
    }

    function getLpStats() public view returns (uint lpSupply, uint lpDominance) {
        lpSupply = liquidityPool.totalSupply();
        lpDominance = 
            IStrategy(strategy).estimatedTotalAssets() 
            * precision 
            / lpSupply;
    }

    function _computeSplitRatios() internal view returns (uint yRatio, uint tRatio) {
        uint userSlope = period.userSlope;
        if(userSlope == 0) return (0, 10_000);
        uint relativeSlope = period.globalSlope == 0 ? 0 : userSlope * precision / period.globalSlope;
        (uint lpSupply, uint lpDominance) = getLpStats();
        if (lpSupply == 0) return (10_000, 0); // @dev avoid div by 0
        if (lpDominance == 0) return (10_000, 0); // @dev avoid div by 0
        yRatio =
            relativeSlope
            * yearn.share
            / lpDominance;
        // Should not return > 100%
        if (yRatio > 10_000){
            return (10_000, 0);
        }
        tRatio = precision - yRatio;
    }

    // @dev Estimate only.
    function estimateSplitRatios() external view returns (uint ySplit, uint tSplit) {
        (ySplit, tSplit) = _computeSplitRatios();
    }

    function updatePeriod() external {
        _updatePeriod();
    }

    function setStrategy(address _strategy) external {
        require(msg.sender == yearn.admin);
        strategy = _strategy;
    }

    // @notice For use by yearn only to update discretionary values
    // @dev Other values in the struct are either immutable or require agreement by both parties to update.
    function setYearn(address _recipient, uint _keepCRV) external {
        require(msg.sender == yearn.admin);
        require(_keepCRV <= 10_000, "TooHigh");
        address recipient = yearn.recipient;
        if(recipient != _recipient){
            pendingShare[recipient] = 0;
            yearn.recipient = _recipient;
        }
        yearn.keepCRV = _keepCRV;
        emit YearnUpdated(_recipient, _keepCRV);
    }

    function setTemple(address _recipient) external {
        address recipient = templeRecipient;
        require(msg.sender == recipient);
        if(recipient != _recipient){
            pendingShare[recipient] = 0;
            templeRecipient = _recipient;
            emit TempleUpdated(_recipient);
        }
    }

    // @notice update share if both parties agree.
    function updateYearnShare(uint _share) external {
        require(_share <= 10_000 && _share != 0, "OutOfRange");
        require(msg.sender == yearn.admin || msg.sender == templeRecipient);
        if(msg.sender == yearn.admin && pendingShare[msg.sender] != _share){
            pendingShare[msg.sender] = _share;
            emit PendingShareUpdated(msg.sender, _share);
            if (pendingShare[templeRecipient] == _share) {
                yearn.share = _share;
                emit ShareUpdated(_share);
            }
        }
        else if(msg.sender == templeRecipient && pendingShare[msg.sender] != _share){
            pendingShare[msg.sender] = _share;
            emit PendingShareUpdated(msg.sender, _share);
            if (pendingShare[yearn.admin] == _share) {
                yearn.share = _share;
                emit ShareUpdated(_share);
            }
        }
    }

    function sweep(address _token) external {
        require(msg.sender == templeRecipient || msg.sender == yearn.admin);
        IERC20 token = IERC20(_token);
        uint amt = token.balanceOf(address(this));
        token.transfer(msg.sender, amt);
        emit Sweep(msg.sender, _token, amt);
    }

}