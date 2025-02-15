import 'dart:io';
import 'dart:typed_data';

import 'package:fuse_wallet_sdk/fuse_wallet_sdk.dart';

void main() async {
  final credentials = EthPrivateKey.fromHex('WALLET_PRIVATE_KEY');
  // Create a project: https://developers.fuse.io
  final publicApiKey = 'YOUR_PUBLIC_API_KEY';
  final fuseSDK = await FuseSDK.init(
    publicApiKey,
    credentials,
  );

  final res = await fuseSDK.executeBatch(
    [
      // Transfer Native Token call
      Call(
        to: EthereumAddress.fromHex('TARGET_ADDRESS'),
        value: BigInt.parse('AMOUNT_IN_WEI'),
        data: Uint8List(0),
      ),
      // Transfer ERC20 Token call
      Call(
        to: EthereumAddress.fromHex('TOKEN_ADDRESS'),
        value: BigInt.zero,
        data: ContractsUtils.encodeERC20TransferCall(
          EthereumAddress.fromHex('TOKEN_ADDRESS'),
          EthereumAddress.fromHex('RECIPIENT_ADDRESS'),
          BigInt.parse('AMOUNT_IN_WEI'),
        ),
      ),
    ],
  );
  print('UserOpHash: ${res.userOpHash}');

  print('Waiting for transaction...');
  final ev = await res.wait();
  print('Transaction hash: ${ev?.transactionHash}');
  exit(1);
}
