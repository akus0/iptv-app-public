import 'package:cached_network_image/cached_network_image.dart';
// `file`'s own `FileSystem` isn't used here — just `File`/`LocalFileSystem`
// — and it collides with flutter_cache_manager's identically-named
// abstract class below, which is the one actually being implemented.
import 'package:file/file.dart' hide FileSystem;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Store [CachedNetworkImage] files and their index in persistent storage. OS eviction
/// of temporary files must not silently invalidate an otherwise persistent index.
final CacheManager persistentImageCacheManager = CacheManager(
  Config('noxplayer_posters',
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: 1500,
      fileSystem: _PersistentFileSystem('noxplayer_posters')),
);

/// Identical to `flutter_cache_manager`'s own default `IOFileSystem`,
/// except rooted at [getApplicationSupportDirectory] instead of
/// [getTemporaryDirectory] — see this file's doc comment for why that's
/// the one thing that actually needed to change.
class _PersistentFileSystem implements FileSystem {
  _PersistentFileSystem(this._cacheKey)
      : _fileDir = _createDirectory(_cacheKey);

  final String _cacheKey;
  final Future<Directory> _fileDir;

  static Future<Directory> _createDirectory(String key) async {
    final baseDir = await getApplicationSupportDirectory();
    final path = p.join(baseDir.path, key);
    const fs = LocalFileSystem();
    final directory = fs.directory(path);
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<File> createFile(String name) async {
    final directory = await _fileDir;
    if (!(await directory.exists())) {
      await _createDirectory(_cacheKey);
    }
    return directory.childFile(name);
  }
}
