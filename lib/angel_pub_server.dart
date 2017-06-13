import 'dart:async';
import 'dart:io';
import 'package:angel_common/angel_common.dart';
import 'package:angel_shelf/angel_shelf.dart';
import 'package:http/http.dart' as http;
import 'package:pub_server/repository.dart';
import 'package:pub_server/shelf_pubserver.dart';
import 'package:yaml/yaml.dart';
import 'src/repo/cow.dart';
import 'src/repo/http_proxy.dart';
import 'src/repo/repo.dart';
import 'src/services/json_file.dart';

Uri baseUrl = Uri.parse('http://localhost:3000');

Future<Angel> createServer() async {
  var app = new Angel();

  // Create package root
  var packageRoot = new Directory('hosted_packages');
  if (!await packageRoot.exists()) await packageRoot.create(recursive: true);

  // Create two services. Not using `use`, because they are "secret" services.
  //
  // In real life, I would use MongoDB or something, but not everybody has that, so I'll just
  // use a filesystem-backed service.
  app.services['api/packages'] =
      new JsonFileService(new File('packages_db.json'));
  app.services['api/versions'] =
      new JsonFileService(new File('versions_db.json'));

  // Setup package repo
  var virtualRepo = new VirtualPackageRepository(
      app.service('api/packages'), app.service('api/versions'), packageRoot);
  var proxyRepo = new HttpProxyRepository(
      new http.Client(), Uri.parse('https://pub.dartlang.org'));
  var cow = new CopyAndWriteRepository(virtualRepo, proxyRepo, false);
  await app.configure(pubApi(cow));

  // Error handling
  var errors = new ErrorHandler(handlers: {
    404: (RequestContext req, ResponseContext res) => res
        .write('No file exists at "${req.uri}". ${req.error?.message ?? ""}'),
    500: (RequestContext req, ResponseContext res) =>
        res.write('Whoops! Something went wrong: ${req.error?.message ?? "Internal Server Error"}')
  });

  errors.fatalErrorHandler = (AngelFatalError e) async {
    try {
      e.request.response.statusCode = HttpStatus.INTERNAL_SERVER_ERROR;
      e.request.response.write('Fatal error occurred');
      await e.request.response.close();
      stderr..writeln('Recovered fatal error: ${e.error}')..writeln(e.stack);
    } catch (_) {
      stderr..writeln('Totally fatal error: ${e.error}')..writeln(e.stack);
    }
  };

  // 404
  app.after.add(errors.throwError());
  app.after.add(errors.middleware);
  await app.configure(errors);

  // Add GZIP compression
  app.responseFinalizers.add(gzip());

  return app;
}

AngelConfigurer pubApi(PackageRepository repo) {
  return (Angel app) async {
    // Patch up `shelf_pubserver` routes that crash the *entire* application!!?!?!?!?!
    app.get('/api/packages/:packageId', (String packageId) async {
      var versions = await repo.versions(packageId).toList();
      if (versions.isEmpty)
        throw new AngelHttpException.notFound(
            message: 'No versions of "$packageId" available.');
      else {
        versions.sort((a, b) => a.version.compareTo(b.version));
        var latestVersion = versions.last;
        for (int i = versions.length - 1; i >= 0; i--) {
          if (!versions[i].version.isPreRelease) {
            latestVersion = versions[i];
            break;
          }
        }

        Map packageVersion2Json(PackageVersion version) {
          return {
            'archive_url': '${_downloadUrl(
                baseUrl, version.packageName, version.versionString)}',
            'pubspec': loadYaml(version.pubspecYaml),
            'version': version.versionString,
          };
        }

        return {
          'name': packageId,
          'latest': packageVersion2Json(latestVersion),
          'versions': versions.map(packageVersion2Json).toList(),
        };
      }
    });

    // Don't bother re-inventing the wheel when we can embed `shelf` right in...
    var server = new ShelfPubServer(repo);
    app.after.add(embedShelf(server.requestHandler));
  };
}

Uri _downloadUrl(Uri url, String package, String version) {
  var encode = Uri.encodeComponent;
  return url.resolve(
      '/packages/${encode(package)}/versions/${encode(version)}.tar.gz');
}
