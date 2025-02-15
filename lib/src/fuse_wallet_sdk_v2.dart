import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fuse_wallet_sdk/fuse_wallet_sdk.dart';
import 'package:web3dart/crypto.dart';

import 'package:fuse_wallet_sdk/src/modules/modules.dart';
import 'package:web3dart/json_rpc.dart';

/// The main SDK class for interacting with FuseBox.
///
/// Provides methods for wallet interaction, calling contracts, and managing tokens.
class FuseSDK {
  /// Creates a new instance of the SDK.
  ///
  /// [publicApiKey] is required to authenticate with the Fuse API.
  FuseSDK(
    String publicApiKey,
  ) : _dio = Dio(
          BaseOptions(
            baseUrl: Uri.https(Variables.BASE_URL, '/api').toString(),
            headers: {
              'Content-Type': 'application/json',
            },
            queryParameters: {
              'apiKey': publicApiKey,
            },
          ),
        ) {
    _initializeModules();
  }

  final _feeTooLowError = 'fee too low';

  /// Default transaction options.
  static final TxOptions defaultTxOptions = TxOptions(
    feePerGas: '1000000',
    feeIncrementPercentage: 10,
    withRetry: false,
  );

  late String _jwtToken;

  late final EtherspotWallet wallet;

  late final IClient client;

  final Dio _dio;

  late ExplorerModule _explorerModule;
  late TradeModule _tradeModule;
  late StakingModule _stakingModule;
  late NftModule _nftModule;

  /// Provides access to the explorer module.
  ExplorerModule get explorerModule => _explorerModule;

  /// Provides access to the trade module.
  TradeModule get tradeModule => _tradeModule;

  /// Provides access to the staking module.
  StakingModule get stakingModule => _stakingModule;

  /// Provides access to the NFT module.
  NftModule get nftModule => _nftModule;

  /// Initializes the modules.
  void _initializeModules() {
    _tradeModule = TradeModule(_dio);
    _explorerModule = ExplorerModule(_dio);
    _stakingModule = StakingModule(_dio);
    _nftModule = NftModule(_dio);
  }

  /// Initializes the SDK.
  ///
  /// [publicApiKey] is required to authenticate with the Fuse API.
  /// [credentials] are the Ethereum private key credentials.
  /// [withPaymaster] indicates if the paymaster should be used.
  /// [paymasterContext] provides additional context for the paymaster.
  /// [opts] are the preset builder options.
  /// [clientOpts] are the client options.
  static Future<FuseSDK> init(
    String publicApiKey,
    EthPrivateKey credentials, {
    bool withPaymaster = false,
    Map<String, dynamic>? paymasterContext,
    IPresetBuilderOpts? opts,
    IClientOpts? clientOpts,
  }) async {
    final fuseSDK = FuseSDK(publicApiKey);

    UserOperationMiddlewareFn? paymasterMiddleware;
    if (withPaymaster) {
      paymasterMiddleware = _getPaymasterMiddleware(
        publicApiKey,
        paymasterContext,
      );
    }

    fuseSDK.wallet = await _initializeWallet(
      credentials,
      publicApiKey,
      opts,
      paymasterMiddleware,
    );

    await fuseSDK.authenticate(credentials);

    fuseSDK.client = await Client.init(
      _getBundlerRpc(publicApiKey),
      opts: clientOpts,
    );

    return fuseSDK;
  }

  /// Authenticates the user using the provided private key [credentials].
  ///
  /// Returns a JWT token upon successful authentication.
  Future<String> authenticate(EthPrivateKey credentials) async {
    final AuthDto auth = SmartWalletAuth.signer(
      credentials,
      smartWalletAddress: wallet.getSender(),
    );
    final Response response = await _dio.post(
      '/v2/smart-wallets/auth',
      data: auth.toJson(),
    );
    _jwtToken = response.data['jwt'];
    return response.data['jwt'];
  }

  /// Transfers a specified [amount] of tokens from the user's address to the [recipientAddress].
  ///
  /// [tokenAddress] - Address of the token contract.
  /// [recipientAddress] - Address of the recipient.
  /// [amount] - Amount of tokens to transfer.
  /// [options] - Additional transaction options.
  Future<ISendUserOperationResponse> transferToken(
    EthereumAddress tokenAddress,
    EthereumAddress recipientAddress,
    BigInt amount, [
    TxOptions? options,
  ]) async {
    Call call;
    if (_isNativeToken(tokenAddress.toString())) {
      call = Call(
        to: recipientAddress,
        value: amount,
        data: Uint8List(0),
      );
    } else {
      final callData = ContractsUtils.encodeERC20TransferCall(
        tokenAddress,
        recipientAddress,
        amount,
      );

      call = Call(
        to: tokenAddress,
        value: BigInt.zero,
        data: callData,
      );
    }

    return _executeUserOperation(call, options);
  }

