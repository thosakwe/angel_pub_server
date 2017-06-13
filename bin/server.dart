import 'dart:async';
import 'dart:io';
import 'package:angel_diagnostics/angel_diagnostics.dart';
import 'package:angel_hot/angel_hot.dart';
import 'package:angel_pub_server/angel_pub_server.dart';

main() {
  runZoned(spawnServer, onError: (e, st) {
    stderr.writeln('Fatal error escaped zone: $e');
    stderr.writeln(st);
  });
}

spawnServer() async {
  HttpServer server;

  if (Platform.environment['ANGEL_ENV'] == 'production') {
    // Not hot-reloading in production
    var app = await createServer();
    await app.configure(logRequests(new File('log.txt')));
    server = await app.startServer(InternetAddress.LOOPBACK_IP_V4, 3000);
  } else {
    var hot = new HotReloader(() async {
      var app = await createServer();
      await app.configure(logRequests(new File('log.txt')));
      return app;
    }, [new Directory('lib'), new File('pubspec.lock')]);
    server = await hot.startServer(InternetAddress.LOOPBACK_IP_V4, 3000);
  }

  print(
      'Angel pub server listening at http://${server.address.address}:${server.port}');
}
