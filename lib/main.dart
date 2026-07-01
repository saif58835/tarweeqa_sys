// ============================================================================
// TARWEEQA ERP - COMPLETE APPLICATION (PART 1/2)
// ============================================================================

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:crypto/crypto.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:vibration/vibration.dart';

// ============================================================================
// PART 1: CORE CONSTANTS & EXCEPTIONS
// ============================================================================

const String kAppName = "ترويقة ERP";
const Color kPrimary = Color(0xFF1565C0);
const Color kPrimaryLight = Color(0xFF2196F3);
const Color kBg = Color(0xFFF0F4FF);
const int kDefaultPageSize = 20;
const double kTolerance = 0.001;
const String kRemoteConfigAppEnabled = 'app_enabled';
const String kRemoteConfigMaintenanceMode = 'maintenance_mode';

class AppException implements Exception {
  final String message;
  final int? code;
  final Object? originalError;
  AppException(this.message, {this.code, this.originalError});
  @override
  String toString() => message;
}

class AuthException extends AppException {
  AuthException(String message, {Object? error}) : super(message, originalError: error);
}

class DatabaseException extends AppException {
  DatabaseException(String message, {Object? error}) : super(message, originalError: error);
}

class StockException extends AppException {
  StockException(String message, {Object? error}) : super(message, originalError: error);
}

class RemoteControlException extends AppException {
  RemoteControlException(String message, {Object? error}) : super(message, originalError: error);
}

// ============================================================================
// PART 2: UTILITIES
// ============================================================================

class Utils {
  static String hashString(String input) {
    final bytes = utf8.encode(input.trim());
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  static String generateStoreId(String password) {
    return hashString(password).substring(0, 24);
  }

  static double roundToTwoDecimals(double value) {
    return double.parse(value.toStringAsFixed(2));
  }

  static double toUSD(double value, String currency, double dollarRate) {
    if (currency == "دولار") return value;
    if (currency == "ل.س قديمة") return dollarRate > 0 ? value / dollarRate : 0;
    return dollarRate > 0 ? (value * 100) / dollarRate : 0;
  }
}

class UniqueIdGenerator {
  static String generateInvoiceId(String storeId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch.toString().substring(8);
    return 'INV-${storeId.substring(0, 6)}-$timestamp-$random';
  }

  static String generateShortId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString().substring(6);
    final random = DateTime.now().microsecondsSinceEpoch.toString().substring(4, 8);
    return '${timestamp}${random}';
  }
}

class GlobalErrorHandler {
  static final FirebaseCrashlytics _crashlytics = FirebaseCrashlytics.instance;

  static Future<void> initialize() async {
    await _crashlytics.setCrashlyticsCollectionEnabled(true);
    FlutterError.onError = (errorDetails) {
      _crashlytics.recordFlutterFatalError(errorDetails);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _crashlytics.recordError(error, stack, fatal: true);
      return true;
    };
  }

  static Future<void> recordError(dynamic error, StackTrace? stack, {bool fatal = false}) async {
    if (error is AppException) {
      await _crashlytics.log(error.message);
    }
    await _crashlytics.recordError(error, stack, fatal: fatal);
  }

  static Future<void> log(String message) async {
    await _crashlytics.log(message);
  }

  static Future<void> setCustomKey(String key, String value) async {
    await _crashlytics.setCustomKey(key, value);
  }

  static Future<void> setUserId(String userId) async {
    await _crashlytics.setUserIdentifier(userId);
  }
}

// ============================================================================
// PART 3: PAGINATION HELPER
// ============================================================================

class PaginatedResult<T> {
  final List<T> documents;
  final T? lastDocument;
  final bool hasMore;

  PaginatedResult({
    required this.documents,
    this.lastDocument,
    required this.hasMore,
  });

  bool get isEmpty => documents.isEmpty;
  bool get isNotEmpty => documents.isNotEmpty;
  int get length => documents.length;
}

// ============================================================================
// PART 4: DATA MODELS (Without json_serializable for single file compatibility)
// ============================================================================

class CartItem {
  final String productId;
  final String groupId;
  final String name;
  final String unit;
  final double priceUSD;
  double qty;
  String qtyType;
  double? directPriceUSD;

  CartItem({
    required this.productId,
    required this.groupId,
    required this.name,
    required this.unit,
    required this.priceUSD,
    required this.qty,
    this.qtyType = "عدد",
    this.directPriceUSD,
  });

  double get totalUSD {
    if (qtyType == "سعر_مباشر" && directPriceUSD != null) return directPriceUSD!;
    if (qtyType == "غرام") return priceUSD * (qty / 1000);
    return priceUSD * qty;
  }

  Map<String, dynamic> toMap() {
    return {
      'productId': productId,
      'groupId': groupId,
      'name': name,
      'unit': unit,
      'priceUSD': priceUSD,
      'qty': qty,
      'totalUSD': totalUSD,
    };
  }

  factory CartItem.fromMap(Map<String, dynamic> map) {
    return CartItem(
      productId: map['productId'] ?? '',
      groupId: map['groupId'] ?? '',
      name: map['name'] ?? '',
      unit: map['unit'] ?? 'عدد',
      priceUSD: (map['priceUSD'] ?? 0).toDouble(),
      qty: (map['qty'] ?? 0).toDouble(),
      qtyType: map['qtyType'] ?? 'عدد',
      directPriceUSD: map['directPriceUSD'] != null ? (map['directPriceUSD'] as num).toDouble() : null,
    );
  }
}

class InvoiceItem {
  final String productId;
  final String groupId;
  final String name;
  final String unit;
  final double priceUSD;
  final double qty;
  final double totalUSD;

  InvoiceItem({
    required this.productId,
    required this.groupId,
    required this.name,
    required this.unit,
    required this.priceUSD,
    required this.qty,
    required this.totalUSD,
  });

  Map<String, dynamic> toMap() {
    return {
      'productId': productId,
      'groupId': groupId,
      'name': name,
      'unit': unit,
      'priceUSD': priceUSD,
      'qty': qty,
      'totalUSD': totalUSD,
    };
  }

  factory InvoiceItem.fromMap(Map<String, dynamic> map) {
    return InvoiceItem(
      productId: map['productId'] ?? '',
      groupId: map['groupId'] ?? '',
      name: map['name'] ?? '',
      unit: map['unit'] ?? 'عدد',
      priceUSD: (map['priceUSD'] ?? 0).toDouble(),
      qty: (map['qty'] ?? 0).toDouble(),
      totalUSD: (map['totalUSD'] ?? 0).toDouble(),
    );
  }
}

class Invoice {
  final String id;
  final String invoiceNumber;
  final List<InvoiceItem> items;
  final double totalUSD;
  final double paidUSD;
  final double remainingUSD;
  final bool isDebt;
  final bool isPaid;
  final String? customerName;
  final String employeeName;
  final double dollarRateAtSale;
  final DateTime createdAt;
  final String dateStr;
  final bool pendingDelete;
  final String? deletedBy;
  final DateTime? deletedAt;

  Invoice({
    required this.id,
    required this.invoiceNumber,
    required this.items,
    required this.totalUSD,
    required this.paidUSD,
    required this.remainingUSD,
    required this.isDebt,
    required this.isPaid,
    this.customerName,
    required this.employeeName,
    required this.dollarRateAtSale,
    required this.createdAt,
    required this.dateStr,
    this.pendingDelete = false,
    this.deletedBy,
    this.deletedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'invoiceNumber': invoiceNumber,
      'items': items.map((item) => item.toMap()).toList(),
      'totalUSD': totalUSD,
      'paidUSD': paidUSD,
      'remainingUSD': remainingUSD,
      'isDebt': isDebt,
      'isPaid': isPaid,
      'customerName': customerName,
      'employeeName': employeeName,
      'dollarRateAtSale': dollarRateAtSale,
      'createdAt': Timestamp.fromDate(createdAt),
      'dateStr': dateStr,
      'pending_delete': pendingDelete,
      'deletedBy': deletedBy,
      'deletedAt': deletedAt != null ? Timestamp.fromDate(deletedAt!) : null,
    };
  }

  factory Invoice.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final itemsList = (data['items'] as List<dynamic>? ?? [])
        .map((item) => InvoiceItem.fromMap(item as Map<String, dynamic>))
        .toList();

    return Invoice(
      id: doc.id,
      invoiceNumber: data['invoiceNumber'] as String? ?? '',
      items: itemsList,
      totalUSD: (data['totalUSD'] as num?)?.toDouble() ?? 0,
      paidUSD: (data['paidUSD'] as num?)?.toDouble() ?? 0,
      remainingUSD: (data['remainingUSD'] as num?)?.toDouble() ?? 0,
      isDebt: data['isDebt'] as bool? ?? false,
      isPaid: data['isPaid'] as bool? ?? true,
      customerName: data['customerName'] as String?,
      employeeName: data['employeeName'] as String? ?? 'موظف',
      dollarRateAtSale: (data['dollarRateAtSale'] as num?)?.toDouble() ?? 15000.0,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dateStr: data['dateStr'] as String? ?? '',
      pendingDelete: data['pending_delete'] as bool? ?? false,
      deletedBy: data['deletedBy'] as String?,
      deletedAt: (data['deletedAt'] as Timestamp?)?.toDate(),
    );
  }

  static String generateInvoiceNumber(String storeId) {
    return UniqueIdGenerator.generateInvoiceId(storeId);
  }
}

class Store {
  final String id;
  final String name;
  final double dollarRate;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isActive;

  Store({
    required this.id,
    required this.name,
    required this.dollarRate,
    required this.createdAt,
    this.updatedAt,
    this.isActive = true,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'dollarRate': dollarRate,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp(),
      'isActive': isActive,
    };
  }