  /// Transfers an NFT with a given [tokenId] to the [recipientAddress].
  ///
  /// [nftContractAddress] - Address of the NFT contract.
  /// [recipientAddress] - Address of the recipient.
  /// [tokenId] - ID of the token to transfer.
  /// [options] - Additional transaction options.
  Future<ISendUserOperationResponse> transferNFT(
    EthereumAddress nftContractAddress,
    EthereumAddress recipientAddress,
    num tokenId, [
    TxOptions? options,
  ]) {
    return _executeTokenOperation(
      nftContractAddress,
      recipientAddress,
      BigInt.from(tokenId),
      ContractsUtils.encodeERC721SafeTransferCall,
      options,
    );
  }

  /// Executes a batch of calls in a single transaction.
  ///
  /// [calls] is a list of calls to be executed.
  /// [options] provides additional transaction options.
  Future<ISendUserOperationResponse> executeBatch(
    List<Call> calls, [
    TxOptions? options,
  ]) async {
    options ??= defaultTxOptions;
    final initialFee = BigInt.parse(options.feePerGas);
    setWalletFees(initialFee);

    try {
      final userOp = await wallet.executeBatch(calls);

      return await client.sendUserOperation(userOp);
    } on RPCError catch (e) {
      if (e.message.contains(_feeTooLowError) && options.withRetry) {
        final increasedFee = _increaseFeeByPercentage(
          initialFee,
          options.feeIncrementPercentage,
        );
        setWalletFees(increasedFee);

        try {
          final userOpRetry = await wallet.executeBatch(calls);

          return await client.sendUserOperation(userOpRetry);
        } catch (e) {
          rethrow;
        }
      } else {
        rethrow;
      }
    }
  }

  /// Approves the [spender] to withdraw or transfer a certain [amount] of tokens on behalf of the user's address.
  ///
  /// [tokenAddress] - Address of the token contract.
  /// [spender] - Address which will spend the tokens.
  /// [amount] - Amount of tokens to approve.
  /// [options] - Additional transaction options.
  Future<ISendUserOperationResponse> approveToken(
    EthereumAddress tokenAddress,
    EthereumAddress spender,
    BigInt amount, [
    TxOptions? options,
  ]) {
    return _executeTokenOperation(
      tokenAddress,
      spender,
      amount,
      ContractsUtils.encodeERC20ApproveCall,
      options,
    );
  }

  /// Approves a [spender] to transfer or withdraw a specific NFT [tokenId] on behalf of the user.
  ///
  /// [nftContractAddress] - Address of the token contract.
  /// [spender] - Address which will spend the tokens.
  /// [tokenId] - NFT token ID of item in the collection to approve.
  /// [options] - Additional transaction options.
  Future<ISendUserOperationResponse> approveNFTToken(
    EthereumAddress nftContractAddress,
    EthereumAddress spender,
    BigInt tokenId, [
    TxOptions? options,
  ]) {
    return _executeTokenOperation(
      nftContractAddress,
      spender,
      tokenId,
      ContractsUtils.encodeERC721ApproveCall,
      options,
    );
  }

  /// Calls a contract with the specified parameters.
  ///
  /// This method facilitates direct contract interactions.
  /// [to] is the address of the contract to be called.
  /// [value] is the amount of Ether (in Wei) to be sent with the call.
  /// [data] is the encoded data for the contract call.
  /// [options] provides additional transaction options.
  Future<ISendUserOperationResponse> callContract(
    EthereumAddress to,
    BigInt value,
    Uint8List data, [
    TxOptions? options,
  ]) async {
    return _executeUserOperation(
      Call(
        to: to,
        value: value,
        data: data,
      ),
      options,
    );
  }

