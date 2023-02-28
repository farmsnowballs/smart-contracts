// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../interfaces/IWETH.sol";
import "../../../lib/Ownable.sol";
import "../../../lib/ERC20.sol";
import "../../../lib/SafeERC20.sol";

import "./interfaces/IXGrail.sol";
import "./interfaces/ICamelotVoter.sol";
import "./interfaces/INFTHandler.sol";

/**
 * @notice CamelotVoter manages deposits for other strategies
 * using a proxy pattern. It also directly accepts deposits
 * in exchange for yyGRAIL token.
 */
contract CamelotVoter is ICamelotVoter, Ownable, ERC20, INFTHandler {
    using SafeERC20 for IERC20;

    IWETH private constant WETH = IWETH(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IXGrail public constant xGRAIL = IXGrail(0x3CAaE25Ee616f2C8E13C74dA0813402eae3F496b);
    address public constant GRAIL = 0x3d9907F9a368ad0a51Be60f7Da3b97cf940982D8;

    address public voterProxy;
    bool public override depositsEnabled;

    modifier onlyCamelotVoterProxy() {
        require(msg.sender == voterProxy, "CamelotVoter::onlyCamelotVoterProxy");
        _;
    }

    constructor(address _owner) ERC20("Yield Yak xGrail", "yyGRAIL") {
        transferOwnership(_owner);
    }

    receive() external payable {}

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onNFTHarvest(
        address,
        address,
        uint256,
        uint256,
        uint256
    ) external pure override returns (bool) {
        return true;
    }

    function onNFTAddToPosition(
        address,
        uint256,
        uint256
    ) external pure override returns (bool) {
        return true;
    }

    function onNFTWithdraw(
        address,
        uint256,
        uint256
    ) external pure override returns (bool) {
        return true;
    }

    /**
     * @notice unallocated xGrail balance
     * @return uint256 unallocated xGrail
     */
    function unallocatedXGrail() public view returns (uint256) {
        return xGRAIL.balanceOf(address(this));
    }

    /**
     * @notice xGrail allocated to plugin
     * @return uint256 allocated xGrail
     */
    function allocatedXGrail() public view returns (uint256) {
        (uint256 allocated, ) = xGRAIL.xGrailBalances(address(this));
        return allocated;
    }

    function totalXGrail() public view returns (uint256) {
        return unallocatedXGrail() + allocatedXGrail();
    }

    /**
     * @notice Enable/disable deposits
     * @dev Restricted to owner
     * @param newValue bool
     */
    function updateDepositsEnabled(bool newValue) external onlyOwner {
        require(depositsEnabled != newValue);
        depositsEnabled = newValue;
    }

    /**
     * @notice External deposit function for GRAIL
     * @param _amount to deposit
     */
    function deposit(uint256 _amount) external override {
        require(depositsEnabled == true, "CamelotVoter:deposits disabled");
        require(IERC20(GRAIL).transferFrom(msg.sender, address(this), _amount), "CamelotVoter::transfer failed");
        _deposit(_amount);
    }

    /**
     * @notice Update proxy address
     * @dev Very sensitive, restricted to owner
     * @param _voterProxy new address
     */
    function setVoterProxy(address _voterProxy) external override onlyOwner {
        voterProxy = _voterProxy;
    }

    function mint(address _receiver) external override onlyCamelotVoterProxy {
        uint256 totalXGrailLocked = totalXGrail();
        uint256 totalSupply = totalSupply();
        if (totalXGrailLocked > totalSupply) {
            _mint(_receiver, totalXGrailLocked - totalSupply);
        }
    }

    /**
     * @notice Deposit function for GRAIL
     * @dev Restricted to proxy
     * @param _amount to deposit
     */
    function depositFromBalance(uint256 _amount) external override onlyCamelotVoterProxy {
        require(depositsEnabled == true, "CamelotVoter:deposits disabled");
        _deposit(_amount);
    }

    /**
     * @notice Deposits GRAIL and mints yyGRAIL at 1:1 ratio
     * @param _amount to deposit
     */
    function _deposit(uint256 _amount) internal {
        IERC20(GRAIL).safeApprove(address(xGRAIL), _amount);
        _mint(msg.sender, _amount);
        xGRAIL.convert(_amount);
    }

    /**
     * @notice Helper function to wrap ETH
     * @return amount wrapped to WETH
     */
    function wrapEthBalance() external override onlyCamelotVoterProxy returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            WETH.deposit{value: balance}();
        }
        return balance;
    }

    /**
     * @notice Open-ended execute function
     * @dev Very sensitive, restricted to proxy
     * @param target address
     * @param value value to transfer
     * @param data calldata
     * @return bool success
     * @return bytes result
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external override onlyCamelotVoterProxy returns (bool, bytes memory) {
        (bool success, bytes memory result) = target.call{value: value}(data);

        return (success, result);
    }
}
