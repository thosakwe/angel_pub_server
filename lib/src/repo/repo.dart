import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart';
import 'package:archive/archive.dart';
import 'package:pub_server/repository.dart';
import 'package:yaml/yaml.dart';

class VirtualPackageRepository extends PackageRepository {
  final Service packageService, versionService;
  final Directory root;

  VirtualPackageRepository(this.packageService, this.versionService, this.root);

  @override
  bool get supportsUpload => true;

  File _resolveVersionToPubspec(String package, Map<String, dynamic> version) {
    var versionString = version['versionString'] as String;
    var directory =
        new Directory.fromUri(root.uri.resolve('$package/$versionString'));
    return new File.fromUri(directory.uri.resolve('pubspec.yaml'));
  }

  File _resolveVersionToTarball(String package, Map<String, dynamic> version) {
    var versionString = version['versionString'] as String;
    var directory =
        new Directory.fromUri(root.uri.resolve('$package/$versionString'));
    return new File.fromUri(directory.uri.resolve('$package-$versionString.tar.gz'));
  }

  Future<PackageVersion> _resolveVersion(
      String package, Map<String, dynamic> version) async {
    // Resolve all versions from the database into actual `PackageVersion` instances.
    var pubspec = _resolveVersionToPubspec(package, version);
    var versionString = version['versionString'] as String;

    try {
      if (await pubspec.exists()) {
        return new PackageVersion(
            package, versionString, await pubspec.readAsString());
      }

      return null;
    } catch(e) {
      return null;
    }
  }

  @override
  Future<Stream> download(String package, String version) {
    return packageService
        .read(package)
        .then((Map<String, dynamic> packageInfo) async {
      // See if the version even exists...
      Iterable<Map<String, dynamic>> versions = await versionService.index({
        'query': {'packageId': package, 'versionString': version}
      });

      if (versions.isEmpty) return null;
      var file = _resolveVersionToTarball(package, versions.first);
      if (!await file.exists()) return null;
      return file.openRead();
    }).catchError((_) => null);
  }

  @override
  Future<PackageVersion> lookupVersion(String package, String version) {
    return packageService
        .read(package)
        .then((Map<String, dynamic> packageInfo) async {
      // Fetch eligible package versions via query
      Iterable<Map<String, dynamic>> versions = await versionService.index({
        'query': {'packageId': package, 'versionString': version}
      });

      if (versions.isEmpty) return null;
      return await _resolveVersion(package, versions.first);
    }).catchError((_) => null);
  }

  @override
  Stream<PackageVersion> versions(String package) {
    var ctrl = new StreamController<PackageVersion>();

    // First, ensure the package exists.
    packageService.read(package).then((Map<String, dynamic> packageInfo) async {
      // Then, just fetch package versions.
      Iterable<Map<String, dynamic>> versions = await versionService.index({
        'query': {'packageId': package}
      });

      for (var version in versions) {
        // Resolve all versions from the database into actual `PackageVersion` instances.
        var resolved = await _resolveVersion(package, version);
        if (resolved != null) ctrl.add(resolved);
      }

      ctrl.close();
    }).catchError((_) {
      ctrl.close();
    });

    return ctrl.stream;
  }

  @override
  Future<PackageVersion> upload(Stream<List<int>> data) async {
    var bb =
        await data.fold<BytesBuilder>(new BytesBuilder(), (b, d) => b..add(d));
    var tarballBytes = bb.takeBytes();
    var tarBytes = new GZipDecoder().decodeBytes(tarballBytes);
    var archive = new TarDecoder().decodeBytes(tarBytes);
    ArchiveFile pubspecArchiveFile;

    for (var file in archive.files) {
      if (file.name == 'pubspec.yaml') {
        pubspecArchiveFile = file;
        break;
      }
    }

    if (pubspecArchiveFile == null)
      throw new AngelHttpException.badRequest(
          message: 'No "pubspec.yaml" file in uploaded archive.');

    var pubspecString = UTF8.decode(pubspecArchiveFile.content);
    var pubspec = loadYaml(pubspecString);

    var package = pubspec['name'];
    var version = pubspec['version'];
    List<Map<String, String>> authors = [];

    if (pubspec['author'] is String) {
      authors.add(parseAuthor(pubspec['author']));
    } else if (pubspec['authors'] is List) {
      authors.addAll(pubspec['authors'].map(parseAuthor));
    }

    if (authors.isEmpty)
      throw new AngelHttpException.badRequest(
          message: 'No author or authors found in "pubspec.yaml" file.');

    var versionData = {'versionString': version, 'pubspec': pubspec};

    var pubspecFile = _resolveVersionToPubspec(package, versionData);
    var tarballFile = _resolveVersionToTarball(package, versionData);

    await pubspecFile.create(recursive: true);
    await pubspecFile.writeAsBytes(pubspecArchiveFile.content);
    await tarballFile.create(recursive: true);
    await tarballFile.writeAsBytes(tarballBytes);

    // Create database entries
    var pkg = await packageService.create({'id': package, 'authors': authors});
    await versionService.create(versionData..['packageId'] = pkg['id']);

    // Return new version
    return new PackageVersion(package, version, pubspecString);
  }
}

final RegExp _author = new RegExp(r'([^<\n$]+) <([^>\n$]+)>');

Map<String, String> parseAuthor(String str) {
  var m = _author.firstMatch(str);

  if (m != null) {
    return {'name': m[1].trim(), 'email': m[2].trim()};
  }

  return {'name': str};
}
