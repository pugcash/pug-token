pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PugERC20Token is ERC20, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _enabledLuckyWinnersSet;  // owners with balance > {_minAmountToBeLuckyWinner}
    uint private _randNonce = 0;  // for very basic pseudo-rand number generator
    bool private _sendToDAO = false;  // set to true if we want to consider DAO always one of lucky winners
    address public DAOaddress = address(0);  // the address of the DAO where to send funds
    uint256 private _minAmountToBeLuckyWinner = 1000000 * 10**18;

    constructor() ERC20("Pug.Cash", "PUG") {
        _mint(msg.sender, 100000000000 * 10**18);
    }

    /**
      * @dev Extract the 1% fee to burn, lucky winners and DAO (if enabled).
      * Send the remaining 99% to recipient + the .% not distributed between lucky winners and DAO
      */
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        uint256 zeroOnePerc = (amount / 1000 * 1);  // 0.1% to burn and basic for lucky winners
        uint256 toDAO = (amount / 1000 * 3);  // 0.3% to DAO (if set)

        // burn the 0.1%
        _burn(sender, zeroOnePerc);

        // add to dao 0.3% is DAO is active
        uint256 realTransferToDAO = 0;
        if (_sendToDAO && sender != DAOaddress && recipient != DAOaddress) {
            super._transfer(sender, DAOaddress, toDAO);
            realTransferToDAO = toDAO;
        }

        // pick 3 lucky winners and send coins
        // if DAO is enable, set the lucky winner to be always the DAO
        address[3] memory winners = _getLuckyWinners(sender, recipient);
        uint256 distributedToLuckyWinners = 0;
        for (uint8 i=0; i<winners.length; i++) {
            if (winners[i] != address(0)) {
                super._transfer(sender, winners[i], zeroOnePerc*uint256((3-i)));
                emit LuckyWinner(sender, winners[i], zeroOnePerc*uint256((3-i)), i+1);
                distributedToLuckyWinners += zeroOnePerc*(3-i);
            }
        }

        // do the final transfer
        uint256 realTransferAmount = amount - zeroOnePerc - distributedToLuckyWinners - realTransferToDAO;
        super._transfer(sender, recipient, realTransferAmount);
    }

    /**
      * @dev Extract 3 lucky winners among {_minAmountToBeLuckyWinner}
      *
      * {excludeFrom} and {excludeTo} are the two addresses to be excluded as they're the 2 included in the transaction
      *
      * Returns an address with 3 addresses, that can be (all or some) address(0) if we have less than 3 lucky winners.
      * Do not send rewards to address(0) over _transfer
      */
    function _getLuckyWinners(address excludeFrom, address excludeTo) private returns (address[3] memory) {
        // no winners when only 2 addresses
        if (_enabledLuckyWinnersSet.length() <= 1) {
            return [address(0), address(0), address(0)];
        }

        // list of addresses lucky
        address[3] memory luckyAddresses;

        // for simplicity we pick 1 rand address and the next 3 addresses will be the lucky ones
        uint randUserStart = uint(keccak256(abi.encodePacked(block.timestamp, msg.sender, _randNonce))) % _enabledLuckyWinnersSet.length();
        _randNonce++;

        // find the next 3, excluding sender and receiver
        uint numUsersAdded = 0;
        for (uint i=0; i<_enabledLuckyWinnersSet.length(); i++) {
            address user = _enabledLuckyWinnersSet.at(randUserStart + i - (randUserStart + i >= _enabledLuckyWinnersSet.length() ? _enabledLuckyWinnersSet.length() : 0));
            if (user != excludeFrom && user != excludeTo) {
                luckyAddresses[numUsersAdded] = user;
                numUsersAdded++;
                if (numUsersAdded == 3) {
                    break;
                }
            }
        }
        return luckyAddresses;
    }

    /**
      * @dev Goal of this hook is to add/remove a user from the list of possible lucky winners.
      *
      * _enabledLuckyWinnersSet speeds up the process of extracting possible winners.
      *
      */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        // store or remove the address from the _enabledLuckyWinnersSet
        if (
            from != address(0)
            && balanceOf(from) - amount < _minAmountToBeLuckyWinner
            && _enabledLuckyWinnersSet.contains(from)
        ) {
            _enabledLuckyWinnersSet.remove(from);
        }
        if (
            !Address.isContract(to)  // so we exclude DAO and pools
            && to != address(0)  //avoid having address(0) among possible lucky winners. That can happens since this function is called during _burn process
            && balanceOf(to) + amount >= _minAmountToBeLuckyWinner
            && !_enabledLuckyWinnersSet.contains(to)
        ) {
            _enabledLuckyWinnersSet.add(to);
        }
    }

    /**
      * @dev Sets the DAO address that receives the 0.3% fee, and activate the _sendToDAO flag
      */
    function setDAO(address newDAOaddress) public onlyOwner{
        require(newDAOaddress != address(0), "DAO address cannot be burn address. To clear DAO call clearDAO()");
        require(Address.isContract(newDAOaddress), "DAO address must be a valid contract, already deployed to chain");
        DAOaddress = newDAOaddress;
        _sendToDAO = true;
    }

    /**
      * @dev Removes the DAO address (setting to address(0)) and disable the flag _sendToDAO
      */
    function clearDAO() public onlyOwner{
        DAOaddress = address(0);
        _sendToDAO = false;
    }

    /**
      * @dev Sets the values for {_minAmountToBeLuckyWinner}.
      *
      * The defaut value of {_minAmountToBeLuckyWinner} is 1m**10^18.
      *
      * Being a deflationary token, this function is designed to work with a decreasing {_minAmountToBeLuckyWinner}.
      * If a user has < {_minAmountToBeLuckyWinner} and, after a call to this function by owner, the user has
      * > {_minAmountToBeLuckyWinner}, to be recorded as luckyWinner he should do a tx of any size vs his wallet
      * (like getting some tokens from a pool or asking a friend to send coins). This tx can be of any
      * size, and will have the _beforeTokenTransfer function add the user in the list of possible luckyWinners
      *
      * Make sure to call this function passing the amount with decimals included.
      * So for 1k pass 1000000000000000000000 (10k * 10**18)
      */
    function updateMinAmountLuckyWinner(uint256 newAmount) public onlyOwner {
        require(newAmount > 0, "New amount needs to be grater than zero");
        _minAmountToBeLuckyWinner = newAmount;
    }

    event LuckyWinner(address indexed from, address indexed winner, uint256 winAmount, uint8 indexed position);

}
