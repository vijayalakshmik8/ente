import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import 'package:photos/core/errors.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/core/network/network.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/db/trash_db.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/force_reload_home_gallery_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/extensions/list.dart';
import 'package:photos/extensions/stop_watch.dart';
import 'package:photos/models/api/collection/create_request.dart';
import "package:photos/models/api/collection/public_url.dart";
import "package:photos/models/api/collection/user.dart";
import 'package:photos/models/collection.dart';
import 'package:photos/models/collection_file_item.dart';
import 'package:photos/models/collection_items.dart';
import 'package:photos/models/file.dart';
import 'package:photos/models/magic_metadata.dart';
import 'package:photos/services/app_lifecycle_service.dart';
import 'package:photos/services/file_magic_service.dart';
import 'package:photos/services/local_sync_service.dart';
import 'package:photos/services/remote_sync_service.dart';
import 'package:photos/utils/crypto_util.dart';
import 'package:photos/utils/file_download_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CollectionsService {
  static const _collectionSyncTimeKeyPrefix = "collection_sync_time_";
  static const _collectionsSyncTimeKey = "collections_sync_time_x";

  static const int kMaximumWriteAttempts = 5;

  final _logger = Logger("CollectionsService");

  late CollectionsDB _db;
  late FilesDB _filesDB;
  late Configuration _config;
  late SharedPreferences _prefs;

  final _enteDio = NetworkClient.instance.enteDio;
  final _localPathToCollectionID = <String, int>{};
  final _collectionIDToCollections = <int, Collection>{};
  final _cachedKeys = <int, Uint8List>{};
  final _cachedUserIdToUser = <int, User>{};
  Collection? cachedDefaultHiddenCollection;
  Future<List<File>>? _cachedLatestFiles;
  Collection? cachedUncategorizedCollection;

  CollectionsService._privateConstructor() {
    _db = CollectionsDB.instance;
    _filesDB = FilesDB.instance;
    _config = Configuration.instance;
  }

  static final CollectionsService instance =
      CollectionsService._privateConstructor();

  Future<void> init(SharedPreferences preferences) async {
    _prefs = preferences;
    final collections = await _db.getAllCollections();

    for (final collection in collections) {
      _cacheCollectionAttributes(collection);
    }
    Bus.instance.on<LocalPhotosUpdatedEvent>().listen((event) {
      _cachedLatestFiles = null;
      getLatestCollectionFiles();
    });
    Bus.instance.on<CollectionUpdatedEvent>().listen((event) {
      _cachedLatestFiles = null;
      getLatestCollectionFiles();
    });
  }

  Configuration get config => _config;

  Map<int, Collection> get collectionIDToCollections =>
      _collectionIDToCollections;

  FilesDB get filesDB => _filesDB;

  // sync method fetches just sync the collections, not the individual files
  // within the collection.
  Future<void> sync() async {
    _logger.info("Syncing collections");
    final EnteWatch watch = EnteWatch("syncCollection")..start();
    final lastCollectionUpdationTime =
        _prefs.getInt(_collectionsSyncTimeKey) ?? 0;

    // Might not have synced the collection fully
    final fetchedCollections =
        await _fetchCollections(lastCollectionUpdationTime);
    watch.log("remote fetch collections ${fetchedCollections.length}");
    if (fetchedCollections.isEmpty) {
      return;
    }
    final updatedCollections = <Collection>[];
    int maxUpdationTime = lastCollectionUpdationTime;
    final ownerID = _config.getUserID();
    bool fireEventForCollectionDeleted = false;
    for (final collection in fetchedCollections) {
      if (collection.isDeleted) {
        await _filesDB.deleteCollection(collection.id);
        await setCollectionSyncTime(collection.id, null);
        if (_collectionIDToCollections.containsKey(collection.id)) {
          fireEventForCollectionDeleted = true;
        }
      }
      // remove reference for incoming collections when unshared/deleted
      if (collection.isDeleted && ownerID != collection.owner?.id) {
        await _db.deleteCollection(collection.id);
      } else {
        // keep entry for deletedCollection as collectionKey may be used during
        // trash file decryption
        updatedCollections.add(collection);
      }
      maxUpdationTime = collection.updationTime > maxUpdationTime
          ? collection.updationTime
          : maxUpdationTime;
    }
    if (fireEventForCollectionDeleted) {
      Bus.instance.fire(
        LocalPhotosUpdatedEvent(
          List<File>.empty(),
          source: "syncCollectionDeleted",
        ),
      );
    }
    await _updateDB(updatedCollections);
    _prefs.setInt(_collectionsSyncTimeKey, maxUpdationTime);
    watch.logAndReset("till DB insertion ${updatedCollections.length}");
    final collections = await _db.getAllCollections();
    for (final collection in collections) {
      _cacheCollectionAttributes(collection);
    }
    _logger.info("Collections synced");
    watch.log("collection cache refresh");
    if (fetchedCollections.isNotEmpty) {
      Bus.instance.fire(
        CollectionUpdatedEvent(
          null,
          List<File>.empty(),
          "collections_updated",
        ),
      );
    }
  }

  void clearCache() {
    _localPathToCollectionID.clear();
    _collectionIDToCollections.clear();
    cachedDefaultHiddenCollection = null;
    cachedUncategorizedCollection = null;
    _cachedKeys.clear();
  }

  Future<Map<int, int>> getCollectionIDsToBeSynced() async {
    final idsToRemoveUpdateTimeMap =
        await _db.getActiveIDsAndRemoteUpdateTime();
    final result = <int, int>{};
    for (final MapEntry<int, int> e in idsToRemoveUpdateTimeMap.entries) {
      final int cid = e.key;
      final int remoteUpdateTime = e.value;
      if (remoteUpdateTime > getCollectionSyncTime(cid)) {
        result[cid] = remoteUpdateTime;
      }
    }
    return result;
  }

  Set<int> getArchivedCollections() {
    return _collectionIDToCollections.values
        .toList()
        .where((element) => element.isArchived())
        .map((e) => e.id)
        .toSet();
  }

  Future<List<CollectionWithThumbnail>> getArchivedCollectionWithThumb() async {
    final allCollections = await getCollectionsWithThumbnails();
    return allCollections
        .where(
          (c) => c.collection.isArchived() && !c.collection.isHidden(),
        )
        .toList();
  }

  Set<int> getHiddenCollections() {
    return _collectionIDToCollections.values
        .toList()
        .where((element) => element.isHidden())
        .map((e) => e.id)
        .toSet();
  }

  Set<int> collectionsHiddenFromTimeline() {
    return _collectionIDToCollections.values
        .toList()
        .where((element) => element.isHidden() || element.isArchived())
        .map((e) => e.id)
        .toSet();
  }

  int getCollectionSyncTime(int collectionID) {
    return _prefs
            .getInt(_collectionSyncTimeKeyPrefix + collectionID.toString()) ??
        0;
  }

  Future<List<File>> getLatestCollectionFiles() {
    _cachedLatestFiles ??= _filesDB.getLatestCollectionFiles();
    return _cachedLatestFiles!;
  }

  Future<bool> setCollectionSyncTime(int collectionID, int? time) async {
    final key = _collectionSyncTimeKeyPrefix + collectionID.toString();
    if (time == null) {
      return _prefs.remove(key);
    }
    return _prefs.setInt(key, time);
  }

  // getActiveCollections returns list of collections which are not deleted yet
  List<Collection> getActiveCollections() {
    return _collectionIDToCollections.values
        .toList()
        .where((element) => !element.isDeleted)
        .toList();
  }

  User getFileOwner(int userID, int? collectionID) {
    if (_cachedUserIdToUser.containsKey(userID)) {
      return _cachedUserIdToUser[userID]!;
    }
    if (collectionID != null) {
      final Collection? collection = getCollectionByID(collectionID);
      if (collection != null) {
        if (collection.owner?.id == userID) {
          _cachedUserIdToUser[userID] = collection.owner!;
        } else {
          final matchingUser = collection.getSharees().firstWhereOrNull(
                (u) => u.id == userID,
              );
          if (matchingUser != null) {
            _cachedUserIdToUser[userID] = matchingUser;
          }
        }
      }
    }
    return _cachedUserIdToUser[userID] ??
        User(
          id: userID,
          email: "unknown@unknown.com",
        );
  }

  Future<List<CollectionWithThumbnail>> getCollectionsWithThumbnails({
    bool includedOwnedByOthers = false,
    // includeCollabCollections will include collections where the current user
    // is added as a collaborator
    bool includeCollabCollections = false,
  }) async {
    final List<CollectionWithThumbnail> collectionsWithThumbnail = [];
    final usersCollection = getActiveCollections();
    // remove any hidden collection to avoid accidental rendering on UI
    usersCollection.removeWhere((element) => element.isHidden());
    if (!includedOwnedByOthers) {
      final userID = Configuration.instance.getUserID();
      if (includeCollabCollections) {
        usersCollection.removeWhere(
          (c) =>
              (c.owner?.id != userID) &&
              (c.getSharees().any((u) => (u.id ?? -1) == userID && u.isViewer)),
        );
      } else {
        usersCollection.removeWhere((c) => c.owner?.id != userID);
      }
    }
    final latestCollectionFiles = await getLatestCollectionFiles();
    final Map<int, File> collectionToThumbnailMap = Map.fromEntries(
      latestCollectionFiles.map((e) => MapEntry(e.collectionID!, e)),
    );

    for (final c in usersCollection) {
      final File? thumbnail = collectionToThumbnailMap[c.id];
      collectionsWithThumbnail.add(CollectionWithThumbnail(c, thumbnail));
    }
    return collectionsWithThumbnail;
  }

  Future<List<User>> getSharees(int collectionID) {
    return _enteDio.get(
      "/collections/sharees",
      queryParameters: {
        "collectionID": collectionID,
      },
    ).then((response) {
      _logger.info(response.toString());
      final sharees = <User>[];
      for (final user in response.data["sharees"]) {
        sharees.add(User.fromMap(user));
      }
      return sharees;
    });
  }

  Future<List<User>> share(
    int collectionID,
    String email,
    String publicKey,
    CollectionParticipantRole role,
  ) async {
    final encryptedKey = CryptoUtil.sealSync(
      getCollectionKey(collectionID),
      CryptoUtil.base642bin(publicKey),
    );
    try {
      final response = await _enteDio.post(
        "/collections/share",
        data: {
          "collectionID": collectionID,
          "email": email,
          "encryptedKey": CryptoUtil.bin2base64(encryptedKey),
          "role": role.toStringVal()
        },
      );
      final sharees = <User>[];
      for (final user in response.data["sharees"]) {
        sharees.add(User.fromMap(user));
      }
      _collectionIDToCollections[collectionID] =
          _collectionIDToCollections[collectionID]!.copyWith(sharees: sharees);
      unawaited(_db.insert([_collectionIDToCollections[collectionID]!]));
      RemoteSyncService.instance.sync(silently: true).ignore();
      return sharees;
    } on DioError catch (e) {
      if (e.response?.statusCode == 402) {
        throw SharingNotPermittedForFreeAccountsError();
      }
      rethrow;
    }
  }

  Future<List<User>> unshare(int collectionID, String email) async {
    try {
      final response = await _enteDio.post(
        "/collections/unshare",
        data: {
          "collectionID": collectionID,
          "email": email,
        },
      );
      final sharees = <User>[];
      for (final user in response.data["sharees"]) {
        sharees.add(User.fromMap(user));
      }
      _collectionIDToCollections[collectionID] =
          _collectionIDToCollections[collectionID]!.copyWith(sharees: sharees);
      unawaited(_db.insert([_collectionIDToCollections[collectionID]!]));
      RemoteSyncService.instance.sync(silently: true).ignore();
      return sharees;
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<void> trashNonEmptyCollection(
    Collection collection,
  ) async {
    try {
      await _turnOffDeviceFolderSync(collection);
      await _enteDio.delete(
        "/collections/v3/${collection.id}?keepFiles=False&collectionID=${collection.id}",
      );
      await _handleCollectionDeletion(collection);
    } catch (e) {
      _logger.severe('failed to trash collection', e);
      rethrow;
    }
  }

  Future<void> _turnOffDeviceFolderSync(Collection collection) async {
    final deviceCollections = await _filesDB.getDeviceCollections();
    final Map<String, bool> devicePathIDsToUnSync = Map.fromEntries(
      deviceCollections
          .where((e) => e.shouldBackup && e.collectionID == collection.id)
          .map((e) => MapEntry(e.id, false)),
    );

    if (devicePathIDsToUnSync.isNotEmpty) {
      _logger.info(
        'turning off backup status for folders $devicePathIDsToUnSync',
      );
      await RemoteSyncService.instance
          .updateDeviceFolderSyncStatus(devicePathIDsToUnSync);
    }
  }

  Future<void> trashEmptyCollection(
    Collection collection, {
    //  during bulk deletion, this event is not fired to avoid quick refresh
    //  of the collection gallery
    bool isBulkDelete = false,
  }) async {
    try {
      if (!isBulkDelete) {
        await _turnOffDeviceFolderSync(collection);
      }
      // While trashing empty albums, we must pass keepFiles flag as True.
      // The server will verify that the collection is actually empty before
      // deleting the files. If keepFiles is set as False and the collection
      // is not empty, then the files in the collections will be moved to trash.
      await _enteDio.delete(
        "/collections/v3/${collection.id}?keepFiles=True&collectionID=${collection.id}",
      );
      if (isBulkDelete) {
        final deletedCollection = collection.copyWith(isDeleted: true);
        _collectionIDToCollections[collection.id] = deletedCollection;
        unawaited(_db.insert([deletedCollection]));
      } else {
        await _handleCollectionDeletion(collection);
      }
    } on DioError catch (e) {
      if (e.response != null) {
        debugPrint("Error " + e.response!.toString());
      }
      rethrow;
    } catch (e) {
      _logger.severe('failed to trash empty collection', e);
      rethrow;
    }
  }

  Future<void> _handleCollectionDeletion(Collection collection) async {
    await _filesDB.deleteCollection(collection.id);
    final deletedCollection = collection.copyWith(isDeleted: true);
    unawaited(_db.insert([deletedCollection]));
    _collectionIDToCollections[collection.id] = deletedCollection;
    Bus.instance.fire(
      CollectionUpdatedEvent(
        collection.id,
        <File>[],
        "delete_collection",
        type: EventType.deletedFromRemote,
      ),
    );
    sync().ignore();
    LocalSyncService.instance.syncAll().ignore();
  }

  Uint8List getCollectionKey(int collectionID) {
    if (!_cachedKeys.containsKey(collectionID)) {
      final collection = _collectionIDToCollections[collectionID];
      if (collection == null) {
        // Async fetch for collection. A collection might be
        // missing from older clients when we used to delete the collection
        // from db. For trashed files, we need collection data for decryption.
        fetchCollectionByID(collectionID);
        throw AssertionError('collectionID $collectionID is not cached');
      }
      _cachedKeys[collectionID] =
          _getAndCacheDecryptedKey(collection, source: "getCollectionKey");
    }
    return _cachedKeys[collectionID]!;
  }

  Uint8List _getAndCacheDecryptedKey(
    Collection collection, {
    String source = "",
  }) {
    if (_cachedKeys.containsKey(collection.id)) {
      return _cachedKeys[collection.id]!;
    }
    debugPrint(
      "Compute collection decryption key for ${collection.id} source"
      " $source",
    );
    final encryptedKey = CryptoUtil.base642bin(collection.encryptedKey);
    Uint8List? collectionKey;
    if (collection.owner?.id == _config.getUserID()) {
      // If the collection is owned by the user, decrypt with the master key
      if (_config.getKey() == null) {
        // Possible during AppStore account migration, where SecureStorage
        // would become inaccessible to the new Developer Account
        throw Exception("key can not be null");
      }
      collectionKey = CryptoUtil.decryptSync(
        encryptedKey,
        _config.getKey()!,
        CryptoUtil.base642bin(collection.keyDecryptionNonce!),
      );
    } else {
      // If owned by a different user, decrypt with the public key
      collectionKey = CryptoUtil.openSealSync(
        encryptedKey,
        CryptoUtil.base642bin(_config.getKeyAttributes()!.publicKey),
        _config.getSecretKey()!,
      );
    }
    _cachedKeys[collection.id] = collectionKey;
    return collectionKey;
  }

  Future<void> rename(Collection collection, String newName) async {
    try {
      // Note: when collection created to sharing few files is renamed
      // convert that collection to a regular collection type.
      if (collection.isSharedFilesCollection()) {
        await updateMagicMetadata(collection, {"subType": 0});
      }
      final encryptedName = CryptoUtil.encryptSync(
        utf8.encode(newName) as Uint8List,
        getCollectionKey(collection.id),
      );
      await _enteDio.post(
        "/collections/rename",
        data: {
          "collectionID": collection.id,
          "encryptedName": CryptoUtil.bin2base64(encryptedName.encryptedData!),
          "nameDecryptionNonce": CryptoUtil.bin2base64(encryptedName.nonce!)
        },
      );
      collection.setName(newName);
      sync().ignore();
    } catch (e, s) {
      _logger.severe("failed to rename collection", e, s);
      rethrow;
    }
  }

  Future<void> leaveAlbum(Collection collection) async {
    try {
      await _enteDio.post(
        "/collections/leave/${collection.id}",
      );
      await _handleCollectionDeletion(collection);
    } catch (e, s) {
      _logger.severe("failed to leave collection", e, s);
      rethrow;
    }
  }

  Future<void> updateMagicMetadata(
    Collection collection,
    Map<String, dynamic> newMetadataUpdate,
  ) async {
    final int ownerID = Configuration.instance.getUserID()!;
    try {
      if (collection.owner?.id != ownerID) {
        throw AssertionError("cannot modify albums not owned by you");
      }
      // read the existing magic metadata and apply new updates to existing data
      // current update is simple replace. This will be enhanced in the future,
      // as required.
      final Map<String, dynamic> jsonToUpdate =
          jsonDecode(collection.mMdEncodedJson ?? '{}');
      newMetadataUpdate.forEach((key, value) {
        jsonToUpdate[key] = value;
      });

      final key = getCollectionKey(collection.id);
      final encryptedMMd = await CryptoUtil.encryptChaCha(
        utf8.encode(jsonEncode(jsonToUpdate)) as Uint8List,
        key,
      );
      // for required field, the json validator on golang doesn't treat 0 as valid
      // value. Instead of changing version to ptr, decided to start version with 1.
      final int currentVersion = max(collection.mMdVersion, 1);
      final params = UpdateMagicMetadataRequest(
        id: collection.id,
        magicMetadata: MetadataRequest(
          version: currentVersion,
          count: jsonToUpdate.length,
          data: CryptoUtil.bin2base64(encryptedMMd.encryptedData!),
          header: CryptoUtil.bin2base64(encryptedMMd.header!),
        ),
      );
      await _enteDio.put(
        "/collections/magic-metadata",
        data: params,
      );
      // update the local information so that it's reflected on UI
      collection.mMdEncodedJson = jsonEncode(jsonToUpdate);
      collection.magicMetadata = CollectionMagicMetadata.fromJson(jsonToUpdate);
      collection.mMdVersion = currentVersion + 1;
      _collectionIDToCollections[collection.id] = collection;

      // trigger sync to fetch the latest collection state from server
      sync().ignore();
    } on DioError catch (e) {
      if (e.response != null && e.response?.statusCode == 409) {
        _logger.severe('collection magic data out of sync');
        sync().ignore();
      }
      rethrow;
    } catch (e, s) {
      _logger.severe("failed to sync magic metadata", e, s);
      rethrow;
    }
  }

  Future<void> createShareUrl(
    Collection collection, {
    bool enableCollect = false,
  }) async {
    try {
      final response = await _enteDio.post(
        "/collections/share-url",
        data: {
          "collectionID": collection.id,
          "enableCollect": enableCollect,
        },
      );
      collection.publicURLs?.add(PublicURL.fromMap(response.data["result"]));
      await _db.insert(List.from([collection]));
      _collectionIDToCollections[collection.id] = collection;
      Bus.instance.fire(
        CollectionUpdatedEvent(collection.id, <File>[], "shareUrL"),
      );
    } on DioError catch (e) {
      if (e.response?.statusCode == 402) {
        throw SharingNotPermittedForFreeAccountsError();
      }
      rethrow;
    } catch (e, s) {
      _logger.severe("failed to rename collection", e, s);
      rethrow;
    }
  }

  Future<void> updateShareUrl(
    Collection collection,
    Map<String, dynamic> prop,
  ) async {
    prop.putIfAbsent('collectionID', () => collection.id);
    try {
      final response = await _enteDio.put(
        "/collections/share-url",
        data: json.encode(prop),
      );
      // remove existing url information
      collection.publicURLs?.clear();
      collection.publicURLs?.add(PublicURL.fromMap(response.data["result"]));
      await _db.insert(List.from([collection]));
      _collectionIDToCollections[collection.id] = collection;
      Bus.instance
          .fire(CollectionUpdatedEvent(collection.id, <File>[], "updateUrl"));
    } on DioError catch (e) {
      if (e.response?.statusCode == 402) {
        throw SharingNotPermittedForFreeAccountsError();
      }
      rethrow;
    } catch (e, s) {
      _logger.severe("failed to update ShareUrl", e, s);
      rethrow;
    }
  }

  Future<void> disableShareUrl(Collection collection) async {
    try {
      await _enteDio.delete(
        "/collections/share-url/" + collection.id.toString(),
      );
      collection.publicURLs?.clear();
      await _db.insert(List.from([collection]));
      _collectionIDToCollections[collection.id] = collection;
      Bus.instance.fire(
        CollectionUpdatedEvent(
          collection.id,
          <File>[],
          "disableShareUrl",
        ),
      );
    } on DioError catch (e) {
      _logger.info(e);
      rethrow;
    }
  }

  Future<List<Collection>> _fetchCollections(int sinceTime) async {
    try {
      final response = await _enteDio.get(
        "/collections",
        queryParameters: {
          "sinceTime": sinceTime,
          "source": AppLifecycleService.instance.isForeground ? "fg" : "bg",
        },
      );
      final List<Collection> collections = [];
      final c = response.data["collections"];
      for (final collectionData in c) {
        final Collection collection =
            await _fromRemoteCollection(collectionData);
        collections.add(collection);
      }
      return collections;
    } catch (e) {
      if (e is DioError && e.response?.statusCode == 401) {
        throw UnauthorizedError();
      }
      rethrow;
    }
  }

  Future<Collection> _fromRemoteCollection(
    Map<String, dynamic>? collectionData,
  ) async {
    final Collection collection = Collection.fromMap(collectionData);
    if (collectionData != null && collectionData['magicMetadata'] != null) {
      final collectionKey =
          _getAndCacheDecryptedKey(collection, source: "fetchCollection");
      final utfEncodedMmd = await CryptoUtil.decryptChaCha(
        CryptoUtil.base642bin(collectionData['magicMetadata']['data']),
        collectionKey,
        CryptoUtil.base642bin(collectionData['magicMetadata']['header']),
      );
      collection.mMdEncodedJson = utf8.decode(utfEncodedMmd);
      collection.mMdVersion = collectionData['magicMetadata']['version'];
      collection.magicMetadata = CollectionMagicMetadata.fromEncodedJson(
        collection.mMdEncodedJson ?? '{}',
      );
    }
    return collection;
  }

  Collection? getCollectionByID(int collectionID) {
    return _collectionIDToCollections[collectionID];
  }

  Future<Collection> createAlbum(String albumName) async {
    final collectionKey = CryptoUtil.generateKey();
    final encryptedKeyData =
        CryptoUtil.encryptSync(collectionKey, _config.getKey()!);
    final encryptedName = CryptoUtil.encryptSync(
      utf8.encode(albumName) as Uint8List,
      collectionKey,
    );
    final collection = await createAndCacheCollection(
      CreateRequest(
        encryptedKey: CryptoUtil.bin2base64(encryptedKeyData.encryptedData!),
        keyDecryptionNonce: CryptoUtil.bin2base64(encryptedKeyData.nonce!),
        encryptedName: CryptoUtil.bin2base64(encryptedName.encryptedData!),
        nameDecryptionNonce: CryptoUtil.bin2base64(encryptedName.nonce!),
        type: CollectionType.album,
        attributes: CollectionAttributes(),
      ),
    );
    return collection;
  }

  Future<Collection> fetchCollectionByID(int collectionID) async {
    try {
      _logger.fine('fetching collectionByID $collectionID');
      final response = await _enteDio.get(
        "/collections/$collectionID",
      );
      assert(response.data != null);
      final collectionData = response.data["collection"];
      final collection = await _fromRemoteCollection(collectionData);
      await _db.insert(List.from([collection]));
      _cacheCollectionAttributes(collection);
      return collection;
    } catch (e) {
      if (e is DioError && e.response?.statusCode == 401) {
        throw UnauthorizedError();
      }
      _logger.severe('failed to fetch collection: $collectionID', e);
      rethrow;
    }
  }

  Future<Collection> getOrCreateForPath(String path) async {
    if (_localPathToCollectionID.containsKey(path)) {
      final Collection? cachedCollection =
          _collectionIDToCollections[_localPathToCollectionID[path]];
      if (cachedCollection != null &&
          cachedCollection.canLinkToDevicePath(_config.getUserID()!)) {
        return cachedCollection;
      }
    }
    final collectionKey = CryptoUtil.generateKey();
    final encryptedKeyData =
        CryptoUtil.encryptSync(collectionKey, _config.getKey()!);
    final encryptedPath =
        CryptoUtil.encryptSync(utf8.encode(path) as Uint8List, collectionKey);
    final collection = await createAndCacheCollection(
      CreateRequest(
        encryptedKey: CryptoUtil.bin2base64(encryptedKeyData.encryptedData!),
        keyDecryptionNonce: CryptoUtil.bin2base64(encryptedKeyData.nonce!),
        encryptedName: CryptoUtil.bin2base64(encryptedPath.encryptedData!),
        nameDecryptionNonce: CryptoUtil.bin2base64(encryptedPath.nonce!),
        type: CollectionType.folder,
        attributes: CollectionAttributes(
          encryptedPath: CryptoUtil.bin2base64(encryptedPath.encryptedData!),
          pathDecryptionNonce: CryptoUtil.bin2base64(encryptedPath.nonce!),
          version: 1,
        ),
      ),
    );
    return collection;
  }

  Future<void> addToCollection(int collectionID, List<File> files) async {
    final containsUploadedFile = files.firstWhereOrNull(
          (element) => element.uploadedFileID != null,
        ) !=
        null;
    if (containsUploadedFile) {
      final existingFileIDsInCollection =
          await FilesDB.instance.getUploadedFileIDs(collectionID);
      files.removeWhere(
        (element) =>
            element.uploadedFileID != null &&
            existingFileIDsInCollection.contains(element.uploadedFileID),
      );
    }
    if (files.isEmpty || !containsUploadedFile) {
      _logger.info("nothing to add to the collection");
      return;
    }

    final params = <String, dynamic>{};
    params["collectionID"] = collectionID;
    final batchedFiles = files.chunks(batchSize);
    for (final batch in batchedFiles) {
      params["files"] = [];
      for (final file in batch) {
        final fileKey = getFileKey(file);
        file.generatedID =
            null; // So that a new entry is created in the FilesDB
        file.collectionID = collectionID;
        final encryptedKeyData =
            CryptoUtil.encryptSync(fileKey, getCollectionKey(collectionID));
        file.encryptedKey =
            CryptoUtil.bin2base64(encryptedKeyData.encryptedData!);
        file.keyDecryptionNonce =
            CryptoUtil.bin2base64(encryptedKeyData.nonce!);
        params["files"].add(
          CollectionFileItem(
            file.uploadedFileID!,
            file.encryptedKey!,
            file.keyDecryptionNonce!,
          ).toMap(),
        );
      }

      try {
        await _enteDio.post(
          "/collections/add-files",
          data: params,
        );
        await _filesDB.insertMultiple(batch);
        Bus.instance.fire(CollectionUpdatedEvent(collectionID, batch, "addTo"));
      } catch (e) {
        rethrow;
      }
    }
  }

  Future<File> linkLocalFileToExistingUploadedFileInAnotherCollection(
    int destCollectionID, {
    required File localFileToUpload,
    required File existingUploadedFile,
  }) async {
    final params = <String, dynamic>{};
    params["collectionID"] = destCollectionID;
    params["files"] = [];
    final int uploadedFileID = existingUploadedFile.uploadedFileID!;

    // encrypt the fileKey with destination collection's key
    final fileKey = getFileKey(existingUploadedFile);
    final encryptedKeyData =
        CryptoUtil.encryptSync(fileKey, getCollectionKey(destCollectionID));

    localFileToUpload.encryptedKey =
        CryptoUtil.bin2base64(encryptedKeyData.encryptedData!);
    localFileToUpload.keyDecryptionNonce =
        CryptoUtil.bin2base64(encryptedKeyData.nonce!);

    params["files"].add(
      CollectionFileItem(
        uploadedFileID,
        localFileToUpload.encryptedKey!,
        localFileToUpload.keyDecryptionNonce!,
      ).toMap(),
    );

    try {
      await _enteDio.post(
        "/collections/add-files",
        data: params,
      );
      localFileToUpload.collectionID = destCollectionID;
      localFileToUpload.uploadedFileID = uploadedFileID;
      await _filesDB.insertMultiple([localFileToUpload]);
      return localFileToUpload;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> restore(int toCollectionID, List<File> files) async {
    final params = <String, dynamic>{};
    params["collectionID"] = toCollectionID;
    final toCollectionKey = getCollectionKey(toCollectionID);
    final int ownerID = Configuration.instance.getUserID()!;
    final Set<String> existingLocalIDS =
        await FilesDB.instance.getExistingLocalFileIDs(ownerID);
    final batchedFiles = files.chunks(batchSize);
    for (final batch in batchedFiles) {
      params["files"] = [];
      for (final file in batch) {
        final fileKey = getFileKey(file);
        file.generatedID =
            null; // So that a new entry is created in the FilesDB
        file.collectionID = toCollectionID;
        // During restore, if trash file local ID is not present in currently
        // imported files, treat the file as deleted from device
        if (file.localID != null && !existingLocalIDS.contains(file.localID)) {
          file.localID = null;
        }
        final encryptedKeyData =
            CryptoUtil.encryptSync(fileKey, toCollectionKey);
        file.encryptedKey =
            CryptoUtil.bin2base64(encryptedKeyData.encryptedData!);
        file.keyDecryptionNonce =
            CryptoUtil.bin2base64(encryptedKeyData.nonce!);
        params["files"].add(
          CollectionFileItem(
            file.uploadedFileID!,
            file.encryptedKey!,
            file.keyDecryptionNonce!,
          ).toMap(),
        );
      }
      try {
        await _enteDio.post(
          "/collections/restore-files",
          data: params,
        );
        await _filesDB.insertMultiple(batch);
        await TrashDB.instance
            .delete(batch.map((e) => e.uploadedFileID!).toList());
        Bus.instance.fire(
          CollectionUpdatedEvent(toCollectionID, batch, "restore"),
        );
        Bus.instance.fire(FilesUpdatedEvent(batch, source: "restore"));
        // Remove imported local files which are imported but not uploaded.
        // This handles the case where local file was trashed -> imported again
        // but not uploaded automatically as it was trashed.
        final localIDs = batch
            .where((e) => e.localID != null)
            .map((e) => e.localID!)
            .toSet()
            .toList();
        if (localIDs.isNotEmpty) {
          await _filesDB.deleteUnSyncedLocalFiles(localIDs);
        }
        // Force reload home gallery to pull in the restored files
        Bus.instance.fire(ForceReloadHomeGalleryEvent("restoredFromTrash"));
      } catch (e, s) {
        _logger.severe("failed to restore files", e, s);
        rethrow;
      }
    }
  }

  Future<void> move(
    int toCollectionID,
    int fromCollectionID,
    List<File> files,
  ) async {
    _validateMoveRequest(toCollectionID, fromCollectionID, files);
    files.removeWhere((element) => element.uploadedFileID == null);
    if (files.isEmpty) {
      _logger.info("nothing to move to collection");
      return;
    }
    final params = <String, dynamic>{};
    params["toCollectionID"] = toCollectionID;
    params["fromCollectionID"] = fromCollectionID;
    final batchedFiles = files.chunks(batchSize);
    for (final batch in batchedFiles) {
      params["files"] = [];
      for (final file in batch) {
        final fileKey = getFileKey(file);
        file.generatedID =
            null; // So that a new entry is created in the FilesDB
        file.collectionID = toCollectionID;
        final encryptedKeyData =
            CryptoUtil.encryptSync(fileKey, getCollectionKey(toCollectionID));
        file.encryptedKey =
            CryptoUtil.bin2base64(encryptedKeyData.encryptedData!);
        file.keyDecryptionNonce =
            CryptoUtil.bin2base64(encryptedKeyData.nonce!);
        params["files"].add(
          CollectionFileItem(
            file.uploadedFileID!,
            file.encryptedKey!,
            file.keyDecryptionNonce!,
          ).toMap(),
        );
      }
      await _enteDio.post(
        "/collections/move-files",
        data: params,
      );
    }

    // remove files from old collection
    await _filesDB.removeFromCollection(
      fromCollectionID,
      files.map((e) => e.uploadedFileID!).toList(),
    );
    Bus.instance.fire(
      CollectionUpdatedEvent(
        fromCollectionID,
        files,
        "moveFrom",
        type: EventType.deletedFromRemote,
      ),
    );
    // insert new files in the toCollection which are not part of the toCollection
    final existingUploadedIDs =
        await FilesDB.instance.getUploadedFileIDs(toCollectionID);
    files.removeWhere(
      (element) => existingUploadedIDs.contains(element.uploadedFileID),
    );
    await _filesDB.insertMultiple(files);
    Bus.instance.fire(
      CollectionUpdatedEvent(toCollectionID, files, "moveTo"),
    );
  }

  void _validateMoveRequest(
    int toCollectionID,
    int fromCollectionID,
    List<File> files,
  ) {
    if (toCollectionID == fromCollectionID) {
      throw AssertionError("Can't move to same album");
    }
    for (final file in files) {
      if (file.uploadedFileID == null) {
        throw AssertionError("Can only move uploaded memories");
      }
      if (file.collectionID != fromCollectionID) {
        throw AssertionError("All memories should belong to the same album");
      }
      if (file.ownerID != Configuration.instance.getUserID()) {
        throw AssertionError("Can only move memories uploaded by you");
      }
    }
  }

  Future<void> removeFromCollection(int collectionID, List<File> files) async {
    final params = <String, dynamic>{};
    params["collectionID"] = collectionID;
    final batchedFiles = files.chunks(batchSize);
    for (final batch in batchedFiles) {
      params["fileIDs"] = <int>[];
      for (final file in batch) {
        params["fileIDs"].add(file.uploadedFileID);
      }
      await _enteDio.post(
        "/collections/v3/remove-files",
        data: params,
      );

      await _filesDB.removeFromCollection(collectionID, params["fileIDs"]);
      Bus.instance
          .fire(CollectionUpdatedEvent(collectionID, batch, "removeFrom"));
      Bus.instance.fire(LocalPhotosUpdatedEvent(batch, source: "removeFrom"));
    }
    RemoteSyncService.instance.sync(silently: true).ignore();
  }

  Future<Collection> createAndCacheCollection(
    CreateRequest createRequest,
  ) async {
    final dynamic payload = createRequest.toJson();
    return _enteDio
        .post(
      "/collections",
      data: payload,
    )
        .then((response) async {
      final collectionData = response.data["collection"];
      final collection = await _fromRemoteCollection(collectionData);
      return _cacheCollectionAttributes(collection);
    });
  }

  @Deprecated("Use _cacheLocalPathAndCollection instead")
  Collection _cacheCollectionAttributes(Collection collection) {
    final String decryptedName = _getDecryptedCollectionName(collection);
    collection.setName(decryptedName);
    if (collection.canLinkToDevicePath(_config.getUserID()!)) {
      _localPathToCollectionID[_decryptCollectionPath(collection)] =
          collection.id;
    }
    _collectionIDToCollections[collection.id] = collection;
    return collection;
  }

  Collection _cacheLocalPathAndCollection(Collection collection) {
    assert(
      collection.decryptedName != null,
      "decryptedName should be already set",
    );
    if (collection.canLinkToDevicePath(_config.getUserID()!) &&
        (collection.decryptedPath ?? '').isNotEmpty) {
      _localPathToCollectionID[collection.decryptedPath!] = collection.id;
    }
    _collectionIDToCollections[collection.id] = collection;
    return collection;
  }

  String _decryptCollectionPath(Collection collection) {
    if (collection.decryptedPath != null &&
        collection.decryptedPath!.isNotEmpty) {
      debugPrint("Using cached decrypted path for collection ${collection.id}");
      return collection.decryptedPath!;
    } else {
      debugPrint(
        "Decrypting path for collection ${collection.id} from "
        "encryptedPath",
      );
    }
    final key = collection.attributes.version! >= 1
        ? getCollectionKey(collection.id)
        : _config.getKey();
    return utf8.decode(
      CryptoUtil.decryptSync(
        CryptoUtil.base642bin(collection.attributes.encryptedPath!),
        key!,
        CryptoUtil.base642bin(collection.attributes.pathDecryptionNonce!),
      ),
    );
  }

  bool hasSyncedCollections() {
    return _prefs.containsKey(_collectionsSyncTimeKey);
  }

  String _getDecryptedCollectionName(Collection collection) {
    if (collection.isDeleted) {
      return "Deleted Album";
    }
    if (collection.encryptedName != null &&
        collection.encryptedName!.isNotEmpty) {
      try {
        final collectionKey = _getAndCacheDecryptedKey(
          collection,
          source: "Name",
        );
        final result = CryptoUtil.decryptSync(
          CryptoUtil.base642bin(collection.encryptedName!),
          collectionKey,
          CryptoUtil.base642bin(collection.nameDecryptionNonce!),
        );
        return utf8.decode(result);
      } catch (e, s) {
        _logger.severe(
          "failed to decrypt collection name: ${collection.id}",
          e,
          s,
        );
      }
    }
    return collection.displayName;
  }

  Future _updateDB(List<Collection> collections, {int attempt = 1}) async {
    if (collections.isEmpty) {
      return;
    }
    try {
      await _db.insert(collections);
    } catch (e) {
      _logger.severe("Failed to update collections", e);
      if (attempt < kMaximumWriteAttempts) {
        return _updateDB(collections, attempt: ++attempt);
      } else {
        rethrow;
      }
    }
  }
}