  /// Approves a token for spending and then calls a contract.
  ///
  /// This method first approves a certain amount of tokens for a spender and then
  /// makes a contract call. It's commonly used in scenarios like interacting with
  /// DeFi protocols where a token approval is required before making a transaction.
  ///
  /// [tokenAddress] is the address of the ERC20 token to be approved.
  /// [spender] is the address that will be approved to spend the tokens.
  /// [value] is the amount of tokens to be approved for spending.
  /// [callData] is the encoded data for the subsequent contract call after approval.
  /// [options] provides additional transaction options.
  Future<ISendUserOperationResponse> approveTokenAndCallContract(
    EthereumAddress tokenAddress,
    EthereumAddress spender,
    BigInt value,
    Uint8List callData, [
    TxOptions? options,
  ]) async {
    final approveCallData = ContractsUtils.encodeERC20ApproveCall(
      tokenAddress,
      spender,
      value,
    );

    final calls = [
      Call(
        to: tokenAddress,
        value: BigInt.zero,
        data: approveCallData,
      ),
      Call(
        to: spender,
        value: BigInt.zero,
        data: callData,
      ),
    ];

    return executeBatch(calls, options);
  }

  /// Swaps tokens based on the provided [tradeRequestBody].
  ///
  /// This method facilitates token swaps by interacting with the trade module.
  /// [tradeRequestBody] contains details about the token swap, such as the input and output tokens.
  /// [options] provides additional transaction options.
  Future<ISendUserOperationResponse> swapTokens(
    TradeRequestBody tradeRequestBody, [
    TxOptions? options,
  ]) async {
    final swapCallParameters = await _tradeModule.requestParameters(
      tradeRequestBody,
    );

    final spender = EthereumAddress.fromHex(
      swapCallParameters.data?.rawTxn['to'],
    );

    final callData = hexToBytes(swapCallParameters.data?.rawTxn['data']);

    final tokenDetails = await getERC20TokenDetails(
      EthereumAddress.fromHex(tradeRequestBody.currencyIn),
    );

    final amount = AmountFormat.toBigInt(
      tradeRequestBody.amountIn,
      tokenDetails.decimals,
    );

    return _processOperation(
      tokenAddress: EthereumAddress.fromHex(tradeRequestBody.currencyIn),
      spender: spender,
      callData: callData,
      amount: amount,
      options: options,
    );
  }

  /// Stakes tokens based on the provided [stakeRequestBody].
  ///
  /// This method facilitates token staking by interacting with the staking module.
  /// [stakeRequestBody] contains details about the token staking, such as the token address and amount.
  /// [options] provides additional transaction options.
  Future<ISendUserOperationResponse> stakeToken(
    StakeRequestBody stakeRequestBody, [
    TxOptions? options,
  ]) async {
    final response = await _stakingModule.stake(stakeRequestBody);
    _handleModuleError(response);

    final tokenDetails = await getERC20TokenDetails(
      EthereumAddress.fromHex(stakeRequestBody.tokenAddress),
    );

    final amount = AmountFormat.toBigInt(
      stakeRequestBody.tokenAmount,
      tokenDetails.decimals,
    );
    final stakeCallData = hexToBytes(
      response.data!.encodedABI,
    );

    final spender = EthereumAddress.fromHex(
      response.data!.contractAddress,
    );

    return _processOperation(
      tokenAddress: EthereumAddress.fromHex(stakeRequestBody.tokenAddress),
      spender: spender,
      callData: stakeCallData,
      amount: amount,
      options: options,
    );
  }

  /// Unstakes tokens based on the provided [unstakeRequestBody].
  ///
  /// This method facilitates token unstaking by interacting with the staking module.
  /// [unstakeRequestBody] contains details about the token unstaking, such as the token address and amount.
  /// [unStakeTokenAddress] is the address of the unstake token contract.
  /// [options] provides additional transaction options.
  Future<ISendUserOperationResponse> unstakeToken(
    UnstakeRequestBody unstakeRequestBody,
    EthereumAddress unStakeTokenAddress, [
    TxOptions? options,
  ]) async {
    final response = await _stakingModule.unstake(unstakeRequestBody);
    _handleModuleError(response);

    final tokenDetails = await getERC20TokenDetails(
      EthereumAddress.fromHex(unstakeRequestBody.tokenAddress),
    );

    final amount = AmountFormat.toBigInt(
      unstakeRequestBody.tokenAmount,
      tokenDetails.decimals,
    );

    final spender = EthereumAddress.fromHex(
      response.data!.contractAddress,
    );

    final unstakeCallData = hexToBytes(response.data!.encodedABI);

    return _processOperation(
      tokenAddress: unStakeTokenAddress,
      spender: spender,
      callData: unstakeCallData,
      amount: amount,
      options: options,
    );
  }

