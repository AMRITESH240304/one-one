import 'package:one_one_app/one_one.dart';

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
