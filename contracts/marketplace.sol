//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract CompodeMarketplace is
   ERC721URIStorage, Ownable, AccessControl, ReentrancyGuard
{
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    using Counters for Counters.Counter;
    //_tokenIds variable has the most recent minted tokenId
    Counters.Counter private _tokenIds;
    //Keeps track of the number of items sold on the marketplace
    Counters.Counter private _itemsSold;
    //owner is the contract address that created the smart contract
    //The fee charged by the marketplace to be allowed to list an NFT
    uint256 listPrice = 0.01 ether;
    uint256 public saleFeePercentage = 3;
    uint256 public accruedFees;

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    //The structure to store info about a listed token
    struct ListedToken {
        uint256 tokenId;
        address payable owner;
        address payable seller;
        uint256 price;
        bool currentlyListed;
    }

    //the event emitted when a token is successfully listed
    event TokenListedSuccess(
        uint256 indexed tokenId,
        address owner,
        address seller,
        uint256 price,
        bool currentlyListed
    );

    //This mapping maps tokenId to token info and is helpful when retrieving details about a tokenId
    mapping(uint256 => ListedToken) private idToListedToken;
    //This mapping maps hashes to true or false to say whether or not a code has been verified by our agents
    mapping(bytes32 => bool) private verifiedCodes;

    constructor() ERC721("Compode Marketplace", "COM") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(VERIFIER_ROLE, msg.sender);
    }

    modifier onlyVerifier() {
        require(hasRole(VERIFIER_ROLE, msg.sender), "Caller is not a verifier");
        _;
    }

    function grantVerifierRole(
        address account
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(VERIFIER_ROLE, account);
    }

    function revokeVerifierRole(
        address account
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(VERIFIER_ROLE, account);
    }

    function updateSaleFeePercentage(
        uint256 newFeePercentage
    ) public onlyOwner {
        require(newFeePercentage <= 100, "Fee percentage cannot exceed 100");
        saleFeePercentage = newFeePercentage;
    }

    function updateListPrice(uint256 _listPrice) public payable {
        require(payable(owner()) == msg.sender, "Only owner can update listing price");
        listPrice = _listPrice;
    }

    function getListPrice() public view returns (uint256) {
        return listPrice;
    }

    function getLatestIdToListedToken()
        public
        view
        returns (ListedToken memory)
    {
        uint256 currentTokenId = _tokenIds.current();
        return idToListedToken[currentTokenId];
    }

    function getListedTokenForId(
        uint256 tokenId
    ) public view returns (ListedToken memory) {
        return idToListedToken[tokenId];
    }

    function getCurrentToken() public view returns (uint256) {
        return _tokenIds.current();
    }

    //The first time a token is created, it is listed here
    function createToken(
        string memory tokenURI,
        uint256 price,
        bytes32 codeHash
    ) public payable returns (uint) {
        //Require the codehash provided to be verified, or else cancel the token creation
        require(verifiedCodes[codeHash], "Code is not verified");
        //Increment the tokenId counter, which is keeping track of the number of minted NFTs
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

        //Mint the NFT with tokenId newTokenId to the address who called createToken
        _safeMint(msg.sender, newTokenId);

        //Map the tokenId to the tokenURI (which is an IPFS URL with the NFT metadata)
        _setTokenURI(newTokenId, tokenURI);

        //Helper function to update Global variables and emit an event
        createListedToken(newTokenId, price);

        return newTokenId;
    }

    function createListedToken(uint256 tokenId, uint256 price) private {
        //Make sure the sender sent enough ETH to pay for listing
        require(msg.value == listPrice, "Hopefully sending the correct price");
        //Just sanity check
        require(price > 0, "Make sure the price isn't negative");

        //Update the mapping of tokenId's to Token details, useful for retrieval functions
        idToListedToken[tokenId] = ListedToken(
            tokenId,
            payable(address(this)),
            payable(msg.sender),
            price,
            true
        );

        _transfer(msg.sender, address(this), tokenId);
        //Emit the event for successful transfer. The frontend parses this message and updates the end user
        emit TokenListedSuccess(
            tokenId,
            address(this),
            msg.sender,
            price,
            true
        );
    }

    //This will return all the Code snippets currently listed to be sold on the marketplace
    function getAllCodeSnippets() public view returns (ListedToken[] memory) {
        uint nftCount = _tokenIds.current();
        ListedToken[] memory tokens = new ListedToken[](nftCount);
        uint currentIndex = 0;
        uint currentId;
        //at the moment currentlyListed is true for all, if it becomes false in the future we will
        //filter out currentlyListed == false over here
        for (uint i = 0; i < nftCount; i++) {
            currentId = i + 1;
            ListedToken storage currentItem = idToListedToken[currentId];
            tokens[currentIndex] = currentItem;
            currentIndex += 1;
        }
        //the array 'tokens' has the list of all NFTs in the marketplace
        return tokens;
    }

    //Returns all the NFTs that the current user is owner or seller in
    function getMyCodeSnippets() public view returns (ListedToken[] memory) {
        uint totalItemCount = _tokenIds.current();
        uint itemCount = 0;
        uint currentIndex = 0;
        uint currentId;
        //Important to get a count of all the NFTs that belong to the user before we can make an array for them
        for (uint i = 0; i < totalItemCount; i++) {
            if (
                idToListedToken[i + 1].owner == msg.sender ||
                idToListedToken[i + 1].seller == msg.sender
            ) {
                itemCount += 1;
            }
        }

        //Once you have the count of relevant NFTs, create an array then store all the NFTs in it
        ListedToken[] memory items = new ListedToken[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (
                idToListedToken[i + 1].owner == msg.sender ||
                idToListedToken[i + 1].seller == msg.sender
            ) {
                currentId = i + 1;
                ListedToken storage currentItem = idToListedToken[currentId];
                items[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        return items;
    }

    //This function ensures 1 to many sales of a code snippet without the ownership right to the purchaser
    function executeWeb2Sale(
        uint256 tokenId,
        address payable seller,
        uint price
    ) public payable nonReentrant {
        // Calculate the marketplace fee, which is 3% of the sale price
        uint256 marketFee = (price * saleFeePercentage) / 100;
        require(
            msg.value == price + marketFee,
            "Please submit the asking price plus marketplace fee to complete the purchase"
        );
        _itemsSold.increment();
        // Actually transfer the token to the new owner
        _transfer(address(this), msg.sender, tokenId);
        // Approve the marketplace to sell NFTs on your behalf
        approve(address(this), tokenId);

        // Transfer the marketplace fee to the contract balance (accrued fees)
        accruedFees += marketFee;
        // Transfer the proceeds from the sale to the seller of the NFT, minus the marketplace fee
        seller.transfer(msg.value - marketFee);
    }

    //This function ensures 1 to 1 sales with the right to ownership on the platform. Once sold, only the purchaser will have the code
    function executeSale(uint256 tokenId) public payable nonReentrant {
        uint price = idToListedToken[tokenId].price;
        address payable seller = idToListedToken[tokenId].seller;
        // Calculate the marketplace fee, which is 3% of the sale price
        uint256 marketFee = (price * saleFeePercentage) / 100;
        require(
            msg.value == price + marketFee,
            "Please submit the asking price plus marketplace fee to complete the purchase"
        );
        // Update the details of the token
        idToListedToken[tokenId].currentlyListed = true;
        idToListedToken[tokenId].seller = payable(msg.sender);
        _itemsSold.increment();

        // Actually transfer the token to the new owner
        _transfer(address(this), msg.sender, tokenId);
        // Approve the marketplace to sell NFTs on your behalf
        approve(address(this), tokenId);

        // Transfer the marketplace fee to the contract balance (accrued fees)
        accruedFees += marketFee;
        // Transfer the proceeds from the sale to the seller of the NFT, minus the marketplace fee
        seller.transfer(msg.value - marketFee);
    }

    function withdrawFees() external onlyOwner nonReentrant {
        require(accruedFees > 0, "No fees to withdraw");
        uint256 fees = accruedFees;
        accruedFees = 0;
        payable(owner()).transfer(fees);
    }
}