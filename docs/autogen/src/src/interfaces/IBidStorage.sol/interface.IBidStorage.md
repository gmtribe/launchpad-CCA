# IBidStorage
[Git Source](https://github.com/Uniswap/twap-auction/blob/eddb06d9f9e6a95363d90d7326e355d98c8b0712/src/interfaces/IBidStorage.sol)


## Functions
### nextBidId

Get the id of the next bid to be created


```solidity
function nextBidId() external view returns (uint256);
```

### bids

Get a bid from storage


```solidity
function bids(uint256 bidId) external view returns (Bid memory);
```