  Future<BigInt> _getNativeBalance(
    EthereumAddress address,
  ) async {
    final web3client = wallet.proxy.client;
    final etherAmount = await web3client.getBalance(address);

    return etherAmount.getInWei;
  }

  /// Retrieves the balance of a specified address for a given token.
  ///
  /// This method fetches the balance of an address. If the token is native, it retrieves
  /// the native balance. Otherwise, it fetches the balance of the ERC20 token using the
  /// `balanceOf` function of the token's contract.
  ///
  /// [tokenAddress] is the address of the token (either ERC20 or native).
  /// [address] is the address whose balance is to be retrieved.
  ///
  /// Returns a [BigInt] representing the balance of the address for the specified token.
  Future<BigInt> getBalance(
    EthereumAddress tokenAddress,
    EthereumAddress address,
  ) async {
    if (_isNativeToken(address.toString())) {
      return _getNativeBalance(address);
    }

    return ContractsUtils.readFromContractWithFirstResult(
      client: wallet.proxy.client,
      contractName: 'ERC20',
      contractAddress: tokenAddress,
      methodName: 'balanceOf',
      params: [address],
    );
  }

  /// Retrieves the allowance of tokens that a spender is allowed to withdraw from an owner.
  ///
  /// This method checks the amount of tokens that an owner has allowed a spender
  /// to withdraw from their account using the ERC20 `approve` function.
  ///
  /// [tokenAddress] is the address of the ERC20 token.
  /// [spender] is the address of the entity that has been approved to spend the tokens.
  ///
  /// Returns a [BigInt] representing the amount of tokens the spender is allowed to withdraw.
  Future<BigInt> getAllowance(
    EthereumAddress tokenAddress,
    EthereumAddress spender,
  ) {
    return ContractsUtils.readFromContractWithFirstResult(
      client: wallet.proxy.client,
      contractName: 'ERC20',
      contractAddress: tokenAddress,
      methodName: 'allowance',
      params: [
        EthereumAddress.fromHex(wallet.getSender()),
        spender,
      ],
    );
  }

  /// Retrieves detailed information about an ERC20 token.
  ///
  /// This method fetches the name, symbol, and decimals of an ERC20 token using its address.
  /// If the provided [tokenAddress] matches the native token address, it returns a native token with zero amount.
  ///
  /// [tokenAddress] is the address of the ERC20 token.
  ///
  /// Returns a [TokenDetails] object containing the token's name, symbol, decimals, and other relevant details.
  Future<TokenDetails> getERC20TokenDetails(
    EthereumAddress tokenAddress,
  ) async {
    if (tokenAddress.toString().toLowerCase() ==
        Variables.NATIVE_TOKEN_ADDRESS.toLowerCase()) {
      return TokenDetails.native(amount: BigInt.zero);
    }
    final toRead = ['name', 'symbol', 'decimals'];
    final token = await Future.wait(
      toRead.map(
        (function) => ContractsUtils.readFromContract(
          wallet.proxy.client,
          'ERC20',
          tokenAddress,
          function,
          [],
        ),
      ),
    );

    return TokenDetails.fromJson({
      'contractAddress': tokenAddress,
      'name': token[0].first,
      'symbol': token[1].first,
      'decimals': token[2].first.toString(),
      'balance': '0',
      'type': 'ERC-20'
    });
  }

  /// Checks if the given [address] is the native token's address.
  bool _isNativeToken(String address) {
    return address.toLowerCase() ==
        Variables.NATIVE_TOKEN_ADDRESS.toLowerCase();
  }

  /// Increases the transaction fee by a specified [percentage].
  ///
  /// [fee] is the initial fee amount.
  BigInt _increaseFeeByPercentage(BigInt fee, int percentage) {
    return fee + BigInt.from(fee * BigInt.from(percentage) / BigInt.from(100));
  }

  /// Sets the maximum fee per gas and priority fee per gas for the wallet.
  ///
  /// [fee] is the fee amount to be set.
  void setWalletFees(BigInt fee) {
    wallet.setMaxFeePerGas(fee);
    wallet.setMaxPriorityFeePerGas(fee);
  }

