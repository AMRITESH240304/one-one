import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../app/app_config.dart';

class AppDatabase {
  const AppDatabase._();

  static FirebaseDatabase? _instance;

  static FirebaseDatabase instance() {
    return _instance ??= _create();
  }

  static FirebaseDatabase _create() {
    final database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: AppConfig.firebaseDatabaseUrl,
    );
    database.setPersistenceEnabled(true);
    return database;
  }
}
