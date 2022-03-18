// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {IERC20, IOwnable} from "./utils/Interfaces.sol";
import './utils/ERC20.sol';
import './utils/Ownable.sol';

contract dToken_Loan {
    address public immutable dTokenPool;
    address public immutable borrower;
    uint256 public immutable loanSize;
    uint256 public immutable borrowRate; //in bps
    uint256 public immutable dAMMCollateralRate;
    uint256 public immutable loanCreationFee; // in bps
    uint256 public immutable loanLengthInDays;
    bool public hasEnded = false;

    //Ropsten test addresses
    address public constant dAMM = 0xf3aC2d4e676Ed31F21Ab5C31D6478FfCdF0E0086;
    address public constant dTokenAssetAddress = 0xA3F8E2FeE6E754617e0f0917A1BA4f77De2D9423;
    address public constant dAMM_comptroller = 0x5cF9559C2DC7200255DADE35d2988E6Bf05ABbFc;

    event LoanRepaid(address borrower, uint loanSize, uint borrowRate, uint interestPaid);
    event LoanCancelled(address borrower, uint loanSize, uint borrowRate, uint interestPaid);
    event CollateralReturned(address borrower, uint dAMM_Balance);


    constructor(
        address _borrower,
        uint256 _loanSize,
        uint256 _borrowRate,
        uint256 _dAMMCollateralRate,
        uint256 _loanCreationFee,
        uint256 _loanLengthInDays
    ) {
        dTokenPool = msg.sender; //check that this actually works
        borrower = _borrower;
        loanSize = _loanSize;
        borrowRate = _borrowRate;
        dAMMCollateralRate = _dAMMCollateralRate;
        loanCreationFee = _loanCreationFee;
        loanLengthInDays = _loanLengthInDays;
    }


    function isCollateralRequirementMet() public view returns (bool) {
        uint bal = IERC20(dAMM).balanceOf(address(this));
        uint owedInterest = (borrowRate * loanSize);
        uint collateralRequirement = owedInterest * dAMMCollateralRate;
        if (bal >= collateralRequirement)  {
            bool isCollateralMet = true;
            return isCollateralMet;
        } else {
            bool isCollateralMet = false;
            return isCollateralMet;
        }
    }

    function returnCollateral() public {
        require(msg.sender == dAMM_comptroller, "Only callable by the comptroller");
        //confirming the loan was paid back
        require(hasEnded == true);

        emit CollateralReturned(borrower, IERC20(dAMM).balanceOf(address(this)));
        IERC20(dAMM).transfer(borrower, IERC20(dAMM).balanceOf(address(this)));
    }
    //create withdraw collateral function incase of no repayment
    function withdrawCollateral() public {
        require(msg.sender == dAMM_comptroller, "You are not the comptroller we are looking for...");

        IERC20(dAMM).transfer(dAMM_comptroller, IERC20(dAMM).balanceOf(address(this)));
    }

    function repayLoan() public {
        require(msg.sender == borrower, "Only callable by the borrower");

        uint principalOwed = loanSize;
        uint interestOwed = (loanSize - loanCreationFee) * borrowRate;
        uint totalOwed = principalOwed + interestOwed;

        require(IERC20(dTokenAssetAddress).balanceOf(msg.sender) >= totalOwed, "Loan repayment exceeds your current balance.");

        IERC20(dTokenAssetAddress).transferFrom(borrower, dTokenPool, totalOwed); 
        //should transfer back to pool but need to test

        emit LoanRepaid(borrower, loanSize, borrowRate, interestOwed);
        hasEnded = true;
    }
    function returnLoanSize() public view returns(uint) {
        return loanSize;
    }
}

