  /// Executes a user operation with the provided [call].
  ///
  /// [options] provides additional transaction options.
  Future<ISendUserOperationResponse> _executeUserOperation(
    Call call, [
    TxOptions? options,
  ]) async {
    options ??= defaultTxOptions;
    final initialFee = BigInt.parse(options.feePerGas);
    setWalletFees(initialFee);

    try {
      final userOp = await wallet.execute(call);

      return await client.sendUserOperation(userOp);
    } on RPCError catch (e) {
      if (e.message.contains(_feeTooLowError) && options.withRetry) {
        final increasedFee = _increaseFeeByPercentage(
          initialFee,
          options.feeIncrementPercentage,
        );
        setWalletFees(increasedFee);

        try {
          final userOpRetry = await wallet.execute(call);
          return await client.sendUserOperation(userOpRetry);
        } catch (e) {
          rethrow;
        }
      } else {
        rethrow;
      }
    }
  }

  /// Processes a token operation, either executing it directly or approving and then executing.
  ///
  /// This method checks if the token is native. If it is, it directly executes the operation.
  /// If not, it checks the allowance of the token. If the allowance is sufficient, it executes the operation.
  /// Otherwise, it first approves the token and then executes the operation.
  ///
  /// [tokenAddress] is the address of the token involved in the operation.
  /// [spender] is the address that will spend or receive the tokens.
  /// [callData] is the encoded data for the operation.
  /// [amount] is the amount of tokens involved in the operation.
  /// [options] provides additional transaction options.
  ///
  /// Returns a [ISendUserOperationResponse] indicating the result of the operation.
  Future<ISendUserOperationResponse> _processOperation({
    required EthereumAddress tokenAddress,
    required EthereumAddress spender,
    required Uint8List callData,
    BigInt? amount,
    TxOptions? options,
  }) async {
    if (_isNativeToken(tokenAddress.toString())) {
      return _executeUserOperation(
        Call(
          to: spender,
          value: amount!,
          data: callData,
        ),
        options,
      );
    }

    final tokenAllowance = await getAllowance(tokenAddress, spender);
    if (tokenAllowance >= amount!) {
      return _executeUserOperation(
        Call(
          to: spender,
          value: BigInt.zero,
          data: callData,
        ),
        options,
      );
    } else {
      return approveTokenAndCallContract(
        tokenAddress,
        spender,
        amount,
        callData,
        options,
      );
    }
  }

  Future<ISendUserOperationResponse> _executeTokenOperation(
    EthereumAddress contractAddress,
    EthereumAddress to,
    BigInt value,
    Function encoder, [
    TxOptions? options,
  ]) {
    final callData = encoder(contractAddress, to, value);
    return _executeUserOperation(
      Call(
        to: contractAddress,
        value: BigInt.zero,
        data: callData,
      ),
      options,
    );
  }

  /// Handles errors that may occur during module operations.
  ///
  /// [response] is the response from the module operation.
  void _handleModuleError(DC response) {
    if (response.hasError) {
      throw response.error!;
    }
  }

  /// Retrieves the paymaster middleware for the provided [publicApiKey].
  ///
  /// [paymasterContext] provides additional context for the paymaster.
  static UserOperationMiddlewareFn? _getPaymasterMiddleware(
    String publicApiKey,
    Map<String, dynamic>? paymasterContext,
  ) {
    final paymasterRpc = Uri.https(Variables.BASE_URL, '/api/v0/paymaster', {
      'apiKey': publicApiKey,
    }).toString();

    return verifyingPaymaster(paymasterRpc, paymasterContext ?? {});
  }

  /// Initializes the wallet with the provided parameters.
  ///
  /// [credentials] are the private key credentials.
  /// [publicApiKey] is required to authenticate with the Fuse API.
  /// [opts] are the preset builder options.
  /// [paymasterMiddleware] is the middleware for the paymaster.
  static Future<EtherspotWallet> _initializeWallet(
    EthPrivateKey credentials,
    String publicApiKey,
    IPresetBuilderOpts? opts,
    UserOperationMiddlewareFn? paymasterMiddleware,
  ) {
    return EtherspotWallet.init(
      credentials,
      _getBundlerRpc(publicApiKey),
      opts: IPresetBuilderOpts()
        ..entryPoint = opts?.entryPoint
        ..salt = opts?.salt
        ..factoryAddress = opts?.factoryAddress
        ..paymasterMiddleware = opts?.paymasterMiddleware ?? paymasterMiddleware
        ..overrideBundlerRpc = opts?.overrideBundlerRpc,
    );
  }

  /// Retrieves the bundler RPC URL for the provided [publicApiKey].
  static String _getBundlerRpc(String publicApiKey) {
    return Uri.https(Variables.BASE_URL, '/api/v0/bundler', {
      'apiKey': publicApiKey,
    }).toString();
  }
}
