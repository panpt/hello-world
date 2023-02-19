pragma solidity ^0.8.0;

contract CARROT is ERC20PresetMinterRebaser, Ownable, ICARROT {
    using SafeMath for uint256;

    /**
     * @dev Guard variable for re-entrancy checks. Not currently used
     */
    bool internal _notEntered;

    /**
     * @notice Internal decimals used to handle scaling factor
     */
    uint256 public constant internalDecimals = 10**24;

    /**
     * @notice Used for percentage maths
     */
    uint256 public constant BASE = 10**18;

    /**
     * @notice Scaling factor that adjusts everyone's balances
     */
    uint256 public CARROTsScalingFactor;

    mapping(address => uint256) internal _CARROTBalances;

    mapping(address => mapping(address => uint256)) internal _allowedFragments;

    mapping(address => bool) public rebaseEX;

    uint256 public initSupply;

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    bytes32 public DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );

    uint256 private INIT_SUPPLY = 3333333333333 * 10**18;
    uint256 private _totalSupply;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    constructor() ERC20PresetMinterRebaser("Rabbit H[ol]e", "CARROT") {
        CARROTsScalingFactor = BASE;
        initSupply = _fragmentToCARROT(INIT_SUPPLY);
        _totalSupply = INIT_SUPPLY;
        _CARROTBalances[owner()] = initSupply;

        emit Transfer(address(0), msg.sender, INIT_SUPPLY);
    }

    /**
     * @return The total number of fragments.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @notice Computes the current max scaling factor
     */
    function maxScalingFactor() external view returns (uint256) {
        return _maxScalingFactor();
    }

    function _maxScalingFactor() internal view returns (uint256) {
        // scaling factor can only go up to 2**256-1 = initSupply * CARROTsScalingFactor
        // this is used to check if CARROTsScalingFactor will be too high to compute balances when rebasing.
        return uint256(int256(-1)) / initSupply;
    }

    /**
     * @notice Mints new tokens, increasing totalSupply, initSupply, and a users balance.
     */
    function mint(address to, uint256 amount) external returns (bool) {
        require(hasRole(MINTER_ROLE, _msgSender()), "Must have minter role");

        _mint(to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal override {
        // increase totalSupply
        _totalSupply = _totalSupply.add(amount);

        // get underlying value
        uint256 CARROTValue = _fragmentToCARROT(amount);

        // increase initSupply
        initSupply = initSupply.add(CARROTValue);

        // make sure the mint didnt push maxScalingFactor too low
        require(
            CARROTsScalingFactor <= _maxScalingFactor(),
            "max scaling factor too low"
        );

        // add balance
        _CARROTBalances[to] = _CARROTBalances[to].add(CARROTValue);

        emit Mint(to, amount);
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burns tokens from msg.sender, decreases totalSupply, initSupply, and a users balance.
     */

    function burn(uint256 amount) public override {
        _burn(amount);
    }

    function _burn(uint256 amount) internal {
        // decrease totalSupply
        _totalSupply = _totalSupply.sub(amount);

        // get underlying value
        uint256 CARROTValue = _fragmentToCARROT(amount);

        // decrease initSupply
        initSupply = initSupply.sub(CARROTValue);

        // decrease balance
        _CARROTBalances[msg.sender] = _CARROTBalances[msg.sender].sub(CARROTValue);
        emit Burn(msg.sender, amount);
        emit Transfer(msg.sender, address(0), amount);
    }

    /**
     * @notice Mints new tokens using underlying amount, increasing totalSupply, initSupply, and a users balance.
     */
    function mintUnderlying(address to, uint256 amount) public returns (bool) {
        require(hasRole(MINTER_ROLE, _msgSender()), "Must have minter role");

        _mintUnderlying(to, amount);
        return true;
    }

    function _mintUnderlying(address to, uint256 amount) internal {
        // increase initSupply
        initSupply = initSupply.add(amount);

        // get external value
        uint256 scaledAmount = _CARROTToFragment(amount);

        // increase totalSupply
        _totalSupply = _totalSupply.add(scaledAmount);

        // make sure the mint didnt push maxScalingFactor too low
        require(
            CARROTsScalingFactor <= _maxScalingFactor(),
            "max scaling factor too low"
        );

        // add balance
        _CARROTBalances[to] = _CARROTBalances[to].add(amount);

        emit Mint(to, scaledAmount);
        emit Transfer(address(0), to, scaledAmount);
    }

    /**
     * @dev Transfer underlying balance to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transferUnderlying(address to, uint256 value)
        public
        validRecipient(to)
        returns (bool)
    {
        // sub from balance of sender
        _CARROTBalances[msg.sender] = _CARROTBalances[msg.sender].sub(value);

        // add to balance of receiver
        _CARROTBalances[to] = _CARROTBalances[to].add(value);
        emit Transfer(msg.sender, to, _CARROTToFragment(value));
        return true;
    }

    /* - ERC20 functionality - */

    /**
     * @dev Transfer tokens to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transfer(address to, uint256 value)
        public
        override
        validRecipient(to)
        returns (bool)
    {
        // underlying balance is stored in CARROTs, so divide by current scaling factor

        // note, this means as scaling factor grows, dust will be untransferrable.
        // minimum transfer value == CARROTsScalingFactor / 1e24;

        // get amount in underlying
        uint256 CARROTValue = _fragmentToCARROT(value);

        // sub from balance of sender
        _CARROTBalances[msg.sender] = _CARROTBalances[msg.sender].sub(CARROTValue);

        // add to balance of receiver
        _CARROTBalances[to] = _CARROTBalances[to].add(CARROTValue);
        emit Transfer(msg.sender, to, value);

        return true;
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     * @param value The amount of tokens to be transferred.
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override validRecipient(to) returns (bool) {
        // decrease allowance
        if (!hasRole(MINTER_ROLE, _msgSender())) {  //the chef do not need allowance
            _allowedFragments[from][msg.sender] = _allowedFragments[from][
                msg.sender
            ].sub(value);
        }

        // get value in CARROTs
        uint256 CARROTValue = _fragmentToCARROT(value);

        // sub from from
        _CARROTBalances[from] = _CARROTBalances[from].sub(CARROTValue);
        _CARROTBalances[to] = _CARROTBalances[to].add(CARROTValue);
        emit Transfer(from, to, value);

        return true;
    }

    /**
     * @param who The address to query.
     * @return The balance of the specified address.
     */
    function balanceOf(address who) public view override returns (uint256) {
        if (!rebaseEX[who]) return _CARROTToFragment(_CARROTBalances[who]);
        else return _CARROTBalances[who].mul(BASE).div(internalDecimals); // no burn 
    }

    /** @notice Currently returns the internal storage amount
     * @param who The address to query.
     * @return The underlying balance of the specified address.
     */
    function balanceOfUnderlying(address who) public view returns (uint256) {
        return _CARROTBalances[who];
    }

    /**
     * @dev Function to check the amount of tokens that an owner has allowed to a spender.
     * @param owner_ The address which owns the funds.
     * @param spender The address which will spend the funds.
     * @return The number of tokens still available for the spender.
     */
    function allowance(address owner_, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowedFragments[owner_][spender];
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of
     * msg.sender. This method is included for ERC20 compatibility.
     * increaseAllowance and decreaseAllowance should be used instead.
     * Changing an allowance with this method brings the risk that someone may transfer both
     * the old and the new allowance - if they are both greater than zero - if a transfer
     * transaction is mined before the later approve() call is mined.
     *
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     */
    function approve(address spender, uint256 value)
        public
        override
        returns (bool)
    {
        _allowedFragments[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to a spender.
     * This method should be used instead of approve() to avoid the double approval vulnerability
     * described above.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        override
        returns (bool)
    {
        _allowedFragments[msg.sender][spender] = _allowedFragments[msg.sender][
            spender
        ].add(addedValue);
        emit Approval(
            msg.sender,
            spender,
            _allowedFragments[msg.sender][spender]
        );
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        override
        returns (bool)
    {
        uint256 oldValue = _allowedFragments[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedFragments[msg.sender][spender] = 0;
        } else {
            _allowedFragments[msg.sender][spender] = oldValue.sub(
                subtractedValue
            );
        }
        emit Approval(
            msg.sender,
            spender,
            _allowedFragments[msg.sender][spender]
        );
        return true;
    }

    // --- Approve by signature ---
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(block.timestamp <= deadline, "CARROT/permit-expired");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );

        require(owner != address(0), "CARROT/invalid-address-0");
        require(owner == ecrecover(digest, v, r, s), "CARROT/invalid-permit");
        _allowedFragments[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function rebase(
        uint256 epoch,
        uint256 indexDelta,
        bool positive
    ) public returns (uint256) {
        require(hasRole(REBASER_ROLE, _msgSender()), "Must have rebaser role");

        // no change
        if (indexDelta == 0) {
            emit Rebase(epoch, CARROTsScalingFactor, CARROTsScalingFactor);
            return _totalSupply;
        }

        // for events
        uint256 prevCARROTsScalingFactor = CARROTsScalingFactor;

        if (!positive) {
            // negative rebase, decrease scaling factor
            CARROTsScalingFactor = CARROTsScalingFactor
                .mul(BASE.sub(indexDelta))
                .div(BASE);
        } else {
            // positive rebase, increase scaling factor
            uint256 newScalingFactor = CARROTsScalingFactor
                .mul(BASE.add(indexDelta))
                .div(BASE);
            if (newScalingFactor < _maxScalingFactor()) {
                CARROTsScalingFactor = newScalingFactor;
            } else {
                CARROTsScalingFactor = _maxScalingFactor();
            }
        }

        // update total supply, correctly
        _totalSupply = _CARROTToFragment(initSupply);

        emit Rebase(epoch, prevCARROTsScalingFactor, CARROTsScalingFactor);
        return _totalSupply;
    }

    function CARROTToFragment(uint256 _CARROT) public view returns (uint256) {
        return _CARROTToFragment(_CARROT);
    }

    function fragmentToCARROT(uint256 value) public view returns (uint256) {
        return _fragmentToCARROT(value);
    }

    function _CARROTToFragment(uint256 _CARROT) internal view returns (uint256) {
        return _CARROT.mul(CARROTsScalingFactor).div(internalDecimals);
    }

    function _fragmentToCARROT(uint256 value) internal view returns (uint256) {
        return value.mul(internalDecimals).div(CARROTsScalingFactor);
    }

    function setRebaseEX(address _who, bool _value) public onlyOwner {
        rebaseEX[_who] = _value;
    }

    // Rescue tokens
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) public onlyOwner returns (bool) {
        // transfer to
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        return true;
    }
}
