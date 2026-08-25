/// Growable copy of [source] (or a new empty map).
///
/// Dart `const {}`, [Map.unmodifiable], method-channel `.cast()` views, and
/// Zone value maps throw `Unsupported operation: Cannot modify unmodifiable
/// map` on write. Firebase plugins (`setDefaults`, `logEvent`) and our own
/// prune/mark paths write in place — always copy before those calls, and
/// before passing a map into [runZonedGuarded] / [Zone.fork] `zoneValues`
/// (those maps are unmodifiable by design).
Map<K, V> mutableMapOf<K, V>([Map<K, V>? source]) {
  return Map<K, V>.of(source ?? <K, V>{});
}
