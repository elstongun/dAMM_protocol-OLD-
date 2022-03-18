// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import './utils/ERC20.sol';
import './utils/IERC4626.sol';
import './utils/Ownable.sol';
import './dToken_Loan.sol';

contract dToken is IERC4626, ERC20, Ownable {

    dToken_Loan[] public loans;

    address public asset;
    uint256 public isWithdrawalEnabled;
    uint256 public multiplierPreKink;
    uint256 public multiplierPostKink;
    uint256 public fixedInterestRate;
    uint256 public kinkUtilRate;
    uint256 public loanCreationFee;

    event borrowerLimitChanged(address borrower, uint256 _borrowLimit);
    event assetsBorrowed(address borrower, uint256 amountBorrowed);
    event assetsReturned(address borrower, uint256 amountBorrowedPlusInterest);

    constructor(
        address _asset, 
        uint256 _kinkUtilRate, 
        uint256 _multiplierPreKink,
        uint256 _multiplierPostKink,
        uint256 _fixedInterestRate,
        uint256 _loanCreationFee
    ) 
    ERC20("Test dAMM Vault", "dToken") {
        asset = _asset;
        isWithdrawalEnabled = false;
        multiplierPreKink = _multiplierPreKink;
        multiplierPostKink = _multiplierPostKink;
        fixedInterestRate = _fixedInterestRate;
        kinkUtilRate = _kinkUtilRate;
        loanCreationFee = 30; //in BPS
    }

    mapping(address => uint) public borrowLimit;

    //Only enabled during withdrawal periods
    function setWithdrawalStatus(bool _value) public onlyOwner {
        isWithdrawalEnabled = _value;
    }

    function deposit(uint256 assets, address receiver) public returns (uint256) {
        uint256 _totalAssets = totalAssets();
        uint256 shares = convertToShares(_totalAssets);
        ERC20(asset).transferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        return shares;
    }


    function mint(uint256 shares, address receiver) public returns (uint256) {
        uint256 assets = convertToAssets(shares);

        if (totalAssets() == 0) assets = shares;

        ERC20(asset).transferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        returns (uint256)
    {

        uint256 _totalAssets = totalAssets();
        uint256 totalBorrows = activeTotalBorrows();
        uint256 totalCash = totalAssets - totalBorrows;

        require(totalCash >= 0, "ERROR");
        require(totalCash >= assets);
    
        require(isWithdrawalEnabled == false, "Withdrawal is currently disabled. See www.dAMM.finance for the current withdrawal schedule.");

        uint256 shares = convertToShares(assets);

        _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        ERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        returns (uint256)
    {
    
        require(isWithdrawalEnabled == false, "Withdrawal is currently disabled. See www.dAMM.finance for the current withdrawal schedule.");

        uint256 assets = convertToAssets(shares);

        _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        ERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return assets;
    }

    /*/ Managing borrower controls /*/
    //To remove a borrower, set their borrowLimit to 0.
    //cap an individual loan at 50-100k
    function setBorrowerLimits(address borrower, uint256 borrowAllowance) public onlyOwner returns(address, uint) {
        //adjust the borrower's  limit for a specific dToken
        borrowLimit[borrower] = borrowAllowance;
        emit borrowerLimitChanged(borrower, borrowAllowance);
    }

    function currentUtilRate() public view returns(uint) {
        uint256 _totalAssets = totalAssets();
        uint256 _utilRate = activeBorrows / totalAssets;
        return _utilRate;
    }

    function currentBorrowRate() public view returns(uint) {
        uint256 _utilRate = currentUtilRate();

        if (_utilRate <= kinkUtilRate) {
            uint256 interestRate = _utilRate * multiplierPreKink;
            return interestRate;
        } else {
            uint256 interestRatePreKink = kinkUtilRate * multiplierPreKink;
            uint256 postKinkUtil = _utilRate - kinkUtilRate;
            uint256 interestRatePostKink = postKinkUtil * multiplierPostKink;
            uint256 interestRate = interestRatePreKink + interestRatePostKink + _fixedInterestRate;
            return interestRate;
        }
    }

    function currentSupplyRate() public view returns (uint256) {
        uint256 _currentBorrowRate = currentBorrowRate();
        uint256 _currentUtilRate = currentUtilRate();
        uint256 supplyRate = _currentBorrowRate * _currentUtilRate * (1 - multiplierPreKink);
        return supplyRate;
    }

    function createLoan(address _borrower, uint256 _loanSize, uint256 _loanLengthInDays) public onlyOwner returns(address, uint) {

        require(borrowLimit[borrower] >= 0, "Cannot request a loan without permission");
        require(borrowLimit[borrower] >= borrowAllowance, "Cannot request a loan of greater size than permitted");
        require(_loanSize <= ERC20(asset).balanceOf(address(this)), "Cannot borrow more capital than is current in the pool");

        uint256 _borrowRate = currentBorrowRate();
        uint256 creationFee = (loanCreationFee/10000) * loanSize;
        uint256 loanMinusFee = loanSize - creationFee;

        //Collateral is a multiple of the collateralRate variable
        dToken_Loan loan = new dToken_Loan(_borrower, loanMinusFee, _borrowRate, 2, loanCreationFee, loanLengthInDays);
        //Treasury collects loan creation fee
        ERC20(asset).transfer(_borrower, creationFee);
        //Loan value is transferred to borrower
        ERC20(asset).transfer(_borrower, loanMinusFee);

        emit assetsBorrowed(_borrower, _loanSize);
    }

    /*/ Read only dToken_Loan Functions /*/

    function getActiveLoans() public view returns (dToken_Loan[] memory) {
        dToken_Loan[] memory activeLoans = new LockedWETHOffer[](loans.length);
        uint256 count;
        for (uint256 i; i < loans.length; i++) {
            LockedWETHOffer loan = LockedWETHOffer(loans[i]);
            if (!loan.hasEnded()) {
                activeLoans[count++] = loan;
            }
        }

        return activeLoans;
    }

    function activeTotalBorrows() public view returns (uint) {
        dToken_Loan[] memory activeLoans = new LockedWETHOffer[](loans.length);
        uint256 count;
        uint256 total;
        for (uint256 i; i < loans.length; i++) {
            LockedWETHOffer loan = LockedWETHOffer(loans[i]);
            if (!loan.hasEnded()) {
                loan[1] += total;
            }
        }
        totalBorrows = total;
        return totalBorrows;
    }

    /*/ Read only functions/Non-state changing /*/





    function totalAssets() public view returns (uint256) {
        //includes loaned capital
        uint256 activeBorrows = activeTotalBorrows();
        uint256 total = ERC20(asset).balanceOf(address(this)) + activeBorrows;
        return total;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return 0;
        return shares * totalAssets() / _totalSupply;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 _totalAssets = totalAssets();
        if (_totalAssets == 0 || _totalSupply == 0) return assets;
        return assets * _totalSupply / _totalAssets;
    }

    function maxDeposit(address receiver) external view returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        uint256 assets = convertToAssets(shares);
        if (assets == 0 && totalAssets() == 0) return shares;
        return assets;
    }

    function maxMint(address receiver) external view returns (uint256) {
        return type(uint256).max;
    }
    
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint256 shares = convertToShares(assets);
        if (totalSupply() == 0) return 0;
        return shares;
    }
    
    function maxWithdraw(address owner) external view returns (uint256) {
        return type(uint256).max;
    }
    
    function maxRedeem(address owner) external view returns (uint256) {
        return type(uint256).max;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function getBorrowerLimits(address borrower) external view returns(uint) {
        return borrowLimit[borrower];
    }
}