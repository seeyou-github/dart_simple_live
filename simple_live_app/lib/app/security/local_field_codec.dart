/// 配置文件中少量敏感字段（WebDAV 地址 / 账号 / 密码）的本地编码工具。
///
/// 只是初级防护：让本地设置、导出的配置文件、同步到云端的配置文件里
/// 不出现可直接阅读的明文，不作为真正的安全边界。
///
/// 编码结果带固定前缀，用于区分「已编码」和「原样保存」的旧数据，
/// 因此旧版本存下的明文仍能正常读取。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// 编码结果的前缀，用来区分「已编码」和「原样保存」的字段。
const String _tag = 'sl1:';

/// 密钥片段：逐位掩码存放，源码 / 二进制里不会出现密钥原文。
const List<int> _fragments = [
  0x08,
  0x1B,
  0xE4,
  0xD0,
  0xDB,
  0xAB,
  0xA9,
  0x95,
  0x65,
  0x4F,
  0x6C,
  0x1B,
  0x00,
  0xE8,
  0xFB,
  0xDD,
  0xAC,
  0xCF,
  0x8F,
  0x21,
];

enc.Encrypter? _cipher;

enc.Encrypter get _encrypter {
  var cached = _cipher;
  if (cached != null) {
    return cached;
  }
  var text = String.fromCharCodes([
    for (var i = 0; i < _fragments.length; i++)
      _fragments[i] ^ ((0x5B + i * 23) & 0xFF),
  ]);
  var key = sha256.convert(utf8.encode(text)).bytes;
  var created = enc.Encrypter(
    enc.AES(enc.Key(Uint8List.fromList(key)), mode: enc.AESMode.cbc),
  );
  _cipher = created;
  return created;
}

/// 该值是否已被本工具编码过。
bool isSealedField(String value) => value.startsWith(_tag);

/// 把明文编码成可以写进配置文件的文本；空值仍然是空串。
///
/// 每次都会用新的随机 IV，同样的明文得到的密文不同。
String sealField(String plain) {
  if (plain.isEmpty) {
    return '';
  }
  var iv = enc.IV.fromSecureRandom(16);
  var body = _encrypter.encrypt(plain, iv: iv);
  var bytes = Uint8List(16 + body.bytes.length)
    ..setRange(0, 16, iv.bytes)
    ..setRange(16, 16 + body.bytes.length, body.bytes);
  return '$_tag${base64Url.encode(bytes)}';
}

/// 还原 [sealField] 的结果。
///
/// 不带本工具前缀的值（旧版本明文）原样返回；内容损坏时返回空串，
/// 避免一条坏字段让整份配置读不出来。
String unsealField(String stored) {
  if (!isSealedField(stored)) {
    return stored;
  }
  try {
    var bytes = base64Url.decode(stored.substring(_tag.length));
    if (bytes.length <= 16) {
      return '';
    }
    var iv = enc.IV(Uint8List.sublistView(bytes, 0, 16));
    var body = enc.Encrypted(Uint8List.sublistView(bytes, 16));
    return _encrypter.decrypt(body, iv: iv);
  } catch (_) {
    return '';
  }
}
