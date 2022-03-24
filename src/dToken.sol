// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import './utils/ERC20.sol';
import './utils/IERC4626.sol';
import './utils/Ownable.sol';
import {SafeERC20} from './utils/SafeERC20.sol';

contract dToken is IERC4626, ERC20, Ownable {

    address public asset;
    bool public isWithdrawalEnabled;
    uint256 public multiplierPerBlock;
    uint256 public jumpMultiplierPerBlock;
    uint256 public fixedInterestRate;
    uint256 public kink;
    uint256 public rFactor;
    uint256 public totalBorrows;
    uint256 public borrowIndex;
    uint256 public currentAssets;
    uint256 public accrualBlockNumber;
    uint256 public blocksPerYear;
    uint256 public fixedRatePerBlock;
    

    event borrowerLimitChanged(address borrower, uint256 _borrowLimit);
    event assetsBorrowed(address borrower, uint256 amountBorrowed, uint256 _totalBorrows);
    event RepayBorrow(address payer, address borrower, uint256 actualRepayAmount, uint256 accountBorrowsNew, uint256 totalBorrowsNew);
    event interestAccrued(uint256 currentAssets, uint256 interestAccumulated, uint256 borrowIndexNew, uint256 totalBorrowsNew);


    constructor(
        address _asset, 
        uint256 _kink, //Must input as a Mantissa in 1e18 scale
        uint256 _multiplierPerBlock, //Must input as a mantissa in 1e18 scale
        uint256 _jumpMultiplierPerBlock, //Must input as a mantissa in 1e18 scale
        uint256 _fixedInterestRate //Must input as a mantissa in 1e18 scale
    ) 
    ERC20("Test dAMM Vault", "dToken") {
        asset = _asset;
        isWithdrawalEnabled = false;
        multiplierPerBlock = _multiplierPerBlock; 
        jumpMultiplierPerBlock = _jumpMultiplierPerBlock; 
        fixedInterestRate = _fixedInterestRate; 
        kink = _kink; //Mantissa
        rFactor = 0.25 * 1e18;
        totalBorrows = 0;
        borrowIndex = 1*1e18;
        accrualBlockNumber = getBlockNumber();
        blocksPerYear = 2102400;
        fixedRatePerBlock = _fixedInterestRate / blocksPerYear;
    }

    mapping(address => uint256) public borrowLimit;
    mapping(address => uint256) public currentBorrows;

    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    mapping(address => BorrowSnapshot) internal accountBorrows;

    function deposit(uint256 assets, address receiver) public returns (uint256) {

        currentAssets = totalAssets();
        uint256 shares = convertToShares(currentAssets);
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

    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256) {
        uint256 _totalAssets = totalAssets();
        uint256 totalCash = _totalAssets - totalBorrows;

        require(totalCash >= 0, "ERROR");
        require(totalCash >= assets, "Sufficient liquidity is not available for withdrawal");
    
        require(isWithdrawalEnabled == true, "Withdrawal is currently disabled.");
        uint256 shares = convertToShares(assets);

        _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        ERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256) {
        require(isWithdrawalEnabled == true, "Withdrawal is currently disabled. See www.dAMM.finance for the current withdrawal schedule.");

        uint256 assets = convertToAssets(shares);

        _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        ERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return assets;
    }

    /*/ 
    
    
    
        Managing Borrowers and Their Limits, Creating and Repaying Loans
    
    
    
    /*/

    function setWithdrawalStatus(bool _value) public onlyOwner returns(bool) {
        isWithdrawalEnabled = _value;
        return isWithdrawalEnabled;
    }

    function setBorrowerLimits(address borrower, uint256 borrowAllowance) public onlyOwner {
        //adjust the borrower's  limit for a specific dToken
        borrowLimit[borrower] = borrowAllowance;
        emit borrowerLimitChanged(borrower, borrowAllowance);
    }

    function setInterestRateModel(uint256 kink_, uint256 multiplierPerBlock_, uint256 jumpMultiplierPerBlock_, uint256 fixedInterestRate_) public onlyOwner returns(uint, uint, uint, uint) {
        kink = kink_;
        multiplierPerBlock = multiplierPerBlock_;
        jumpMultiplierPerBlock = jumpMultiplierPerBlock_;
        fixedRatePerBlock = fixedInterestRate_ / blocksPerYear;
        return (kink, multiplierPerBlock, jumpMultiplierPerBlock, fixedRatePerBlock);
    }

    struct BorrowLocalVars {
        uint256 accountBorrows;
        uint256 accountBorrowsNew;
        uint256 totalBorrowsNew;
    }

    function createLoan(address _borrower, uint256 _loanSize) public returns(address, uint256, uint256) {
        
        accrueInterest();
        require(accrualBlockNumber == getBlockNumber(), "Accrual Block does not equal current block");

        require(borrowLimit[_borrower] >= 0, "Cannot request a loan without permission");
        require(borrowLimit[_borrower] >= (_loanSize + storedBorrowsInternal(_borrower)), "Cannot borrow more than permitted");
        require(_loanSize <= ERC20(asset).balanceOf(address(this)), "Cannot borrow more capital than is current in the pool");

        BorrowLocalVars memory vars;

        vars.accountBorrows = storedBorrowsInternal(_borrower);

        //new values locally stored

        //   accountBorrowsNew = accountBorrows + borrowAmount
         //  totalBorrowsNew = totalBorrows + borrowAmount
        vars.accountBorrowsNew =  vars.accountBorrows + _loanSize;
        vars.totalBorrowsNew = totalBorrows + _loanSize;

        //Loan value is transferred to borrower
        doSafeTransferOut(_borrower, _loanSize);

        //write new borrowsnapshots to storage
        accountBorrows[_borrower].principal = vars.accountBorrowsNew;
        accountBorrows[_borrower].interestIndex = borrowIndex;

        //write new total borrows to storage
        totalBorrows = vars.totalBorrowsNew;

        emit assetsBorrowed(_borrower, _loanSize, totalBorrows);
        return(_borrower, _loanSize, totalBorrows);
    }
    
    function storedBorrowsInternal(address _borrower) internal view returns(uint256) {
        BorrowSnapshot storage borrowSnapshot = accountBorrows[_borrower];
        
        uint256 totalOwed = borrowSnapshot.principal + borrowSnapshot.interestIndex;

        return totalOwed;
    }

    struct RepayBorrowLocalVars {
        uint256 repayAmount;
        uint256 borrowerIndex;
        uint256 accountBorrows;
        uint256 accountBorrowsNew;
        uint256 totalBorrowsNew;
        uint256 actualRepayAmount;
    }

    function repayLoan(address _payer, address _borrower, uint256 repayAmount) public returns(uint256) {
        require(accrualBlockNumber == getBlockNumber(), "Accrual Block does not equal current block");

        RepayBorrowLocalVars memory vars;
        
        vars.borrowerIndex = accountBorrows[_borrower].interestIndex;
        vars.accountBorrows = storedBorrowsInternal(_borrower);

        /* If repayAmount == -1, repayAmount = accountBorrows */
        if (repayAmount == type(uint).max) {
            vars.repayAmount = vars.accountBorrows;
        } else {
            vars.repayAmount = repayAmount;
        }

        //confirm the actual repay amount
        vars.actualRepayAmount = doSafeTransferIn(_payer, vars.repayAmount);

        //locally store the users new borrow balances
        vars.accountBorrowsNew = vars.accountBorrows - vars.actualRepayAmount;
        vars.totalBorrowsNew = totalBorrows - vars.actualRepayAmount;

        //Write new variables to storage
        accountBorrows[_borrower].principal = vars.accountBorrowsNew;
        accountBorrows[_borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;
        emit RepayBorrow(_payer, _borrower, vars.actualRepayAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);
        
        return vars.actualRepayAmount;
    }

    function accrueInterest() public returns (bool) {
        uint256 currentBlockNumber = getBlockNumber();
        uint256 accrualBlockNumberPrior = accrualBlockNumber;
        
        require(accrualBlockNumberPrior == currentBlockNumber);

        currentAssets = totalAssets();
        totalBorrows = currentTotalBorrows();

        //get current borrows
        uint256 _borrowRateMantissa = currentBorrowRate(currentAssets, totalBorrows);
        
        //blocks since last accrual
        uint256 blockDelta = currentBlockNumber - accrualBlockNumber;

        //interest calculations
        uint256 simpleInterestFactor = _borrowRateMantissa * blockDelta;
        uint256 interestAccumulated = simpleInterestFactor * totalBorrows;
        uint256 totalBorrowsNew = totalBorrows + interestAccumulated;
        uint256 borrowIndexNew = simpleInterestFactor = _borrowRateMantissa * borrowIndex + borrowIndex;

        // pee pee poo poo (  )=)====D --- from adam
        //store new variables
        accrualBlockNumber = currentBlockNumber;
        totalBorrows = totalBorrowsNew;
        borrowIndex = borrowIndexNew;
        emit interestAccrued(currentAssets, interestAccumulated, borrowIndexNew, totalBorrowsNew);

        return true;
    }



    /*/ 
    
    
    
                Internal Utilization and Interest Rate Functions 
    
    
    
    /*/

    function utilizationRate(uint256 _totalAssets, uint256 _totalBorrows) public pure returns(uint) {
        if(_totalBorrows == 0) {
            return 0;
        }
        uint256 utilRate = (_totalBorrows / _totalAssets) * 1e18 ;
        return utilRate;
    }


    function currentBorrowRate(uint256 _totalAssets, uint256 _totalBorrows) internal view returns(uint256) {
        uint256 util = utilizationRate(_totalAssets, _totalBorrows);

        if (util <= kink) {
            return ((util * multiplierPerBlock) / 1e18) + fixedRatePerBlock;
        } else {
            uint256 baseRatePerBlock = (kink * multiplierPerBlock) / 1e18;
            uint256 additionalRatePerBlock = ((util - kink) * jumpMultiplierPerBlock) / 1e18;
            return (baseRatePerBlock + additionalRatePerBlock) + fixedRatePerBlock;
        }
    }
    
    function currentSupplyRate(uint256 _totalAssets, uint256 _totalBorrows) public view returns (uint256) {
        uint256 util = utilizationRate(_totalAssets, _totalBorrows);
        uint256 borrowRate = currentBorrowRate(_totalAssets, _totalBorrows);
        uint256 supplyRatePre = (borrowRate * util) / 1e18;
        return (supplyRatePre * (1 - rFactor)) / 1e18;
    }

    /*/ 
    
    
    
                Read only dToken Functions 
    
    
    
    /*/
    
    function totalAssets() public view returns (uint256) {
        return ERC20(asset).balanceOf(address(this)) + totalBorrows;
    }

    function currentTotalBorrows() public view returns (uint) {
        return totalBorrows;
    }

    //create totalborrows call function
    
    function getActiveLoansByUser(address borrower) public view returns (uint256) {
        uint256 result = storedBorrowsInternal(borrower);
        return result;
    }

        /*/ Read only functions/Non-state changing /*/

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

    function maxMint(address receiver) public pure returns (uint256) {
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

    function doSafeTransferIn(address borrower, uint256 repayAmount) internal returns(uint256) {

        SafeERC20.safeTransferFrom(ERC20(asset), borrower, address(this), repayAmount);
        
        return repayAmount;
    }

    function doSafeTransferOut(address borrower, uint256 loanAmount) internal returns(uint256) {

        SafeERC20.safeTransfer(ERC20(asset), borrower, loanAmount);
        
        return loanAmount;
    }

    function getBlockNumber() public view returns(uint256) {
        return block.number;
    }
}