  factory Store.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Store(
      id: doc.id,
      name: data['name'] as String? ?? '',
      dollarRate: (data['dollarRate'] as num?)?.toDouble() ?? 15000.0,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      isActive: data['isActive'] as bool? ?? true,
    );
  }
}

// ============================================================================
// PART 5: SERVICES
// ============================================================================

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<UserCredential> signInWithEmailAndPassword(String email, String password) async {
    try {
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final userDoc = await _firestore
          .collection('employees')
          .doc(userCredential.user!.uid)
          .get();

      if (!userDoc.exists) {
        await _auth.signOut();
        throw AuthException('هذا المستخدم غير مسجل في أي متجر');
      }

      final data = userDoc.data() as Map<String, dynamic>;
      if (data['isActive'] == false) {
        await _auth.signOut();
        throw AuthException('هذا الحساب معطل');
      }

      await GlobalErrorHandler.setUserId(userCredential.user!.uid);
      await GlobalErrorHandler.setCustomKey('email', email);
      await GlobalErrorHandler.setCustomKey('storeId', data['storeId'] as String? ?? 'unknown');

      return userCredential;
    } on FirebaseAuthException catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw AuthException(_mapFirebaseAuthError(e), error: e);
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw AuthException('خطأ في تسجيل الدخول: $e', error: e);
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  User? get currentUser => _auth.currentUser;

  Future<String?> getCurrentUserStoreId() async {
    final user = currentUser;
    if (user == null) return null;

    final doc = await _firestore
        .collection('employees')
        .doc(user.uid)
        .get();

    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>;
      return data['storeId'] as String?;
    }
    return null;
  }

  Future<bool> isAdmin() async {
    final user = currentUser;
    if (user == null) return false;

    final doc = await _firestore
        .collection('employees')
        .doc(user.uid)
        .get();

    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>;
      return data['role'] == 'admin';
    }
    return false;
  }

  Future<Map<String, dynamic>?> getUserProfile() async {
    final user = currentUser;
    if (user == null) return null;

    final doc = await _firestore
        .collection('employees')
        .doc(user.uid)
        .get();

    if (doc.exists) {
      return doc.data() as Map<String, dynamic>;
    }
    return null;
  }

  String _mapFirebaseAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
        return 'البريد الإلكتروني غير مسجل';
      case 'wrong-password':
        return 'كلمة المرور غير صحيحة';
      case 'invalid-email':
        return 'البريد الإلكتروني غير صالح';
      case 'user-disabled':
        return 'هذا الحساب معطل';
      case 'too-many-requests':
        return 'تم إرسال طلبات كثيرة جداً، حاول لاحقاً';
      default:
        return 'خطأ في تسجيل الدخول: ${e.message}';
    }
  }
}

class DatabaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<T> runTransactionWithRetry<T>(
    Future<T> Function(Transaction) transactionFunction,
    {int maxRetries = 3}
  ) async {
    int retries = 0;
    while (retries < maxRetries) {
      try {
        return await _firestore.runTransaction(transactionFunction);
      } on FirebaseException catch (e, stack) {
        if (e.code == 'aborted' || e.code == 'unavailable') {
          retries++;
          if (retries >= maxRetries) {
            await GlobalErrorHandler.recordError(e, stack);
            throw DatabaseException('فشلت العملية بعد $maxRetries محاولات', error: e);
          }
          await Future.delayed(Duration(milliseconds: 100 * retries));
        } else {
          await GlobalErrorHandler.recordError(e, stack);
          rethrow;
        }
      } catch (e, stack) {
        await GlobalErrorHandler.recordError(e, stack);
        rethrow;
      }
    }
    throw DatabaseException('فشلت العملية بعد $maxRetries محاولات');
  }

  Future<DocumentSnapshot> getStore(String storeId) async {
    try {
      return await _firestore.collection('stores').doc(storeId).get();
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في جلب المتجر: $e', error: e);
    }
  }

  Future<void> updateDollarRate(String storeId, double newRate) async {
    try {
      await _firestore.collection('stores').doc(storeId).update({
        'dollarRate': newRate,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في تحديث سعر الدولار: $e', error: e);
    }
  }

  Future<List<QueryDocumentSnapshot>> getGroups(String storeId) async {
    try {
      final snapshot = await _firestore
          .collection('stores')
          .doc(storeId)
          .collection('groups')
          .where('pending_delete', isEqualTo: false)
          .orderBy('order')
          .get();
      return snapshot.docs;
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في جلب الأقسام: $e', error: e);
    }
  }

  Future<PaginatedResult<QueryDocumentSnapshot>> getProducts(
    String storeId,
    String groupId, {
    String? searchTerm,
    DocumentSnapshot? lastDocument,
    int pageSize = kDefaultPageSize,
  }) async {
    try {
      Query query = _firestore
          .collection('stores')
          .doc(storeId)
          .collection('groups')
          .doc(groupId)
          .collection('products')
          .where('pending_delete', isEqualTo: false)
          .orderBy('name')
          .limit(pageSize);

      if (searchTerm != null && searchTerm.isNotEmpty) {
        query = query.where('searchTerms', arrayContains: searchTerm.toLowerCase());
      }

      if (lastDocument != null) {
        query = query.startAfterDocument(lastDocument);
      }

      final snapshot = await query.get();
      return PaginatedResult(
        documents: snapshot.docs,
        lastDocument: snapshot.docs.isNotEmpty ? snapshot.docs.last : null,
        hasMore: snapshot.docs.length == pageSize,
      );
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في جلب المنتجات: $e', error: e);
    }
  }

  Future<PaginatedResult<QueryDocumentSnapshot>> getInvoices(
    String storeId, {
    bool? isPaid,
    DocumentSnapshot? lastDocument,
    int pageSize = kDefaultPageSize,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      Query query = _firestore
          .collection('stores')
          .doc(storeId)
          .collection('invoices')
          .where('pending_delete', isEqualTo: false)
          .orderBy('createdAt', descending: true)
          .limit(pageSize);

      if (isPaid != null) {
        query = query.where('isPaid', isEqualTo: isPaid);
      }

      if (startDate != null) {
        query = query.where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }

      if (endDate != null) {
        query = query.where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      if (lastDocument != null) {
        query = query.startAfterDocument(lastDocument);
      }

      final snapshot = await query.get();
      return PaginatedResult(
        documents: snapshot.docs,
        lastDocument: snapshot.docs.isNotEmpty ? snapshot.docs.last : null,
        hasMore: snapshot.docs.length == pageSize,
      );
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في جلب الفواتير: $e', error: e);
    }
  }

  Future<void> softDelete(String collectionPath, String docId, String requestedBy) async {
    try {
      final ref = _firestore.doc('$collectionPath/$docId');
      await ref.update({
        'pending_delete': true,
        'deletedBy': requestedBy,
        'deletedAt': FieldValue.serverTimestamp(),
      });
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في طلب الحذف: $e', error: e);
    }
  }

  Future<void> logAudit(String storeId, String action, String performedBy, Map<String, dynamic>? details) async {
    try {
      await _firestore
          .collection('stores')
          .doc(storeId)
          .collection('audit_logs')
          .add({
        'action': action,
        'performedBy': performedBy,
        'details': details ?? {},
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
    }
  }
}

class RemoteConfigService {
  final FirebaseRemoteConfig _remoteConfig = FirebaseRemoteConfig.instance;
  bool _initialized = false;

  Future<void> initialize() async {
    try {
      await _remoteConfig.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 10),
          minimumFetchInterval: const Duration(minutes: 5),
        ),
      );

      await _remoteConfig.setDefaults({
        kRemoteConfigAppEnabled: true,
        kRemoteConfigMaintenanceMode: false,
      });

      await _remoteConfig.fetchAndActivate();
      _initialized = true;

      await GlobalErrorHandler.log('Remote Config initialized successfully');
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw RemoteControlException('خطأ في تهيئة Remote Config: $e', error: e);
    }
  }

  bool get isAppEnabled => _initialized ? _remoteConfig.getBool(kRemoteConfigAppEnabled) : true;
  bool get isMaintenanceMode => _initialized ? _remoteConfig.getBool(kRemoteConfigMaintenanceMode) : false;

  Future<void> fetchConfig() async {
    try {
      await _remoteConfig.fetch();
      await _remoteConfig.activate();
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw RemoteControlException('خطأ في جلب الإعدادات: $e', error: e);
    }
  }

  Future<void> checkKillSwitch() async {
    await fetchConfig();
    if (!isAppEnabled) {
      throw RemoteControlException('تم إيقاف التطبيق من قبل المسؤول. يرجى التواصل مع الدعم.');
    }
    if (isMaintenanceMode) {
      throw RemoteControlException('التطبيق في وضع الصيانة. يرجى المحاولة لاحقاً.');
    }
  }
}

// ============================================================================
// PART 6: REPOSITORY
// ============================================================================

class InvoiceRepository {
  final DatabaseService _database = DatabaseService();
  final RemoteConfigService _remoteConfig = RemoteConfigService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<Invoice> createInvoice({
    required String storeId,
    required String employeeName,
    required double dollarRateAtSale,
    required List<CartItem> cart,
    required double totalUSD,
    required double paidUSD,
    required double remaining,
    required bool isDebt,
    String? customerName,
  }) async {
    await _remoteConfig.checkKillSwitch();

    return await _database.runTransactionWithRetry((transaction) async {
      final invoiceNumber = Invoice.generateInvoiceNumber(storeId);

      final items = cart.map((c) => InvoiceItem(
        productId: c.productId,
        groupId: c.groupId,
        name: c.name,
        unit: c.unit,
        priceUSD: c.priceUSD,
        qty: c.qty,
        totalUSD: c.totalUSD,
      )).toList();

      final invoice = Invoice(
        id: invoiceNumber,
        invoiceNumber: invoiceNumber,
        items: items,
        totalUSD: totalUSD,
        paidUSD: paidUSD,
        remainingUSD: remaining,
        isDebt: isDebt,
        isPaid: !isDebt,
        customerName: isDebt ? customerName : null,
        employeeName: employeeName,
        dollarRateAtSale: dollarRateAtSale,
        createdAt: DateTime.now(),
        dateStr: DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
      );

      // Final stock check and update
      for (final c in cart) {
        if (c.qtyType != "سعر_مباشر") {
          final productRef = _firestore
              .collection('stores')
              .doc(storeId)
              .collection('groups')
              .doc(c.groupId)
              .collection('products')
              .doc(c.productId);

          final doc = await transaction.get(productRef);
          if (!doc.exists) {
            throw StockException('المنتج ${c.name} غير موجود');
          }

          final currentQty = (doc.data()?['qty'] as num?)?.toDouble() ?? 0;
          final deduct = c.qtyType == "غرام" ? c.qty / 1000 : c.qty;

          if (currentQty < deduct) {
            throw StockException('الكمية غير كافية للمنتج ${c.name}. المتاح: $currentQty، المطلوب: $deduct');
          }

          transaction.update(productRef, {'qty': FieldValue.increment(-deduct)});
        }
      }

      final invoiceRef = _firestore
          .collection('stores')
          .doc(storeId)
          .collection('invoices')
          .doc(invoiceNumber);

      final existingDoc = await transaction.get(invoiceRef);
      if (existingDoc.exists) {
        throw DatabaseException('رقم الفاتورة $invoiceNumber موجود مسبقاً');
      }

      transaction.set(invoiceRef, invoice.toMap());

      final auditRef = _firestore
          .collection('stores')
          .doc(storeId)
          .collection('audit_logs')
          .doc();
      transaction.set(auditRef, {
        'action': 'create_invoice',
        'invoiceNumber': invoiceNumber,
        'performedBy': employeeName,
        'totalUSD': totalUSD,
        'isDebt': isDebt,
        'timestamp': FieldValue.serverTimestamp(),
      });

      await GlobalErrorHandler.log('Invoice created successfully: $invoiceNumber');
      return invoice;
    });
  }

  Future<PaginatedResult<Invoice>> getInvoices(
    String storeId, {
    bool? isPaid,
    DocumentSnapshot? lastDocument,
    int pageSize = kDefaultPageSize,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final result = await _database.getInvoices(
        storeId,
        isPaid: isPaid,
        lastDocument: lastDocument,
        pageSize: pageSize,
        startDate: startDate,
        endDate: endDate,
      );

      final invoices = result.documents.map((doc) => Invoice.fromDocument(doc)).toList();

      return PaginatedResult(
        documents: invoices,
        lastDocument: result.lastDocument,
        hasMore: result.hasMore,
      );
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في جلب الفواتير: $e', error: e);
    }
  }

  Future<void> updateInvoicePayment(
    String storeId,
    String invoiceId,
    double additionalPaidUSD,
  ) async {
    await _remoteConfig.checkKillSwitch();

    return await _database.runTransactionWithRetry((transaction) async {
      final invoiceRef = _firestore
          .collection('stores')
          .doc(storeId)
          .collection('invoices')
          .doc(invoiceId);

      final doc = await transaction.get(invoiceRef);
      if (!doc.exists) {
        throw DatabaseException('الفاتورة غير موجودة');
      }

      final data = doc.data() as Map<String, dynamic>;
      final currentPaid = (data['paidUSD'] as num?)?.toDouble() ?? 0;
      final currentRemaining = (data['remainingUSD'] as num?)?.toDouble() ?? 0;
      final newPaid = currentPaid + additionalPaidUSD;
      final newRemaining = (currentRemaining - additionalPaidUSD).clamp(0.0, double.infinity);
      final isPaid = newRemaining < kTolerance;

      transaction.update(invoiceRef, {
        'paidUSD': newPaid,
        'remainingUSD': newRemaining,
        'isPaid': isPaid,
        'isDebt': !isPaid,
      });

      await GlobalErrorHandler.log('Invoice payment updated: $invoiceId, new paid: $newPaid');
    });
  }

  Future<void> softDeleteInvoice(String storeId, String invoiceId, String requestedBy) async {
    await _remoteConfig.checkKillSwitch();
    await _database.softDelete(
      'stores/$storeId/invoices',
      invoiceId,
      requestedBy,
    );
    await GlobalErrorHandler.log('Invoice soft deleted: $invoiceId by $requestedBy');
  }

  Future<void> permanentDeleteInvoice(String storeId, String invoiceId) async {
    await _remoteConfig.checkKillSwitch();
    try {
      await _firestore
          .collection('stores')
          .doc(storeId)
          .collection('invoices')
          .doc(invoiceId)
          .delete();
      await GlobalErrorHandler.log('Invoice permanently deleted: $invoiceId');
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في الحذف النهائي: $e', error: e);
    }
  }

  Future<DailyReport> getDailyReport(String storeId, DateTime date) async {
    try {
      final startOfDay = DateTime(date.year, date.month, date.day);
      final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

      final result = await getInvoices(
        storeId,
        startDate: startOfDay,
        endDate: endOfDay,
        pageSize: 1000,
      );

      double totalPaidUSD = 0;
      double totalDebtUSD = 0;
      int invoiceCount = 0;
      int debtCount = 0;
      double totalRevenueUSD = 0;

      for (final invoice in result.documents) {
        totalRevenueUSD += invoice.totalUSD;
        totalPaidUSD += invoice.paidUSD;

        if (invoice.isDebt) {
          totalDebtUSD += invoice.remainingUSD;
          debtCount++;
        }
        invoiceCount++;
      }

      final storeDoc = await _database.getStore(storeId);
      final storeData = storeDoc.data() as Map<String, dynamic>;
      final dollarRate = (storeData['dollarRate'] as num?)?.toDouble() ?? 15000.0;

      return DailyReport(
        date: DateFormat('yyyy-MM-dd').format(startOfDay),
        totalPaidUSD: totalPaidUSD,
        totalPaidLiraOld: totalPaidUSD * dollarRate,
        totalPaidLiraNew: (totalPaidUSD * dollarRate) / 100,
        totalDebtUSD: totalDebtUSD,
        totalDebtLiraOld: totalDebtUSD * dollarRate,
        totalDebtLiraNew: (totalDebtUSD * dollarRate) / 100,
        totalRevenueUSD: totalRevenueUSD,
        invoiceCount: invoiceCount,
        debtCount: debtCount,
        dollarRate: dollarRate,
      );
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      throw DatabaseException('خطأ في جلب التقرير: $e', error: e);
    }
  }
}

class DailyReport {
  final String date;
  final double totalPaidUSD;
  final double totalPaidLiraOld;
  final double totalPaidLiraNew;
  final double totalDebtUSD;
  final double totalDebtLiraOld;
  final double totalDebtLiraNew;
  final double totalRevenueUSD;
  final int invoiceCount;
  final int debtCount;
  final double dollarRate;

  DailyReport({
    required this.date,
    required this.totalPaidUSD,
    required this.totalPaidLiraOld,
    required this.totalPaidLiraNew,
    required this.totalDebtUSD,
    required this.totalDebtLiraOld,
    required this.totalDebtLiraNew,
    required this.totalRevenueUSD,
    required this.invoiceCount,
    required this.debtCount,
    required this.dollarRate,
  });
}
// ============================================================================
// PART 7: APP CONTROLLER (GetX)
// ============================================================================

class AppController extends GetxController {
  final AuthService _authService = AuthService();
  final RemoteConfigService _remoteConfigService = RemoteConfigService();
  final DatabaseService _databaseService = DatabaseService();
  final InvoiceRepository _invoiceRepository = InvoiceRepository();

  final isLoggedIn = false.obs;
  final isLoading = false.obs;
  final isProcessing = false.obs;
  final currentUserEmail = Rxn<String>();
  final currentStoreId = Rxn<String>();
  final isAdmin = false.obs;
  final dollarRate = 15000.0.obs;
  final lastKnownDollarRate = 15000.0.obs;
  final employeeName = Rxn<String>();
  final employeeRole = Rxn<String>();
  final appEnabled = true.obs;
  final maintenanceMode = false.obs;

  AuthService get auth => _authService;
  DatabaseService get database => _databaseService;
  InvoiceRepository get invoice => _invoiceRepository;

  @override
  void onInit() async {
    super.onInit();
    await _initializeRemoteConfig();
    _checkAuthState();
    await _setupCrashlytics();
  }

  Future<void> _initializeRemoteConfig() async {
    try {
      await _remoteConfigService.initialize();
      appEnabled.value = _remoteConfigService.isAppEnabled;
      maintenanceMode.value = _remoteConfigService.isMaintenanceMode;
      await GlobalErrorHandler.log('Remote Config initialized');
    } catch (e) {
      await GlobalErrorHandler.recordError(e, null);
    }
  }

  Future<void> _setupCrashlytics() async {
    await GlobalErrorHandler.initialize();
  }

  void _checkAuthState() {
    if (_authService.currentUser != null) {
      isLoggedIn.value = true;
      currentUserEmail.value = _authService.currentUser!.email;
      _loadUserData();
    }
  }

  Future<void> _loadUserData() async {
    try {
      isLoading.value = true;
      final storeId = await _authService.getCurrentUserStoreId();
      if (storeId != null) {
        currentStoreId.value = storeId;
        isAdmin.value = await _authService.isAdmin();

        final storeDoc = await _databaseService.getStore(storeId);
        if (storeDoc.exists) {
          final data = storeDoc.data() as Map<String, dynamic>;
          dollarRate.value = (data['dollarRate'] as num?)?.toDouble() ?? 15000.0;
          lastKnownDollarRate.value = dollarRate.value;
        }

        final profile = await _authService.getUserProfile();
        if (profile != null) {
          employeeName.value = profile['name'] as String? ?? 'موظف';
          employeeRole.value = profile['role'] as String? ?? 'employee';
        }

        await GlobalErrorHandler.setCustomKey('storeId', storeId);
      }
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      Get.snackbar('خطأ', 'فشل تحميل البيانات: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> login(String email, String password) async {
    try {
      isLoading.value = true;
      await _authService.signInWithEmailAndPassword(email, password);
      isLoggedIn.value = true;
      currentUserEmail.value = email;
      await _loadUserData();
      await GlobalErrorHandler.log('User logged in: $email');
      Get.offAll(() => const HomePage());
    } on AppException catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      Get.snackbar('خطأ', e.message,
          backgroundColor: Colors.red, colorText: Colors.white);
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
      Get.snackbar('خطأ', 'حدث خطأ غير متوقع',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> logout() async {
    await _authService.signOut();
    isLoggedIn.value = false;
    currentUserEmail.value = null;
    currentStoreId.value = null;
    isAdmin.value = false;
    await GlobalErrorHandler.log('User logged out');
    Get.offAll(() => const LoginPage());
  }

  Future<void> checkRemoteConfig() async {
    try {
      await _remoteConfigService.fetchConfig();
      appEnabled.value = _remoteConfigService.isAppEnabled;
      maintenanceMode.value = _remoteConfigService.isMaintenanceMode;

      if (!appEnabled.value) {
        Get.dialog(
          AlertDialog(
            title: const Text("التطبيق متوقف"),
            content: const Text("تم إيقاف التطبيق من قبل المسؤول. يرجى التواصل مع الدعم."),
            actions: [
              TextButton(
                onPressed: () => SystemNavigator.pop(),
                child: const Text("خروج"),
              ),
            ],
          ),
        );
      }
    } catch (e, stack) {
      await GlobalErrorHandler.recordError(e, stack);
    }
  }

  void checkDollarRateChange(double newRate) {
    if (lastKnownDollarRate.value != newRate) {
      lastKnownDollarRate.value = newRate;
      Get.snackbar(
        'تحديث سعر الدولار',
        'تم تحديث سعر الدولار إلى ${NumberFormat("#,##0").format(newRate)} ل.س',
        backgroundColor: Colors.blue[700],
        colorText: Colors.white,
        snackPosition: SnackPosition.TOP,
        duration: const Duration(seconds: 4),
        icon: const Icon(Icons.currency_exchange, color: Colors.white),
      );
      Vibration.vibrate(duration: 200);
    }
  }

  Future<void> addGroup(String storeId, String name, int color) async {
    try {
      isLoading.value = true;
      await _databaseService.addGroup(storeId, name, color);
      Get.snackbar('نجاح', 'تم إضافة القسم بنجاح',
          backgroundColor: Colors.green, colorText: Colors.white);
      Vibration.vibrate(duration: 100);
    } catch (e) {
      Get.snackbar('خطأ', 'فشل إضافة القسم: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> updateGroup(String storeId, String groupId, String newName) async {
    try {
      await _databaseService.updateGroup(storeId, groupId, newName);
      Get.snackbar('نجاح', 'تم تعديل القسم بنجاح',
          backgroundColor: Colors.green, colorText: Colors.white);
      Vibration.vibrate(duration: 100);
    } catch (e) {
      Get.snackbar('خطأ', 'فشل تعديل القسم: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> softDelete(String collectionPath, String docId, String requestedBy) async {
    try {
      await _databaseService.softDelete(collectionPath, docId, requestedBy);
      Get.snackbar('طلب حذف', 'تم إرسال طلب الحذف للمراجعة',
          backgroundColor: Colors.orange, colorText: Colors.white);
      Vibration.vibrate(duration: 200);
    } catch (e) {
      Get.snackbar('خطأ', 'فشل طلب الحذف: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<Invoice> saveInvoice(
    String storeId,
    List<CartItem> cart,
    double totalUSD,
    double paidUSD,
    double remaining,
    bool isDebt,
    String? customerName,
    String empName,
    double dollarRateAtSale,
  ) async {
    if (isProcessing.value) {
      Get.snackbar('تنبيه', 'جاري معالجة عملية سابقة، يرجى الانتظار...',
          backgroundColor: Colors.orange, colorText: Colors.white);
      throw AppException('جاري معالجة عملية أخرى');
    }

    try {
      isProcessing.value = true;
      isLoading.value = true;

      final invoice = await _invoiceRepository.createInvoice(
        storeId: storeId,
        employeeName: empName,
        dollarRateAtSale: dollarRateAtSale,
        cart: cart,
        totalUSD: totalUSD,
        paidUSD: paidUSD,
        remaining: remaining,
        isDebt: isDebt,
        customerName: customerName,
      );

      Get.snackbar('نجاح', isDebt ? 'تم حفظ الفاتورة في قسم الدين' : 'تم حفظ الفاتورة بنجاح',
          backgroundColor: isDebt ? Colors.orange : Colors.green,
          colorText: Colors.white);
      Vibration.vibrate(duration: 300);
      return invoice;
    } catch (e) {
      Get.snackbar('خطأ', 'فشل حفظ الفاتورة: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      rethrow;
    } finally {
      isProcessing.value = false;
      isLoading.value = false;
    }
  }
}

// ============================================================================
// PART 8: MAIN APP & ENTRY POINT
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyCFNad5ADOdWKfWJf6UfwaGb4s17sjcjDs",
      appId: "1:915069495500:android:80f6a8ebc128e249e77a69",
      messagingSenderId: "915069495500",
      projectId: "tarweeqa-erp",
    ),
  );

  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  Get.put(AppController());

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appCtrl = Get.find<AppController>();

    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      title: kAppName,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kPrimaryLight,
          primary: kPrimaryLight,
          secondary: const Color(0xFF64B5F6),
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kPrimaryLight,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kPrimaryLight,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        cardTheme: const CardTheme(
          color: Colors.white,
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      home: Obx(() {
        if (appCtrl.isLoggedIn.value) {
          return const HomePage();
        }
        return const LoginPage();
      }),
    );
  }
}

// ============================================================================
// PART 9: LOGIN PAGE
// ============================================================================

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _appCtrl = Get.find<AppController>();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleLogin() {
    if (_formKey.currentState?.validate() ?? false) {
      _appCtrl.login(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 10,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text("🧀", style: TextStyle(fontSize: 32)),
                          SizedBox(width: 8),
                          Text("🥛", style: TextStyle(fontSize: 32)),
                          SizedBox(width: 8),
                          Text("🫙", style: TextStyle(fontSize: 32)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "تَرْوِيقَة",
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w900,
                          color: kPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "نظام إدارة المبيعات",
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                      const SizedBox(height: 32),
                      TextFormField(
                        controller: _emailController,
                        decoration: const InputDecoration(
                          labelText: "البريد الإلكتروني",
                          prefixIcon: Icon(Icons.email),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'يرجى إدخال البريد الإلكتروني';
                          }
                          if (!value.contains('@')) {
                            return 'بريد إلكتروني غير صالح';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: "كلمة المرور",
                          prefixIcon: Icon(Icons.lock),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'يرجى إدخال كلمة المرور';
                          }
                          if (value.length < 6) {
                            return 'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      Obx(() => SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _appCtrl.isLoading.value ? null : _handleLogin,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: _appCtrl.isLoading.value
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(color: Colors.white),
                                )
                              : const Text(
                                  "تسجيل الدخول",
                                  style: TextStyle(fontSize: 16),
                                ),
                        ),
                      )),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// PART 10: HOME PAGE
// ============================================================================

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final appCtrl = Get.find<AppController>();

    return Scaffold(
      appBar: AppBar(
        flexible_space: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text("تَرْوِيقَة",
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Colors.white)),
            ),
            const SizedBox(width: 8),
            const Text("| الأقسام", style: TextStyle(fontSize: 14, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Get.to(() => const SettingsPage()),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => appCtrl.logout(),
          ),
        ],
      ),
      body: Obx(() {
        final storeId = appCtrl.currentStoreId.value;
        if (storeId == null) {
          return const Center(child: Text("لم يتم ربط المتجر"));
        }

        return Column(
          children: [
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance.collection('stores').doc(storeId).snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.red[100],
                    child: const Text("خطأ في تحميل سعر الدولار", style: TextStyle(color: Colors.red)),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return Container(
                    padding: const EdgeInsets.all(12),
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }

                double rate = appCtrl.dollarRate.value;
                if (snap.hasData && snap.data!.exists) {
                  final data = snap.data!.data() as Map<String, dynamic>?;
                  if (data != null && data['dollarRate'] != null) {
                    rate = (data['dollarRate'] as num).toDouble();
                    if (rate != appCtrl.dollarRate.value) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        appCtrl.dollarRate.value = rate;
                        appCtrl.checkDollarRateChange(rate);
                      });
                    }
                  }
                }
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: const Color(0xFFE3F2FD),
                  child: Text(
                    "👤 ${appCtrl.employeeName.value}   |   💵 ${NumberFormat("#,##0").format(rate)} ل.س",
                    style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                );
              },
            ),
            _NavRow(storeId: storeId),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('stores').doc(storeId).collection('groups')
                    .where('pending_delete', isEqualTo: false)
                    .orderBy('order').snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text("خطأ: ${snapshot.error}", style: const TextStyle(color: Colors.red)));
                  }
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: Text("لا توجد أقسام", style: TextStyle(color: Colors.grey)));
                  }

                  final groups = snapshot.data!.docs;
                  return GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                      childAspectRatio: 1.1,
                    ),
                    itemCount: groups.length + 1,
                    itemBuilder: (context, index) {
                      if (index == groups.length) {
                        return GestureDetector(
                          onTap: () => _addGroupDialog(context, appCtrl, storeId),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.grey[300]!),
                            ),
                            child: const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_circle_outline, size: 40, color: Colors.grey),
                                  SizedBox(height: 6),
                                  Text("قسم جديد", style: TextStyle(color: Colors.grey, fontSize: 13)),
                                ],
                              ),
                            ),
                          ),
                        );
                      }
                      final doc = groups[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final color = data['color'] != null
                          ? Color(data['color'] as int)
                          : const Color(0xFFE3F2FD);
                      return GestureDetector(
                        onTap: () => Get.to(() => ProductsPage(
                          storeId: storeId,
                          groupId: doc.id,
                          groupName: doc['name'],
                        )),
                        onLongPress: () => _showGroupOptions(context, appCtrl, storeId, doc),
                        child: Container(
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: [
                              BoxShadow(color: Colors.grey.withOpacity(0.2), blurRadius: 8, offset: const Offset(0, 4)),
                            ],
                          ),
                          child: Stack(
                            children: [
                              Center(
                                child: Text(doc['name'],
                                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: kPrimary),
                                    textAlign: TextAlign.center),
                              ),
                              Positioned(
                                top: 8, left: 8,
                                child: StreamBuilder<QuerySnapshot>(
                                  stream: FirebaseFirestore.instance
                                      .collection('stores').doc(storeId)
                                      .collection('groups').doc(doc.id)
                                      .collection('products')
                                      .where('pending_delete', isEqualTo: false)
                                      .snapshots(),
                                  builder: (_, snap) {
                                    if (snap.hasError) return const SizedBox();
                                    if (snap.connectionState == ConnectionState.waiting) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: kPrimary.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Text("جاري التحميل...",
                                            style: TextStyle(fontSize: 10, color: kPrimary)),
                                      );
                                    }
                                    final count = snap.hasData ? snap.data!.docs.length : 0;
                                    bool hasLow = false;
                                    if (snap.hasData) {
                                      for (var p in snap.data!.docs) {
                                        if ((p['qty'] ?? 0).toDouble() <= 3) { hasLow = true; break; }
                                      }
                                    }
                                    return Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: kPrimary.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text("$count منتج",
                                              style: const TextStyle(fontSize: 10, color: kPrimary, fontWeight: FontWeight.bold)),
                                        ),
                                        if (hasLow) ...[
                                          const SizedBox(width: 4),
                                          const CircleAvatar(radius: 5, backgroundColor: Colors.red),
                                        ]
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      }),
    );
  }

  void _addGroupDialog(BuildContext context, AppController appCtrl, String storeId) {
    final ctrl = TextEditingController();
    Color selectedColor = const Color(0xFFE3F2FD);
    final colors = [
      const Color(0xFFE3F2FD),
      const Color(0xFFFFF9C4),
      const Color(0xFFE8F5E9),
      const Color(0xFFFFEBEE),
      const Color(0xFFF3E5F5),
      const Color(0xFFE0F2F1),
    ];

    Get.dialog(
      StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text("قسم جديد"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(labelText: "اسم القسم"),
              ),
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerRight,
                child: Text("اختر لون القسم:", style: TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: colors.map((color) => GestureDetector(
                  onTap: () => setD(() => selectedColor = color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selectedColor == color ? Colors.blue : Colors.grey.shade300,
                        width: selectedColor == color ? 3 : 1,
                      ),
                    ),
                  ),
                )).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
            ElevatedButton(
              onPressed: () {
                if (ctrl.text.isNotEmpty) {
                  appCtrl.addGroup(storeId, ctrl.text, selectedColor.value);
                  Get.back();
                }
              },
              child: const Text("إضافة"),
            ),
          ],
        ),
      ),
    );
  }

  void _showGroupOptions(BuildContext context, AppController appCtrl, String storeId, QueryDocumentSnapshot doc) {
    final nameCtrl = TextEditingController(text: doc['name']);
    Get.bottomSheet(
      SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: kPrimaryLight),
              title: const Text("تعديل اسم القسم"),
              onTap: () {
                Get.back();
                Get.dialog(
                  AlertDialog(
                    title: const Text("تعديل القسم"),
                    content: TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: "الاسم الجديد"),
                    ),
                    actions: [
                      TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
                      ElevatedButton(
                        onPressed: () {
                          appCtrl.updateGroup(storeId, doc.id, nameCtrl.text);
                          Get.back();
                        },
                        child: const Text("حفظ"),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text("حذف القسم", style: TextStyle(color: Colors.red)),
              onTap: () {
                Get.back();
                Get.dialog(
                  AlertDialog(
                    title: const Text("تأكيد الحذف"),
                    content: Text("هل تريد حذف قسم '${doc['name']}' وكل منتجاته؟"),
                    actions: [
                      TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: () {
                          appCtrl.softDelete(
                            'stores/$storeId/groups',
                            doc.id,
                            appCtrl.employeeName.value ?? 'موظف',
                          );
                          Get.back();
                        },
                        child: const Text("طلب حذف"),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final String storeId;
  const _NavRow({required this.storeId});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Expanded(child: _NavBtn(icon: Icons.point_of_sale, label: "فاتورة جديدة", color: kPrimaryLight,
              onTap: () => Get.to(() => NewInvoicePage(storeId: storeId)))),
          const SizedBox(width: 8),
          Expanded(child: _NavBtn(icon: Icons.receipt_long, label: "الفواتير", color: const Color(0xFF2E7D32),
              onTap: () => Get.to(() => InvoicesPage(storeId: storeId, debtOnly: false)))),
          const SizedBox(width: 8),
          Expanded(child: _NavBtn(icon: Icons.warning_amber_rounded, label: "الدين", color: Colors.red[700]!,
              onTap: () => Get.to(() => InvoicesPage(storeId: storeId, debtOnly: true)))),
          const SizedBox(width: 8),
          Expanded(child: _NavBtn(
            icon: Icons.bar_chart,
            label: "التقارير",
            color: Colors.purple[700]!,
            onTap: () => Get.to(() => DailyReportPage(storeId: storeId)),
          )),
        ],
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _NavBtn({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// PART 11: SETTINGS PAGE
// ============================================================================

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appCtrl = Get.find<AppController>();

    final nameCtrl = TextEditingController(text: appCtrl.employeeName.value);
    final rateCtrl = TextEditingController(text: appCtrl.dollarRate.value.toStringAsFixed(0));

    return Scaffold(
      appBar: AppBar(
        flexible_space: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Text("الإعدادات"),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section("معلومات الموظف"),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: "اسم الموظف"),
                    onSubmitted: (_) => _autoSave(appCtrl, nameCtrl, rateCtrl),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: rateCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: "سعر الدولار (ل.س)"),
                    onSubmitted: (_) => _autoSave(appCtrl, nameCtrl, rateCtrl),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _section("النسخ الاحتياطي"),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("تصدير كل بيانات المتجر كملف JSON وإرساله عبر واتساب أو حفظه",
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: () => _exportBackup(appCtrl.currentStoreId.value!),
                    icon: const Icon(Icons.download),
                    label: const Text("تصدير نسخة احتياطية"),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _save(appCtrl, nameCtrl, rateCtrl),
            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text("حفظ الإعدادات", style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  void _autoSave(AppController appCtrl, TextEditingController nameCtrl, TextEditingController rateCtrl) {
    final name = nameCtrl.text.trim().isEmpty ? "موظف" : nameCtrl.text.trim();
    final rate = double.tryParse(rateCtrl.text) ?? 15000.0;
    appCtrl.employeeName.value = name;
    appCtrl.dollarRate.value = rate;
    Get.snackbar('تم الحفظ', 'تم الحفظ التلقائي',
        backgroundColor: Colors.green, colorText: Colors.white);
  }

  void _save(AppController appCtrl, TextEditingController nameCtrl, TextEditingController rateCtrl) {
    final name = nameCtrl.text.trim().isEmpty ? "موظف" : nameCtrl.text.trim();
    final rate = double.tryParse(rateCtrl.text) ?? 15000.0;
    appCtrl.employeeName.value = name;
    appCtrl.dollarRate.value = rate;
    Get.back();
  }

  Future<void> _exportBackup(String storeId) async {
    try {
      final Map<String, dynamic> backup = {};
      final groups = await FirebaseFirestore.instance
          .collection('stores').doc(storeId).collection('groups')
          .where('pending_delete', isEqualTo: false)
          .get();
      final groupsData = [];
      for (var g in groups.docs) {
        final products = await FirebaseFirestore.instance
            .collection('stores').doc(storeId).collection('groups').doc(g.id).collection('products')
            .where('pending_delete', isEqualTo: false)
            .get();
        groupsData.add({'id': g.id, 'name': g['name'], 'products': products.docs.map((p) => p.data()).toList()});
      }
      backup['groups'] = groupsData;
      final invoices = await FirebaseFirestore.instance
          .collection('stores').doc(storeId).collection('invoices')
          .where('pending_delete', isEqualTo: false)
          .get();
      backup['invoices'] = invoices.docs.map((i) => i.data()).toList();
      final json = jsonEncode(backup);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/tarweeqa_backup_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(json);
      await Share.shareXFiles([XFile(file.path)], text: 'نسخة احتياطية - ترويقة ERP');
    } catch (e) {
      Get.snackbar('خطأ', 'فشل التصدير: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8, right: 4),
    child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: kPrimary)),
  );
}

// ============================================================================
// PART 12: PRODUCTS PAGE
// ============================================================================

class ProductsPage extends StatefulWidget {
  final String storeId;
  final String groupId;
  final String groupName;

  const ProductsPage({
    super.key,
    required this.storeId,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  final _pageSize = 20;
  DocumentSnapshot? _lastDocument;
  final List<QueryDocumentSnapshot> _products = [];
  bool _hasMore = true;
  bool _isLoadingMore = false;
  final searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final appCtrl = Get.find<AppController>();

  @override
  void initState() {
    super.initState();
    _loadInitialProducts();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
        _loadMoreProducts();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialProducts() async {
    try {
      final result = await appCtrl.database.getProducts(
        widget.storeId,
        widget.groupId,
        searchTerm: searchController.text.isNotEmpty ? searchController.text : null,
        pageSize: _pageSize,
      );

      setState(() {
        _products.clear();
        _products.addAll(result.documents);
        _lastDocument = result.lastDocument;
        _hasMore = result.hasMore;
      });
    } catch (e) {
      Get.snackbar('خطأ', 'فشل تحميل المنتجات: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _loadMoreProducts() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final result = await appCtrl.database.getProducts(
        widget.storeId,
        widget.groupId,
        searchTerm: searchController.text.isNotEmpty ? searchController.text : null,
        lastDocument: _lastDocument,
        pageSize: _pageSize,
      );

      setState(() {
        _products.addAll(result.documents);
        _lastDocument = result.lastDocument;
        _hasMore = result.hasMore;
        _isLoadingMore = false;
      });
    } catch (e) {
      Get.snackbar('خطأ', 'فشل تحميل المزيد: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      setState(() => _isLoadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexible_space: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: Text(widget.groupName, style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => _productDialog(context)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: "بحث في المنتجات...",
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              onChanged: (_) => _loadInitialProducts(),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _products.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _products.length) {
                  return const Center(child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ));
                }
                final p = _products[index];
                final data = p.data() as Map<String, dynamic>;
                final qty = (data['qty'] ?? 0).toDouble();
                final unit = data['unit'] ?? "عدد";
                final priceUSD = (data['priceUSD'] ?? 0.0).toDouble();
                final priceLiraOld = priceUSD * appCtrl.dollarRate.value;
                final priceLiraNew = priceLiraOld / 100;
                final isLow = qty <= 3;
                final updatedAt = data['updatedAt'] as Timestamp?;

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  color: isLow ? Colors.red[50] : null,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(data['name'] ?? "",
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                            if (isLow) const Icon(Icons.warning_amber, color: Colors.red, size: 18),
                            IconButton(
                              icon: const Icon(Icons.edit, color: kPrimaryLight, size: 20),
                              onPressed: () => _productDialog(context, existing: p),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                              onPressed: () => _deleteProduct(p),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isLow ? Colors.red[100] : const Color(0xFFE3F2FD),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            "الكمية: ${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2)} $unit${isLow ? " ⚠️ نفاد قريب" : ""}",
                            style: TextStyle(color: isLow ? Colors.red : kPrimary, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text("💵 ${NumberFormat("#,##0.##").format(priceUSD)} \$", style: const TextStyle(fontSize: 14)),
                        Text("ل.س قديمة: ${NumberFormat("#,##0").format(priceLiraOld)}", style: const TextStyle(fontSize: 13, color: Colors.grey)),
                        Text("ل.س جديدة: ${NumberFormat("#,##0.##").format(priceLiraNew)}", style: const TextStyle(fontSize: 13, color: Colors.grey)),
                        if (updatedAt != null)
                          Text(
                            "آخر تحديث: ${DateFormat('yyyy/MM/dd HH:mm').format(updatedAt.toDate())}",
                            style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _productDialog(BuildContext context, {QueryDocumentSnapshot? existing}) async {
    final data = existing?.data() as Map<String, dynamic>?;
    final nameCtrl = TextEditingController(text: data?['name'] ?? "");
    final qtyCtrl = TextEditingController(text: (data?['qty'] ?? "").toString());
    final priceCtrl = TextEditingController(text: data != null ? (data['priceUSD'] ?? 0).toStringAsFixed(2) : "");
    String unit = data?['unit'] ?? "عدد";
    String currency = "دولار";

    Get.dialog(
      StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(existing == null ? "إضافة منتج" : "تعديل المنتج"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "اسم المنتج")),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: qtyCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: "الكمية"),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: unit,
                      items: ["عدد", "كيلو", "غرام"]
                          .map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) => setD(() => unit = v ?? "عدد"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: priceCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: "السعر"),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: currency,
                      items: ["دولار", "ل.س قديمة", "ل.س جديدة"]
                          .map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                      onChanged: (v) => setD(() => currency = v ?? "دولار"),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.isNotEmpty) {
                  final priceUSD = Utils.toUSD(
                    double.tryParse(priceCtrl.text) ?? 0,
                    currency,
                    appCtrl.dollarRate.value,
                  );
                  final d = {
                    'name': nameCtrl.text.trim(),
                    'qty': double.tryParse(qtyCtrl.text) ?? 0,
                    'unit': unit,
                    'priceUSD': priceUSD,
                    'addedBy': appCtrl.employeeName.value,
                    'updatedAt': FieldValue.serverTimestamp(),
                    'searchTerms': [nameCtrl.text.trim().toLowerCase(), ...nameCtrl.text.trim().split(' ')],
                    'pending_delete': false,
                  };
                  if (existing == null) {
                    await appCtrl.database.addProduct(widget.storeId, widget.groupId, d);
                    Get.snackbar('نجاح', 'تم إضافة المنتج بنجاح',
                        backgroundColor: Colors.green, colorText: Colors.white);
                    Vibration.vibrate(duration: 100);
                  } else {
                    await appCtrl.database.updateProduct(widget.storeId, widget.groupId, existing.id, d);
                    Get.snackbar('نجاح', 'تم تعديل المنتج بنجاح',
                        backgroundColor: Colors.green, colorText: Colors.white);
                    Vibration.vibrate(duration: 100);
                  }
                  Get.back();
                  _loadInitialProducts();
                }
              },
              child: Text(existing == null ? "إضافة" : "حفظ التعديل"),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteProduct(QueryDocumentSnapshot doc) async {
    Get.dialog(
      AlertDialog(
        title: const Text("حذف المنتج"),
        content: Text("هل تريد حذف '${doc['name']}'؟"),
        actions: [
          TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              appCtrl.softDelete(
                'stores/${widget.storeId}/groups/${widget.groupId}/products',
                doc.id,
                appCtrl.employeeName.value ?? 'موظف',
              );
              Get.back();
              _loadInitialProducts();
            },
            child: const Text("حذف"),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PART 13: NEW INVOICE PAGE
// ============================================================================

class NewInvoicePage extends StatefulWidget {
  final String storeId;
  const NewInvoicePage({super.key, required this.storeId});

  @override
  State<NewInvoicePage> createState() => _NewInvoicePageState();
}

class _NewInvoicePageState extends State<NewInvoicePage> {
  final List<CartItem> cart = [];
  final appCtrl = Get.find<AppController>();

  double get totalUSD => cart.fold(0.0, (s, i) => s + i.totalUSD);
  double get totalLiraOld => totalUSD * appCtrl.dollarRate.value;
  double get totalLiraNew => totalLiraOld / 100;

  void _editQtyDialog(CartItem item) {
    String qtyType = item.qtyType;
    final qtyCtrl = TextEditingController(text: item.qty.toStringAsFixed(0));
    final priceCtrl = TextEditingController(text: item.directPriceUSD?.toStringAsFixed(2) ?? "");
    String currency = "دولار";

    Get.dialog(
      StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text("تحديد كمية: ${item.name}"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                children: ["عدد", "كيلو", "غرام", "سعر مباشر"].map((t) {
                  final val = t == "سعر مباشر" ? "سعر_مباشر" : t;
                  return ChoiceChip(
                    label: Text(t),
                    selected: qtyType == val,
                    onSelected: (_) => setD(() => qtyType = val),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              if (qtyType != "سعر_مباشر")
                TextField(
                  controller: qtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: "الكمية (${qtyType == "غرام" ? "غرام" : qtyType == "كيلو" ? "كيلو" : "عدد"})"),
                )
              else
                Column(
                  children: [
                    TextField(
                      controller: priceCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: "السعر"),
                    ),
                    const SizedBox(height: 8),
                    DropdownButton<String>(
                      value: currency,
                      isExpanded: true,
                      items: ["دولار", "ل.س قديمة", "ل.س جديدة"]
                          .map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                      onChanged: (v) => setD(() => currency = v ?? "دولار"),
                    ),
                  ],
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  item.qtyType = qtyType;
                  if (qtyType == "سعر_مباشر") {
                    item.directPriceUSD = Utils.toUSD(
                      double.tryParse(priceCtrl.text) ?? 0,
                      currency,
                      appCtrl.dollarRate.value,
                    );
                    item.qty = 1;
                  } else {
                    item.qty = double.tryParse(qtyCtrl.text) ?? 1;
                    item.directPriceUSD = null;
                  }
                });
                Get.back();
              },
              child: const Text("تأكيد"),
            ),
          ],
        ),
      ),
    );
  }

  void _pickProducts() async {
    final groupsSnap = await FirebaseFirestore.instance
        .collection('stores').doc(widget.storeId).collection('groups')
        .where('pending_delete', isEqualTo: false)
        .get();
    if (!mounted) return;
    String? selectedGroupId = groupsSnap.docs.isNotEmpty ? groupsSnap.docs.first.id : null;

    await Get.bottomSheet(
      StatefulBuilder(
        builder: (c, setSheet) => DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (c, scrollCtrl) => Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                const Text("اختر المنتجات", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: groupsSnap.docs.map((g) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(g['name']),
                        selected: g.id == selectedGroupId,
                        onSelected: (_) => setSheet(() => selectedGroupId = g.id),
                      ),
                    )).toList(),
                  ),
                ),
                const Divider(),
                Expanded(
                  child: selectedGroupId == null
                      ? const Center(child: Text("لا توجد أقسام"))
                      : StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('stores').doc(widget.storeId)
                              .collection('groups').doc(selectedGroupId)
                              .collection('products')
                              .where('pending_delete', isEqualTo: false)
                              .snapshots(),
                          builder: (context, snap) {
                            if (snap.hasError) {
                              return const Center(child: Text("خطأ في تحميل المنتجات", style: TextStyle(color: Colors.red)));
                            }
                            if (snap.connectionState == ConnectionState.waiting) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                            final products = snap.data!.docs;
                            if (products.isEmpty) return const Center(child: Text("لا توجد منتجات"));
                            return ListView.builder(
                              controller: scrollCtrl,
                              itemCount: products.length,
                              itemBuilder: (c, i) {
                                final p = products[i];
                                final price = (p['priceUSD'] ?? 0.0).toDouble();
                                return ListTile(
                                  title: Text(p['name'] ?? ""),
                                  subtitle: Text("${NumberFormat("#,##0.##").format(price)} \$"),
                                  trailing: const Icon(Icons.add_circle, color: kPrimaryLight),
                                  onTap: () {
                                    setState(() {
                                      final ex = cart.where((c) => c.productId == p.id).toList();
                                      if (ex.isNotEmpty) {
                                        ex.first.qty += 1;
                                      } else {
                                        cart.add(CartItem(
                                          productId: p.id,
                                          groupId: selectedGroupId!,
                                          name: p['name'] ?? "",
                                          unit: p['unit'] ?? "عدد",
                                          priceUSD: price,
                                          qty: 1,
                                        ));
                                      }
                                    });
                                  },
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexible_space: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Text("فاتورة جديدة"),
      ),
      body: Column(
        children: [
          Expanded(
            child: cart.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.shopping_cart_outlined, size: 64, color: Colors.blue[200]),
                        const SizedBox(height: 12),
                        const Text("لم تتم إضافة منتجات بعد", style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: cart.length,
                    itemBuilder: (c, i) {
                      final item = cart[i];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                    GestureDetector(
                                      onTap: () => _editQtyDialog(item),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: kPrimaryLight.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          item.qtyType == "سعر_مباشر"
                                              ? "سعر: ${NumberFormat("#,##0.##").format(item.totalUSD)} \$  ✏️"
                                              : "${item.qty.toStringAsFixed(item.qty % 1 == 0 ? 0 : 2)} ${item.qtyType}  ✏️",
                                          style: const TextStyle(fontSize: 12, color: kPrimaryLight),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (item.qtyType != "سعر_مباشر") ...[
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: () => setState(() {
                                    item.qty -= 1;
                                    if (item.qty <= 0) cart.removeAt(i);
                                  }),
                                ),
                                Text(item.qty.toStringAsFixed(item.qty % 1 == 0 ? 0 : 2)),
                                IconButton(
                                  icon: const Icon(Icons.add_circle_outline),
                                  onPressed: () => setState(() => item.qty += 1),
                                ),
                              ],
                              Text(
                                "${NumberFormat("#,##0.##").format(item.totalUSD)} \$",
                                style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.red, size: 18),
                                onPressed: () => setState(() => cart.removeAt(i)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.2), blurRadius: 8, offset: const Offset(0, -2))],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("الإجمالي:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text("${NumberFormat("#,##0.##").format(totalUSD)} \$",
                            style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary, fontSize: 15)),
                        Text("ل.س ق: ${NumberFormat("#,##0").format(totalLiraOld)}",
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        Text("ل.س ج: ${NumberFormat("#,##0.##").format(totalLiraNew)}",
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickProducts,
                        icon: const Icon(Icons.add_shopping_cart),
                        label: const Text("إضافة منتج"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          if (cart.isEmpty) {
                            Get.snackbar('تنبيه', 'أضف منتجات أولاً',
                                backgroundColor: Colors.orange, colorText: Colors.white);
                            return;
                          }
                          Get.to(() => PaymentPage(
                            storeId: widget.storeId,
                            cart: cart,
                            totalUSD: totalUSD,
                          ));
                        },
                        icon: const Icon(Icons.payments),
                        label: const Text("الدفع"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PART 14: PAYMENT PAGE
// ============================================================================

class PaymentPage extends StatelessWidget {
  final String storeId;
  final List<CartItem> cart;
  final double totalUSD;

  const PaymentPage({
    super.key,
    required this.storeId,
    required this.cart,
    required this.totalUSD,
  });

  @override
  Widget build(BuildContext context) {
    final appCtrl = Get.find<AppController>();
    final paidCtrl = TextEditingController(text: totalUSD.toStringAsFixed(2));
    final customerCtrl = TextEditingController();
    final paidCurrency = "دولار".obs;

    return Scaffold(
      appBar: AppBar(
        flexible_space: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Text("الدفع"),
      ),
      body: Obx(() {
        final paidUSD = Utils.toUSD(
          double.tryParse(paidCtrl.text) ?? 0,
          paidCurrency.value,
          appCtrl.dollarRate.value,
        );
        final remaining = (totalUSD - paidUSD).clamp(0.0, double.infinity);
        final isDebt = remaining > kTolerance;

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("إجمالي الفاتورة"),
                          Text("${NumberFormat("#,##0.##").format(totalUSD)} \$",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("ل.س قديمة:"),
                          Text(NumberFormat("#,##0").format(totalUSD * appCtrl.dollarRate.value)),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("ل.س جديدة:"),
                          Text(NumberFormat("#,##0.##").format(totalUSD * appCtrl.dollarRate.value / 100)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: paidCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => {},
                      decoration: const InputDecoration(labelText: "المبلغ المدفوع", border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: paidCurrency.value,
                    items: ["دولار", "ل.س قديمة", "ل.س جديدة"]
                        .map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                    onChanged: (v) => paidCurrency.value = v ?? "دولار",
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (isDebt) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.orange[300]!),
                  ),
                  child: Text(
                    "متبقي: ${NumberFormat("#,##0.##").format(remaining)} \$ — ستُسجَّل في الدين",
                    style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: customerCtrl,
                  onChanged: (_) => {},
                  decoration: const InputDecoration(labelText: "اسم الزبون *", border: OutlineInputBorder()),
                ),
              ],
              const Spacer(),
              ElevatedButton(
                onPressed: appCtrl.isProcessing.value ? null : () {
                  if (isDebt && customerCtrl.text.trim().isEmpty) {
                    Get.snackbar('خطأ', 'يجب إدخال اسم الزبون عند وجود متبقي',
                        backgroundColor: Colors.red, colorText: Colors.white);
                    return;
                  }
                  appCtrl.saveInvoice(
                    storeId,
                    cart,
                    totalUSD,
                    paidUSD,
                    remaining,
                    isDebt,
                    isDebt ? customerCtrl.text.trim() : null,
                    appCtrl.employeeName.value ?? 'موظف',
                    appCtrl.dollarRate.value,
                  ).then((_) {
                    if (!isDebt) {
                      Get.offAll(() => const HomePage());
                    }
                  });
                },
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                child: appCtrl.isProcessing.value
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text("حفظ الفاتورة", style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        );
      }),
    );
  }
}

// ============================================================================
// PART 15: INVOICES PAGE
// ============================================================================

class InvoicesPage extends StatefulWidget {
  final String storeId;
  final bool debtOnly;
  const InvoicesPage({super.key, required this.storeId, required this.debtOnly});

  @override
  State<InvoicesPage> createState() => _InvoicesPageState();
}

class _InvoicesPageState extends State<InvoicesPage> {
  final _pageSize = 20;
  DocumentSnapshot? _lastDocument;
  final List<Invoice> _invoices = [];
  bool _hasMore = true;
  bool _isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();
  final appCtrl = Get.find<AppController>();

  @override
  void initState() {
    super.initState();
    _loadInitialInvoices();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
        _loadMoreInvoices();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialInvoices() async {
    try {
      final result = await appCtrl.invoice.getInvoices(
        widget.storeId,
        isPaid: widget.debtOnly ? false : true,
        pageSize: _pageSize,
      );

      setState(() {
        _invoices.clear();
        _invoices.addAll(result.documents);
        _lastDocument = result.lastDocument;
        _hasMore = result.hasMore;
      });
    } catch (e) {
      Get.snackbar('خطأ', 'فشل تحميل الفواتير: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _loadMoreInvoices() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final result = await appCtrl.invoice.getInvoices(
        widget.storeId,
        isPaid: widget.debtOnly ? false : true,
        lastDocument: _lastDocument,
        pageSize: _pageSize,
      );

      setState(() {
        _invoices.addAll(result.documents);
        _lastDocument = result.lastDocument;
        _hasMore = result.hasMore;
        _isLoadingMore = false;
      });
    } catch (e) {
      Get.snackbar('خطأ', 'فشل تحميل المزيد: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _payDebtDialog(Invoice invoice) async {
    final ctrl = TextEditingController();
    String currency = "دولار";

    Get.dialog(
      StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text("تسديد دين: ${invoice.customerName ?? ''}"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("المتبقي: ${NumberFormat("#,##0.##").format(invoice.remainingUSD)} \$"),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: "المبلغ المدفوع"),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: currency,
                    items: ["دولار", "ل.س قديمة", "ل.س جديدة"]
                        .map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                    onChanged: (v) => setD(() => currency = v ?? "دولار"),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
            ElevatedButton(
              onPressed: () async {
                if (appCtrl.isProcessing.value) {
                  Get.snackbar('تنبيه', 'جاري معالجة عملية أخرى...',
                      backgroundColor: Colors.orange, colorText: Colors.white);
                  return;
                }
                appCtrl.isProcessing.value = true;
                try {
                  double paid = double.tryParse(ctrl.text) ?? 0;
                  double paidUSD = Utils.toUSD(
                    paid,
                    currency,
                    invoice.dollarRateAtSale,
                  );

                  await appCtrl.invoice.updateInvoicePayment(
                    widget.storeId,
                    invoice.id,
                    paidUSD,
                  );

                  Get.back();
                  Get.snackbar(
                    'نجاح',
                    'تم تسجيل الدفعة بنجاح',
                    backgroundColor: Colors.green,
                    colorText: Colors.white,
                  );
                  Vibration.vibrate(duration: 200);
                  _loadInitialInvoices();
                } catch (e) {
                  Get.snackbar('خطأ', 'فشل التسديد: $e',
                      backgroundColor: Colors.red, colorText: Colors.white);
                } finally {
                  appCtrl.isProcessing.value = false;
                }
              },
              child: const Text("تأكيد التسديد"),
            ),
          ],
        ),
      ),
    );
  }

  void _shareInvoice(Invoice invoice) {
    final sb = StringBuffer();
    sb.writeln("🧾 فاتورة ترويقة");
    sb.writeln("━━━━━━━━━━━━━━━━");
    sb.writeln("📅 ${invoice.dateStr}");
    sb.writeln("👤 البائع: ${invoice.employeeName}");
    if (invoice.customerName != null) sb.writeln("🛒 الزبون: ${invoice.customerName}");
    sb.writeln("━━━━━━━━━━━━━━━━");
    for (final item in invoice.items) {
      sb.writeln("• ${item.name} — ${item.qty} ${item.unit} = ${NumberFormat("#,##0.##").format(item.totalUSD)} \$");
    }
    sb.writeln("━━━━━━━━━━━━━━━━");
    sb.writeln("💵 الإجمالي: ${NumberFormat("#,##0.##").format(invoice.totalUSD)} \$");
    sb.writeln("✅ المدفوع: ${NumberFormat("#,##0.##").format(invoice.paidUSD)} \$");
    if (invoice.remainingUSD > 0) {
      sb.writeln("⚠️ المتبقي: ${NumberFormat("#,##0.##").format(invoice.remainingUSD)} \$");
    }
    Share.share(sb.toString(), subject: "فاتورة ترويقة");
  }

  void _deleteInvoice(Invoice invoice) async {
    Get.dialog(
      AlertDialog(
        title: const Text("حذف الفاتورة"),
        content: const Text("هل تريد حذف هذه الفاتورة نهائياً؟"),
        actions: [
          TextButton(onPressed: () => Get.back(), child: const Text("إلغاء")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              if (appCtrl.isProcessing.value) {
                Get.snackbar('تنبيه', 'جاري معالجة عملية أخرى...',
                    backgroundColor: Colors.orange, colorText: Colors.white);
                return;
              }
              appCtrl.isProcessing.value = true;
              try {
                await appCtrl.invoice.permanentDeleteInvoice(
                  widget.storeId,
                  invoice.id,
                );
                Get.back();
                Get.snackbar('نجاح', 'تم حذف الفاتورة',
                    backgroundColor: Colors.green, colorText: Colors.white);
                _loadInitialInvoices();
              } catch (e) {
                Get.snackbar('خطأ', 'فشل الحذف: $e',
                    backgroundColor: Colors.red, colorText: Colors.white);
              } finally {
                appCtrl.isProcessing.value = false;
              }
            },
            child: const Text("حذف"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexible_space: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: Text(widget.debtOnly ? "قسم الدين" : "الفواتير المدفوعة"),
      ),
      body: Column(
        children: [
          if (widget.debtOnly)
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('stores').doc(widget.storeId).collection('invoices')
                  .where('isPaid', isEqualTo: false)
                  .where('pending_delete', isEqualTo: false)
                  .snapshots(),
              builder: (_, snap) {
                if (snap.hasError) {
                  return Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.red[100],
                    child: const Text("خطأ في تحميل الديون", style: TextStyle(color: Colors.red)),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return Container(
                    padding: const EdgeInsets.all(12),
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                if (!snap.hasData) return const SizedBox();
                final total = snap.data!.docs.fold<double>(
                    0, (s, d) => s + ((d.data() as Map<String, dynamic>)['remainingUSD'] ?? 0));
                return Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.red[50],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.warning_amber, color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Text("إجمالي الديون: ${NumberFormat("#,##0.##").format(total)} \$",
                          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                    ],
                  ),
                );
              },
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _invoices.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _invoices.length) {
                  return const Center(child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ));
                }
                final invoice = _invoices[index];
                return Card(
                  color: widget.debtOnly ? Colors.red[50] : null,
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ExpansionTile(
                    title: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "${NumberFormat("#,##0.##").format(invoice.totalUSD)} \$",
                          style: TextStyle(fontWeight: FontWeight.bold,
                              color: widget.debtOnly ? Colors.red[800] : kPrimary),
                        ),
                        if (widget.debtOnly)
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                            icon: const Icon(Icons.payment, size: 14),
                            label: const Text("تسديد", style: TextStyle(fontSize: 12)),
                            onPressed: () => _payDebtDialog(invoice),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      "البائع: ${invoice.employeeName} • ${invoice.dateStr}"
                      "${widget.debtOnly ? '\nالزبون: ${invoice.customerName ?? ''} — متبقي: ${NumberFormat("#,##0.##").format(invoice.remainingUSD)} \$' : ''}",
                      style: TextStyle(color: widget.debtOnly ? Colors.red[700] : Colors.grey[600], fontSize: 12),
                    ),
                    children: [
                      ...invoice.items.map((item) => ListTile(
                        dense: true,
                        title: Text(item.name),
                        trailing: Text(
                          "${item.qty} ${item.unit} = ${NumberFormat("#,##0.##").format(item.totalUSD)}\$",
                          style: const TextStyle(fontSize: 12),
                        ),
                      )),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.share, size: 16),
                              label: const Text("مشاركة", style: TextStyle(fontSize: 12)),
                              onPressed: () => _shareInvoice(invoice),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              icon: const Icon(Icons.delete, color: Colors.red, size: 16),
                              label: const Text("حذف", style: TextStyle(color: Colors.red, fontSize: 12)),
                              onPressed: () => _deleteInvoice(invoice),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PART 16: DAILY REPORT PAGE
// ============================================================================

class DailyReportPage extends StatelessWidget {
  final String storeId;
  const DailyReportPage({super.key, required this.storeId});

  @override
  Widget build(BuildContext context) {
    final appCtrl = Get.find<AppController>();

    return Scaffold(
      appBar: AppBar(
        flexible_space: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Text("التقرير اليومي"),
      ),
      body: FutureBuilder<DailyReport>(
        future: appCtrl.invoice.getDailyReport(storeId, DateTime.now()),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text("خطأ: ${snapshot.error}", style: const TextStyle(color: Colors.red)));
          }
          if (!snapshot.hasData) {
            return const Center(child: Text("لا توجد بيانات لهذا اليوم", style: TextStyle(color: Colors.grey)));
          }

          final report = snapshot.data!;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text("تقرير يوم ${report.date}",
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const Divider(),
                        _reportRow("عدد الفواتير", "${report.invoiceCount}"),
                        _reportRow("عدد الديون", "${report.debtCount}"),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("المبيعات النقدية (مدفوعة):", style: TextStyle(fontWeight: FontWeight.bold)),
                        _reportRow("دولار", "${NumberFormat("#,##0.##").format(report.totalPaidUSD)} \$"),
                        _reportRow("ل.س قديمة", "${NumberFormat("#,##0").format(report.totalPaidLiraOld)}"),
                        _reportRow("ل.س جديدة", "${NumberFormat("#,##0.##").format(report.totalPaidLiraNew)}"),
                      ],
                    ),
                  ),
                ),
                if (report.totalDebtUSD > 0) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("الديون المتبقية:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                          _reportRow("دولار", "${NumberFormat("#,##0.##").format(report.totalDebtUSD)} \$"),
                          _reportRow("ل.س قديمة", "${NumberFormat("#,##0").format(report.totalDebtLiraOld)}"),
                          _reportRow("ل.س جديدة", "${NumberFormat("#,##0.##").format(report.totalDebtLiraNew)}"),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Card(
                  color: Colors.green[50],
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("الإيراد الإجمالي:", style: TextStyle(fontWeight: FontWeight.bold)),
                        Text("${NumberFormat("#,##0.##").format(report.totalRevenueUSD)} \$",
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.green)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => _shareReport(report),
                  icon: const Icon(Icons.share),
                  label: const Text("مشاركة التقرير"),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _reportRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void _shareReport(DailyReport report) {
    final sb = StringBuffer();
    sb.writeln("📊 تقرير ترويقة اليومي");
    sb.writeln("━━━━━━━━━━━━━━━━");
    sb.writeln("📅 التاريخ: ${report.date}");
    sb.writeln("💰 سعر الدولار: ${report.dollarRate} ل.س");
    sb.writeln("━━━━━━━━━━━━━━━━");
    sb.writeln("📋 الفواتير: ${report.invoiceCount}");
    sb.writeln("🛒 الديون: ${report.debtCount}");
    sb.writeln("━━━━━━━━━━━━━━━━");
    sb.writeln("💵 المبيعات النقدية:");
    sb.writeln("  دولار: ${NumberFormat("#,##0.##").format(report.totalPaidUSD)} \$");
    sb.writeln("  ل.س ق: ${NumberFormat("#,##0").format(report.totalPaidLiraOld)}");
    sb.writeln("  ل.س ج: ${NumberFormat("#,##0.##").format(report.totalPaidLiraNew)}");
    if (report.totalDebtUSD > 0) {
      sb.writeln("━━━━━━━━━━━━━━━━");
      sb.writeln("⚠️ الديون المتبقية:");
      sb.writeln("  دولار: ${NumberFormat("#,##0.##").format(report.totalDebtUSD)} \$");
      sb.writeln("  ل.س ق: ${NumberFormat("#,##0").format(report.totalDebtLiraOld)}");
      sb.writeln("  ل.س ج: ${NumberFormat("#,##0.##").format(report.totalDebtLiraNew)}");
    }
    sb.writeln("━━━━━━━━━━━━━━━━");
    sb.writeln("📈 الإيراد الإجمالي: ${NumberFormat("#,##0.##").format(report.totalRevenueUSD)} \$");
    Share.share(sb.toString(), subject: "تقرير ترويقة اليومي");
  }
}
